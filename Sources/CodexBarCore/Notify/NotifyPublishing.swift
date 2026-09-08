import Foundation

/// Publishing quota state to a linked Notify! device.
///
/// The value-type side of the feature: what CodexBar can ask for, in Core value
/// types, with no idea that HTTP exists. `NotifyGatewayClient` is the
/// implementation, and a test double is the other conformer.
///
/// Every write method takes the handle of the thing it last wrote and returns
/// the handle to store next time. That is what keeps CodexBar from touching a
/// tile or widget the user created for something else: a nil handle means
/// "create your own", and every later write addresses that one by id.
public protocol NotifyPublishing: Sendable {
    /// Starts a Live Activity, or updates the one `activityId` names.
    /// - Returns: the activity id to store for the next update.
    func publishTile(_ tile: NotifyTile, link: NotifyDeviceLink, activityId: String?) async throws -> String

    /// Creates the Lock Screen widget, or updates the one `widgetId` names.
    /// - Returns: the widget id to store for the next update.
    func publishGauge(_ gauge: NotifyGauge, link: NotifyDeviceLink, widgetId: String?) async throws -> String

    /// Creates the Home Screen widget, or updates the one `screenWidgetId` names.
    ///
    /// Takes a `NotifyTile` rather than a shape of its own: the gateway derives
    /// this route's content contract from the Live Activity module, so the two
    /// surfaces genuinely accept one body.
    /// - Returns: the screen widget id to store for the next update.
    func publishScreenTile(
        _ tile: NotifyTile,
        link: NotifyDeviceLink,
        screenWidgetId: String?) async throws -> String

    /// Sends a one-off notification, which is how a quota warning reaches a
    /// phone whose Mac the user has walked away from.
    func sendNotification(_ notification: NotifyNotification, link: NotifyDeviceLink) async throws

    /// Ends the Live Activity, optionally leaving it on the Lock Screen for a
    /// while so the final state can be read.
    func endTile(link: NotifyDeviceLink, activityId: String, keepFor: TimeInterval) async throws

    /// Checks a device id and token pair and describes the device it names.
    /// The only user-triggered call, and rate limited to five a minute by the
    /// gateway, so it belongs behind an explicit button and nothing else.
    func deviceInfo(link: NotifyDeviceLink) async throws -> NotifyDeviceInfo
}
