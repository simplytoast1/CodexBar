import Foundation

/// How much trouble a quota window is in, and the accent color that says so.
///
/// The thresholds are CodexBar's own, borrowed from `AccountMenuLayoutPlanner`
/// so a window that reads critical in the account menu reads critical on the
/// phone. `depleted` is the extra step the menu does not need: a window at or
/// below zero is not merely critical, it is spent, and the tile earns a
/// distinct color for it because that is the state worth walking back to the
/// desk for.
public enum NotifyQuotaStatus: Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case healthy
    case warning
    case critical
    case depleted

    /// Sorts worst-first when reversed, which is how the payload builder ranks
    /// readings. Declared order is best-to-worst, so `<` means "less urgent".
    public static func < (lhs: NotifyQuotaStatus, rhs: NotifyQuotaStatus) -> Bool {
        lhs.urgency < rhs.urgency
    }

    private var urgency: Int {
        switch self {
        case .healthy: 0
        case .warning: 1
        case .critical: 2
        case .depleted: 3
        }
    }

    /// Classifies a window by how much of it is left.
    ///
    /// A reading with no percentage at all — a credit balance, say — has no
    /// status to derive, so callers pass nil and get `healthy`: a balance meter
    /// should not paint the whole tile red just because it cannot be scored.
    public static func status(remainingPercent: Double?) -> NotifyQuotaStatus {
        guard let remainingPercent, remainingPercent.isFinite else { return .healthy }
        if remainingPercent <= 0 { return .depleted }
        if remainingPercent <= AccountMenuLayoutPlanner.criticalHeadroomPercent { return .critical }
        if remainingPercent <= AccountMenuLayoutPlanner.warningHeadroomPercent { return .warning }
        return .healthy
    }

    /// The accent color sent to Notify!, as the `#RRGGBB` the gateway wants.
    ///
    /// Fixed hex rather than the `NSColor` system palette the Mac draws with,
    /// because the phone has to be told the color and cannot resolve a macOS
    /// dynamic one. These are the light-appearance values of the same system
    /// colors, so the two surfaces stay recognizably in step.
    public var tintHex: String {
        switch self {
        case .healthy: "#34C759"
        case .warning: "#FF9F0A"
        case .critical: "#FF453A"
        case .depleted: "#D70015"
        }
    }
}

/// SF Symbols CodexBar asks Notify! to draw. Named here rather than inline so
/// the tile and the widgets cannot drift apart.
public enum NotifySymbol {
    /// The tile and widget icon. A gauge reads correctly at both sizes and does
    /// not imply a direction of travel the way an arrow would.
    public static let quota = "gauge.with.needle"
}
