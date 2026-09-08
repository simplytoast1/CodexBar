import Foundation

/// Flattens the widget snapshot into the readings the payload builder sorts.
///
/// `WidgetSnapshot` is chosen deliberately over a second pass across the live
/// providers. It is already the reduction of CodexBar's main-actor usage state
/// into `Sendable` values, it is already filtered to the providers the user
/// enabled, and it is already what the macOS widget draws. Building the phone's
/// numbers from anything else would let the two surfaces describe one quota
/// differently, and the first bug report about that would be impossible to read.
///
/// Pure: no clock of its own beyond the `now` it is handed, no settings, no
/// network.
public enum NotifyReadingsBuilder {
    /// Every quota window the enabled providers are currently reporting.
    ///
    /// - Parameters:
    ///   - snapshot: the widget snapshot to read.
    ///   - pluginNames: display names for provider instances that are not
    ///     first-party, which Core cannot resolve for itself. A missing name
    ///     falls back to the instance id, which is at least stable and
    ///     recognizable rather than blank.
    public static func readings(
        from snapshot: WidgetSnapshot,
        pluginNames: [ProviderInstanceID: String] = [:]) -> [NotifyQuotaReading]
    {
        let enabled = Set(snapshot.enabledProviders)
        return snapshot.entries
            .filter { enabled.contains($0.provider) }
            .flatMap { entry in
                self.readings(for: entry, name: self.name(for: entry.provider, pluginNames: pluginNames))
            }
    }

    /// The display name to put on a metric label.
    static func name(for instanceID: ProviderInstanceID, pluginNames: [ProviderInstanceID: String]) -> String {
        if let name = pluginNames[instanceID] { return name }
        if let provider = instanceID.firstPartyProvider,
           let metadata = ProviderDefaults.metadata[provider]
        {
            // The short name, because a metric label is capped at 24 characters and shares that
            // line with the window label. "Claude 5h" fits; the long name plus a window would not.
            return metadata.shortDisplayName
        }
        return instanceID.rawValue
    }

    /// One provider entry's windows, in the order the widget lists them.
    static func readings(for entry: WidgetSnapshot.ProviderEntry, name: String) -> [NotifyQuotaReading] {
        var readings: [NotifyQuotaReading] = []

        // `usageRows` is the labeled per-window list the widget itself draws, so it is preferred
        // whenever a provider fills it in. Its ids are lane keys rather than display strings,
        // which is what makes them safe to persist as half of a gauge selection.
        if let rows = entry.usageRows, !rows.isEmpty {
            for row in rows {
                guard let window = row.window else { continue }
                guard !window.isSyntheticPlaceholder else { continue }
                readings.append(NotifyQuotaReading(
                    instanceID: entry.provider,
                    providerName: name,
                    quotaKey: "row:\(row.id)",
                    windowLabel: row.title,
                    remainingPercent: row.percentLeft ?? window.remainingPercent,
                    resetsAt: window.resetsAt))
            }
        } else {
            // The three fixed slots, for providers that report windows without labeling them.
            let metadata = entry.provider.firstPartyProvider.flatMap { ProviderDefaults.metadata[$0] }
            let slots: [(String, String, RateWindow?)] = [
                ("primary", metadata?.sessionLabel ?? "Session", entry.primary),
                ("secondary", metadata?.weeklyLabel ?? "Weekly", entry.secondary),
                ("tertiary", metadata?.opusLabel ?? "Extra", entry.tertiary),
            ]
            for (key, label, window) in slots {
                guard let window, !window.isSyntheticPlaceholder else { continue }
                readings.append(NotifyQuotaReading(
                    instanceID: entry.provider,
                    providerName: name,
                    quotaKey: key,
                    windowLabel: label,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt))
            }
        }

        // A credit balance has no percentage, so it can never lead the bar, but it is often the
        // number the user actually wants and it belongs on the tile beside the windows.
        if let credits = entry.creditsRemaining, credits.isFinite {
            readings.append(NotifyQuotaReading(
                instanceID: entry.provider,
                providerName: name,
                quotaKey: "credits",
                windowLabel: "Credits",
                remainingPercent: nil,
                resetsAt: nil,
                balanceText: UsageFormatter.creditsNumberString(from: credits)))
        }

        return readings
    }
}
