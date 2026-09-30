import Foundation

/// One provider instance's quota window, flattened for the payload builder.
///
/// CodexBar's own usage state is main-actor isolated and shaped per provider,
/// so something has to reduce it to `Sendable` values before the builder can
/// sort and label them. `WidgetSnapshot` is already that reduction for the macOS
/// widget, and `NotifyQuotaReading` is built from it rather than from a second
/// pass over the providers, so the phone and the desktop widget cannot end up
/// describing the same quota differently.
public struct NotifyQuotaReading: Sendable, Equatable, Hashable {
    /// Which provider instance this window belongs to.
    public let instanceID: ProviderInstanceID

    /// Display name for the provider, e.g. "Codex". Used for a metric label
    /// when more than one provider is on show.
    public let providerName: String

    /// Stable key for this window inside its provider instance, e.g. "primary"
    /// or "row:weekly". Persisted as half of the gauge selection, so it has to
    /// survive a relaunch and must not be derived from a display string.
    public let quotaKey: String

    /// Short window label, e.g. "5h" or "7d".
    public let windowLabel: String

    /// How much of the window is left, 0...100. Nil for a meter with no
    /// percentage at all, such as a credit balance.
    public let remainingPercent: Double?

    /// When the window rolls over, when the provider says.
    public let resetsAt: Date?

    /// Pre-formatted balance for a money-based meter, e.g. "$42.10". Nil for a
    /// percentage window. Formatted here rather than on the phone, which has no
    /// idea what currency the provider bills in.
    public let balanceText: String?

    public init(
        instanceID: ProviderInstanceID,
        providerName: String,
        quotaKey: String,
        windowLabel: String,
        remainingPercent: Double?,
        resetsAt: Date? = nil,
        balanceText: String? = nil)
    {
        self.instanceID = instanceID
        self.providerName = providerName
        self.quotaKey = quotaKey
        self.windowLabel = windowLabel
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.balanceText = balanceText
    }

    /// How much trouble this window is in.
    public var status: NotifyQuotaStatus {
        NotifyQuotaStatus.status(remainingPercent: self.remainingPercent)
    }

    /// Whether this reading can drive a progress bar. A balance meter cannot,
    /// which is why the tile falls through to the worst window that can.
    public var hasProgress: Bool {
        self.remainingPercent != nil
    }
}

/// Which quota the Lock Screen gauge shows.
///
/// Both fields empty means "whichever quota needs attention most", which is the
/// useful default for a glance and the only sane behavior before the user has
/// chosen anything.
public struct NotifyGaugeSelection: Sendable, Equatable, Hashable {
    public let instanceID: String
    public let quotaKey: String

    public init(instanceID: String = "", quotaKey: String = "") {
        self.instanceID = instanceID
        self.quotaKey = quotaKey
    }

    /// Whether the selection names a specific window.
    public var isAutomatic: Bool {
        self.instanceID.isEmpty || self.quotaKey.isEmpty
    }

    /// Whether this selection names the given reading.
    public func matches(_ reading: NotifyQuotaReading) -> Bool {
        !self.isAutomatic
            && reading.instanceID.rawValue == self.instanceID
            && reading.quotaKey == self.quotaKey
    }

    public static let automatic = NotifyGaugeSelection()
}

/// Which provider instances are allowed to fill the tile's metrics row.
///
/// This is the one piece ClaudeBar did not need. The gateway caps a metrics row
/// at six cells, and CodexBar routinely tracks far more than six windows across
/// its providers and their accounts, so "worst six wins" alone would produce a
/// row whose membership churns every refresh. An explicit allow-list keeps the
/// same six windows in the same order day after day, which is what makes a
/// glance worth anything.
///
/// Empty means automatic: every instance is eligible and severity decides.
public struct NotifyInstanceSelection: Sendable, Equatable, Hashable {
    public let instanceIDs: [String]

    public init(instanceIDs: [String] = []) {
        // Order is the user's, but duplicates would silently eat a metrics slot.
        var seen = Set<String>()
        self.instanceIDs = instanceIDs.filter { seen.insert($0).inserted }
    }

    public var isAutomatic: Bool {
        self.instanceIDs.isEmpty
    }

    /// Whether a reading's provider instance may appear on the tile.
    public func admits(_ reading: NotifyQuotaReading) -> Bool {
        self.isAutomatic || self.instanceIDs.contains(reading.instanceID.rawValue)
    }

    /// Where a reading's instance sits in the user's order, for a stable sort.
    /// Automatic selection returns nil, leaving severity in charge.
    public func rank(of reading: NotifyQuotaReading) -> Int? {
        guard !self.isAutomatic else { return nil }
        return self.instanceIDs.firstIndex(of: reading.instanceID.rawValue)
    }

    public static let automatic = NotifyInstanceSelection()
}

/// Everything CodexBar wants standing on the phone right now.
///
/// `Equatable` on purpose: the publish gate drops a payload identical to the
/// last one, so an unchanged quota costs no HTTP at all. A nil surface means the
/// user turned that surface off, and the driver leaves it alone rather than
/// clearing it.
public struct NotifyPayload: Sendable, Equatable {
    public let tile: NotifyTile?
    public let gauge: NotifyGauge?

    /// The Home Screen tile. Deliberately the same `NotifyTile` the Live
    /// Activity carries, because the gateway derives both content sets from one
    /// module: any body that starts a Live Activity is a valid screen widget
    /// body. It is a separate property rather than a reuse of `tile` because the
    /// two surfaces are switched on and off independently and published on
    /// different clocks, so a payload has to be able to carry one without the
    /// other.
    public let screenTile: NotifyTile?

    public init(tile: NotifyTile? = nil, gauge: NotifyGauge? = nil, screenTile: NotifyTile? = nil) {
        self.tile = tile
        self.gauge = gauge
        self.screenTile = screenTile
    }

    /// Nothing to say, so nothing to send.
    public var isEmpty: Bool {
        self.tile == nil && self.gauge == nil && self.screenTile == nil
    }

    public static let empty = NotifyPayload()
}
