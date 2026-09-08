import CodexBarCore
import Foundation

/// Hooks the Notify! publisher into the usage refresh pipeline.
///
/// The seam is `persistWidgetSnapshot`, which already runs on exactly the "usage
/// changed" edge and already coalesces back-to-back writes. Publishing from
/// there means the phone and the macOS widget are fed from one snapshot, on one
/// clock, and neither can be updated without the other being offered the same
/// numbers.
@MainActor
extension UsageStore {
    /// Offers the newest snapshot to the Notify! driver.
    ///
    /// Starting the driver here rather than at launch keeps a user who never
    /// links a phone from paying for a timer they will never use: nothing runs
    /// until the app has usage worth publishing.
    func notifyUsageDidChange() {
        guard self.settings.notifyEnabled else { return }
        let driver = self.notifyPublishDriver()
        driver.start()
        driver.usageDidChange()
    }

    /// The driver, created once and kept for the life of the store.
    ///
    /// It holds the stored handles and the single in-flight publish, so there
    /// has to be exactly one: two drivers racing over one nil activity id is
    /// precisely how a phone ends up with two Live Activities.
    func notifyPublishDriver() -> NotifyPublishDriver {
        if let existing = self.notifyDriver { return existing }
        let driver = NotifyPublishDriver(
            settings: self.settings,
            snapshotProvider: { [weak self] in self?.lastQueuedWidgetSnapshot },
            pluginNames: { Self.notifyPluginNames() })
        self.notifyDriver = driver
        return driver
    }

    /// Display names for provider instances that are not first-party, which the
    /// Core-side readings builder cannot resolve for itself.
    static func notifyPluginNames() -> [ProviderInstanceID: String] {
        var names: [ProviderInstanceID: String] = [:]
        for plugin in UserProviderPluginRegistry.all {
            names[plugin.manifest.id] = plugin.manifest.name
        }
        return names
    }

    /// Sends one CodexBar alert on to the linked phone.
    ///
    /// Fire-and-forget, and silent on failure by design. This runs beside a
    /// notification the user is already being shown on the Mac, so a gateway
    /// that is unreachable must not turn a quota warning into an error dialog
    /// about a quota warning.
    nonisolated static func relayNotifyAlert(
        kind: NotifyAlertKind,
        providerID: String,
        title: String,
        body: String,
        link: NotifyDeviceLink,
        publisher: any NotifyPublishing = NotifyGatewayClient())
    {
        guard let notification = NotifyAlertBuilder.notification(
            kind: kind,
            providerID: providerID,
            title: title,
            body: body)
        else { return }

        Task.detached(priority: .utility) {
            let log = CodexBarLog.logger(LogCategories.notify)
            do {
                try await publisher.sendNotification(notification, link: link)
                log.debug("relayed an alert", metadata: ["provider": providerID])
            } catch {
                // The surface the user is actually looking at is the Mac notification, which has
                // already been posted. A failure here costs them the phone copy and nothing else.
                log.warning(
                    "could not relay an alert",
                    metadata: ["provider": providerID, "error": String(describing: type(of: error))])
            }
        }
    }
}
