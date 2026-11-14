import Foundation
import os

/// WebSocket connections to a set of Nostr relays, with reconnect and resubscribe.
///
/// Publishes go to every connected relay; incoming events from all relays are merged
/// into one stream (the channel layer dedups by event ID).
public actor RelayPool {
    public enum Inbound: Sendable {
        case event(NostrEvent, subscription: String)
        case status(connected: Int, total: Int)
    }

    public static let defaultRelays: [URL] = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://offchain.pub",
    ].compactMap(URL.init(string:))

    public nonisolated let inbound: AsyncStream<Inbound>
    private let continuation: AsyncStream<Inbound>.Continuation
    private let relays: [URL]
    private let session: URLSession
    private let log = Logger(subsystem: "app.letterbox", category: "nostr")

    private var sockets: [URL: URLSessionWebSocketTask] = [:]
    private var connected: Set<URL> = []
    private var attempts: [URL: Int] = [:]
    /// Live subscriptions, replayed after every reconnect.
    private var subscriptions: [String: String] = [:]
    private var active = false

    public init(relays: [URL] = RelayPool.defaultRelays, session: URLSession = .shared) {
        self.relays = relays
        self.session = session
        (inbound, continuation) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .bufferingNewest(512))
    }

    public func connect() {
        guard !active else { return }
        active = true
        relays.forEach(open)
    }

    public func disconnect() {
        active = false
        for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
        sockets.removeAll()
        connected.removeAll()
        publishStatus()
    }

    public func subscribe(id: String, filter: NostrFilter) {
        guard let filterJSON = try? String(data: JSONEncoder().encode(filter), encoding: .utf8) else { return }
        let message = "[\"REQ\",\(NostrEvent.quote(id)),\(filterJSON)]"
        subscriptions[id] = message
        sockets.values.forEach { send(message, on: $0) }
    }

    public func unsubscribe(id: String) {
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        let message = "[\"CLOSE\",\(NostrEvent.quote(id))]"
        sockets.values.forEach { send(message, on: $0) }
    }

    public func publish(_ event: NostrEvent) {
        guard let eventJSON = try? String(data: JSONEncoder().encode(event), encoding: .utf8) else { return }
        let message = "[\"EVENT\",\(eventJSON)]"
        sockets.values.forEach { send(message, on: $0) }
    }

    // MARK: - Connections

    private func open(_ url: URL) {
        guard active else { return }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 512 * 1024
        sockets[url] = socket
        socket.resume()
        for message in subscriptions.values { send(message, on: socket) }
        receive(on: socket, from: url)
    }

    private func send(_ text: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(text)) { _ in }
    }

    private func receive(on socket: URLSessionWebSocketTask, from url: URL) {
        Task {
            while true {
                do {
                    let message = try await socket.receive()
                    self.markConnected(url, socket: socket)
                    switch message {
                    case let .string(text): self.handle(Data(text.utf8))
                    case let .data(data): self.handle(data)
                    @unknown default: break
                    }
                } catch {
                    self.socketFailed(url, socket: socket)
                    return
                }
            }
        }
    }

    private func markConnected(_ url: URL, socket: URLSessionWebSocketTask) {
        guard sockets[url] === socket, !connected.contains(url) else { return }
        connected.insert(url)
        attempts[url] = 0
        publishStatus()
    }

    private func socketFailed(_ url: URL, socket: URLSessionWebSocketTask) {
        guard sockets[url] === socket else { return }
        sockets[url] = nil
        connected.remove(url)
        publishStatus()
        guard active else { return }
        let attempt = (attempts[url] ?? 0) + 1
        attempts[url] = attempt
        let delay = min(60, pow(2, Double(min(attempt, 6)))) * Double.random(in: 0.8...1.2)
        log.debug("relay \(url.absoluteString, privacy: .public) down; retry in \(Int(delay))s")
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.open(url)
        }
    }

    /// Parses one relay message. Internal so tests can feed relay traffic without a network.
    func handle(_ data: Data) {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = array.first as? String
        else { return }
        switch type {
        case "EVENT":
            guard array.count >= 3,
                  let subscription = array[1] as? String,
                  let object = array[2] as? [String: Any],
                  let eventData = try? JSONSerialization.data(withJSONObject: object),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData)
            else { return }
            continuation.yield(.event(event, subscription: subscription))
        case "NOTICE":
            log.debug("relay notice: \(String(describing: array.dropFirst().first), privacy: .public)")
        default:
            break // EOSE, OK, CLOSED: nothing to do for ephemeral chat.
        }
    }

    private func publishStatus() {
        continuation.yield(.status(connected: connected.count, total: relays.count))
    }
}
