import Foundation
import LetterboxDomain

public enum PacketType: UInt8, Sendable, CaseIterable {
    /// Signed "I'm here": nickname and public keys. Flooded.
    case announce = 0x01
    /// Signed public chat line. Flooded.
    case publicMessage = 0x02
    /// Signed "I'm leaving". Flooded.
    case leave = 0x03
    /// Noise XX handshake message. Directed.
    case handshake = 0x10
    /// Noise transport ciphertext (DMs and receipts). Directed.
    case encrypted = 0x11
    /// A sealed message carried by other people (store and forward). Handed to direct
    /// neighbours with TTL 1, or directed at its recipient once a courier meets them.
    case courier = 0x12
}

/// One mesh packet.
///
/// ```
/// ┌───────┬─────┬──────┬─────┬───────┬───────────┬──────────┬────────┬────────────┬────────────┬─────────┬───────────┐
/// │ magic │ ver │ type │ TTL │ flags │ timestamp │ packetID │ sender │ recipient? │ payloadLen │ payload │ signature?│
/// │  2 B  │ 1 B │ 1 B  │ 1 B │  1 B  │ 8 B (ms)  │   8 B    │  8 B   │    8 B     │    2 B     │  var    │   64 B    │
/// └───────┴─────┴──────┴─────┴───────┴───────────┴──────────┴────────┴────────────┴────────────┴─────────┴───────────┘
/// flags: 0x01 has recipient, 0x02 has signature. All integers big-endian.
/// ```
///
/// The signature covers every byte except TTL (encoded as 0) and the signature itself,
/// so relays can decrement TTL without invalidating it.
public struct Packet: Sendable, Equatable {
    public static let magic: [UInt8] = [0x4C, 0x42] // "LB"
    public static let version: UInt8 = 1
    public static let packetIDLength = 8
    public static let signatureLength = 64
    public static let maxPayload = 32 * 1024
    static let headerLength = 2 + 1 + 1 + 1 + 1 + 8 + 8 + 8

    private enum Flag {
        static let hasRecipient: UInt8 = 0x01
        static let hasSignature: UInt8 = 0x02
    }

    public var type: PacketType
    public var ttl: UInt8
    /// Milliseconds since 1970.
    public var timestamp: UInt64
    /// Random per packet; the dedup key across the mesh.
    public var packetID: Data
    public var sender: PeerID
    public var recipient: PeerID?
    public var payload: Data
    public var signature: Data?

    public init(
        type: PacketType,
        ttl: UInt8,
        timestamp: UInt64,
        packetID: Data,
        sender: PeerID,
        recipient: PeerID? = nil,
        payload: Data,
        signature: Data? = nil
    ) {
        self.type = type
        self.ttl = ttl
        self.timestamp = timestamp
        self.packetID = packetID
        self.sender = sender
        self.recipient = recipient
        self.payload = payload
        self.signature = signature
    }

    public static func randomPacketID() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<packetIDLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Bytes an Ed25519 signature is computed over.
    public func signingBytes() -> Data {
        serialize(ttl: 0, includeSignature: false)
    }

    public func encoded() -> Data {
        serialize(ttl: ttl, includeSignature: true)
    }

    private func serialize(ttl: UInt8, includeSignature: Bool) -> Data {
        var flags: UInt8 = 0
        if recipient != nil { flags |= Flag.hasRecipient }
        let signed = includeSignature && signature != nil
        if signed { flags |= Flag.hasSignature }

        var out = Data(capacity: Self.headerLength + payload.count + 80)
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(type.rawValue)
        out.append(ttl)
        out.append(flags)
        out.appendU64(timestamp)
        out.append(packetID)
        out.append(sender.bytes)
        if let recipient { out.append(recipient.bytes) }
        out.appendU16(UInt16(payload.count))
        out.append(payload)
        if signed, let signature { out.append(signature) }
        return out
    }

    public static func decode(_ data: Data) throws -> Packet {
        var reader = ByteReader(data)
        guard try reader.read(2) == Data(magic) else { throw WireError.badMagic }
        let version = try reader.readU8()
        guard version == Self.version else { throw WireError.unsupportedVersion(version) }
        let rawType = try reader.readU8()
        guard let type = PacketType(rawValue: rawType) else { throw WireError.unknownType(rawType) }
        let ttl = try reader.readU8()
        let flags = try reader.readU8()
        let timestamp = try reader.readU64()
        let packetID = try reader.read(packetIDLength)
        guard let sender = PeerID(bytes: try reader.read(PeerID.byteCount)) else { throw WireError.truncated }
        var recipient: PeerID?
        if flags & Flag.hasRecipient != 0 {
            recipient = PeerID(bytes: try reader.read(PeerID.byteCount))
        }
        let length = Int(try reader.readU16())
        guard length <= maxPayload else { throw WireError.tooLarge }
        let payload = try reader.read(length)
        var signature: Data?
        if flags & Flag.hasSignature != 0 {
            signature = try reader.read(signatureLength)
        }
        guard reader.remaining == 0 else { throw WireError.invalidField("trailing bytes") }
        return Packet(
            type: type,
            ttl: ttl,
            timestamp: timestamp,
            packetID: packetID,
            sender: sender,
            recipient: recipient,
            payload: payload,
            signature: signature
        )
    }
}
