import CodexBarCore
import Foundation

/// Relays CodexBar's own alerts to a linked phone.
///
/// This is the surface the three tile surfaces cannot cover. A tile answers
/// "where is my quota now" to somebody already looking at their phone; a
/// notification is the only one that goes and finds them, which is the case that
/// matters when the Mac is awake in another room and the user is not.
///
/// Nothing here decides when an alert is worth sending. CodexBar already makes
/// that call — quota warning thresholds, session depletion and restore,
/// predictive pace — and each relay sits beside the local post so the two can
/// never diverge about whether something happened.
///
/// One thing does differ from the Mac copy, deliberately: the account label is
/// dropped. `hidePersonalInfo` already governs what appears on this Mac's own
/// screen, but sending an email address to a gateway is a stronger step than
/// showing it on the machine it came from, and the phone alert reads perfectly
/// well without it.
@MainActor
extension UsageStore {
    /// The link to publish to, or nil when the relay is off or unlinked.
    private var notifyAlertLink: NotifyDeviceLink? {
        guard self.settings.notifyEnabled, self.settings.notifyNotificationsEnabled else { return nil }
        return self.settings.notifyDeviceLink()
    }

    func relayQuotaWarningToNotify(_ event: QuotaWarningEvent, provider: UsageProvider) {
        guard let link = self.notifyAlertLink else { return }
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
            window: event.window,
            threshold: event.threshold,
            currentRemaining: event.currentRemaining,
            accountDisplayName: nil,
            windowDisplayLabel: event.windowDisplayLabel)

        Self.relayNotifyAlert(
            kind: .quotaWarning(remainingPercent: event.currentRemaining),
            providerID: provider.rawValue,
            title: copy.title,
            body: copy.body,
            link: link)
    }

    func relayPredictivePaceWarningToNotify(
        _ event: PredictivePaceWarningEvent,
        provider: UsageProvider,
        now: Date)
    {
        guard let link = self.notifyAlertLink else { return }
        // A copy of the event with the account label removed, so the outbound wording is built
        // without it rather than having it stripped back out of a finished sentence.
        let redacted = PredictivePaceWarningEvent(
            window: event.window,
            etaSeconds: event.etaSeconds,
            accountDisplayName: nil)
        let copy = PredictivePaceWarningNotificationLogic.notificationCopy(
            providerName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
            event: redacted,
            now: now)

        Self.relayNotifyAlert(
            kind: .paceWarning,
            providerID: provider.rawValue,
            title: copy.title,
            body: copy.body,
            link: link)
    }

    func relaySessionQuotaTransitionToNotify(_ transition: SessionQuotaTransition, provider: UsageProvider) {
        guard transition != .none else { return }
        guard let link = self.notifyAlertLink else { return }
        let copy = SessionQuotaNotificationLogic.notificationCopy(
            transition: transition,
            providerName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)

        Self.relayNotifyAlert(
            kind: transition == .depleted ? .quotaDepleted : .quotaRestored,
            providerID: provider.rawValue,
            title: copy.title,
            body: copy.body,
            link: link)
    }
}
