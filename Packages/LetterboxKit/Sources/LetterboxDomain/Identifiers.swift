import Foundation

/// 8-byte on-air mesh address.
///
/// Letterbox picks a fresh random PeerID on every launch, so a passive listener
/// cannot link one session's radio presence to the next by address alone.
/// Long-term identity is the `Fingerprint`, which is only meaningful to peers
/// that have seen the signed announce.
public struct PeerID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 8
    public let bytes: Data

    public init?(bytes: some DataProtocol) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    public static func random() -> PeerID {
        var generator = SystemRandomNumberGenerator()
        let raw = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PeerID(bytes: raw)!
    }

    public var hex: String { bytes.hexString }
    public var description: String { hex }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

/// Stable identity of a person: SHA-256 of their Noise static public key, as lowercase hex.
public struct Fingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hex: String

    public init(hex: String) {
        self.hex = hex.lowercased()
    }

    /// Short human-comparable form, e.g. `3fa9 c210 77be 01d4`.
    public var short: String {
        let prefix = hex.prefix(16)
        return stride(from: 0, to: prefix.count, by: 4).map { offset -> String in
            let start = prefix.index(prefix.startIndex, offsetBy: offset)
            let end = prefix.index(start, offsetBy: 4, limitedBy: prefix.endIndex) ?? prefix.endIndex
            return String(prefix[start..<end])
        }.joined(separator: " ")
    }

    public var description: String { hex }
}

public extension DataProtocol {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public extension Data {
    /// Parses lowercase or uppercase hex; returns nil on odd length or bad characters.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        self = out
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
