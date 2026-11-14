import Foundation

/// Where a conversation lives.
public enum ChannelID: Hashable, Sendable {
    /// Public chat with everyone on the local Bluetooth mesh. Shown to users as `#nearby`.
    case mesh
    /// Public chat for a geohash cell, carried over Nostr relays.
    case location(geohash: String)
    /// End-to-end encrypted 1:1 chat with one person over the mesh.
    case direct(Fingerprint)
}

public enum DeliveryState: Sendable, Hashable {
    /// Queued until the recipient is reachable and a secure session exists.
    case queued
    /// Not delivered yet, but sealed in an envelope and handed to other hikers
    /// (couriers), who deliver it if they meet the recipient.
    case inEnvelope
    /// Handed to the radio.
    case sent
    /// Recipient's device acknowledged it.
    case delivered
    /// Recipient opened the conversation.
    case read
    /// Gave up (expired before the recipient came back).
    case failed
}

public struct ChatMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let channel: ChannelID
    public let senderName: String
    /// Stable key for the sender (fingerprint hex on the mesh, Nostr pubkey hex for
    /// location channels). Used for colouring and to tell people apart, never nicknames.
    public let senderKey: String
    public let text: String
    public let timestamp: Date
    public let isOwn: Bool
    /// True when the sender's signature (or Noise session) authenticated the message.
    public var isVerified: Bool
    /// Only set for our own direct messages.
    public var delivery: DeliveryState?

    public init(
        id: String,
        channel: ChannelID,
        senderName: String,
        senderKey: String,
        text: String,
        timestamp: Date,
        isOwn: Bool,
        isVerified: Bool,
        delivery: DeliveryState? = nil
    ) {
        self.id = id
        self.channel = channel
        self.senderName = senderName
        self.senderKey = senderKey
        self.text = text
        self.timestamp = timestamp
        self.isOwn = isOwn
        self.isVerified = isVerified
        self.delivery = delivery
    }
}

/// A person currently visible on the mesh.
public struct Peer: Identifiable, Hashable, Sendable {
    public let peerID: PeerID
    public var nickname: String
    public var fingerprint: Fingerprint
    /// Directly connected over Bluetooth (as opposed to heard through relays).
    public var isDirect: Bool
    public var hasSecureSession: Bool
    public var lastSeen: Date

    public var id: Fingerprint { fingerprint }

    public init(
        peerID: PeerID,
        nickname: String,
        fingerprint: Fingerprint,
        isDirect: Bool,
        hasSecureSession: Bool,
        lastSeen: Date
    ) {
        self.peerID = peerID
        self.nickname = nickname
        self.fingerprint = fingerprint
        self.isDirect = isDirect
        self.hasSecureSession = hasSecureSession
        self.lastSeen = lastSeen
    }
}

public enum RadioState: Sendable, Hashable {
    case unknown
    case poweredOff
    case unauthorized
    case unsupported
    case ready
}

/// Nickname rules shared by every transport.
public enum Nickname {
    public static let maxLength = 24

    public static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }
        return String(trimmed.prefix(maxLength))
    }

    public static func random() -> String {
        "anon\(Int.random(in: 1000...9999))"
    }
}
