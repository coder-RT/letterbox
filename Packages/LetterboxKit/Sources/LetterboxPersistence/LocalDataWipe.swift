import Foundation
import LetterboxDomain

/// Adapter for the `LocalDataEraser` port: Keychain items, the folder of encrypted state
/// files, and the app's settings.
public struct DeviceDataEraser: LocalDataEraser, @unchecked Sendable {
    private let secrets: any SecretStore
    private let directory: URL
    private let defaults: UserDefaults
    private let defaultsDomain: String?

    /// - Parameters:
    ///   - directory: Holds only Letterbox's own files; removed as a whole.
    ///   - defaultsDomain: The settings domain to remove (the bundle ID in the app).
    public init(secrets: any SecretStore, directory: URL, defaults: UserDefaults = .standard,
                defaultsDomain: String? = Bundle.main.bundleIdentifier) {
        self.secrets = secrets
        self.directory = directory
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
    }

    public func eraseAll() {
        secrets.deleteAll()
        try? FileManager.default.removeItem(at: directory)
        if let defaultsDomain { defaults.removePersistentDomain(forName: defaultsDomain) }
        defaults.synchronize()
    }
}

/// Keychain items outlive the app on iOS: delete Letterbox and reinstall it, and the old
/// identity keys would still be there. Someone who deletes the app expects their
/// identity gone, so a fresh install (no settings yet) clears leftover secrets first.
public enum FreshInstall {
    static let markerKey = "install.marker"

    /// Call once at launch, before loading any secrets.
    /// - Parameter existingSettingKey: A setting every earlier version wrote, so updating
    ///   from a version without the marker isn't mistaken for a fresh install.
    public static func clearLeftoverSecrets(secrets: any SecretStore, defaults: UserDefaults = .standard,
                                            existingSettingKey: String) {
        guard defaults.string(forKey: markerKey) == nil else { return }
        if defaults.object(forKey: existingSettingKey) == nil {
            secrets.deleteAll()
        }
        defaults.set("1", forKey: markerKey)
    }
}
