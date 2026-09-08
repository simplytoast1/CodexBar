import CodexBarCore
import Foundation

/// Keeps a linked phone showing CodexBar's current quota.
///
/// It sits downstream of everything: `UsageStore` builds a `WidgetSnapshot` on
/// every refresh, this driver turns that into a payload, the gate decides
/// whether the payload is worth a request, and the gateway client writes it.
/// Nothing here fetches a quota, and nothing here decides what a quota means.
///
/// Two things wake it. `usageDidChange()` is called when the snapshot moves, so
/// a quota that drops reaches the phone promptly. A one-minute tick covers what
/// state changes cannot: the gate's keep-alive and its per-surface intervals are
/// both functions of elapsed time, and a change the gate held back for arriving
/// too soon has to be offered again once its interval has passed.
@MainActor
final class NotifyPublishDriver {
    /// How long to leave the Home Screen surface alone after the gateway says it
    /// is not serving that route yet. Nothing this Mac does moves that switch,
    /// so asking every minute would be a poll against a decision that has not
    /// changed.
    static let switchedOffSuppression: TimeInterval = 6 * 60 * 60

    /// The tick that makes the time-based rules reachable at all.
    static let tickInterval: TimeInterval = 60

    private let settings: SettingsStore
    private let snapshotProvider: @MainActor () -> WidgetSnapshot?
    private let pluginNames: @MainActor () -> [ProviderInstanceID: String]
    private let publisher: any NotifyPublishing
    private let builder: NotifyPayloadBuilder
    private let gate: NotifyPublishGate
    private let now: @Sendable () -> Date
    private let log = CodexBarLog.logger(LogCategories.notify)

    private var tickTimer: Timer?

    /// The single in-flight publish. Two publishes racing over one nil activity
    /// id is precisely how a phone ends up with two Live Activities, so the
    /// driver holds the only one and everything else waits for it.
    private var publishTask: Task<String?, Never>?

    /// What each surface is currently showing, and when it was last written.
    private var record: NotifyPublishRecord?

    /// Waits the gateway asked for, per surface. A tile's push-to-start backoff
    /// must never silence the widgets, which are polls the gateway does not
    /// ration.
    private var tileSuppressedUntil: Date?
    private var screenTileSuppressedUntil: Date?

    init(
        settings: SettingsStore,
        snapshotProvider: @escaping @MainActor () -> WidgetSnapshot?,
        pluginNames: @escaping @MainActor () -> [ProviderInstanceID: String] = { [:] },
        publisher: any NotifyPublishing = NotifyGatewayClient(),
        builder: NotifyPayloadBuilder = NotifyPayloadBuilder(),
        gate: NotifyPublishGate = NotifyPublishGate(),
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.settings = settings
        self.snapshotProvider = snapshotProvider
        self.pluginNames = pluginNames
        self.publisher = publisher
        self.builder = builder
        self.gate = gate
        self.now = now
    }

    // MARK: - Lifecycle

    /// Starts the tick. Cheap to call when the feature is off: the tick still
    /// runs, and every pass short-circuits at the enabled check, which keeps the
    /// switch itself from needing an observer of its own.
    func start() {
        guard self.tickTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.usageDidChange() }
        }
        // Common mode, so the tick keeps running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.tickTimer = timer
    }

    func stop() {
        self.tickTimer?.invalidate()
        self.tickTimer = nil
        self.publishTask?.cancel()
        self.publishTask = nil
    }

    /// Offers the current state to the gate, and publishes if it says so.
    ///
    /// Called on every usage refresh and on every tick. Doing nothing is the
    /// common case and costs one comparison.
    func usageDidChange() {
        guard self.settings.notifyEnabled else { return }
        guard self.publishTask == nil else { return }

        let payload = self.currentPayload()
        guard !payload.isEmpty else { return }

        let now = self.now()
        let decision = self.withoutSuppressedSurfaces(
            self.gate.decide(payload: payload, since: self.record, now: now),
            now: now)
        guard !decision.publishesNothing else { return }

        self.startPublish(payload: payload, decision: decision, at: now)
    }

    /// Publishes immediately, whatever the gate would have said.
    ///
    /// The settings pane's "Publish Now", and the save that follows entering
    /// credentials. Waiting a quarter of an hour to find out whether a token
    /// works is not an answer, so the record is cleared rather than consulted.
    /// It goes through the driver rather than publishing for itself because the
    /// driver holds the stored handles and the single in-flight publish.
    /// - Returns: nil on success, or the first failure as a message to show.
    func publishNow() async -> String? {
        if let existing = self.publishTask {
            _ = await existing.value
        }

        guard self.settings.notifyDeviceLink() != nil else {
            return NotifyPublishError.notLinked.errorDescription
        }

        let payload = self.currentPayload()
        guard !payload.isEmpty else {
            return L("notify_status_no_usage")
        }

        // A manual publish is also the user's way of clearing a wait they can
        // see no reason for, so the suppressions go with the record.
        self.record = nil
        self.tileSuppressedUntil = nil
        self.screenTileSuppressedUntil = nil

        let decision = NotifyPublishDecision(
            publishesTile: payload.tile != nil,
            publishesGauge: payload.gauge != nil,
            publishesScreenTile: payload.screenTile != nil)
        self.startPublish(payload: payload, decision: decision, at: self.now())
        guard let task = self.publishTask else { return nil }
        return await task.value
    }

    // MARK: - Building

    /// The payload for the current usage state, honoring the user's surface
    /// switches and their choice of what the tile and gauge show.
    private func currentPayload() -> NotifyPayload {
        guard let snapshot = self.snapshotProvider() else { return .empty }
        let readings = NotifyReadingsBuilder.readings(from: snapshot, pluginNames: self.pluginNames())
        return self.builder.payload(
            readings: readings,
            instanceSelection: self.settings.notifyInstanceSelection,
            gaugeSelection: self.settings.notifyGaugeSelection,
            includesTile: self.settings.notifyLiveActivityEnabled,
            includesGauge: self.settings.notifyWidgetEnabled,
            includesScreenTile: self.settings.notifyScreenWidgetEnabled,
            now: self.now())
    }

    private func startPublish(payload: NotifyPayload, decision: NotifyPublishDecision, at now: Date) {
        self.publishTask = Task { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.publishTask = nil }
            return await self.publish(payload: payload, decision: decision, at: now)
        }
    }

    /// Drops any surface the gateway asked us to wait on.
    ///
    /// Applied after the gate rather than inside it, because a wait is a fact
    /// about one device's recent replies and the gate is a pure function of
    /// content and elapsed time.
    private func withoutSuppressedSurfaces(
        _ decision: NotifyPublishDecision,
        now: Date) -> NotifyPublishDecision
    {
        let tileHeld = self.tileSuppressedUntil.map { now < $0 } ?? false
        let screenTileHeld = self.screenTileSuppressedUntil.map { now < $0 } ?? false
        return NotifyPublishDecision(
            publishesTile: decision.publishesTile && !tileHeld,
            publishesGauge: decision.publishesGauge,
            publishesScreenTile: decision.publishesScreenTile && !screenTileHeld)
    }

    /// Drops any surface this particular device cannot show.
    ///
    /// A Mac link and a browser link cannot start a Live Activity, and a group
    /// carries no surface at all. Refusing locally spends no request and, more
    /// to the point, keeps the tick from writing the same refusal into the log
    /// every minute.
    private func withoutUnsupportedSurfaces(
        _ decision: NotifyPublishDecision,
        for link: NotifyDeviceLink) -> NotifyPublishDecision
    {
        NotifyPublishDecision(
            publishesTile: decision.publishesTile && link.supportsLiveActivity,
            publishesGauge: decision.publishesGauge && link.supportsWidget,
            publishesScreenTile: decision.publishesScreenTile && link.supportsScreenWidget)
    }

    // MARK: - Publishing

    /// Which surface a write was for. Each is addressed by its own handle and
    /// fails for its own reasons, so every reaction to a failure has to know
    /// which one it is reacting to.
    private enum Surface {
        case tile
        case gauge
        case screenTile

        var label: String {
            switch self {
            case .tile: "tile"
            case .gauge: "Lock Screen widget"
            case .screenTile: "Home Screen widget"
            }
        }
    }

    /// - Returns: nil when every surface the decision named was written, or the
    ///   first failure as a message fit to show the user.
    private func publish(
        payload: NotifyPayload,
        decision: NotifyPublishDecision,
        at now: Date) async -> String?
    {
        guard let link = self.settings.notifyDeviceLink() else {
            // No device linked is the state the feature ships in, not a failure, so it stays out
            // of the file log.
            self.log.debug("publish skipped: no device linked")
            return NotifyPublishError.notLinked.errorDescription
        }

        let supported = self.withoutUnsupportedSurfaces(decision, for: link)
        guard !supported.publishesNothing else {
            // Debug only, and no message, for the same reason as the unlinked case above. A Mac, a
            // browser or a group takes notifications and nothing else, which is a fact about the
            // user's setup rather than anything going wrong. The place to explain a device's
            // limits is where the user pastes the link, not once a minute forever.
            self.log.debug(
                "publish skipped: the linked device shows none of these surfaces",
                metadata: ["kind": link.kind.displayName])
            return nil
        }

        // Each surface is written independently. A tile the device refuses to start must not cost
        // the user their widgets, which poll happily on a device that cannot do Live Activities.
        var sentTile = false
        var sentGauge = false
        var sentScreenTile = false
        var failures: [String] = []

        if supported.publishesTile, let tile = payload.tile {
            if let failure = await self.sendTile(tile, link: link) {
                failures.append(failure)
            } else {
                sentTile = true
            }
        }
        if supported.publishesGauge, let gauge = payload.gauge {
            if let failure = await self.sendGauge(gauge, link: link) {
                failures.append(failure)
            } else {
                sentGauge = true
            }
        }
        // Last, and with the same content the Live Activity just carried. The Home Screen route
        // takes the tile body unchanged, which is why the builder hands out one value for both
        // rather than two that agree.
        if supported.publishesScreenTile, let screenTile = payload.screenTile {
            if let failure = await self.sendScreenTile(screenTile, link: link) {
                failures.append(failure)
            } else {
                sentScreenTile = true
            }
        }

        self.remember(
            payload: payload,
            sentTile: sentTile,
            sentGauge: sentGauge,
            sentScreenTile: sentScreenTile,
            at: now)
        return failures.first
    }

    /// - Returns: nil when the tile was written, or the failure as a message.
    private func sendTile(_ tile: NotifyTile, link: NotifyDeviceLink) async -> String? {
        do {
            let activityID = try await self.publisher.publishTile(
                tile,
                link: link,
                activityId: self.settings.notifyActivityID)
            self.store(activityID: activityID, for: link)
            return nil
        } catch NotifyPublishError.tileGone {
            // The handle names a tile the user dismissed, which can never be updated again. Forget
            // it and start one fresh, exactly once: a retry loop here is a retry loop against the
            // gateway.
            self.log.info("tile was dismissed on the device, starting a new one")
            self.settings.notifyActivityID = nil
            return await self.restartTile(tile, link: link)
        } catch {
            self.report(error, surface: .tile)
            return self.message(for: error)
        }
    }

    private func restartTile(_ tile: NotifyTile, link: NotifyDeviceLink) async -> String? {
        do {
            let activityID = try await self.publisher.publishTile(tile, link: link, activityId: nil)
            self.store(activityID: activityID, for: link)
            return nil
        } catch {
            self.report(error, surface: .tile)
            return self.message(for: error)
        }
    }

    private func sendGauge(_ gauge: NotifyGauge, link: NotifyDeviceLink) async -> String? {
        do {
            let widgetID = try await self.publisher.publishGauge(
                gauge,
                link: link,
                widgetId: self.settings.notifyWidgetID)
            self.store(widgetID: widgetID, for: link)
            return nil
        } catch {
            self.report(error, surface: .gauge)
            return self.message(for: error)
        }
    }

    private func sendScreenTile(_ tile: NotifyTile, link: NotifyDeviceLink) async -> String? {
        do {
            let screenWidgetID = try await self.publisher.publishScreenTile(
                tile,
                link: link,
                screenWidgetId: self.settings.notifyScreenWidgetID)
            self.store(screenWidgetID: screenWidgetID, for: link)
            return nil
        } catch {
            self.report(error, surface: .screenTile)
            return self.message(for: error)
        }
    }

    // MARK: - Handles

    /// Stores a handle only while it still belongs to the saved link.
    ///
    /// A publish holds the link it started with, and a request can be in flight
    /// for as long as the timeout allows. The user can remove or replace the
    /// link in that window, and the reply, when it lands, carries a handle for a
    /// device that is no longer the one on file. Writing it would leave the next
    /// link inheriting a stranger's tile id, which costs a wasted request and a
    /// 403 before it heals. Comparing first is cheaper than healing.
    private func store(activityID: String, for link: NotifyDeviceLink) {
        guard self.settings.notifyDeviceLink() == link else {
            self.log.info("link changed while publishing, discarding the tile handle it returned")
            return
        }
        self.settings.notifyActivityID = activityID
    }

    private func store(widgetID: String, for link: NotifyDeviceLink) {
        guard self.settings.notifyDeviceLink() == link else {
            self.log.info("link changed while publishing, discarding the widget handle it returned")
            return
        }
        self.settings.notifyWidgetID = widgetID
    }

    private func store(screenWidgetID: String, for link: NotifyDeviceLink) {
        guard self.settings.notifyDeviceLink() == link else {
            self.log.info("link changed while publishing, discarding the screen widget handle it returned")
            return
        }
        self.settings.notifyScreenWidgetID = screenWidgetID
    }

    /// Drops the stored handle for one surface, so the next publish creates its
    /// own replacement rather than writing to something that is gone.
    private func forget(_ surface: Surface) {
        switch surface {
        case .tile: self.settings.notifyActivityID = nil
        case .gauge: self.settings.notifyWidgetID = nil
        case .screenTile: self.settings.notifyScreenWidgetID = nil
        }
    }

    // MARK: - Bookkeeping

    private func remember(
        payload: NotifyPayload,
        sentTile: Bool,
        sentGauge: Bool,
        sentScreenTile: Bool,
        at now: Date)
    {
        let sent = NotifyPublishDecision(
            publishesTile: sentTile,
            publishesGauge: sentGauge,
            publishesScreenTile: sentScreenTile)
        self.record = (self.record ?? NotifyPublishRecord(payload: .empty))
            .updated(with: payload, decision: sent, at: now)
    }

    private func message(for error: any Error) -> String {
        (error as? NotifyPublishError)?.errorDescription ?? error.localizedDescription
    }

    /// Turns a failed write into whatever state change it implies, and one log
    /// line. Never a device id and never a token: both are secrets, and the
    /// gateway answers a bad token and an unknown device identically anyway, so
    /// naming the id would not help anyone read the log.
    ///
    /// Every reaction is scoped to the surface that actually failed. The gateway
    /// answers a missing token, a wrong token, an unknown id and somebody else's
    /// id with one identical 403, so a 403 is not evidence the credentials are
    /// bad. The likeliest cause by far is the ordinary one: the user deleted
    /// that one tile or that one widget in the Notify! app, and the handle now
    /// names something that is gone.
    private func report(_ error: any Error, surface: Surface) {
        guard let error = error as? NotifyPublishError else {
            // An error from outside this feature's own vocabulary, so its text is not known to be
            // free of a URL, and every URL here carries the device token. The type is enough to
            // find the cause and cannot quote anything.
            self.log.error(
                "publish failed",
                metadata: ["surface": surface.label, "error": String(describing: type(of: error))])
            return
        }

        switch error {
        case .rejectedCredentials:
            // Forget only the handle that was refused, and let the next publish create a
            // replacement for it. Clearing the other surfaces' handles as well would abandon
            // something alive and being written to perfectly happily, and the next write, having
            // no handle for it, would create a second one beside it.
            self.forget(surface)
            self.log.error(
                "the stored handle was refused, forgetting it so the next publish creates a new one",
                metadata: ["surface": surface.label])

        case let .backoff(retryAfter, openingTheAppMayHelp):
            // Push-to-start backoff is a Live Activity rule. Both widgets are polls the gateway
            // does not ration, so a tile's wait must never silence either of them.
            guard surface == .tile else {
                self.log.warning(
                    "publish was rate limited, retrying on a later tick",
                    metadata: ["surface": surface.label])
                return
            }
            self.tileSuppressedUntil = self.now().addingTimeInterval(retryAfter)
            self.log.warning(
                "holding off Live Activity starts",
                metadata: [
                    "seconds": String(Int(retryAfter.rounded())),
                    "openingTheAppMayHelp": String(openingTheAppMayHelp),
                ])

        case .surfaceSwitchedOff:
            // Not a failure, which is why it is the only branch here that logs at info. Home
            // Screen widgets ship behind a server-side kill switch, so a CodexBar that can write
            // them meets a gateway that is not serving them yet, and the remedy is entirely
            // Notify!'s. Backing off for hours rather than retrying every tick, because nothing
            // this app does moves that switch.
            guard surface == .screenTile else {
                // The 503 belongs to the Home Screen route. Reaching here means the gateway
                // switched off a surface this code did not expect to be switchable, so that write
                // is skipped and offered again on a later tick.
                self.log.info(
                    "this surface is switched off at the moment, retrying on a later tick",
                    metadata: ["surface": surface.label])
                return
            }
            self.screenTileSuppressedUntil = self.now().addingTimeInterval(Self.switchedOffSuppression)
            self.log.info("Home Screen widgets are not being served yet, pausing that surface for six hours")

        case let .deliveryUnconfirmed(activityID):
            // Apple never answered, so a tile may already exist. Keeping the id the gateway did
            // hand back means the next update addresses that tile instead of starting a second one
            // beside it.
            if let activityID, !activityID.isEmpty {
                self.settings.notifyActivityID = activityID
            }
            self.log.warning("could not confirm the tile started, updating it on the next tick")

        case .transportFailed:
            // The one error whose text is not CodexBar's own. It carries a URLError's localized
            // description, which is free to quote the URL it failed on, and every URL in this
            // feature has the device token in its query string. The client already refuses to
            // write that down; logging it here through the error's description would put it in the
            // same file by the back door. The pane still shows it, which is not written down.
            self.log.error("publish could not reach the gateway", metadata: ["surface": surface.label])

        default:
            self.log.error(
                "publish failed",
                metadata: ["surface": surface.label, "error": error.localizedDescription])
        }
    }
}
