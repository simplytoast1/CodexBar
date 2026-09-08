import CodexBarCore
import Foundation
import Security

/// Reads and writes the Notify! device token.
///
/// The token is the one secret this feature holds: anybody with it can write to
/// the user's phone. It goes to the Keychain and never to the settings defaults,
/// it is never logged, and it is deliberately left out of `SyncedPreferences`
/// so iCloud sync cannot copy it to another Mac — two Macs sharing one device
/// token would fight over one Live Activity handle.
protocol NotifyTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

enum NotifyTokenStoreError: LocalizedError {
    case keychainStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            "Keychain error: \(status)"
        case .invalidData:
            "Keychain returned invalid data."
        }
    }
}

struct KeychainNotifyTokenStore: NotifyTokenStoring {
    private static let log = CodexBarLog.logger(LogCategories.notify)

    private let service = "com.steipete.CodexBar"
    private let account = "notify-device-token"

    /// The publish driver reads the token on every tick, and a Keychain round
    /// trip per minute is both slow and, on a machine whose Keychain is locked,
    /// a source of repeated prompts. The same cache the other token stores use.
    private nonisolated(unsafe) static var cachedToken: String?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 1800

    func loadToken() throws -> String? {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping token load")
            return nil
        }

        Self.cacheLock.lock()
        if let timestamp = Self.cacheTimestamp, Date().timeIntervalSince(timestamp) < Self.cacheTTL {
            let cached = Self.cachedToken
            Self.cacheLock.unlock()
            return cached
        }
        Self.cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        if KeychainAccessPreflight.checkGenericPassword(
            service: self.service,
            account: self.account).requiresInteraction
        {
            KeychainPromptHandler.handler?(KeychainPromptContext(
                kind: .notifyToken,
                service: self.service,
                account: self.account))
        }

        var result: CFTypeRef?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            Self.cache(nil)
            return nil
        }
        guard status == errSecSuccess else {
            Self.log.error("Keychain read failed", metadata: ["status": String(status)])
            throw NotifyTokenStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw NotifyTokenStoreError.invalidData
        }

        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (token?.isEmpty == false) ? token : nil
        Self.cache(value)
        return value
    }

    func storeToken(_ token: String?) throws {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping token store")
            return
        }

        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty else {
            try self.deleteTokenIfPresent()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(cleaned.utf8),
            // This device only: the token names one Mac's write access to one phone, and syncing
            // it to another Mac would put two publishers on one Live Activity.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = KeychainSecurity.update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            Self.cache(cleaned)
            return
        }
        if updateStatus != errSecItemNotFound {
            Self.log.error("Keychain update failed", metadata: ["status": String(updateStatus)])
            throw NotifyTokenStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = KeychainSecurity.add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.log.error("Keychain add failed", metadata: ["status": String(addStatus)])
            throw NotifyTokenStoreError.keychainStatus(addStatus)
        }
        Self.cache(cleaned)
    }

    private func deleteTokenIfPresent() throws {
        guard !KeychainAccessGate.isDisabled else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        let status = KeychainSecurity.delete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            Self.cache(nil)
            return
        }
        Self.log.error("Keychain delete failed", metadata: ["status": String(status)])
        throw NotifyTokenStoreError.keychainStatus(status)
    }

    /// Caches the answer, including a `nil` one: "there is no token" is worth
    /// remembering too, or an unlinked install would hit the Keychain on every
    /// publish tick forever.
    private static func cache(_ token: String?) {
        self.cacheLock.lock()
        self.cachedToken = token
        self.cacheTimestamp = Date()
        self.cacheLock.unlock()
    }

    /// Drops the cache so the next read goes back to the Keychain. Used after a
    /// save from the settings pane, where waiting half an hour to find out
    /// whether the token took would not be an answer.
    static func invalidateCache() {
        self.cacheLock.lock()
        self.cachedToken = nil
        self.cacheTimestamp = nil
        self.cacheLock.unlock()
    }
}
