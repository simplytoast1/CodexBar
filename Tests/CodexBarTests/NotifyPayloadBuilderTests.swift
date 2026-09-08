import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for the decision layer: which quota leads, which six fill the
/// metrics row, what the labels say, and the total ordering that stops the
/// driver republishing an unchanged payload forever.
struct NotifyPayloadBuilderTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    private func reading(
        instance: String,
        name: String,
        key: String,
        label: String,
        remaining: Double?,
        resetsIn: TimeInterval? = nil,
        balance: String? = nil) -> NotifyQuotaReading
    {
        NotifyQuotaReading(
            instanceID: ProviderInstanceID(rawValue: instance)!,
            providerName: name,
            quotaKey: key,
            windowLabel: label,
            remainingPercent: remaining,
            resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) },
            balanceText: balance)
    }

    // MARK: - Ordering

    @Test
    func `the worst quota leads`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 80),
            self.reading(instance: "claude", name: "Claude", key: "b", label: "7d", remaining: 4),
            self.reading(instance: "gemini", name: "Gemini", key: "c", label: "5h", remaining: 45),
        ]
        let ordered = NotifyPayloadBuilder.ordered(readings)
        #expect(ordered.map(\.providerName) == ["Claude", "Gemini", "Codex"])
    }

    @Test
    func `a reading with no percentage sorts after every reading that has one`() {
        let readings = [
            self.reading(
                instance: "codex",
                name: "Codex",
                key: "credits",
                label: "Credits",
                remaining: nil,
                balance: "42.00"),
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 3),
        ]
        let ordered = NotifyPayloadBuilder.ordered(readings)
        #expect(ordered.map(\.quotaKey) == ["a", "credits"])
    }

    @Test
    func `ordering is total so the same readings always build the same payload`() {
        // Two readings that tie on status, percentage and provider name. Swift's sort is not
        // stable, so without the instance-id tie break the payload could differ between builds of
        // the same state and the gate would republish for nothing.
        let readings = [
            self.reading(instance: "zed", name: "Same", key: "k", label: "5h", remaining: 50),
            self.reading(instance: "amp", name: "Same", key: "k", label: "5h", remaining: 50),
        ]
        let first = NotifyPayloadBuilder.ordered(readings).map(\.instanceID.rawValue)
        let second = NotifyPayloadBuilder.ordered(readings.reversed()).map(\.instanceID.rawValue)
        #expect(first == ["amp", "zed"])
        #expect(first == second)
    }

    // MARK: - Instance selection

    @Test
    func `a chosen instance leads even when another provider is redder`() {
        let readings = [
            self.reading(instance: "claude", name: "Claude", key: "b", label: "7d", remaining: 2),
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 80),
        ]
        let selection = NotifyInstanceSelection(instanceIDs: ["codex", "claude"])
        let ordered = NotifyPayloadBuilder.ordered(readings, selection: selection)
        #expect(ordered.map(\.providerName) == ["Codex", "Claude"])
    }

    @Test
    func `an unchosen instance is dropped entirely`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 80),
            self.reading(instance: "gemini", name: "Gemini", key: "c", label: "5h", remaining: 1),
        ]
        let selection = NotifyInstanceSelection(instanceIDs: ["codex"])
        let ordered = NotifyPayloadBuilder.ordered(readings, selection: selection)
        #expect(ordered.map(\.providerName) == ["Codex"])
    }

    @Test
    func `severity still orders the windows inside one chosen instance`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 80),
            self.reading(instance: "codex", name: "Codex", key: "b", label: "7d", remaining: 5),
        ]
        let selection = NotifyInstanceSelection(instanceIDs: ["codex"])
        let ordered = NotifyPayloadBuilder.ordered(readings, selection: selection)
        #expect(ordered.map(\.quotaKey) == ["b", "a"])
    }

    @Test
    func `a duplicate instance never eats a metrics slot`() {
        let selection = NotifyInstanceSelection(instanceIDs: ["codex", "codex", "claude"])
        #expect(selection.instanceIDs == ["codex", "claude"])
    }

    @Test
    func `an empty selection admits everything`() {
        let selection = NotifyInstanceSelection.automatic
        #expect(selection.isAutomatic)
        #expect(selection.admits(self.reading(
            instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 50)))
    }

    // MARK: - Tile

    @Test
    func `the tile carries at most six metrics`() {
        let readings = (0..<9).map { index in
            self.reading(
                instance: "codex",
                name: "Codex",
                key: "k\(index)",
                label: "w\(index)",
                remaining: Double(index * 10))
        }
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile?.metrics.count == 6)
    }

    @Test
    func `labels drop the provider name when only one provider is on show`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 40),
            self.reading(instance: "codex", name: "Codex", key: "b", label: "7d", remaining: 60),
        ]
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile?.metrics.map(\.label) == ["5h", "7d"])
    }

    @Test
    func `the provider name comes back as soon as a second provider appears`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 40),
            self.reading(instance: "claude", name: "Claude", key: "b", label: "7d", remaining: 60),
        ]
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile?.metrics.map(\.label) == ["Codex 5h", "Claude 7d"])
    }

    @Test
    func `the tile takes its tint from the headline`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 2),
            self.reading(instance: "claude", name: "Claude", key: "b", label: "7d", remaining: 90),
        ]
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile?.tintHex == NotifyQuotaStatus.critical.tintHex)
    }

    @Test
    func `the bar falls through to the worst quota that has a percentage`() {
        // A money-based meter has no percentage to draw, so the bar must not vanish just because a
        // credit balance happens to lead.
        let readings = [
            self.reading(
                instance: "codex",
                name: "Codex",
                key: "credits",
                label: "Credits",
                remaining: nil,
                balance: "0.00"),
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 33),
        ]
        #expect(NotifyPayloadBuilder.progress(for: NotifyPayloadBuilder.ordered(readings)) == 33)
    }

    @Test
    func `percentages published are remaining not used`() {
        let readings = [self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 42)]
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile?.progress == 42)
        #expect(payload.tile?.metrics.first?.value == "42")
        #expect(payload.tile?.metrics.first?.unit == "%")
    }

    @Test
    func `a balance meter carries no percent sign`() {
        let readings = [
            self.reading(
                instance: "codex",
                name: "Codex",
                key: "credits",
                label: "Credits",
                remaining: nil,
                balance: "42.00"),
        ]
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile?.metrics.first?.value == "42.00")
        #expect(payload.tile?.metrics.first?.unit == nil)
    }

    // MARK: - Surfaces

    @Test
    func `the live activity and the home screen tile are the same value`() {
        let readings = [self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 42)]
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)
        #expect(payload.tile == payload.screenTile)
    }

    @Test
    func `a surface the user switched off is left alone rather than cleared`() {
        let readings = [self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 42)]
        let payload = NotifyPayloadBuilder().payload(
            readings: readings,
            includesTile: false,
            includesGauge: true,
            includesScreenTile: false,
            now: Self.now)
        #expect(payload.tile == nil)
        #expect(payload.screenTile == nil)
        #expect(payload.gauge != nil)
    }

    @Test
    func `no readings means nothing to say`() {
        #expect(NotifyPayloadBuilder().payload(readings: [], now: Self.now).isEmpty)
    }

    // MARK: - Gauge

    @Test
    func `the gauge shows the chosen window`() {
        let readings = [
            self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 4),
            self.reading(instance: "claude", name: "Claude", key: "b", label: "7d", remaining: 88),
        ]
        let payload = NotifyPayloadBuilder().payload(
            readings: readings,
            gaugeSelection: NotifyGaugeSelection(instanceID: "claude", quotaKey: "b"),
            now: Self.now)
        #expect(payload.gauge?.value == "88")
        #expect(payload.gauge?.detail?.hasPrefix("Claude 7d") == true)
    }

    @Test
    func `the gauge falls back to the headline when its window stops reporting`() {
        let readings = [self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 4)]
        let payload = NotifyPayloadBuilder().payload(
            readings: readings,
            gaugeSelection: NotifyGaugeSelection(instanceID: "gone", quotaKey: "missing"),
            now: Self.now)
        #expect(payload.gauge?.value == "4")
    }

    @Test
    func `the gauge title never changes with the shown quota`() {
        // The gateway treats a widget title as its identity, so a title that tracked the headline
        // would rename the widget under the user in the phone's own widget picker.
        let first = NotifyPayloadBuilder().payload(
            readings: [self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 4)],
            now: Self.now)
        let second = NotifyPayloadBuilder().payload(
            readings: [self.reading(instance: "claude", name: "Claude", key: "b", label: "7d", remaining: 90)],
            now: Self.now)
        #expect(first.gauge?.title == "CodexBar")
        #expect(second.gauge?.title == "CodexBar")
    }

    // MARK: - Words

    @Test
    func `the countdown reads as a bare duration for the trailing slot`() {
        let reading = self.reading(
            instance: "codex",
            name: "Codex",
            key: "a",
            label: "5h",
            remaining: 42,
            resetsIn: 2 * 3600 + 14 * 60)
        #expect(NotifyPayloadBuilder.compactReset(for: reading, now: Self.now) == "2h 14m")
    }

    @Test
    func `the countdown collapses to days and then to soon`() {
        let days = self.reading(
            instance: "codex",
            name: "Codex",
            key: "a",
            label: "7d",
            remaining: 42,
            resetsIn: 3 * 86400 + 2 * 3600)
        #expect(NotifyPayloadBuilder.compactReset(for: days, now: Self.now) == "3d 2h")

        let imminent = self.reading(
            instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 42, resetsIn: 30)
        #expect(NotifyPayloadBuilder.compactReset(for: imminent, now: Self.now) == "soon")

        let unknown = self.reading(instance: "codex", name: "Codex", key: "a", label: "5h", remaining: 42)
        #expect(NotifyPayloadBuilder.compactReset(for: unknown, now: Self.now) == nil)
    }

    @Test
    func `the body line carries the number because it replaces the metrics row`() {
        let reading = self.reading(
            instance: "codex",
            name: "Codex",
            key: "a",
            label: "5h",
            remaining: 42,
            resetsIn: 2 * 3600 + 14 * 60)
        #expect(NotifyPayloadBuilder.summary(for: reading, now: Self.now)
            == "Codex 5h, 42% left, resets in 2h 14m")
    }

    @Test
    func `the gauge detail leaves the number to the headline value`() {
        let reading = self.reading(
            instance: "codex",
            name: "Codex",
            key: "a",
            label: "5h",
            remaining: 42,
            resetsIn: 2 * 3600 + 14 * 60)
        #expect(NotifyPayloadBuilder.gaugeDetail(for: reading, now: Self.now)
            == "Codex 5h, resets in 2h 14m")
    }
}
