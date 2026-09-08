import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for the seam that flattens the widget snapshot into readings, which
/// is what keeps the phone and the macOS widget from describing one quota
/// differently.
struct NotifyReadingsBuilderTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    private func window(
        used: Double,
        minutes: Int = 300,
        resetsIn: TimeInterval? = 3600,
        placeholder: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) },
            resetDescription: nil,
            isSyntheticPlaceholder: placeholder)
    }

    private func entry(
        provider: UsageProvider = .codex,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        rows: [WidgetSnapshot.WidgetUsageRowSnapshot]? = nil,
        credits: Double? = nil) -> WidgetSnapshot.ProviderEntry
    {
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: Self.now,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            usageRows: rows,
            creditsRemaining: credits,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }

    private func snapshot(
        entries: [WidgetSnapshot.ProviderEntry],
        enabled: [UsageProvider] = [.codex]) -> WidgetSnapshot
    {
        WidgetSnapshot(
            entries: entries,
            enabledProviders: enabled.map(\.instanceID),
            usageBarsShowUsed: false,
            generatedAt: Self.now)
    }

    // MARK: - Row-backed providers

    @Test
    func `prefers the labeled rows the widget itself draws`() {
        let rows = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "session", title: "5h", percentLeft: 42, window: self.window(used: 58)),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "weekly", title: "7d", percentLeft: 80, window: self.window(used: 20)),
        ]
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [self.entry(rows: rows)]))

        #expect(readings.map(\.quotaKey) == ["row:session", "row:weekly"])
        #expect(readings.map(\.windowLabel) == ["5h", "7d"])
        #expect(readings.first?.remainingPercent == 42)
    }

    @Test
    func `keys a row by its lane id rather than its display title`() {
        // The key is persisted as half of a gauge selection, so it has to survive a relaunch and a
        // change of language. A display string would not.
        let rows = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "session", title: "Sitzung", percentLeft: 42, window: self.window(used: 58)),
        ]
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [self.entry(rows: rows)]))
        #expect(readings.first?.quotaKey == "row:session")
    }

    @Test
    func `skips a row whose window is a synthetic placeholder`() {
        // A placeholder stands in for a lane the provider did not report, so publishing it would
        // put a quota on a phone that does not exist.
        let rows = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "session",
                title: "5h",
                percentLeft: 100,
                window: self.window(used: 0, placeholder: true)),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "weekly", title: "7d", percentLeft: 80, window: self.window(used: 20)),
        ]
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [self.entry(rows: rows)]))
        #expect(readings.map(\.quotaKey) == ["row:weekly"])
    }

    @Test
    func `skips a row that carries no window at all`() {
        let rows = [
            WidgetSnapshot.WidgetUsageRowSnapshot(id: "session", title: "5h", percentLeft: 42, window: nil),
        ]
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [self.entry(rows: rows)]))
        #expect(readings.isEmpty)
    }

    // MARK: - Slot-backed providers

    @Test
    func `falls back to the three fixed slots when a provider labels nothing`() {
        let entry = self.entry(
            primary: self.window(used: 58),
            secondary: self.window(used: 20, minutes: 7 * 24 * 60))
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [entry]))

        #expect(readings.map(\.quotaKey) == ["primary", "secondary"])
        #expect(readings.first?.remainingPercent == 42)
        #expect(readings.first?.windowLabel.isEmpty == false)
    }

    @Test
    func `skips a placeholder in a fixed slot too`() {
        let entry = self.entry(
            primary: self.window(used: 0, placeholder: true),
            secondary: self.window(used: 20, minutes: 7 * 24 * 60))
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [entry]))
        #expect(readings.map(\.quotaKey) == ["secondary"])
    }

    // MARK: - Credits

    @Test
    func `carries a credit balance as a reading with no percentage`() {
        let entry = self.entry(primary: self.window(used: 58), credits: 42.5)
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [entry]))

        let credits = readings.first { $0.quotaKey == "credits" }
        #expect(credits?.remainingPercent == nil)
        #expect(credits?.balanceText == "42.5")
        #expect(credits?.hasProgress == false)
    }

    // MARK: - Filtering and naming

    @Test
    func `ignores a provider the user has not enabled`() {
        let entries = [
            self.entry(provider: .codex, primary: self.window(used: 58)),
            self.entry(provider: .claude, primary: self.window(used: 10)),
        ]
        let readings = NotifyReadingsBuilder.readings(
            from: self.snapshot(entries: entries, enabled: [.codex]))
        #expect(Set(readings.map(\.instanceID)) == [UsageProvider.codex.instanceID])
    }

    @Test
    func `names a first party provider from its own metadata`() {
        let name = NotifyReadingsBuilder.name(for: UsageProvider.codex.instanceID, pluginNames: [:])
        #expect(name.isEmpty == false)
        #expect(name != UsageProvider.codex.instanceID.rawValue.uppercased())
    }

    @Test
    func `takes a plugin name from the caller and otherwise falls back to the id`() throws {
        let plugin = try #require(ProviderInstanceID(rawValue: "my-plugin"))
        #expect(NotifyReadingsBuilder.name(for: plugin, pluginNames: [plugin: "My Plugin"]) == "My Plugin")
        #expect(NotifyReadingsBuilder.name(for: plugin, pluginNames: [:]) == "my-plugin")
    }

    // MARK: - End to end

    @Test
    func `a snapshot with nothing in it produces no readings`() {
        #expect(NotifyReadingsBuilder.readings(from: self.snapshot(entries: [])).isEmpty)
    }

    @Test
    func `readings feed straight into a publishable payload`() {
        let rows = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "session", title: "5h", percentLeft: 8, window: self.window(used: 92)),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "weekly",
                title: "7d",
                percentLeft: 80,
                window: self.window(used: 20, minutes: 7 * 24 * 60)),
        ]
        let readings = NotifyReadingsBuilder.readings(from: self.snapshot(entries: [self.entry(rows: rows)]))
        let payload = NotifyPayloadBuilder().payload(readings: readings, now: Self.now)

        #expect(payload.tile?.metrics.map(\.label) == ["5h", "7d"])
        #expect(payload.tile?.progress == 8)
        #expect(payload.tile?.tintHex == NotifyQuotaStatus.critical.tintHex)
    }
}
