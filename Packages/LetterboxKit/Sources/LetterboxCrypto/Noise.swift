import CryptoKit
import Foundation

// Noise Protocol Framework (revision 34), pattern XX, suite 25519_ChaChaPoly_SHA256.
// https://noiseprotocol.org/noise.html
//
//   XX:
//     -> e
//     <- e, ee, s, es
//     -> s, se
//
// XX gives mutual authentication with no prior knowledge of the other side's key,
// plus forward secrecy: compromise of a static key later does not expose past sessions.

public enum NoiseError: Error, Equatable, Sendable {
    case decryptFailed
    case malformedMessage
    case outOfOrder
    case nonceExhausted
    case invalidKey
}

private let dhLength = 32
private let hashLength = 32
private let tagLength = 16

private func hmac(_ key: Data, _ data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// Noise HKDF (section 4.3), which differs from RFC 5869 only in how it is called.
private func noiseHKDF(chainingKey: Data, input: Data) -> (Data, Data) {
    let temp = hmac(chainingKey, input)
    let out1 = hmac(temp, Data([0x01]))
    let out2 = hmac(temp, out1 + Data([0x02]))
    return (out1, out2)
}

func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Data) throws -> Data {
    guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else {
        throw NoiseError.invalidKey
    }
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
    return shared.withUnsafeBytes { Data($0) }
}

// MARK: - CipherState

/// ChaCha20-Poly1305 with Noise nonce encoding: 32 zero bits then the 64-bit counter, little-endian.
public struct CipherState: Sendable {
    private var key: SymmetricKey?
    /// Next implicit nonce for the sequential API.
    public private(set) var nonce: UInt64 = 0

    init(key: Data? = nil) {
        self.key = key.map { SymmetricKey(data: $0) }
    }

    var hasKey: Bool { key != nil }

    private static func nonceBytes(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Encrypts with an explicit nonce. Used directly by the mesh transport.
    public func encrypt(nonce n: UInt64, ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard n != UInt64.max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonceBytes(n), authenticating: ad)
        return box.ciphertext + box.tag
    }

    public func decrypt(nonce n: UInt64, ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= tagLength else { throw NoiseError.malformedMessage }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -tagLength)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.nonceBytes(n),
                ciphertext: ciphertext[ciphertext.startIndex..<split],
                tag: ciphertext[split...]
            )
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseError.decryptFailed
        }
    }

    /// Sequential encrypt (Noise `EncryptWithAd`): uses and advances the implicit nonce.
    public mutating func encryptWithAd(_ ad: Data, _ plaintext: Data) throws -> Data {
        let out = try encrypt(nonce: nonce, ad: ad, plaintext: plaintext)
        if hasKey { nonce += 1 }
        return out
    }

    /// Sequential decrypt (Noise `DecryptWithAd`): the nonce only advances on success.
    public mutating func decryptWithAd(_ ad: Data, _ ciphertext: Data) throws -> Data {
        let out = try decrypt(nonce: nonce, ad: ad, ciphertext: ciphertext)
        if hasKey { nonce += 1 }
        return out
    }
}

// MARK: - SymmetricState

struct SymmetricState {
    private(set) var chainingKey: Data
    private(set) var handshakeHash: Data
    private(set) var cipher = CipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        if name.count <= hashLength {
            handshakeHash = name + Data(count: hashLength - name.count)
        } else {
            handshakeHash = Data(SHA256.hash(data: name))
        }
        chainingKey = handshakeHash
    }

    mutating func mixKey(_ input: Data) {
        let (ck, tempKey) = noiseHKDF(chainingKey: chainingKey, input: input)
        chainingKey = ck
        cipher = CipherState(key: tempKey)
    }

    mutating func mixHash(_ data: Data) {
        handshakeHash = Data(SHA256.hash(data: handshakeHash + data))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encryptWithAd(handshakeHash, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decryptWithAd(handshakeHash, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (CipherState, CipherState) {
        let (k1, k2) = noiseHKDF(chainingKey: chainingKey, input: Data())
        return (CipherState(key: k1), CipherState(key: k2))
    }
}

// MARK: - Handshake

/// The two cipher states produced by a finished handshake.
public struct NoiseTransport: Sendable {
    public var send: CipherState
    public var receive: CipherState
    /// Remote party's authenticated static public key.
    public let remoteStaticKey: Data
    /// Unique per-session value both sides agree on (channel binding).
    public let handshakeHash: Data
}

/// Runs one side of a Noise XX handshake.
public struct NoiseXXHandshake {
    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

    public enum Role: Sendable { case initiator, responder }

    private enum Token { case e, s, ee, es, se }
    private static let pattern: [[Token]] = [[.e], [.e, .ee, .s, .es], [.s, .se]]

    public let role: Role
    private var symmetric: SymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteStatic: Data?
    private var remoteEphemeral: Data?
    private var messageIndex = 0

    /// - Parameter ephemeral: inject a fixed ephemeral key (test vectors only).
    public init(role: Role, staticKey: Data, prologue: Data, ephemeral: Data? = nil) throws {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticKey) else {
            throw NoiseError.invalidKey
        }
        self.role = role
        localStatic = key
        if let ephemeral {
            localEphemeral = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeral)
        }
        symmetric = SymmetricState(protocolName: Self.protocolName)
        symmetric.mixHash(prologue)
    }

    public init(role: Role, identity: IdentityKeys, prologue: Data) throws {
        try self.init(role: role, staticKey: identity.noisePrivate, prologue: prologue)
    }

    public var isComplete: Bool { messageIndex >= Self.pattern.count }

    /// Whose turn it is to write.
    public var isMyTurn: Bool {
        guard !isComplete else { return false }
        let initiatorWrites = messageIndex.isMultiple(of: 2)
        return (role == .initiator) == initiatorWrites
    }

    public var handshakeHash: Data { symmetric.handshakeHash }

    public mutating func writeMessage(payload: Data = Data()) throws -> Data {
        guard isMyTurn else { throw NoiseError.outOfOrder }
        var out = Data()
        for token in Self.pattern[messageIndex] {
            switch token {
            case .e:
                let ephemeral = localEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
                localEphemeral = ephemeral
                let pub = ephemeral.publicKey.rawRepresentation
                out.append(pub)
                symmetric.mixHash(pub)
            case .s:
                out.append(try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation))
            case .ee, .es, .se:
                symmetric.mixKey(try dhFor(token))
            }
        }
        out.append(try symmetric.encryptAndHash(payload))
        messageIndex += 1
        return out
    }

    public mutating func readMessage(_ message: Data) throws -> Data {
        guard !isComplete, !isMyTurn else { throw NoiseError.outOfOrder }
        // Work on a copy so a bad message leaves the handshake untouched.
        var copy = self
        var cursor = message.startIndex
        func take(_ count: Int) throws -> Data {
            guard message.endIndex - cursor >= count else { throw NoiseError.malformedMessage }
            defer { cursor += count }
            return Data(message[cursor..<cursor + count])
        }
        for token in Self.pattern[messageIndex] {
            switch token {
            case .e:
                let re = try take(dhLength)
                copy.remoteEphemeral = re
                copy.symmetric.mixHash(re)
            case .s:
                let length = copy.symmetric.cipher.hasKey ? dhLength + tagLength : dhLength
                copy.remoteStatic = try copy.symmetric.decryptAndHash(try take(length))
            case .ee, .es, .se:
                copy.symmetric.mixKey(try copy.dhFor(token))
            }
        }
        let payload = try copy.symmetric.decryptAndHash(Data(message[cursor...]))
        copy.messageIndex += 1
        self = copy
        return payload
    }

    /// Call once `isComplete`.
    public func finish() throws -> NoiseTransport {
        guard isComplete, let remoteStatic else { throw NoiseError.outOfOrder }
        let (c1, c2) = symmetric.split()
        return switch role {
        case .initiator:
            NoiseTransport(send: c1, receive: c2, remoteStaticKey: remoteStatic, handshakeHash: symmetric.handshakeHash)
        case .responder:
            NoiseTransport(send: c2, receive: c1, remoteStaticKey: remoteStatic, handshakeHash: symmetric.handshakeHash)
        }
    }

    private func dhFor(_ token: Token) throws -> Data {
        switch (token, role) {
        case (.ee, _):
            guard let e = localEphemeral, let re = remoteEphemeral else { throw NoiseError.outOfOrder }
            return try dh(e, re)
        case (.es, .initiator), (.se, .responder):
            guard let e = localEphemeral, let rs = remoteStatic else { throw NoiseError.outOfOrder }
            return try dh(e, rs)
        case (.es, .responder), (.se, .initiator):
            guard let re = remoteEphemeral else { throw NoiseError.outOfOrder }
            return try dh(localStatic, re)
        default:
            throw NoiseError.outOfOrder
        }
    }
}

// MARK: - Replay protection

/// Accepts each explicit nonce at most once, within a sliding window behind the highest seen.
public struct ReplayWindow: Sendable {
    public static let size: UInt64 = 1024
    private var highest: UInt64?
    private var seen: Set<UInt64> = []

    public init() {}

    public func wouldAccept(_ nonce: UInt64) -> Bool {
        guard let highest else { return true }
        if nonce > highest { return true }
        if highest - nonce >= Self.size { return false }
        return !seen.contains(nonce)
    }

    /// Record a nonce after its ciphertext authenticated.
    public mutating func record(_ nonce: UInt64) {
        seen.insert(nonce)
        if highest == nil || nonce > highest! {
            highest = nonce
            // Forget only what `wouldAccept` already rejects as too old. Until the
            // window has slid past zero there is nothing to forget, and filtering
            // with a floor of 0 would drop nonce 0 and let it be replayed.
            if nonce >= Self.size {
                let floor = nonce - Self.size
                seen = seen.filter { $0 > floor }
            }
        }
    }
}
