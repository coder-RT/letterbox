import Foundation

/// Payload of `.syncRequest`: the oldest message time we care about and the IDs of the
/// #nearby messages we already hold, so the neighbour sends only what's missing.
public struct SyncRequestPayload: Sendable, Equatable {
    /// Most message IDs listed in one request (8 bytes each, so under 3 KB).
    public static let maxIDs = 300
    /// Milliseconds since 1970.
    public var since: UInt64
    public var have: [Data]

    private enum Field { static let since: UInt8 = 0x01, have: UInt8 = 0x02 }

    public init(since: UInt64, have: [Data]) {
        self.since = since
        self.have = have
    }

    public func encoded() -> Data {
        var since = Data()
        since.appendU64(self.since)
        let ids = have.prefix(Self.maxIDs).filter { $0.count == Packet.packetIDLength }
        return TLV.encode([(Field.since, since), (Field.have, Data(ids.joined()))])
    }

    public static func decode(_ data: Data) throws -> SyncRequestPayload {
        let fields = try TLV.decode(data)
        guard let rawSince = fields[Field.since], rawSince.count == 8 else { throw WireError.invalidField("since") }
        var reader = ByteReader(rawSince)
        let since = try reader.readU64()
        let raw = fields[Field.have] ?? Data()
        let size = Packet.packetIDLength
        guard raw.count % size == 0, raw.count / size <= maxIDs else { throw WireError.invalidField("have") }
        let ids = stride(from: 0, to: raw.count, by: size).map { offset in
            Data(raw[raw.startIndex + offset ..< raw.startIndex + offset + size])
        }
        return SyncRequestPayload(since: since, have: ids)
    }
}

/// Payload of `.syncResponse`: the original signed public message and the signed
/// announce of whoever wrote it. Both are checked as if they had arrived live.
public struct SyncResponsePayload: Sendable, Equatable {
    public var message: Data
    public var announce: Data

    private enum Field { static let message: UInt8 = 0x01, announce: UInt8 = 0x02 }

    public init(message: Data, announce: Data) {
        self.message = message
        self.announce = announce
    }

    public func encoded() -> Data {
        TLV.encode([(Field.message, message), (Field.announce, announce)])
    }

    public static func decode(_ data: Data) throws -> SyncResponsePayload {
        let fields = try TLV.decode(data)
        guard let message = fields[Field.message], let announce = fields[Field.announce] else {
            throw WireError.invalidField("sync response")
        }
        return SyncResponsePayload(message: message, announce: announce)
    }
}
