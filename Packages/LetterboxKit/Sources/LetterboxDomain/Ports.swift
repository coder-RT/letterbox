import Foundation

// Ports: the only way the application layer reaches the outside world.
// Adapters (BLE mesh, Nostr, Keychain, CoreLocation) implement these; tests use fakes.

// MARK: - Mesh

public enum MeshEvent: Sendable {
    case peersChanged([Peer])
    case publicMessage(ChatMessage)
    /// A #nearby message sent before we could hear it (we were out of range, off, or
    /// not yet here), passed on by a neighbour. Signature checked; may be hours old.
    case publicHistory(ChatMessage)
    case privateMessage(ChatMessage)
    case deliveryChanged(messageID: String, state: DeliveryState)
    case radioChanged(RadioState)
    /// One of our own private messages still waiting from before the app last closed.
    case outgoingRestored(ChatMessage, recipientName: String)
    /// Our envelopes still on their way, and how many we carry for other people.
    case envelopesChanged(EnvelopeSummary)
}

/// One of our own messages sealed in an envelope and handed to couriers.
public struct OutgoingEnvelope: Sendable, Hashable {
    public let messageID: String
    public let recipient: Fingerprint
    /// How many hikers have a copy.
    public let carriers: Int
    /// When couriers stop carrying it and we mark it as failed.
    public let expires: Date

    public init(messageID: String, recipient: Fingerprint, carriers: Int, expires: Date) {
        self.messageID = messageID
        self.recipient = recipient
        self.carriers = carriers
        self.expires = expires
    }
}

public struct EnvelopeSummary: Sendable, Hashable {
    /// Our messages handed to at least one courier and not yet acknowledged, oldest first.
    public var outgoing: [OutgoingEnvelope]
    /// Sealed envelopes we carry for other people. We can't read them or see who they're for.
    public var carryingForOthers: Int

    public static let empty = EnvelopeSummary(outgoing: [], carryingForOthers: 0)

    public init(outgoing: [OutgoingEnvelope], carryingForOthers: Int) {
        self.outgoing = outgoing
        self.carryingForOthers = carryingForOthers
    }

    public func carriers(for messageID: String) -> Int? {
        outgoing.first { $0.messageID == messageID }?.carriers
    }
}

/// Offline transport: public mesh chat plus encrypted direct messages.
public protocol MeshTransport: Sendable {
    var events: AsyncStream<MeshEvent> { get }
    var myFingerprint: Fingerprint { get }

    func start() async
    func stop() async
    func setNickname(_ nickname: String) async
    func sendPublic(_ text: String) async -> ChatMessage
    /// Returns the outgoing message immediately; its delivery state then
    /// advances through `deliveryChanged` events.
    func sendPrivate(_ text: String, to recipient: Fingerprint) async -> ChatMessage
    func markRead(messageIDs: [String], from sender: Fingerprint) async
    /// Whether we know this person's key from a past meeting, so a message to them
    /// can travel in an envelope.
    func canSeal(to recipient: Fingerprint) async -> Bool
}

// MARK: - Location channels

public enum LocationEvent: Sendable {
    case message(ChatMessage)
    case relaysChanged(connected: Int, total: Int)
}

/// Internet transport: public chat rooms scoped to a geohash cell.
public protocol LocationChannelTransport: Sendable {
    var events: AsyncStream<LocationEvent> { get }

    func join(geohash: String) async
    func leave() async
    func send(_ text: String, nickname: String) async -> ChatMessage?
}

// MARK: - Device services

public struct Coordinate: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum LocationError: Error, Sendable {
    case denied
    case unavailable
}

public protocol LocationProvider: Sendable {
    func currentCoordinate() async throws -> Coordinate
}

/// Small secrets (identity keys). Implemented by the Keychain in the app.
public protocol SecretStore: Sendable {
    func load(_ key: String) -> Data?
    func save(_ data: Data, for key: String) throws
    func deleteAll()
}

/// Opaque bytes kept across launches, such as the mesh engine's queue of
/// undelivered messages and the envelopes it carries for other people.
public protocol BlobStore: Sendable {
    func load() -> Data?
    func save(_ data: Data) throws
    func delete()
}

/// Non-secret user preferences.
public protocol SettingsStore: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

/// Tells the user about a message that arrived while Letterbox wasn't on screen, such as
/// with the phone locked in a pocket on the trail. Implemented with local notifications:
/// nothing leaves the device.
public protocol MessageNotifier: Sendable {
    /// Asks for permission once; the system remembers the answer.
    func requestPermission() async
    /// Shows or replaces the alert for one conversation.
    func show(_ alert: MessageAlert)
    /// Removes the alert for a conversation the user has now opened.
    func clear(conversation: String)
    func clearAll()
}

/// One lock-screen alert. There's at most one per conversation; a newer one replaces it.
public struct MessageAlert: Sendable, Equatable {
    public let conversation: String
    public let title: String
    public let body: String

    public init(conversation: String, title: String, body: String) {
        self.conversation = conversation
        self.title = title
        self.body = body
    }
}

/// Deletes everything Letterbox keeps on this device: identity keys, saved messages and
/// envelopes, people you verified or blocked, and settings.
public protocol LocalDataEraser: Sendable {
    func eraseAll()
}
