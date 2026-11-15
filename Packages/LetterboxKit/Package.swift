// swift-tools-version: 6.0
// LetterboxKit: all of the app's real logic, split into modules along ports-and-adapters lines.
// Each target lists its dependencies explicitly, so a forbidden import fails to compile:
// the domain and application layers can never reach CoreBluetooth, URLSession or the Keychain.
import PackageDescription

let package = Package(
    name: "LetterboxKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "LetterboxDomain", targets: ["LetterboxDomain"]),
        .library(name: "LetterboxWire", targets: ["LetterboxWire"]),
        .library(name: "LetterboxCrypto", targets: ["LetterboxCrypto"]),
        .library(name: "LetterboxMesh", targets: ["LetterboxMesh"]),
        .library(name: "LetterboxBLE", targets: ["LetterboxBLE"]),
        .library(name: "LetterboxNostr", targets: ["LetterboxNostr"]),
        .library(name: "LetterboxPersistence", targets: ["LetterboxPersistence"]),
        .library(name: "LetterboxApplication", targets: ["LetterboxApplication"]),
        .library(name: "LetterboxDevice", targets: ["LetterboxDevice"]),
        // Simulated radio and phones: unit tests, and the app's UI-test mode (DEBUG only).
        .library(name: "LetterboxTestSupport", targets: ["LetterboxTestSupport"]),
    ],
    dependencies: [
        // BIP-340 Schnorr signatures for Nostr events (CryptoKit has no secp256k1).
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.25.1"),
    ],
    targets: [
        // Core: entities, value types and ports (protocols). Foundation only.
        .target(name: "LetterboxDomain"),

        // Use cases and UI-facing state. Talks to the outside world only through domain ports.
        .target(name: "LetterboxApplication", dependencies: ["LetterboxDomain"]),

        // Pure binary wire format: packets, TLV payloads, BLE link framing.
        .target(name: "LetterboxWire", dependencies: ["LetterboxDomain"]),

        // Identity keys, Ed25519 signatures, Noise XX. CryptoKit only.
        .target(name: "LetterboxCrypto", dependencies: ["LetterboxDomain"]),

        // Mesh engine: flooding, dedup, peers, Noise sessions. Implements the MeshTransport port
        // on top of an abstract LinkLayer port, so it runs in tests with no radio.
        .target(name: "LetterboxMesh", dependencies: ["LetterboxDomain", "LetterboxWire", "LetterboxCrypto"]),

        // Adapter: what the device reports about its network, mobile radio and location
        // permission (Network, CoreTelephony, CoreLocation), for the ConnectivityMonitor port.
        .target(name: "LetterboxDevice", dependencies: ["LetterboxDomain"]),

        // Adapter: CoreBluetooth implementation of the mesh LinkLayer port.
        .target(name: "LetterboxBLE", dependencies: ["LetterboxMesh", "LetterboxWire", "LetterboxDomain"]),

        // Adapter: Nostr relays for geohash location channels.
        .target(name: "LetterboxNostr", dependencies: [
            "LetterboxDomain",
            .product(name: "P256K", package: "swift-secp256k1"),
        ]),

        // Adapter: Keychain implementation of the SecretStore port.
        .target(name: "LetterboxPersistence", dependencies: ["LetterboxDomain"]),

        // In-memory radio for multi-node mesh tests.
        .target(name: "LetterboxTestSupport", dependencies: ["LetterboxMesh", "LetterboxDomain", "LetterboxWire", "LetterboxCrypto"]),

        .testTarget(name: "LetterboxDomainTests", dependencies: ["LetterboxDomain"]),
        .testTarget(name: "LetterboxWireTests", dependencies: ["LetterboxWire", "LetterboxDomain"]),
        .testTarget(
            name: "LetterboxCryptoTests",
            dependencies: ["LetterboxCrypto", "LetterboxDomain"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "LetterboxMeshTests", dependencies: [
            "LetterboxMesh", "LetterboxTestSupport", "LetterboxCrypto", "LetterboxDomain",
        ]),
        .testTarget(name: "LetterboxNostrTests", dependencies: ["LetterboxNostr", "LetterboxDomain"]),
        .testTarget(name: "LetterboxApplicationTests", dependencies: [
            "LetterboxApplication", "LetterboxDomain",
            // Integration tests run the real engine under the store, on a simulated radio.
            "LetterboxMesh", "LetterboxCrypto", "LetterboxTestSupport",
        ]),
        .testTarget(name: "LetterboxPersistenceTests", dependencies: ["LetterboxPersistence", "LetterboxDomain"]),
        .testTarget(name: "LetterboxDeviceTests", dependencies: ["LetterboxDevice", "LetterboxDomain"]),
    ],
    swiftLanguageModes: [.v6]
)
