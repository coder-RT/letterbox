import Foundation

/// Splits a packet into chunks that fit one BLE write or notification, and puts
/// them back together on the other side of that one link.
///
/// Chunk: `frameID (2 B) | index (1 B) | count (1 B) | bytes`.
/// Reassembly is per hop: each relay rebuilds the full packet before deciding what to do.
public enum LinkFramer {
    public static let headerLength = 4
    public static let maxChunks = 255

    public static func chunks(for frame: Data, frameID: UInt16, mtu: Int) -> [Data] {
        let body = max(mtu - headerLength, 1)
        let count = max(1, Int((Double(frame.count) / Double(body)).rounded(.up)))
        guard count <= maxChunks else { return [] }
        return (0..<count).map { index in
            let start = frame.startIndex + index * body
            let end = min(start + body, frame.endIndex)
            var chunk = Data(capacity: headerLength + (end - start))
            chunk.appendU16(frameID)
            chunk.append(UInt8(index))
            chunk.append(UInt8(count))
            chunk.append(frame[start..<end])
            return chunk
        }
    }
}

/// Rebuilds frames from chunks arriving on a single link. Bounded in memory and time.
public struct FrameReassembler: Sendable {
    private struct Partial: Sendable {
        var parts: [Int: Data]
        let count: Int
        let started: Date
    }

    private var partials: [UInt16: Partial] = [:]
    private let timeout: TimeInterval
    private let maxConcurrent: Int

    public init(timeout: TimeInterval = 30, maxConcurrent: Int = 32) {
        self.timeout = timeout
        self.maxConcurrent = maxConcurrent
    }

    /// Feed one chunk; returns the complete frame once its last chunk arrives.
    public mutating func accept(_ chunk: Data, now: Date = Date()) -> Data? {
        guard chunk.count > LinkFramer.headerLength else { return nil }
        let bytes = [UInt8](chunk)
        let frameID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let index = Int(bytes[2])
        let count = Int(bytes[3])
        guard count >= 1, index < count else { return nil }
        let body = Data(bytes[LinkFramer.headerLength...])

        if count == 1 { return body }

        partials = partials.filter { now.timeIntervalSince($0.value.started) < timeout }
        var partial = partials[frameID] ?? Partial(parts: [:], count: count, started: now)
        guard partial.count == count else {
            partials[frameID] = nil
            return nil
        }
        if partials[frameID] == nil, partials.count >= maxConcurrent,
           let oldest = partials.min(by: { $0.value.started < $1.value.started })?.key {
            partials[oldest] = nil
        }
        partial.parts[index] = body
        if partial.parts.count == count {
            partials[frameID] = nil
            return (0..<count).reduce(into: Data()) { $0.append(partial.parts[$1]!) }
        }
        partials[frameID] = partial
        return nil
    }
}
