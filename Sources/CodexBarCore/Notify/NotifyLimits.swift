import Foundation

/// The Notify! gateway's field limits, kept in one place so every value type
/// enforces the same rules at construction instead of hoping the caller did.
///
/// The gateway rejects an oversized string with a 400 naming the field, and
/// clamps an out-of-range number rather than rejecting it. CodexBar does both
/// itself: a quota label that happens to be long should shorten, never fail to
/// reach the phone.
public enum NotifyLimits {
    // MARK: - Live Activity tile

    public static let titleLength = 120
    public static let bodyLength = 300
    public static let symbolLength = 64
    public static let trailingLength = 40
    public static let statusLength = 40
    public static let metricCount = 6
    public static let metricLabelLength = 24
    public static let metricValueLength = 16
    public static let metricUnitLength = 8

    // MARK: - Lock Screen widget

    public static let widgetTitleLength = 120
    public static let widgetValueLength = 40
    public static let widgetUnitLength = 12
    public static let widgetDetailLength = 120

    // MARK: - Normalization

    /// Trims whitespace, drops NUL (the gateway rejects it outright), shortens
    /// to `maximum` characters, and reports an empty result as `nil` so an
    /// absent field is never sent as `""`.
    public static func text(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > maximum else { return cleaned }
        return String(cleaned.prefix(maximum))
    }

    /// Clamps a percentage into the 0...100 the gateway accepts. A quota can
    /// legitimately report a negative remainder when the user is over the
    /// limit, and that reads as an empty bar rather than an error.
    public static func progress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    /// Normalizes an accent color to the `#RRGGBB` (or `#AARRGGBB`) the gateway
    /// accepts, returning nil for anything else so a bad color is dropped
    /// rather than failing the whole publish.
    public static func tint(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6 || digits.count == 8 else { return nil }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    // MARK: - Notification

    /// `/notify-json` counts UTF-8 bytes rather than characters, and its caps
    /// are far larger than the tile's.
    public static let notificationTextBytes = 16384
    public static let notificationTitleBytes = 2048
    public static let notificationGroupBytes = 1024

    /// Trims, drops NUL, and shortens to `maximumBytes` of UTF-8 without ever
    /// splitting a character in half.
    ///
    /// Character-count truncation is wrong here: one emoji is four bytes, so a
    /// message well under the character cap can still be over the byte cap the
    /// gateway actually enforces, and a message cut mid-scalar is worse than a
    /// short one.
    public static func utf8Text(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.utf8.count > maximumBytes else { return cleaned }

        var result = ""
        var used = 0
        for character in cleaned {
            let width = String(character).utf8.count
            guard used + width <= maximumBytes else { break }
            result.append(character)
            used += width
        }
        return result.isEmpty ? nil : result
    }
}
