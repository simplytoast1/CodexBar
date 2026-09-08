import Foundation

/// Turns quota readings into the tile and gauge CodexBar publishes to Notify!.
///
/// This is the whole decision layer of the feature and it is deliberately pure:
/// no clock beyond the `now` it is handed, no network, no settings lookups. What
/// to show, in what order, in what words, and in what color is decided here so
/// it can be tested as plain state assertions.
///
/// The rules:
/// 1. The user's chosen providers lead. CodexBar tracks far more than the six
///    windows a metrics row can hold, so when the user has named the instances
///    they care about, those fill the row in their own order and everything else
///    is dropped. Without a choice, severity decides.
/// 2. Within that, the worst quota leads. Readings sort by status severity, then
///    by how little is left, so the number that needs attention is the headline
///    and the tile takes its color and progress bar from it.
/// 3. Labels drop the provider name when every reading comes from the same
///    provider, so a single-provider tile reads "5h  7d" rather than
///    "Codex 5h  Codex 7d".
/// 4. Percentages are remaining, not used. Every CodexBar surface reads that
///    way, and a full bar meaning a full quota is the only intuitive mapping a
///    gauge has.
/// 5. Ordering is total. Two payloads built from the same readings must compare
///    equal, or the publish gate would see a change every time and republish
///    forever.
public struct NotifyPayloadBuilder: Sendable {
    /// The tile and widget title. All three surfaces name the sending app rather
    /// than the current quota: the gateway treats a title as an identity, and a
    /// widget that renamed itself whenever the headline moved would be
    /// unrecognizable in the phone's widget picker.
    public static let defaultTitle = "CodexBar"

    private let title: String

    public init(title: String = NotifyPayloadBuilder.defaultTitle) {
        self.title = title
    }

    public func payload(
        readings: [NotifyQuotaReading],
        instanceSelection: NotifyInstanceSelection = .automatic,
        gaugeSelection: NotifyGaugeSelection = .automatic,
        includesTile: Bool = true,
        includesGauge: Bool = true,
        includesScreenTile: Bool = true,
        now: Date = Date()) -> NotifyPayload
    {
        let ordered = Self.ordered(readings, selection: instanceSelection)
        guard let headline = ordered.first else { return .empty }

        // The Live Activity and the Home Screen tile are built once and shared. The gateway takes
        // the same body on both routes, so building them twice could only produce two things that
        // were supposed to be identical and one day were not.
        let tile = (includesTile || includesScreenTile)
            ? self.tile(ordered: ordered, headline: headline, now: now)
            : nil

        return NotifyPayload(
            tile: includesTile ? tile : nil,
            gauge: includesGauge
                ? self.gauge(ordered: ordered, headline: headline, selection: gaugeSelection, now: now)
                : nil,
            screenTile: includesScreenTile ? tile : nil)
    }

    // MARK: - Ordering

    /// The readings a tile may show, worst first, and fully deterministic.
    ///
    /// The instance selection is applied as a filter and then as the primary
    /// sort key, which is the whole point of having one: a user who put Codex
    /// before Claude wants Codex first on Monday and on Friday, whether or not
    /// Claude happens to be redder today. Severity still orders the windows
    /// inside each instance, so the worst window of the leading provider is
    /// still the headline.
    static func ordered(
        _ readings: [NotifyQuotaReading],
        selection: NotifyInstanceSelection = .automatic) -> [NotifyQuotaReading]
    {
        readings
            .filter { selection.admits($0) }
            .sorted { left, right in
                if let leftRank = selection.rank(of: left), let rightRank = selection.rank(of: right),
                   leftRank != rightRank
                {
                    return leftRank < rightRank
                }
                if left.status != right.status { return left.status > right.status }

                // A reading with no percentage sorts after every reading that has one. It cannot
                // be scored, so putting it above a genuinely critical window would bury the thing
                // the user needs to see.
                switch (left.remainingPercent, right.remainingPercent) {
                case let (leftPercent?, rightPercent?) where leftPercent != rightPercent:
                    return leftPercent < rightPercent
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                default:
                    break
                }

                if left.providerName != right.providerName { return left.providerName < right.providerName }
                if left.quotaKey != right.quotaKey { return left.quotaKey < right.quotaKey }
                // The last tie break, and the one that makes the comparator total. Display names
                // are not unique — two instances can share one — and Swift's sort is not stable,
                // so without this two readings that tie on everything else could come back in
                // either order. The payload would then differ between builds of the same state
                // and the driver would republish for nothing.
                return left.instanceID.rawValue < right.instanceID.rawValue
            }
    }

    // MARK: - Tile

    private func tile(ordered: [NotifyQuotaReading], headline: NotifyQuotaReading, now: Date) -> NotifyTile? {
        let omitsProviderName = Set(ordered.map(\.instanceID)).count == 1
        let metrics = ordered
            .prefix(NotifyLimits.metricCount)
            .compactMap { reading in
                NotifyMetric(
                    label: Self.label(for: reading, omittingProviderName: omitsProviderName),
                    value: Self.headlineValue(for: reading),
                    unit: Self.unit(for: reading),
                    tintHex: reading.status.tintHex)
            }

        return NotifyTile(
            title: self.title,
            body: Self.summary(for: headline, now: now),
            symbolName: NotifySymbol.quota,
            tintHex: headline.status.tintHex,
            progress: Self.progress(for: ordered),
            trailing: Self.compactReset(for: headline, now: now),
            metrics: metrics)
    }

    // MARK: - Gauge

    private func gauge(
        ordered: [NotifyQuotaReading],
        headline: NotifyQuotaReading,
        selection: NotifyGaugeSelection,
        now: Date) -> NotifyGauge?
    {
        let shown = Self.selected(from: ordered, selection: selection) ?? headline

        return NotifyGauge(
            title: self.title,
            value: Self.headlineValue(for: shown),
            unit: Self.unit(for: shown),
            detail: Self.gaugeDetail(for: shown, now: now),
            symbolName: NotifySymbol.quota,
            tintHex: shown.status.tintHex,
            progress: shown.remainingPercent)
    }

    /// The reading the user asked the gauge to show, or nil when the selection
    /// is automatic or names a window that is no longer reporting.
    static func selected(
        from readings: [NotifyQuotaReading],
        selection: NotifyGaugeSelection) -> NotifyQuotaReading?
    {
        guard !selection.isAutomatic else { return nil }
        return readings.first { selection.matches($0) }
    }

    // MARK: - Words and numbers

    /// "Codex 5h", or just "5h" when the tile only covers one provider.
    static func label(for reading: NotifyQuotaReading, omittingProviderName: Bool) -> String {
        guard !omittingProviderName else { return reading.windowLabel }
        return "\(reading.providerName) \(reading.windowLabel)"
    }

    /// A percentage as a bare integer, or the formatted balance for a meter
    /// measured in money rather than percent.
    static func headlineValue(for reading: NotifyQuotaReading) -> String {
        if let balance = reading.balanceText { return balance }
        guard let percent = reading.remainingPercent else { return "—" }
        return "\(Int(percent.rounded()))"
    }

    static func unit(for reading: NotifyQuotaReading) -> String? {
        reading.remainingPercent == nil ? nil : "%"
    }

    /// "Codex 5h, 42% left, resets in 2h 14m". The tile's body line, which the
    /// gateway shows only when there are no metrics to put in its place, so it
    /// has to carry the number itself.
    static func summary(for reading: NotifyQuotaReading, now: Date) -> String {
        var parts = ["\(reading.providerName) \(reading.windowLabel)"]

        if let balance = reading.balanceText {
            parts.append("\(balance) left")
        } else if let percent = reading.remainingPercent {
            parts.append("\(Int(percent.rounded()))% left")
        }

        if let resets = Self.compactReset(for: reading, now: now) {
            parts.append(resets == "soon" ? "resets soon" : "resets in \(resets)")
        }

        return parts.joined(separator: ", ")
    }

    /// "Codex 5h, resets in 2h 14m". The gauge's quieter line, which sits next
    /// to a headline value that already shows the percentage, so repeating the
    /// number here would waste the one short line the widget has.
    static func gaugeDetail(for reading: NotifyQuotaReading, now: Date) -> String {
        var parts = ["\(reading.providerName) \(reading.windowLabel)"]

        if let resets = Self.compactReset(for: reading, now: now) {
            parts.append(resets == "soon" ? "resets soon" : "resets in \(resets)")
        }

        return parts.joined(separator: ", ")
    }

    /// The bar on the tile. A balance meter has no percentage to draw, so the
    /// bar falls through to the worst reading that does have one rather than
    /// disappearing whenever a credit balance happens to be the headline.
    static func progress(for ordered: [NotifyQuotaReading]) -> Double? {
        ordered.first(where: \.hasProgress)?.remainingPercent
    }

    /// "2h 14m", "3d 2h", "14m", or "soon".
    ///
    /// Written here rather than taken from `UsageFormatter.resetCountdownDescription`
    /// because the tile needs the bare duration: the gateway puts `trailing`
    /// where a timer would sit, and "in 2h 14m" reads wrong in that slot. The
    /// body and detail lines add their own "resets in" around it.
    static func compactReset(for reading: NotifyQuotaReading, now: Date) -> String? {
        guard let resetsAt = reading.resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds.isFinite else { return nil }
        guard seconds > 60 else { return "soon" }

        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
