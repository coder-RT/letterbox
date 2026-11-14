import CryptoKit
import Foundation
import LetterboxDomain

/// A device's long-term keys. Stored as raw bytes so the type is trivially Sendable;
/// CryptoKit key objects are rebuilt on use (cheap).
public struct IdentityKeys: Sendable, Equatable {
    /// Curve25519 private key for Noise key agreement.
    public let noisePrivate: Data
    /// Ed25519 private key for packet signatures.
    public let signingPrivate: Data

    public init(noisePrivate: Data, signingPrivate: Data) throws {
        // Validate both up front so later force-unwraps are safe.
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: noisePrivate)
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivate)
        self.noisePrivate = noisePrivate
        self.signingPrivate = signingPrivate
    }

    public static func generate() -> IdentityKeys {
        try! IdentityKeys(
            noisePrivate: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            signingPrivate: Curve25519.Signing.PrivateKey().rawRepresentation
        )
    }

    var noiseKey: Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: noisePrivate)
    }

    private var signingKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivate)
    }

    public var noisePublic: Data { noiseKey.publicKey.rawRepresentation }
    public var signingPublic: Data { signingKey.publicKey.rawRepresentation }
    public var fingerprint: Fingerprint { Self.fingerprint(ofNoiseKey: noisePublic) }

    public func sign(_ data: Data) -> Data {
        // CryptoKit Ed25519 signing only fails on a broken key, which init rules out.
        try! signingKey.signature(for: data)
    }

    public static func verify(_ signature: Data, for data: Data, signingKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    public static func fingerprint(ofNoiseKey key: Data) -> Fingerprint {
        Fingerprint(hex: Data(SHA256.hash(data: key)).hexString)
    }
}
