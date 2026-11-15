import Foundation
import LetterboxCrypto
import LetterboxDomain
import LetterboxWire

/// Packet IDs seen recently, so each packet is processed and relayed once.
struct SeenPackets {
    private var entries: [Data: Date] = [:]
    private let capacity: Int
    private let lifetime: TimeInterval

    init(capacity: Int = 4096, lifetime: TimeInterval = 600) {
        self.capacity = capacity
        self.lifetime = lifetime
    }

    /// Returns false if the ID was already present.
    mutating func insert(_ id: Data, now: Date) -> Bool {
        if entries[id] != nil { return false }
        if entries.count >= capacity { prune(now: now, force: true) }
        entries[id] = now
        return true
    }

    mutating func prune(now: Date, force: Bool = false) {
        entries = entries.filter { now.timeIntervalSince($0.value) < lifetime }
        if force, entries.count >= capacity {
            let keep = entries.sorted { $0.value > $1.value }.prefix(capacity / 2)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

/// Bounded set of recently received direct-message IDs (drops resent duplicates).
struct RecentIDs {
    private(set) var order: [String] = []
    private var set: Set<String> = []
    private let capacity: Int

    init(capacity: Int = 2000, restoring saved: [String] = []) {
        self.capacity = capacity
        for id in saved.suffix(capacity) { _ = insert(id) }
    }

    func contains(_ id: String) -> Bool { set.contains(id) }

    mutating func insert(_ id: String) -> Bool {
        guard set.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            set.remove(order.removeFirst())
        }
        return true
    }
}

struct PeerRecord {
    let peerID: PeerID
    var nickname: String
    let noiseKey: Data
    let signingKey: Data
    let fingerprint: Fingerprint
    var lastSeen: Date
    var directLinks: Set<LinkID>
}

enum Session {
    case handshaking(NoiseXXHandshake, started: Date)
    case established(NoiseTransport, sendNonce: UInt64, replay: ReplayWindow)

    var isEstablished: Bool {
        if case .established = self { return true }
        return false
    }
}

struct OutgoingPrivate {
    let payload: PrivatePayload
    let created: Date
    /// Sealed copy for couriers, made once the message has waited a while.
    var envelope: CourierEnvelope?
    /// Who has been handed a copy, so each courier gets it once.
    var couriers: Set<Fingerprint> = []

    var messageID: String? {
        if case let .message(id, _, _, _) = payload { return id }
        return nil
    }
}

/// Token buckets keyed by anything (a sender, a Bluetooth link). Each key may spend up
/// to `capacity` tokens at once, refilled at `perMinute`. Bounded in memory: idle keys
/// are forgotten, and at most `maxKeys` are tracked (the stalest go first).
struct RateLimiter<Key: Hashable> {
    private struct Bucket {
        var tokens: Double
        var updated: Date
    }

    private var buckets: [Key: Bucket] = [:]
    let capacity: Double
    let perMinute: Double
    let maxKeys: Int

    init(capacity: Double, perMinute: Double, maxKeys: Int = 1024) {
        self.capacity = capacity
        self.perMinute = perMinute
        self.maxKeys = maxKeys
    }

    /// Spends one token for `key`. Returns false (and spends nothing) when it's empty.
    mutating func allow(_ key: Key, now: Date) -> Bool {
        var bucket = buckets[key] ?? Bucket(tokens: capacity, updated: now)
        let elapsed = max(0, now.timeIntervalSince(bucket.updated))
        bucket.tokens = min(capacity, bucket.tokens + elapsed * perMinute / 60)
        bucket.updated = now
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        if buckets[key] == nil, buckets.count >= maxKeys, let stalest = buckets.min(by: { $0.value.updated < $1.value.updated })?.key {
            buckets[stalest] = nil
        }
        buckets[key] = bucket
        return true
    }

    var trackedKeys: Int { buckets.count }
}
