import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxPersistence

/// A Keychain store under a throwaway service name, so tests never touch the app's real items.
private func makeKeychain() -> KeychainSecretStore {
    KeychainSecretStore(service: "app.letterbox.tests.\(UUID().uuidString)")
}

/// Some environments (CI without a login keychain) can't use the Keychain from `swift test`.
private let keychainAvailable: Bool = {
    let store = makeKeychain()
    defer { store.deleteAll() }
    return (try? store.save(Data([1]), for: "probe")) != nil && store.load("probe") == Data([1])
}()

@Suite("Keychain secret store", .enabled(if: keychainAvailable, "Keychain not available in this environment"), .serialized)
struct KeychainSecretStoreTests {
    @Test func savesLoadsAndOverwrites() throws {
        let store = makeKeychain()
        defer { store.deleteAll() }
        #expect(store.load("identity") == nil)
        try store.save(Data([1, 2, 3]), for: "identity")
        #expect(store.load("identity") == Data([1, 2, 3]))
        try store.save(Data([9]), for: "identity")
        #expect(store.load("identity") == Data([9]))
    }

    @Test func keysAreIndependent() throws {
        let store = makeKeychain()
        defer { store.deleteAll() }
        try store.save(Data("noise".utf8), for: "identity.noise")
        try store.save(Data("signing".utf8), for: "identity.signing")
        #expect(store.load("identity.noise") == Data("noise".utf8))
        #expect(store.load("identity.signing") == Data("signing".utf8))
    }

    @Test func servicesDoNotSeeEachOthersItems() throws {
        let one = makeKeychain()
        let two = makeKeychain()
        defer { one.deleteAll(); two.deleteAll() }
        try one.save(Data([1]), for: "shared-name")
        #expect(two.load("shared-name") == nil)
    }

    @Test func deleteAllRemovesOnlyThisServicesItems() throws {
        let store = makeKeychain()
        let other = makeKeychain()
        defer { other.deleteAll() }
        try store.save(Data([1]), for: "a")
        try store.save(Data([2]), for: "b")
        try other.save(Data([3]), for: "a")
        store.deleteAll()
        #expect(store.load("a") == nil)
        #expect(store.load("b") == nil)
        #expect(other.load("a") == Data([3]))
    }

    @Test func storesLargerAndEmptyValues() throws {
        let store = makeKeychain()
        defer { store.deleteAll() }
        let big = Data((0..<4096).map { UInt8($0 & 0xFF) })
        try store.save(big, for: "big")
        #expect(store.load("big") == big)
        try store.save(Data(), for: "empty")
        #expect(store.load("empty") == nil || store.load("empty") == Data())
    }
}

@Suite("UserDefaults settings store")
struct UserDefaultsSettingsStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "app.letterbox.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func setsReadsAndClearsValues() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.string(for: "nickname") == nil)
        store.set("ana", for: "nickname")
        #expect(store.string(for: "nickname") == "ana")
        store.set("zoë 🙂", for: "nickname")
        #expect(store.string(for: "nickname") == "zoë 🙂")
        store.set(nil, for: "nickname")
        #expect(store.string(for: "nickname") == nil)
    }

    @Test func valuesSurviveANewStoreOnTheSameDefaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsSettingsStore(defaults: defaults).set("1", for: "privacy.hideMessages")
        #expect(UserDefaultsSettingsStore(defaults: defaults).string(for: "privacy.hideMessages") == "1")
    }
}

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    func load(_ key: String) -> Data? { values[key] }
    func save(_ data: Data, for key: String) throws { values[key] = data }
    func deleteAll() { values.removeAll() }
}

@Suite("Encrypted file store")
struct EncryptedFileStoreTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("letterbox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.bin")
    }

    @Test func roundTripsAndCreatesItsFolder() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = EncryptedFileStore(fileURL: url, secrets: MemorySecrets(), keyName: "k")
        #expect(store.load() == nil)
        try store.save(Data("queued message".utf8))
        #expect(store.load() == Data("queued message".utf8))
        try store.save(Data("replaced".utf8))
        #expect(store.load() == Data("replaced".utf8))
    }

    @Test func fileOnDiskRevealsNothing() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secret = Data("meet dave at the north ridge".utf8)
        try EncryptedFileStore(fileURL: url, secrets: MemorySecrets(), keyName: "k").save(secret)
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: secret) == nil)
        #expect(raw.count == secret.count + 12 + 16) // nonce + ciphertext + tag
    }

    @Test func survivesANewStoreObjectWithTheSameKey() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecrets()
        try EncryptedFileStore(fileURL: url, secrets: secrets, keyName: "k").save(Data([1, 2, 3]))
        #expect(EncryptedFileStore(fileURL: url, secrets: secrets, keyName: "k").load() == Data([1, 2, 3]))
    }

    @Test func wrongOrMissingKeyOrTamperingReadsAsEmpty() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecrets()
        try EncryptedFileStore(fileURL: url, secrets: secrets, keyName: "k").save(Data("x".utf8))

        #expect(EncryptedFileStore(fileURL: url, secrets: MemorySecrets(), keyName: "k").load() == nil) // key lost (wiped)
        #expect(EncryptedFileStore(fileURL: url, secrets: secrets, keyName: "other").load() == nil)     // another store's file

        var raw = try Data(contentsOf: url)
        raw[raw.count - 1] ^= 0x01
        try raw.write(to: url)
        #expect(EncryptedFileStore(fileURL: url, secrets: secrets, keyName: "k").load() == nil)
    }

    @Test func deleteRemovesTheFile() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = EncryptedFileStore(fileURL: url, secrets: MemorySecrets(), keyName: "k")
        try store.save(Data([1]))
        store.delete()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.load() == nil)
    }
}

private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func load(_ key: String) -> Data? { values[key] }
    func save(_ data: Data, for key: String) throws { values[key] = data }
    func deleteAll() { values.removeAll() }
}

@Suite("Erasing local data")
struct LocalDataWipeTests {
    private func temporaryDefaults() -> (UserDefaults, String) {
        let name = "letterbox.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func eraserRemovesSecretsFilesAndSettings() throws {
        let secrets = InMemorySecretStore()
        try secrets.save(Data([1, 2, 3]), for: "identity.noise")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("letterbox-wipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("sealed".utf8).write(to: folder.appendingPathComponent("mesh-state.bin"))
        let (defaults, domain) = temporaryDefaults()
        defaults.set("Ana", forKey: "nickname")

        DeviceDataEraser(secrets: secrets, directory: folder, defaults: defaults, defaultsDomain: domain).eraseAll()

        #expect(secrets.load("identity.noise") == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(UserDefaults(suiteName: domain)?.string(forKey: "nickname") == nil)
    }

    @Test func freshInstallClearsKeysLeftByADeletedApp() throws {
        let secrets = InMemorySecretStore()
        try secrets.save(Data([9]), for: "identity.noise") // survived an uninstall
        let (defaults, _) = temporaryDefaults()             // settings didn't
        FreshInstall.clearLeftoverSecrets(secrets: secrets, defaults: defaults, existingSettingKey: "nickname")
        #expect(secrets.load("identity.noise") == nil)

        // Later launches leave new keys alone.
        try secrets.save(Data([7]), for: "identity.noise")
        FreshInstall.clearLeftoverSecrets(secrets: secrets, defaults: defaults, existingSettingKey: "nickname")
        #expect(secrets.load("identity.noise") == Data([7]))
    }

    @Test func updatingFromAnOlderVersionKeepsYourIdentity() throws {
        let secrets = InMemorySecretStore()
        try secrets.save(Data([5]), for: "identity.noise")
        let (defaults, _) = temporaryDefaults()
        defaults.set("Ana", forKey: "nickname") // written by every earlier version
        FreshInstall.clearLeftoverSecrets(secrets: secrets, defaults: defaults, existingSettingKey: "nickname")
        #expect(secrets.load("identity.noise") == Data([5]))
    }
}
