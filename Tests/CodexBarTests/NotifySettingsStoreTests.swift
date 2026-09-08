import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Coverage for how the Notify! settings are stored: what the feature ships as,
/// where the token is allowed to live, and what has to be forgotten when the
/// linked device changes.
@MainActor
struct NotifySettingsStoreTests {
    // MARK: - Defaults

    @Test
    func `ships switched off`() {
        // This is the only CodexBar feature that sends app state to a host the user has no account
        // with, so it cannot ship enabled.
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-defaults")
        #expect(settings.notifyEnabled == false)
        #expect(settings.notifyDeviceID.isEmpty)
    }

    @Test
    func `every surface is on once the feature is`() {
        // The switches only matter after the user links a phone, and somebody who linked one
        // wants what they linked it for.
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-surface-defaults")
        #expect(settings.notifyLiveActivityEnabled)
        #expect(settings.notifyWidgetEnabled)
        #expect(settings.notifyScreenWidgetEnabled)
        #expect(settings.notifyNotificationsEnabled)
    }

    @Test
    func `starts with no selection so severity decides`() {
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-selection-defaults")
        #expect(settings.notifyInstanceSelection.isAutomatic)
        #expect(settings.notifyGaugeSelection.isAutomatic)
    }

    // MARK: - Handles

    @Test
    func `forgets its handles when the device changes`() {
        // A new device owns none of the old device's tiles, and writing this Mac's stored handles
        // to it would either fail with a 403 or, worse, address somebody else's tile.
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-handles")
        settings.notifyDeviceID = "ABC12345"
        settings.notifyActivityID = "LA123456"
        settings.notifyWidgetID = "WG123456"
        settings.notifyScreenWidgetID = "SW123456"

        settings.notifyDeviceID = "DEF67890"

        #expect(settings.notifyActivityID == nil)
        #expect(settings.notifyWidgetID == nil)
        #expect(settings.notifyScreenWidgetID == nil)
    }

    @Test
    func `keeps its handles when the device is set to what it already was`() {
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-handles-unchanged")
        settings.notifyDeviceID = "ABC12345"
        settings.notifyActivityID = "LA123456"

        settings.notifyDeviceID = "  ABC12345  "

        #expect(settings.notifyActivityID == "LA123456")
    }

    @Test
    func `reports an empty handle as no handle`() {
        // Nil means "create your own"; an empty string would be sent as a target and 404.
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-empty-handle")
        settings.notifyActivityID = "LA123456"
        settings.notifyActivityID = nil
        #expect(settings.notifyActivityID == nil)
    }

    // MARK: - Token

    @Test
    func `never writes the token to defaults`() throws {
        let store = InMemoryNotifyTokenStore()
        nonisolated(unsafe) var captured: UserDefaults?
        let settings = testSettingsStore(
            suiteName: "NotifySettingsStoreTests-token-storage",
            notifyTokenStore: store,
            prepareDefaults: { captured = $0 })

        settings.notifyDeviceID = "ABC12345"
        try settings.setNotifyDeviceToken("super-secret")

        let defaults = try #require(captured)
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let text = value as? String else { continue }
            #expect(text != "super-secret", "the token leaked into defaults under \(key)")
        }
        #expect(try store.loadToken() == "super-secret")
    }

    @Test
    func `builds a link only when both halves are on file`() throws {
        let settings = testSettingsStore(
            suiteName: "NotifySettingsStoreTests-link",
            notifyTokenStore: InMemoryNotifyTokenStore())

        #expect(settings.notifyDeviceLink() == nil)

        settings.notifyDeviceID = "ABC12345"
        #expect(settings.notifyDeviceLink() == nil)

        try settings.setNotifyDeviceToken("secret")
        let link = settings.notifyDeviceLink()
        #expect(link?.deviceId == "ABC12345")
        #expect(link?.token == "secret")
    }

    @Test
    func `clearing the token unlinks`() throws {
        let settings = testSettingsStore(
            suiteName: "NotifySettingsStoreTests-clear-token",
            notifyTokenStore: InMemoryNotifyTokenStore())
        settings.notifyDeviceID = "ABC12345"
        try settings.setNotifyDeviceToken("secret")

        try settings.setNotifyDeviceToken(nil)
        #expect(settings.notifyDeviceLink() == nil)
    }

    @Test
    func `treats a blank token as no token`() throws {
        let store = InMemoryNotifyTokenStore()
        try store.storeToken("   ")
        #expect(try store.loadToken() == nil)
    }

    // MARK: - Selection

    @Test
    func `round trips the instance and gauge selections`() {
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-selection")

        settings.notifyInstanceSelection = NotifyInstanceSelection(instanceIDs: ["codex", "claude"])
        #expect(settings.notifyInstanceSelection.instanceIDs == ["codex", "claude"])

        settings.notifyGaugeSelection = NotifyGaugeSelection(instanceID: "codex", quotaKey: "row:session")
        #expect(settings.notifyGaugeSelection.instanceID == "codex")
        #expect(settings.notifyGaugeSelection.quotaKey == "row:session")
        #expect(settings.notifyGaugeSelection.isAutomatic == false)
    }

    // MARK: - Sync

    @Test
    func `keeps everything Notify out of iCloud sync`() {
        // The handles name a tile and two widgets this Mac created, and a second Mac adopting them
        // would put two publishers on one Live Activity.
        let settings = testSettingsStore(suiteName: "NotifySettingsStoreTests-sync")
        settings.notifyEnabled = true
        settings.notifyDeviceID = "ABC12345"
        settings.notifyActivityID = "LA123456"

        let mirror = Mirror(reflecting: settings.syncedPreferences)
        let labels = mirror.children.compactMap(\.label)
        #expect(labels.allSatisfy { !$0.lowercased().contains("notify") })
    }
}
