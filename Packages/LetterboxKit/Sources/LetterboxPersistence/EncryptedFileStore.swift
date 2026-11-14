import CryptoKit
import Foundation
import LetterboxDomain

/// File adapter for the `BlobStore` port. The bytes are sealed with ChaCha20-Poly1305
/// under a random key kept in the `SecretStore` (the Keychain in the app), so the file
/// on its own reveals nothing: not who you've met, not what's queued.
public final class EncryptedFileStore: BlobStore, @unchecked Sendable {
    private let fileURL: URL
    private let secrets: any SecretStore
    private let keyName: String
    private let lock = NSLock()

    public init(fileURL: URL, secrets: any SecretStore, keyName: String) {
        self.fileURL = fileURL
        self.secrets = secrets
        self.keyName = keyName
    }

    /// Ties the file to its purpose, so one store's file can't be passed off as another's.
    private var associatedData: Data { Data("letterbox/blob/1/\(keyName)".utf8) }

    public func load() -> Data? {
        lock.withLock {
            guard let sealed = try? Data(contentsOf: fileURL),
                  let raw = secrets.load(keyName), raw.count == 32,
                  let box = try? ChaChaPoly.SealedBox(combined: sealed)
            else { return nil }
            return try? ChaChaPoly.open(box, using: SymmetricKey(data: raw), authenticating: associatedData)
        }
    }

    public func save(_ data: Data) throws {
        try lock.withLock {
            let key = try existingOrNewKey()
            let sealed = try ChaChaPoly.seal(data, using: key, authenticating: associatedData).combined
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            // Readable after the first unlock, so the mesh can keep working in the background.
            try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try sealed.write(to: fileURL, options: .atomic)
            #endif
        }
    }

    public func delete() {
        lock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func existingOrNewKey() throws -> SymmetricKey {
        if let raw = secrets.load(keyName), raw.count == 32 { return SymmetricKey(data: raw) }
        let key = SymmetricKey(size: .bits256)
        try secrets.save(key.withUnsafeBytes { Data($0) }, for: keyName)
        return key
    }
}
