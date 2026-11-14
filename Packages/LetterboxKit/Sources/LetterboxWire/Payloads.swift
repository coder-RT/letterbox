import Foundation

private func utf8(_ fields: [UInt8: Data], _ key: UInt8, _ name: String) throws -> String {
    guard let raw = fields[key], let value = String(data: raw, encoding: .utf8) else {
        throw WireError.invalidField(name)
    }
    return value
}

private func bytes(_ fields: [UInt8: Data], _ key: UInt8, _ name: String, count: Int) throws -> Data {
    guard let raw = fields[key], raw.count == count else { throw WireError.invalidField(name) }
    return raw
}

/// Payload of `.announce`.
public struct AnnouncePayload: Sendable, Equatable {
    public var nickname: String
    /// Curve25519 Noise static public key (32 bytes).
    public var noiseKey: Data
    /// Ed25519 signing public key (32 bytes).
    public var signingKey: Data

    private enum Field { static let nickname: UInt8 = 0x01, noiseKey: UInt8 = 0x02, signingKey: UInt8 = 0x03 }

    public init(nickname: String, noiseKey: Data, signingKey: Data) {
        self.nickname = nickname
        self.noiseKey = noiseKey
        self.signingKey = signingKey
    }

    public func encoded() -> Data {
        TLV.encode([
            (Field.nickname, Data(nickname.utf8)),
            (Field.noiseKey, noiseKey),
            (Field.signingKey, signingKey),
        ])
    }

    public static func decode(_ data: Data) throws -> AnnouncePayload {
        let fields = try TLV.decode(data)
        return AnnouncePayload(
            nickname: try utf8(fields, Field.nickname, "nickname"),
            noiseKey: try bytes(fields, Field.noiseKey, "noiseKey", count: 32),
            signingKey: try bytes(fields, Field.signingKey, "signingKey", count: 32)
        )
    }
}

/// Payload of `.publicMessage`.
public struct PublicMessagePayload: Sendable, Equatable {
    public static let maxTextBytes = 2000
    public var nickname: String
    public var text: String

    private enum Field { static let nickname: UInt8 = 0x01, text: UInt8 = 0x02 }

    public init(nickname: String, text: String) {
        self.nickname = nickname
        self.text = text
    }

    public func encoded() -> Data {
        TLV.encode([(Field.nickname, Data(nickname.utf8)), (Field.text, Data(text.utf8))])
    }

    public static func decode(_ data: Data) throws -> PublicMessagePayload {
        let fields = try TLV.decode(data)
        let text = try utf8(fields, Field.text, "text")
        guard text.utf8.count <= maxTextBytes else { throw WireError.tooLarge }
        return PublicMessagePayload(nickname: try utf8(fields, Field.nickname, "nickname"), text: text)
    }
}

/// Payload of `.handshake`: which Noise XX message this is, then the Noise bytes.
public struct HandshakePayload: Sendable, Equatable {
    public var stage: UInt8
    public var noiseMessage: Data

    public init(stage: UInt8, noiseMessage: Data) {
        self.stage = stage
        self.noiseMessage = noiseMessage
    }

    public func encoded() -> Data {
        var out = Data([stage])
        out.append(noiseMessage)
        return out
    }

    public static func decode(_ data: Data) throws -> HandshakePayload {
        var reader = ByteReader(data)
        let stage = try reader.readU8()
        guard stage <= 2 else { throw WireError.invalidField("stage") }
        return HandshakePayload(stage: stage, noiseMessage: reader.readRest())
    }
}

/// Payload of `.encrypted`: explicit 64-bit nonce, then ChaCha20-Poly1305 ciphertext+tag.
/// An explicit nonce (rather than Noise's implicit counter) tolerates loss and
/// reordering across mesh paths; the receiver enforces a replay window instead.
public struct EncryptedPayload: Sendable, Equatable {
    public var nonce: UInt64
    public var ciphertext: Data

    public init(nonce: UInt64, ciphertext: Data) {
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    public func encoded() -> Data {
        var out = Data()
        out.appendU64(nonce)
        out.append(ciphertext)
        return out
    }

    public static func decode(_ data: Data) throws -> EncryptedPayload {
        var reader = ByteReader(data)
        let nonce = try reader.readU64()
        let ciphertext = reader.readRest()
        guard ciphertext.count >= 16 else { throw WireError.truncated }
        return EncryptedPayload(nonce: nonce, ciphertext: ciphertext)
    }
}

/// What travels inside a Noise session.
public enum PrivatePayload: Sendable, Equatable {
    case message(id: String, nickname: String, text: String, timestamp: UInt64)
    case delivered(ids: [String])
    case read(ids: [String])

    private enum Kind { static let message: UInt8 = 0x01, delivered: UInt8 = 0x02, read: UInt8 = 0x03 }
    private enum Field {
        static let id: UInt8 = 0x01, nickname: UInt8 = 0x02, text: UInt8 = 0x03, timestamp: UInt8 = 0x04
        static let ids: UInt8 = 0x05
    }

    public func encoded() -> Data {
        var out = Data()
        switch self {
        case let .message(id, nickname, text, timestamp):
            out.append(Kind.message)
            var ts = Data()
            ts.appendU64(timestamp)
            out.append(TLV.encode([
                (Field.id, Data(id.utf8)),
                (Field.nickname, Data(nickname.utf8)),
                (Field.text, Data(text.utf8)),
                (Field.timestamp, ts),
            ]))
        case let .delivered(ids):
            out.append(Kind.delivered)
            out.append(TLV.encode([(Field.ids, Data(ids.joined(separator: "\n").utf8))]))
        case let .read(ids):
            out.append(Kind.read)
            out.append(TLV.encode([(Field.ids, Data(ids.joined(separator: "\n").utf8))]))
        }
        return out
    }

    public static func decode(_ data: Data) throws -> PrivatePayload {
        var reader = ByteReader(data)
        let kind = try reader.readU8()
        let fields = try TLV.decode(reader.readRest())
        switch kind {
        case Kind.message:
            var tsReader = ByteReader(try bytes(fields, Field.timestamp, "timestamp", count: 8))
            return .message(
                id: try utf8(fields, Field.id, "id"),
                nickname: try utf8(fields, Field.nickname, "nickname"),
                text: try utf8(fields, Field.text, "text"),
                timestamp: try tsReader.readU64()
            )
        case Kind.delivered:
            return .delivered(ids: try utf8(fields, Field.ids, "ids").split(separator: "\n").map(String.init))
        case Kind.read:
            return .read(ids: try utf8(fields, Field.ids, "ids").split(separator: "\n").map(String.init))
        default:
            throw WireError.unknownType(kind)
        }
    }
}

/// Payload of `.courier`: one message sealed to one person (Noise X), carried by
/// other phones until one of them meets that person.
///
/// Couriers see only a random ID, a recipient tag and the expiry. The tag is a hash of
/// the recipient's fingerprint and the ID, so a courier can recognise the recipient when
/// it meets them without the envelope naming them outright. All three are bound into
/// the seal, so a courier can't extend the expiry or redirect the envelope.
public struct CourierEnvelope: Sendable, Equatable {
    public static let idLength = 16
    public static let tagLength = 16
    public static let maxSealedBytes = 4096

    public var id: Data
    public var recipientTag: Data
    /// Milliseconds since 1970. Nobody carries or opens it after this.
    public var expiry: UInt64
    public var sealed: Data

    private enum Field { static let id: UInt8 = 0x01, tag: UInt8 = 0x02, expiry: UInt8 = 0x03, sealed: UInt8 = 0x04 }

    public init(id: Data, recipientTag: Data, expiry: UInt64, sealed: Data) {
        self.id = id
        self.recipientTag = recipientTag
        self.expiry = expiry
        self.sealed = sealed
    }

    /// What the seal authenticates besides the message: everything a courier can see.
    public static func associatedData(id: Data, recipientTag: Data, expiry: UInt64) -> Data {
        var out = Data("letterbox/courier/1".utf8)
        out.append(id)
        out.append(recipientTag)
        out.appendU64(expiry)
        return out
    }

    public var associatedData: Data {
        Self.associatedData(id: id, recipientTag: recipientTag, expiry: expiry)
    }

    public func encoded() -> Data {
        var expiryBytes = Data()
        expiryBytes.appendU64(expiry)
        return TLV.encode([
            (Field.id, id),
            (Field.tag, recipientTag),
            (Field.expiry, expiryBytes),
            (Field.sealed, sealed),
        ])
    }

    public static func decode(_ data: Data) throws -> CourierEnvelope {
        let fields = try TLV.decode(data)
        var expiryReader = ByteReader(try bytes(fields, Field.expiry, "expiry", count: 8))
        guard let sealed = fields[Field.sealed], !sealed.isEmpty else { throw WireError.invalidField("sealed") }
        guard sealed.count <= maxSealedBytes else { throw WireError.tooLarge }
        return CourierEnvelope(
            id: try bytes(fields, Field.id, "id", count: idLength),
            recipientTag: try bytes(fields, Field.tag, "tag", count: tagLength),
            expiry: try expiryReader.readU64(),
            sealed: sealed
        )
    }
}
