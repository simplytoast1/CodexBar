import Foundation

/// Which CodexBar alert is being relayed to a phone.
///
/// The kind decides one thing only — whether the push is allowed to break
/// through Focus — so it stays a small closed set rather than growing a case per
/// notification CodexBar can post.
public enum NotifyAlertKind: Sendable, Equatable, Hashable {
    /// A session quota ran out. The one alert worth interrupting for.
    case quotaDepleted

    /// A session quota came back. Good news, and good news can wait.
    case quotaRestored

    /// A threshold crossing, carrying how much is left so a warning fired at the
    /// last rung can still be treated as urgent.
    case quotaWarning(remainingPercent: Double?)

    /// A pace warning: on current burn the window will not last.
    case paceWarning

    /// Whether this alert may use the Time Sensitive interruption level.
    ///
    /// Reserved for a quota that has actually run out. A warning at 50%
    /// remaining has not earned the right to break a Focus mode, and a feature
    /// that interrupts too often gets its notifications switched off entirely,
    /// which costs the user the alert that did matter.
    public var isTimeSensitive: Bool {
        switch self {
        case .quotaDepleted:
            true
        case let .quotaWarning(remainingPercent):
            (remainingPercent ?? 100) <= 0
        case .quotaRestored, .paceWarning:
            false
        }
    }
}

/// Turns a CodexBar alert into the notification sent to a linked phone.
///
/// The three tile surfaces answer "where is my quota now" to somebody already
/// looking at their phone. This is the only surface that goes and finds them,
/// and it is the cheapest part of the whole feature because CodexBar already
/// decides when an alert is worth posting: quota warnings, session depletion and
/// restore, and pace warnings all run through `SessionQuotaNotifier`. This adds
/// a second destination to that decision rather than a second decision.
///
/// Pure, so the wording and the grouping are testable without a network.
public enum NotifyAlertBuilder {
    /// Prefix on every thread id, so CodexBar's alerts can never collide with
    /// another tool writing to the same device.
    static let groupPrefix = "codexbar"

    /// Builds the outbound notification, or nil when there is nothing to send.
    ///
    /// - Parameters:
    ///   - kind: what happened, which decides the interruption level.
    ///   - providerID: the provider instance the alert is about, used as the
    ///     thread so one provider's alerts stack instead of forming a column of
    ///     near-identical rows.
    ///   - title: the alert title CodexBar shows on the Mac.
    ///   - body: the alert body CodexBar shows on the Mac.
    ///
    /// The copy is deliberately the Mac's own. A phone alert that said something
    /// different from the notification on the desk would leave the user
    /// reconciling two accounts of one event.
    public static func notification(
        kind: NotifyAlertKind,
        providerID: String,
        title: String,
        body: String) -> NotifyNotification?
    {
        NotifyNotification(
            text: body,
            title: title,
            groupType: self.groupType(providerID: providerID),
            timeSensitive: kind.isTimeSensitive)
    }

    /// The APNs thread for one provider's alerts.
    ///
    /// Per provider rather than per alert kind: a depletion followed by its
    /// restore is one story about one provider, and threading them together is
    /// how the phone tells that story in one row instead of two.
    static func groupType(providerID: String) -> String {
        let cleaned = providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return self.groupPrefix }
        return "\(self.groupPrefix)-\(cleaned)"
    }
}
