import CryptoKit
import Foundation

// Noise pattern X, suite 25519_ChaChaPoly_SHA256: a one-way message to someone whose
// static key you already know.
//
//   X:
//     <- s
//     ...
//     -> e, es, s, ss
//
// Used for messages carried by couriers: there is no live session to run a handshake
// over, so the sender seals one self-contained message. The recipient learns, and can
// trust, the sender's static key. Unlike an XX session there is no forward secrecy:
// someone who later steals the recipient's static key can open captured envelopes.

public enum NoiseXSeal {
    public static let protocolName = "Noise_X_25519_ChaChaPoly_SHA256"
    /// Bytes added to the plaintext: ephemeral key, encrypted static key, payload tag.
    public static let overhead = 32 + (32 + 16) + 16

    /// - Parameter ephemeral: inject a fixed ephemeral key (tests only).
    public static func seal(
        _ plaintext: Data,
        to recipientStatic: Data,
        from sender: IdentityKeys,
        prologue: Data,
        ephemeral: Data? = nil
    ) throws -> Data {
        var state = SymmetricState(protocolName: protocolName)
        state.mixHash(prologue)
        state.mixHash(recipientStatic) // pre-message: <- s

        let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
        if let ephemeral {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeral) else {
                throw NoiseError.invalidKey
            }
            ephemeralKey = key
        } else {
            ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        }
        let ephemeralPublic = ephemeralKey.publicKey.rawRepresentation
        var out = ephemeralPublic
        state.mixHash(ephemeralPublic)                              // e
        state.mixKey(try dh(ephemeralKey, recipientStatic))         // es
        out.append(try state.encryptAndHash(sender.noisePublic))    // s
        state.mixKey(try dh(sender.noiseKey, recipientStatic))      // ss
        out.append(try state.encryptAndHash(plaintext))
        return out
    }

    /// Opens a sealed message. Returns the sender's authenticated static key and the plaintext.
    public static func open(
        _ message: Data,
        with recipient: IdentityKeys,
        prologue: Data
    ) throws -> (senderStatic: Data, plaintext: Data) {
        let bytes = Data(message) // re-base indices at zero
        guard bytes.count >= overhead else { throw NoiseError.malformedMessage }
        var state = SymmetricState(protocolName: protocolName)
        state.mixHash(prologue)
        state.mixHash(recipient.noisePublic)

        let remoteEphemeral = bytes.subdata(in: 0..<32)
        state.mixHash(remoteEphemeral)
        state.mixKey(try dh(recipient.noiseKey, remoteEphemeral))
        let senderStatic = try state.decryptAndHash(bytes.subdata(in: 32..<80))
        state.mixKey(try dh(recipient.noiseKey, senderStatic))
        let plaintext = try state.decryptAndHash(bytes.subdata(in: 80..<bytes.count))
        return (senderStatic, plaintext)
    }
}
