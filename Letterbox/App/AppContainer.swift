import CryptoKit
import Foundation
import LetterboxApplication
import LetterboxBLE
import LetterboxCrypto
import LetterboxDevice
import LetterboxDomain
import LetterboxMesh
import LetterboxNostr
import LetterboxPersistence
#if DEBUG
import LetterboxTestSupport
#endif

/// Composition root: the one place that knows which adapter backs which port.
/// Swap `BLELinkLayer` or `NostrLocationChannel` here and nothing else changes.
@MainActor
final class AppContainer {
    let store: ChatStore
    #if DEBUG
    /// Simulated phones and radio when launched by UI tests; kept alive here.
    private var testWorld: UITestWorld?
    #endif

    private enum SecretKey {
        static let noise = "identity.noise"
        static let signing = "identity.signing"
        static let geoSeed = "nostr.geo-seed"
        static let meshState = "storage.mesh-state"
        static let appState = "storage.app-state"
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            let world = UITestWorld(environment: ProcessInfo.processInfo.environment)
            testWorld = world
            store = world.store
            return
        }
        #endif
        let secrets = KeychainSecretStore()
        let identity = Self.loadIdentity(from: secrets)
        let seed = Self.loadSeed(from: secrets)

        // Undelivered messages, people met and envelopes carried for others survive restarts.
        let meshState = EncryptedFileStore(fileURL: Self.meshStateURL, secrets: secrets, keyName: SecretKey.meshState)
        let mesh = MeshNode(identity: identity, nickname: "", link: BLELinkLayer(), store: meshState)
        let channels = NostrLocationChannel(seed: seed)

        store = ChatStore(
            mesh: mesh,
            locationChannels: channels,
            locationProvider: CoreLocationProvider(),
            settings: UserDefaultsSettingsStore(),
            connectivity: SystemConnectivityMonitor(),
            // Who you've verified stays encrypted on disk.
            appState: EncryptedFileStore(fileURL: Self.stateURL("app-state.bin"), secrets: secrets, keyName: SecretKey.appState)
        )
    }

    func start() async {
        await store.start()
        #if DEBUG
        await testWorld?.start()
        #endif
    }

    private static var meshStateURL: URL { stateURL("mesh-state.bin") }

    private static func stateURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Letterbox", isDirectory: true).appendingPathComponent(name)
    }

    private static func loadIdentity(from secrets: SecretStore) -> IdentityKeys {
        if let noise = secrets.load(SecretKey.noise),
           let signing = secrets.load(SecretKey.signing),
           let keys = try? IdentityKeys(noisePrivate: noise, signingPrivate: signing) {
            return keys
        }
        let keys = IdentityKeys.generate()
        try? secrets.save(keys.noisePrivate, for: SecretKey.noise)
        try? secrets.save(keys.signingPrivate, for: SecretKey.signing)
        return keys
    }

    private static func loadSeed(from secrets: SecretStore) -> Data {
        if let seed = secrets.load(SecretKey.geoSeed), seed.count == 32 { return seed }
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try? secrets.save(seed, for: SecretKey.geoSeed)
        return seed
    }
}
