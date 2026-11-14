import Foundation
import LetterboxCrypto
import LetterboxDomain
import LetterboxMesh

/// Another phone running the real mesh engine on an `InMemoryRadio`, with a scripted
/// personality. Used by integration tests and by the app's UI-test mode, where there
/// is no Bluetooth.
public final class SimulatedPhone: @unchecked Sendable {
    public let name: String
    public let identity: IdentityKeys
    public let node: MeshNode
    private let replyToPrivate: Bool
    private let replyToPublic: Bool
    private var listener: Task<Void, Never>?
    private let lock = NSLock()
    private var received: [ChatMessage] = []

    public init(
        name: String,
        radio: InMemoryRadio,
        configuration: MeshNode.Configuration = .init(),
        replyToPrivate: Bool = true,
        replyToPublic: Bool = false
    ) {
        self.name = name
        self.replyToPrivate = replyToPrivate
        self.replyToPublic = replyToPublic
        identity = IdentityKeys.generate()
        node = MeshNode(identity: identity, nickname: name, link: radio.makeLink(name), configuration: configuration)
    }

    /// Every message this phone has received so far.
    public var inbox: [ChatMessage] { lock.withLock { received } }

    public func start() async {
        let events = node.events
        let node = node
        listener = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .privateMessage(message):
                    self.record(message)
                    if self.replyToPrivate, case let .direct(sender) = message.channel {
                        _ = await node.sendPrivate("Got it: \(message.text)", to: sender)
                    }
                case let .publicMessage(message):
                    self.record(message)
                    if self.replyToPublic {
                        _ = await node.sendPublic("\(self.name) heard you")
                    }
                default:
                    break
                }
            }
        }
        await node.start()
    }

    public func stop() async {
        await node.stop()
        listener?.cancel()
    }

    private func record(_ message: ChatMessage) {
        lock.withLock { received.append(message) }
    }
}

/// A `ConnectivityMonitor` that reports a fixed reading, for tests and UI-test mode.
public final class ScriptedConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    public let updates: AsyncStream<SystemConnectivity>
    private let continuation: AsyncStream<SystemConnectivity>.Continuation
    private let reading: SystemConnectivity

    public init(_ reading: SystemConnectivity) {
        self.reading = reading
        (updates, continuation) = AsyncStream.makeStream(of: SystemConnectivity.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() { continuation.yield(reading) }

    /// Change the reading later in a test.
    public func report(_ reading: SystemConnectivity) { continuation.yield(reading) }

    /// Named readings used by UI tests, chosen through an environment variable.
    public static func named(_ name: String?) -> SystemConnectivity {
        switch name {
        case "offline":
            SystemConnectivity(internet: InternetStatus(path: .offline), cellular: .noService, canSendTexts: true, location: .notDetermined)
        case "cellular5G":
            SystemConnectivity(internet: InternetStatus(path: .cellular, isExpensive: true), cellular: .connected(radio: "5G"),
                               canSendTexts: true, location: .allowed)
        default: // "wifi"
            SystemConnectivity(internet: InternetStatus(path: .wifi), cellular: .connected(radio: "LTE"), canSendTexts: true, location: .allowed)
        }
    }
}

/// In-memory `SecretStore` and `SettingsStore`, so a test run never touches the real ones.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func load(_ key: String) -> Data? { lock.withLock { values[key] } }
    public func save(_ data: Data, for key: String) throws { lock.withLock { values[key] = data } }
    public func deleteAll() { lock.withLock { values.removeAll() } }
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func string(for key: String) -> String? { lock.withLock { values[key] } }
    public func set(_ value: String?, for key: String) { lock.withLock { values[key] = value } }
}
