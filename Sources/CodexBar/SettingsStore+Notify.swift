import CodexBarCore
import Foundation

/// The Notify! settings, and the one place the device token is read from and
/// written to.
///
/// Two rules hold across the whole file. The token never appears in
/// `userDefaults`, only in the Keychain; and none of these values is listed in
/// `SyncedPreferences`, so iCloud sync leaves them alone. That is deliberate
/// rather than an oversight: the three handles name a tile and two widgets this
/// Mac created, and a second Mac adopting them would put two publishers on one
/// Live Activity and leave the user with duplicates they cannot dismiss.
extension SettingsStore {
    // MARK: - Feature switch

    var notifyEnabled: Bool {
        get { self.defaultsState.notify.enabled }
        set {
            self.defaultsState.notify.enabled = newValue
            self.userDefaults.set(newValue, forKey: "notifyEnabled")
        }
    }

    var notifyDeviceID: String {
        get { self.defaultsState.notify.deviceID }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned != self.defaultsState.notify.deviceID else { return }
            self.defaultsState.notify.deviceID = cleaned
            self.userDefaults.set(cleaned, forKey: "notifyDeviceID")
            // A new device owns none of the old device's tiles, and writing this Mac's stored
            // handles to it would either fail with a 403 or, worse, address somebody else's tile.
            self.clearNotifyHandles()
        }
    }

    // MARK: - Token

    /// The device token, read through the Keychain-backed store.
    ///
    /// A read failure is reported as "not linked" rather than thrown: the
    /// publish driver runs on a timer and has no user in front of it, and a
    /// locked Keychain is a reason to skip a publish, not to show an error.
    func notifyDeviceToken() -> String? {
        guard let token = try? self.notifyTokenStore.loadToken() else { return nil }
        return token
    }

    /// Saves or clears the token. Errors surface here because the only caller is
    /// the settings pane, where there is a user to tell.
    func setNotifyDeviceToken(_ token: String?) throws {
        try self.notifyTokenStore.storeToken(token)
        // The store caches for half an hour so the publish tick is not a Keychain round trip per
        // minute. Saving is the one moment that cache is certainly wrong.
        KeychainNotifyTokenStore.invalidateCache()
    }

    /// The credentials as one value, or nil when either half is missing.
    func notifyDeviceLink() -> NotifyDeviceLink? {
        guard let token = self.notifyDeviceToken() else { return nil }
        return NotifyDeviceLink(deviceId: self.notifyDeviceID, token: token)
    }

    // MARK: - Surfaces

    var notifyLiveActivityEnabled: Bool {
        get { self.defaultsState.notify.liveActivityEnabled }
        set {
            self.defaultsState.notify.liveActivityEnabled = newValue
            self.userDefaults.set(newValue, forKey: "notifyLiveActivityEnabled")
        }
    }

    var notifyWidgetEnabled: Bool {
        get { self.defaultsState.notify.widgetEnabled }
        set {
            self.defaultsState.notify.widgetEnabled = newValue
            self.userDefaults.set(newValue, forKey: "notifyWidgetEnabled")
        }
    }

    var notifyScreenWidgetEnabled: Bool {
        get { self.defaultsState.notify.screenWidgetEnabled }
        set {
            self.defaultsState.notify.screenWidgetEnabled = newValue
            self.userDefaults.set(newValue, forKey: "notifyScreenWidgetEnabled")
        }
    }

    var notifyNotificationsEnabled: Bool {
        get { self.defaultsState.notify.notificationsEnabled }
        set {
            self.defaultsState.notify.notificationsEnabled = newValue
            self.userDefaults.set(newValue, forKey: "notifyNotificationsEnabled")
        }
    }

    // MARK: - What the tile shows

    /// Which provider instances may fill the tile's six metric slots.
    var notifyInstanceSelection: NotifyInstanceSelection {
        get { NotifyInstanceSelection(instanceIDs: self.defaultsState.notify.instanceSelectionRaw) }
        set {
            self.defaultsState.notify.instanceSelectionRaw = newValue.instanceIDs
            self.userDefaults.set(newValue.instanceIDs, forKey: "notifyInstanceSelection")
        }
    }

    /// Which single window the Lock Screen gauge shows.
    var notifyGaugeSelection: NotifyGaugeSelection {
        get {
            NotifyGaugeSelection(
                instanceID: self.defaultsState.notify.gaugeInstanceID,
                quotaKey: self.defaultsState.notify.gaugeQuotaKey)
        }
        set {
            self.defaultsState.notify.gaugeInstanceID = newValue.instanceID
            self.defaultsState.notify.gaugeQuotaKey = newValue.quotaKey
            self.userDefaults.set(newValue.instanceID, forKey: "notifyGaugeInstanceID")
            self.userDefaults.set(newValue.quotaKey, forKey: "notifyGaugeQuotaKey")
        }
    }

    // MARK: - Handles

    /// The handle of the Live Activity CodexBar started, or nil before the
    /// first one. Nil means "create your own"; a value means "address that one".
    var notifyActivityID: String? {
        get { self.defaultsState.notify.activityID.isEmpty ? nil : self.defaultsState.notify.activityID }
        set {
            self.defaultsState.notify.activityID = newValue ?? ""
            self.userDefaults.set(newValue ?? "", forKey: "notifyActivityID")
        }
    }

    var notifyWidgetID: String? {
        get { self.defaultsState.notify.widgetID.isEmpty ? nil : self.defaultsState.notify.widgetID }
        set {
            self.defaultsState.notify.widgetID = newValue ?? ""
            self.userDefaults.set(newValue ?? "", forKey: "notifyWidgetID")
        }
    }

    var notifyScreenWidgetID: String? {
        get {
            self.defaultsState.notify.screenWidgetID.isEmpty ? nil : self.defaultsState.notify.screenWidgetID
        }
        set {
            self.defaultsState.notify.screenWidgetID = newValue ?? ""
            self.userDefaults.set(newValue ?? "", forKey: "notifyScreenWidgetID")
        }
    }

    /// Forgets all three handles, so the next publish creates replacements.
    func clearNotifyHandles() {
        self.notifyActivityID = nil
        self.notifyWidgetID = nil
        self.notifyScreenWidgetID = nil
    }
}
