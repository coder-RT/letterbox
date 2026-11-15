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
    /// Their latest signed announce, passed on with their #nearby messages so a phone
    /// that catches up later can check who wrote them.
    var announce: Packet?
}

/// Recent #nearby messages (with their authors' announces) kept in memory to pass on to
/// phones that missed them: someone who walked out of range, arrived late, or restarted.
/// Bounded by count and age; only messages whose signature was checked are kept.
struct PublicArchive {
    struct Entry {
        let message: Packet
        let announce: Packet
    }

    private(set) var entries: [Data: Entry] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func contains(_ id: Data) -> Bool { entries[id] != nil }

    mutating func insert(_ entry: Entry) {
        entries[entry.message.packetID] = entry
        guard entries.count > capacity else { return }
        let oldest = entries.values.sorted { $0.message.timestamp < $1.message.timestamp }.prefix(entries.count - capacity)
        for entry in oldest { entries[entry.message.packetID] = nil }
    }

    mutating func prune(olderThan cutoff: UInt64) {
        entries = entries.filter { $0.value.message.timestamp >= cutoff }
    }

    /// IDs we hold, newest first.
    func ids(limit: Int) -> [Data] {
        entries.values.sorted { $0.message.timestamp > $1.message.timestamp }.prefix(limit).map(\.message.packetID)
    }

    /// What the other phone lacks: the newest `limit` messages since `since` that aren't
    /// in `have`, oldest first so they arrive in reading order.
    func missing(from have: Set<Data>, since: UInt64, limit: Int) -> [Entry] {
        entries.values
            .filter { $0.message.timestamp >= since && !have.contains($0.message.packetID) }
            .sorted { $0.message.timestamp > $1.message.timestamp }
            .prefix(limit)
            .reversed()
    }
}

/// A catch-up request we sent on one link: answers are accepted only for a short while,
/// and only as many as we asked for.
struct PendingSync {
    let requested: Date
    var remaining: Int
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
