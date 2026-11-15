import Foundation

// Routing and connectivity: which ways of communicating work right now, which ones
// the user allows Letterbox to use, and which way a message should go.

// MARK: - What the device reports

public enum InternetPath: Sendable, Hashable {
    case unknown
    case offline
    case wifi
    case cellular
    case wired
    case other
}

public struct InternetStatus: Sendable, Hashable {
    public var path: InternetPath
    /// Low Data Mode is on.
    public var isConstrained: Bool
    /// Metered, such as mobile data or a phone hotspot.
    public var isExpensive: Bool

    public init(path: InternetPath, isConstrained: Bool = false, isExpensive: Bool = false) {
        self.path = path
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }

    public var isOnline: Bool {
        switch path {
        case .wifi, .cellular, .wired, .other: true
        case .unknown, .offline: false
        }
    }
}

public enum CellularStatus: Sendable, Hashable {
    case unknown
    /// This device has no mobile radio (a Mac, a Wi-Fi-only iPad).
    case unsupported
    case noService
    /// Registered on a mobile network; `radio` is a display name such as "5G" or "LTE".
    case connected(radio: String)
}

public enum LocationAccess: Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    case allowed
}

/// Raw readings from the device, before any wording.
public struct SystemConnectivity: Sendable, Hashable {
    public var internet: InternetStatus
    public var cellular: CellularStatus
    /// Whether the phone can send text messages at all (not whether there's signal).
    public var canSendTexts: Bool?
    public var location: LocationAccess

    public static let unknown = SystemConnectivity(
        internet: InternetStatus(path: .unknown), cellular: .unknown, canSendTexts: nil, location: .notDetermined
    )

    public init(internet: InternetStatus, cellular: CellularStatus, canSendTexts: Bool?, location: LocationAccess) {
        self.internet = internet
        self.cellular = cellular
        self.canSendTexts = canSendTexts
        self.location = location
    }
}

/// Watches the device's network, mobile radio and location permission.
public protocol ConnectivityMonitor: Sendable {
    var updates: AsyncStream<SystemConnectivity> { get }
    func start()
}

// MARK: - What the user allows

/// Ways of communicating the user lets Letterbox use. Both on by default.
public struct TransportPermissions: Sendable, Hashable {
    public var bluetooth: Bool
    public var internet: Bool

    public init(bluetooth: Bool = true, internet: Bool = true) {
        self.bluetooth = bluetooth
        self.internet = internet
    }
}

// MARK: - Which way a message goes

public enum OutgoingKind: Sendable, Hashable {
    case text
    case photo
}

public enum Route: Sendable, Hashable {
    /// Over Bluetooth, the recipient is in range of the mesh now.
    case mesh
    /// Over the internet (phase 2).
    case internet
    /// Queued, and sealed in an envelope for passing hikers to carry.
    case envelope
    /// Queued until a way opens up. The reason is shown to the user.
    case queue(String)
    /// Can't be sent as things are. The reason says what to change.
    case impossible(String)
}

/// Picks the best allowed way to send a private message. Pure, so every
/// combination is tested.
public enum RoutePlanner {
    public static func route(
        for kind: OutgoingKind,
        recipientNearby: Bool,
        recipientKeyKnown: Bool,
        recipientHasInternetAddress: Bool,
        permissions: TransportPermissions,
        internetOnline: Bool
    ) -> Route {
        switch kind {
        case .photo:
            guard permissions.internet else {
                return .impossible("Photos need the internet, which is off in HelloLetter. Turn it on in Connections.")
            }
            guard recipientHasInternetAddress else {
                return .impossible("Photos can only go over the internet, and you can't reach this person that way yet.")
            }
            return internetOnline ? .internet : .queue("Waiting for an internet connection to send the photo.")

        case .text:
            if permissions.bluetooth, recipientNearby { return .mesh }
            if permissions.internet, internetOnline, recipientHasInternetAddress { return .internet }
            if permissions.bluetooth {
                return recipientKeyKnown
                    ? .envelope
                    : .queue("They're out of range. It will send when they're back within reach.")
            }
            if permissions.internet, recipientHasInternetAddress {
                return .queue("Waiting for an internet connection.")
            }
            if recipientKeyKnown || recipientNearby {
                return .queue("Bluetooth is off in HelloLetter. It will send when you turn it back on in Connections.")
            }
            return .impossible("Bluetooth and the internet are both off in HelloLetter. Turn one on in Connections.")
        }
    }
}

// MARK: - What the user sees

public enum ConnectionKind: String, Sendable, Hashable, CaseIterable {
    case bluetooth, internet, wifi, mobile, satellite, location, relays, envelopes
}

public enum ConnectionStatus: Sendable, Hashable {
    case working(String)
    case off(String)
    case blockedByYou(String)
    case notAllowed(String)
    case unavailable(String)
    case notDetectable(String)
    case checking(String)

    public var detail: String {
        switch self {
        case let .working(text), let .off(text), let .blockedByYou(text), let .notAllowed(text),
             let .unavailable(text), let .notDetectable(text), let .checking(text):
            text
        }
    }

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

public struct ConnectionRow: Sendable, Hashable, Identifiable {
    public let kind: ConnectionKind
    public let title: String
    public let status: ConnectionStatus
    /// What this way of communicating lets you do.
    public let enables: String

    public var id: ConnectionKind { kind }

    public init(kind: ConnectionKind, title: String, status: ConnectionStatus, enables: String) {
        self.kind = kind
        self.title = title
        self.status = status
        self.enables = enables
    }
}
