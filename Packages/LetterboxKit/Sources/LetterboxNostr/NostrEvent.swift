import CryptoKit
import Foundation
import LetterboxDomain
import P256K

/// A signed Nostr event (NIP-01).
public struct NostrEvent: Codable, Sendable, Equatable {
    public let id: String
    public let pubkey: String
    public let created_at: Int
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public let sig: String

    public func firstTag(_ name: String) -> String? {
        tags.first { $0.count >= 2 && $0[0] == name }?[1]
    }

    /// NIP-01 canonical form: `[0,<pubkey>,<created_at>,<kind>,<tags>,<content>]`, no whitespace.
    public static func canonicalJSON(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> String {
        let tagJSON = "[" + tags.map { "[" + $0.map(quote).joined(separator: ",") + "]" }.joined(separator: ",") + "]"
        return "[0,\(quote(pubkey)),\(createdAt),\(kind),\(tagJSON),\(quote(content))]"
    }

    public static func computeID(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> Data {
        let json = canonicalJSON(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        return Data(CryptoKit.SHA256.hash(data: Data(json.utf8)))
    }

    /// JSON string escaping as NIP-01 specifies (matches JavaScript's JSON.stringify).
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Checks the ID matches the content and the Schnorr signature matches the pubkey.
    public var isValid: Bool {
        let expected = Self.computeID(pubkey: pubkey, createdAt: created_at, kind: kind, tags: tags, content: content)
        guard expected.hexString == id.lowercased(),
              let pubkeyBytes = Data(hexString: pubkey), pubkeyBytes.count == 32,
              let sigBytes = Data(hexString: sig), sigBytes.count == 64,
              let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sigBytes)
        else { return false }
        // Since swift-secp256k1 0.25 an x-only key is validated (length and curve point)
        // when it's created, so a malformed key from a relay is rejected here, not deep inside.
        guard let key = try? P256K.Schnorr.XonlyKey(dataRepresentation: pubkeyBytes) else { return false }
        return key.isValid(signature, for: [UInt8](expected))
    }
}

/// A secp256k1 key pair for signing Nostr events. Raw bytes only, so it is Sendable.
public struct NostrKeys: Sendable, Equatable {
    public let privateKey: Data
    /// x-only public key, hex.
    public let publicKeyHex: String

    public init(privateKey: Data) throws {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        self.privateKey = privateKey
        publicKeyHex = Data(key.xonly.dataRepresentation).hexString
    }

    public static func generate() -> NostrKeys {
        while true {
            if let keys = try? NostrKeys(privateKey: Data(CryptoKit.SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })) {
                return keys
            }
        }
    }

    /// Location-channel identity: a separate key per geohash, derived from one device seed,
    /// so posts in different places cannot be linked to each other or to the mesh identity.
    public static func forGeohash(_ geohash: String, seed: Data) -> NostrKeys {
        var counter: UInt8 = 0
        while true {
            let input = Data("letterbox/geo/\(geohash)/\(counter)".utf8)
            let candidate = Data(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: input, using: CryptoKit.SymmetricKey(data: seed)))
            if let keys = try? NostrKeys(privateKey: candidate) { return keys }
            counter &+= 1 // Invalid scalars are astronomically rare; try the next one.
        }
    }

    public func sign(kind: Int, tags: [[String]], content: String, createdAt: Date = Date()) throws -> NostrEvent {
        let timestamp = Int(createdAt.timeIntervalSince1970)
        let id = NostrEvent.computeID(pubkey: publicKeyHex, createdAt: timestamp, kind: kind, tags: tags, content: content)
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        let auxiliary = [UInt8](CryptoKit.SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        // BIP-340 over the 32-byte event id; the library verifies its own output before returning.
        let signature = try key.signature(message: [UInt8](id), auxiliaryRand: auxiliary)
        return NostrEvent(
            id: id.hexString,
            pubkey: publicKeyHex,
            created_at: timestamp,
            kind: kind,
            tags: tags,
            content: content,
            sig: signature.dataRepresentation.hexString
        )
    }
}

/// Subscription filter (NIP-01) with the subset of fields Letterbox uses.
public struct NostrFilter: Sendable, Equatable, Encodable {
    public var kinds: [Int]
    public var geohashes: [String]
    public var since: Int?
    public var limit: Int?

    public init(kinds: [Int], geohashes: [String], since: Int? = nil, limit: Int? = nil) {
        self.kinds = kinds
        self.geohashes = geohashes
        self.since = since
        self.limit = limit
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(kinds, forKey: Key("kinds"))
        if !geohashes.isEmpty { try container.encode(geohashes, forKey: Key("#g")) }
        if let since { try container.encode(since, forKey: Key("since")) }
        if let limit { try container.encode(limit, forKey: Key("limit")) }
    }
}
