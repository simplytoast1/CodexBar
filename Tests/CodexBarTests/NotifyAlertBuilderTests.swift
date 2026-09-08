import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for the relay that sends a CodexBar alert on to a linked phone:
/// which alerts may break through Focus, and how they thread on the device.
struct NotifyAlertBuilderTests {
    // MARK: - Interruption level

    @Test
    func `only a spent quota may break through Focus`() {
        #expect(NotifyAlertKind.quotaDepleted.isTimeSensitive)
        #expect(NotifyAlertKind.quotaWarning(remainingPercent: 0).isTimeSensitive)
        #expect(NotifyAlertKind.quotaWarning(remainingPercent: -3).isTimeSensitive)
    }

    @Test
    func `a warning with headroom left has not earned an interruption`() {
        // A feature that interrupts too often gets its notifications switched off entirely, which
        // costs the user the alert that did matter.
        #expect(NotifyAlertKind.quotaWarning(remainingPercent: 50).isTimeSensitive == false)
        #expect(NotifyAlertKind.quotaWarning(remainingPercent: 1).isTimeSensitive == false)
        #expect(NotifyAlertKind.quotaWarning(remainingPercent: nil).isTimeSensitive == false)
        #expect(NotifyAlertKind.paceWarning.isTimeSensitive == false)
        #expect(NotifyAlertKind.quotaRestored.isTimeSensitive == false)
    }

    // MARK: - Threading

    @Test
    func `threads one provider's alerts together`() {
        // A depletion followed by its restore is one story about one provider.
        #expect(NotifyAlertBuilder.groupType(providerID: "codex") == "codexbar-codex")
        #expect(NotifyAlertBuilder.groupType(providerID: "  Claude  ") == "codexbar-claude")
    }

    @Test
    func `never collides with another tool writing to the same device`() {
        #expect(NotifyAlertBuilder.groupType(providerID: "").hasPrefix("codexbar"))
        #expect(NotifyAlertBuilder.groupType(providerID: "codex").hasPrefix("codexbar-"))
    }

    // MARK: - Copy

    @Test
    func `sends the same words the Mac shows`() {
        // A phone alert that said something different from the notification on the desk would
        // leave the user reconciling two accounts of one event.
        let notification = NotifyAlertBuilder.notification(
            kind: .quotaWarning(remainingPercent: 20),
            providerID: "codex",
            title: "Codex session quota low",
            body: "20% left, resets in 2h 14m")

        #expect(notification?.title == "Codex session quota low")
        #expect(notification?.text == "20% left, resets in 2h 14m")
        #expect(notification?.groupType == "codexbar-codex")
        #expect(notification?.timeSensitive == false)
    }

    @Test
    func `marks a depletion time sensitive`() {
        let notification = NotifyAlertBuilder.notification(
            kind: .quotaDepleted,
            providerID: "codex",
            title: "Codex quota used up",
            body: "Resets in 2h 14m")
        #expect(notification?.timeSensitive == true)
    }

    @Test
    func `refuses to build a notification with nothing to say`() {
        #expect(NotifyAlertBuilder.notification(
            kind: .quotaDepleted, providerID: "codex", title: "Codex", body: "   ") == nil)
        #expect(NotifyAlertBuilder.notification(
            kind: .quotaDepleted, providerID: "codex", title: "  ", body: "Resets soon") == nil)
    }
}
