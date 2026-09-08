import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for the gateway's field limits, which every Notify value type
/// enforces at construction so an oversized label shortens rather than failing
/// to reach the phone.
struct NotifyLimitsTests {
    // MARK: - Text

    @Test
    func `trims whitespace and reports an empty result as nil`() {
        #expect(NotifyLimits.text("  hello  ", maximum: 10) == "hello")
        #expect(NotifyLimits.text("   ", maximum: 10) == nil)
        #expect(NotifyLimits.text(nil, maximum: 10) == nil)
    }

    @Test
    func `drops NUL which the gateway rejects outright`() {
        #expect(NotifyLimits.text("a\0b", maximum: 10) == "ab")
    }

    @Test
    func `shortens rather than failing`() {
        #expect(NotifyLimits.text("abcdefghij", maximum: 4) == "abcd")
        #expect(NotifyLimits.text("abcd", maximum: 4) == "abcd")
    }

    // MARK: - Progress

    @Test
    func `clamps progress into the range the gateway accepts`() {
        #expect(NotifyLimits.progress(-12) == 0)
        #expect(NotifyLimits.progress(142) == 100)
        #expect(NotifyLimits.progress(42) == 42)
    }

    @Test
    func `drops a progress value that is not a number`() {
        #expect(NotifyLimits.progress(.nan) == nil)
        #expect(NotifyLimits.progress(.infinity) == nil)
        #expect(NotifyLimits.progress(nil) == nil)
    }

    // MARK: - Tint

    @Test
    func `normalizes a tint to uppercase hex with a leading hash`() {
        #expect(NotifyLimits.tint("34c759") == "#34C759")
        #expect(NotifyLimits.tint("#34c759") == "#34C759")
        #expect(NotifyLimits.tint("ff34c759") == "#FF34C759")
    }

    @Test
    func `drops a tint that is not hex rather than failing the publish`() {
        #expect(NotifyLimits.tint("blue") == nil)
        #expect(NotifyLimits.tint("#12345") == nil)
        #expect(NotifyLimits.tint("#GGGGGG") == nil)
        #expect(NotifyLimits.tint(nil) == nil)
    }

    // MARK: - Byte-limited text

    @Test
    func `counts utf8 bytes rather than characters`() {
        // Four bytes each, so five of them are twenty bytes and only four fit in sixteen.
        let emoji = String(repeating: "😀", count: 5)
        let trimmed = NotifyLimits.utf8Text(emoji, maximumBytes: 16)
        #expect(trimmed == String(repeating: "😀", count: 4))
    }

    @Test
    func `never splits a character in half`() {
        let trimmed = NotifyLimits.utf8Text("a😀", maximumBytes: 3)
        #expect(trimmed == "a")
    }

    @Test
    func `leaves text that already fits alone`() {
        #expect(NotifyLimits.utf8Text("hello", maximumBytes: 16) == "hello")
        #expect(NotifyLimits.utf8Text("  ", maximumBytes: 16) == nil)
    }
}
