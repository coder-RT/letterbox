import CryptoKit
import Foundation
import LetterboxCrypto
import LetterboxDomain
import LetterboxWire

/// Someone we've met, kept so we can seal messages to them after they've left.
struct Contact: Codable, Equatable {
    var fingerprint: Fingerprint
    var nickname: String
    /// Curve25519 Noise static public key. Its SHA-256 is the fingerprint.
    var noiseKey: Data
    var lastSeen: Date
}

/// Sealing and opening courier envelopes.
enum Courier {
    /// Lets a courier recognise the recipient when it meets them, without the envelope
    /// naming them outright.
    static func tag(for fingerprint: Fingerprint, envelopeID: Data) -> Data {
        var input = Data("letterbox/courier/tag".utf8)
        input.append(Data(hexString: fingerprint.hex) ?? Data(fingerprint.hex.utf8))
        input.append(envelopeID)
        return Data(SHA256.hash(data: input).prefix(CourierEnvelope.tagLength))
    }

    static func seal(_ payload: PrivatePayload, to contact: Contact, from identity: IdentityKeys, expiry: Date) -> CourierEnvelope? {
        var generator = SystemRandomNumberGenerator()
        let id = Data((0..<CourierEnvelope.idLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let tag = tag(for: contact.fingerprint, envelopeID: id)
        let expiryMilliseconds = UInt64(max(0, expiry.timeIntervalSince1970 * 1000))
        let prologue = CourierEnvelope.associatedData(id: id, recipientTag: tag, expiry: expiryMilliseconds)
        guard let sealed = try? NoiseXSeal.seal(payload.encoded(), to: contact.noiseKey, from: identity, prologue: prologue),
              sealed.count <= CourierEnvelope.maxSealedBytes
        else { return nil }
        return CourierEnvelope(id: id, recipientTag: tag, expiry: expiryMilliseconds, sealed: sealed)
    }

    static func open(_ envelope: CourierEnvelope, as identity: IdentityKeys) -> (senderKey: Data, payload: PrivatePayload)? {
        guard let opened = try? NoiseXSeal.open(envelope.sealed, with: identity, prologue: envelope.associatedData),
              let payload = try? PrivatePayload.decode(opened.plaintext)
        else { return nil }
        return (opened.senderStatic, payload)
    }
}

/// Envelopes this phone carries for other people. Bounded in count and in time, so a
/// flood of envelopes can only push out others, never fill the phone.
struct CarriedEnvelopes {
    struct Item {
        let envelope: CourierEnvelope
        let received: Date
        /// The link it was handed over on, for the per-depositor share (nil once restored
        /// from disk: link IDs don't survive a restart).
        var depositor: LinkID?
        /// Last time we handed it to its recipient. We keep it until it expires, since a
        /// hand-off across several hops can be lost; the recipient drops duplicates.
        var lastDelivery: Date?
    }

    private(set) var items: [Data: Item] = [:]
    let capacity: Int
    let maxLifetime: TimeInterval

    init(capacity: Int = 256, maxLifetime: TimeInterval = 3 * 24 * 60 * 60) {
        self.capacity = capacity
        self.maxLifetime = maxLifetime
    }

    var count: Int { items.count }

    /// When we stop carrying it: its own expiry, or our limit, whichever comes first.
    func expiry(of item: Item) -> Date {
        min(Date(milliseconds: item.envelope.expiry), item.received.addingTimeInterval(maxLifetime))
    }

    /// Returns false if it's already carried, already expired, or there's no room.
    /// - Parameters:
    ///   - depositor: Who handed it over. One depositor may fill at most
    ///     `perDepositorLimit` slots, so a single hostile phone can't push out everyone
    ///     else's mail by depositing junk (see docs/gap-analysis.md).
    mutating func insert(_ envelope: CourierEnvelope, received: Date, depositor: LinkID? = nil,
                         perDepositorLimit: Int = .max) -> Bool {
        guard items[envelope.id] == nil else { return false }
        if let depositor, items.values.count(where: { $0.depositor == depositor }) >= perDepositorLimit { return false }
        let item = Item(envelope: envelope, received: received, depositor: depositor)
        guard expiry(of: item) > received else { return false }
        prune(now: received)
        if items.count >= capacity {
            // Make room by dropping whatever would expire soonest.
            guard let soonest = items.min(by: { expiry(of: $0.value) < expiry(of: $1.value) }),
                  expiry(of: soonest.value) < expiry(of: item)
            else { return false }
            items[soonest.key] = nil
        }
        items[envelope.id] = item
        return true
    }

    mutating func prune(now: Date) {
        items = items.filter { expiry(of: $0.value) > now }
    }

    /// Envelopes for this person not handed to them within `retryInterval`, marked as
    /// handed over now.
    mutating func due(for fingerprint: Fingerprint, now: Date, retryInterval: TimeInterval) -> [CourierEnvelope] {
        var due: [CourierEnvelope] = []
        for (id, item) in items where item.envelope.recipientTag == Courier.tag(for: fingerprint, envelopeID: id) {
            if let last = item.lastDelivery, now.timeIntervalSince(last) < retryInterval { continue }
            items[id]?.lastDelivery = now
            due.append(item.envelope)
        }
        return due
    }
}

/// What the engine keeps across launches.
struct MeshSnapshot: Codable {
    static let currentVersion = 1

    struct Item: Codable {
        var recipient: Fingerprint
        var payload: Data
        var created: Date
        var envelope: Data?
        var couriers: [Fingerprint]
    }

    struct Carried: Codable {
        var envelope: Data
        var received: Date
    }

    var version = currentVersion
    var outbox: [Item]
    var contacts: [Contact]
    var carried: [Carried]
    /// Recently opened envelopes and received message IDs, so replays are recognised after
    /// a restart (SEC-07). Optional so older state files still load.
    var openedEnvelopes: [String]? = nil
    var receivedMessageIDs: [String]? = nil
}
