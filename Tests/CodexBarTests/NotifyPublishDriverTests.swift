import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Coverage for the driver: when it writes, which handle each surface is
/// addressed by, and what it does with each way a write can fail.
@MainActor
struct NotifyPublishDriverTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    /// Records what was asked of it and answers with whatever the test set up.
    private final class StubPublisher: NotifyPublishing, @unchecked Sendable {
        struct Call: Equatable {
            let surface: String
            let handle: String?
        }

        var calls: [Call] = []
        var notifications: [NotifyNotification] = []
        var tileResult: Result<String, NotifyPublishError> = .success("LA123456")
        var gaugeResult: Result<String, NotifyPublishError> = .success("WG123456")
        var screenTileResult: Result<String, NotifyPublishError> = .success("SW123456")

        /// Answers the first tile write differently from any retry, which is how
        /// the dismissed-tile restart is exercised.
        var firstTileResult: Result<String, NotifyPublishError>?

        var tileCalls: [Call] {
            self.calls.filter { $0.surface == "tile" }
        }

        func publishTile(_: NotifyTile, link _: NotifyDeviceLink, activityId: String?) async throws -> String {
            self.calls.append(Call(surface: "tile", handle: activityId))
            if let first = self.firstTileResult {
                self.firstTileResult = nil
                return try first.get()
            }
            return try self.tileResult.get()
        }

        func publishGauge(_: NotifyGauge, link _: NotifyDeviceLink, widgetId: String?) async throws -> String {
            self.calls.append(Call(surface: "gauge", handle: widgetId))
            return try self.gaugeResult.get()
        }

        func publishScreenTile(
            _: NotifyTile,
            link _: NotifyDeviceLink,
            screenWidgetId: String?) async throws -> String
        {
            self.calls.append(Call(surface: "screenTile", handle: screenWidgetId))
            return try self.screenTileResult.get()
        }

        func sendNotification(_ notification: NotifyNotification, link _: NotifyDeviceLink) async throws {
            self.notifications.append(notification)
        }

        func endTile(link _: NotifyDeviceLink, activityId _: String, keepFor _: TimeInterval) async throws {}

        func deviceInfo(link: NotifyDeviceLink) async throws -> NotifyDeviceInfo {
            NotifyDeviceInfo(deviceId: link.deviceId, name: "Apollo", platform: "iOS")
        }
    }

    // MARK: - Publishing

    @Test
    func `writes every surface on the first pass`() async {
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)

        _ = await driver.publishNow()

        #expect(Set(publisher.calls.map(\.surface)) == ["tile", "gauge", "screenTile"])
        // A first write carries no handle, which is what tells the gateway to create its own
        // rather than upserting over whatever the user last started from some other script.
        #expect(publisher.calls.allSatisfy { $0.handle == nil })
        #expect(settings.notifyActivityID == "LA123456")
        #expect(settings.notifyWidgetID == "WG123456")
        #expect(settings.notifyScreenWidgetID == "SW123456")
    }

    @Test
    func `addresses each surface by its own handle after the first write`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher)

        _ = await driver.publishNow()
        publisher.calls.removeAll()
        _ = await driver.publishNow()

        #expect(publisher.calls.contains(StubPublisher.Call(surface: "tile", handle: "LA123456")))
        #expect(publisher.calls.contains(StubPublisher.Call(surface: "gauge", handle: "WG123456")))
        #expect(publisher.calls.contains(StubPublisher.Call(surface: "screenTile", handle: "SW123456")))
    }

    @Test
    func `writes nothing while the feature is switched off`() {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher, enabled: false)

        driver.usageDidChange()

        #expect(publisher.calls.isEmpty)
    }

    @Test
    func `writes nothing when there is no usage yet`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher, snapshot: nil)

        let failure = await driver.publishNow()

        #expect(publisher.calls.isEmpty)
        #expect(failure != nil)
    }

    @Test
    func `skips a surface the user switched off`() async {
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)
        settings.notifyLiveActivityEnabled = false
        settings.notifyScreenWidgetEnabled = false

        _ = await driver.publishNow()

        #expect(publisher.calls.map(\.surface) == ["gauge"])
    }

    @Test
    func `a Mac link keeps its widgets even though it can show no tile`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(
            suite: #function,
            deviceID: "MC12345678901234",
            publisher: publisher)

        _ = await driver.publishNow()

        // Refused locally, so the request is never spent and the user never reads a 400 as a
        // CodexBar failure.
        #expect(publisher.calls.contains { $0.surface == "tile" } == false)
        #expect(Set(publisher.calls.map(\.surface)) == ["gauge", "screenTile"])
    }

    @Test
    func `a group link carries nothing at all`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, deviceID: "GRP12345", publisher: publisher)

        _ = await driver.publishNow()

        #expect(publisher.calls.isEmpty)
    }

    // MARK: - The gate

    @Test
    func `holds an unchanged payload back on the next tick`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher)

        _ = await driver.publishNow()
        publisher.calls.removeAll()
        driver.usageDidChange()

        #expect(publisher.calls.isEmpty)
    }

    @Test
    func `publish now ignores the gate entirely`() async {
        // Waiting a quarter of an hour to find out whether a token works is not an answer.
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher)

        _ = await driver.publishNow()
        publisher.calls.removeAll()
        _ = await driver.publishNow()

        #expect(publisher.calls.isEmpty == false)
    }

    // MARK: - Failures

    @Test
    func `starts a fresh tile once when the old one was dismissed`() async {
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)
        _ = await driver.publishNow()
        publisher.calls.removeAll()

        publisher.firstTileResult = .failure(.tileGone)
        _ = await driver.publishNow()

        // The dismissed handle, then a start with none: exactly one retry, because a retry loop
        // here is a retry loop against the gateway.
        #expect(publisher.tileCalls.map(\.handle) == ["LA123456", nil])
        #expect(settings.notifyActivityID == "LA123456")
    }

    @Test
    func `forgets only the handle that was refused`() async {
        // The gateway answers a missing token, a wrong token, an unknown id and somebody else's id
        // identically, so a 403 is not evidence the credentials are bad. Clearing the other
        // surfaces' handles would abandon something alive and put a duplicate beside it.
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)
        _ = await driver.publishNow()

        publisher.tileResult = .failure(.rejectedCredentials)
        _ = await driver.publishNow()

        #expect(settings.notifyActivityID == nil)
        #expect(settings.notifyWidgetID == "WG123456")
        #expect(settings.notifyScreenWidgetID == "SW123456")
    }

    @Test
    func `keeps the activity id when Apple never answered`() async {
        // A tile may already exist, so starting again could leave two.
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)
        publisher.tileResult = .failure(.deliveryUnconfirmed(activityId: "LA999999"))

        _ = await driver.publishNow()

        #expect(settings.notifyActivityID == "LA999999")
    }

    @Test
    func `a failed tile never costs the user their widgets`() async {
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)
        publisher.tileResult = .failure(.backoff(retryAfter: 1800, openingTheAppMayHelp: true))

        let failure = await driver.publishNow()

        #expect(failure != nil)
        #expect(settings.notifyWidgetID == "WG123456")
        #expect(settings.notifyScreenWidgetID == "SW123456")
    }

    @Test
    func `a Home Screen kill switch leaves the other two alone`() async {
        let publisher = StubPublisher()
        let (driver, settings) = Self.makeDriver(suite: #function, publisher: publisher)
        publisher.screenTileResult = .failure(.surfaceSwitchedOff(""))

        _ = await driver.publishNow()

        #expect(settings.notifyActivityID == "LA123456")
        #expect(settings.notifyWidgetID == "WG123456")
        #expect(settings.notifyScreenWidgetID == nil)
    }

    @Test
    func `reports the failure as a message the pane can show`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher)
        publisher.tileResult = .failure(.rejectedCredentials)

        let failure = await driver.publishNow()

        #expect(failure == NotifyPublishError.rejectedCredentials.errorDescription)
    }

    @Test
    func `says so when nothing is linked`() async {
        let publisher = StubPublisher()
        let (driver, _) = Self.makeDriver(suite: #function, publisher: publisher, token: nil)

        let failure = await driver.publishNow()

        #expect(failure == NotifyPublishError.notLinked.errorDescription)
        #expect(publisher.calls.isEmpty)
    }

    // MARK: - Fixtures

    private static func snapshot(remaining: Double = 42) -> WidgetSnapshot {
        let window = RateWindow(
            usedPercent: 100 - remaining,
            windowMinutes: 300,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: UsageProvider.codex,
            updatedAt: Self.now,
            primary: window,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "session",
                    title: "5h",
                    percentLeft: remaining,
                    window: window),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        return WidgetSnapshot(
            entries: [entry],
            enabledProviders: [UsageProvider.codex.instanceID],
            usageBarsShowUsed: false,
            generatedAt: Self.now)
    }

    private static func makeDriver(
        suite: String,
        deviceID: String = "ABC12345",
        token: String? = "secret",
        publisher: StubPublisher,
        snapshot: WidgetSnapshot? = NotifyPublishDriverTests.snapshot(),
        enabled: Bool = true) -> (NotifyPublishDriver, SettingsStore)
    {
        let settings = testSettingsStore(
            suiteName: suite,
            notifyTokenStore: InMemoryNotifyTokenStore(token: token))
        settings.notifyDeviceID = deviceID
        settings.notifyEnabled = enabled

        let driver = NotifyPublishDriver(
            settings: settings,
            snapshotProvider: { snapshot },
            publisher: publisher,
            now: { Self.now })
        return (driver, settings)
    }
}
