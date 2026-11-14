import Foundation
import LetterboxDomain
import Security

/// Keychain adapter for the `SecretStore` port. Items stay on this device
/// (`ThisDeviceOnly`) and are readable after the first unlock, so the mesh can run
/// in the background.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "app.letterbox.secrets") {
        self.service = service
    }

    public func load(_ key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func save(_ data: Data, for key: String) throws {
        SecItemDelete(baseQuery(key) as CFDictionary)
        var item = baseQuery(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // On the macOS file-based keychain one SecItemDelete removes only the first
        // match (iOS removes them all), so repeat until nothing is left.
        var remaining = 1000 // bound, in case a delete ever keeps "succeeding"
        while remaining > 0, SecItemDelete(query as CFDictionary) == errSecSuccess {
            remaining -= 1
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// UserDefaults adapter for the `SettingsStore` port.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(for key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, for key: String) {
        defaults.set(value, forKey: key)
    }
}
