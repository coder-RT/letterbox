import Foundation

public enum WireError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case invalidField(String)
    case tooLarge
}

/// Sequential big-endian reader over a byte buffer. Never traps on short input.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }

    mutating func readU8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU16() throws -> UInt16 {
        let raw = try read(2)
        return UInt16(raw[0]) << 8 | UInt16(raw[1])
    }

    mutating func readU64() throws -> UInt64 {
        try read(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func readRest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}

extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendU64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

/// Type-length-value fields: 1-byte type, 2-byte big-endian length, value.
/// Unknown types are kept, so newer peers can add fields without breaking older ones.
public enum TLV {
    public static func encode(_ fields: [(UInt8, Data)]) -> Data {
        var out = Data()
        for (type, value) in fields {
            precondition(value.count <= Int(UInt16.max), "TLV value too large")
            out.append(type)
            out.appendU16(UInt16(value.count))
            out.append(value)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> [UInt8: Data] {
        var reader = ByteReader(data)
        var fields: [UInt8: Data] = [:]
        while reader.remaining > 0 {
            let type = try reader.readU8()
            let length = try reader.readU16()
            fields[type] = try reader.read(Int(length))
        }
        return fields
    }
}
