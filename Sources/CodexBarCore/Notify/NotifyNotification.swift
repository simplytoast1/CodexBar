import Foundation

/// A one-off push CodexBar sends through `/notify-json`.
///
/// This is the surface the three tile surfaces cannot cover. A tile answers
/// "where is my quota now" to somebody already looking at their phone; a
/// notification is the only one that goes and finds them. CodexBar already
/// decides when that is worth doing — quota warnings, session-quota depletion
/// and restore, pace warnings — so this type carries the result of that decision
/// rather than making one of its own.
public struct NotifyNotification: Sendable, Equatable {
    /// The message body. Required, and the one field the gateway will not
    /// default for you.
    public let text: String

    /// Notification title. The gateway substitutes "Notify!" for a blank one,
    /// which would be a poor label for a CodexBar alert, so CodexBar always
    /// sends its own.
    public let title: String

    /// Thread identifier. Notifications sharing one stack together on the
    /// device, so a provider's repeated warnings collapse into a single thread
    /// instead of a column of near-identical alerts.
    public let groupType: String?

    /// Raises delivery to the Time Sensitive level, which breaks through Focus.
    /// Reserved for a quota that has actually run out: a warning that fires at
    /// 50% remaining has not earned an interruption.
    public let timeSensitive: Bool

    public init?(text: String, title: String, groupType: String? = nil, timeSensitive: Bool = false) {
        guard let text = NotifyLimits.utf8Text(text, maximumBytes: NotifyLimits.notificationTextBytes),
              let title = NotifyLimits.utf8Text(title, maximumBytes: NotifyLimits.notificationTitleBytes)
        else {
            return nil
        }
        self.text = text
        self.title = title
        self.groupType = NotifyLimits.utf8Text(groupType, maximumBytes: NotifyLimits.notificationGroupBytes)
        self.timeSensitive = timeSensitive
    }
}
