import Foundation
import LetterboxDomain
import LetterboxMesh
import LetterboxWire

/// A fake radio: named nodes, links you connect and cut by hand, every frame recorded.
/// Lets tests build any topology (line, triangle, partition) with no Bluetooth.
public final class InMemoryRadio: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [String: InMemoryLink] = [:]
    private var edges: Set<[String]> = []
    private var log: [(from: String, to: String, frame: Data)] = []

    public init() {}

    public func makeLink(_ name: String) -> InMemoryLink {
        let link = InMemoryLink(name: name, radio: self)
        lock.withLock { links[name] = link }
        return link
    }

    public func connect(_ a: String, _ b: String) {
        let (linkA, linkB) = lock.withLock { () -> (InMemoryLink?, InMemoryLink?) in
            edges.insert([a, b].sorted())
            return (links[a], links[b])
        }
        linkA?.emit(.up(b))
        linkB?.emit(.up(a))
    }

    public func disconnect(_ a: String, _ b: String) {
        let (linkA, linkB) = lock.withLock { () -> (InMemoryLink?, InMemoryLink?) in
            edges.remove([a, b].sorted())
            return (links[a], links[b])
        }
        linkA?.emit(.down(b))
        linkB?.emit(.down(a))
    }

    /// Every frame that crossed any link, for "a relay never saw plaintext" style checks.
    public var transmittedFrames: [Data] {
        lock.withLock { log.map(\.frame) }
    }

    /// Every frame with the link it crossed, oldest first.
    public var transmissions: [(from: String, to: String, frame: Data)] {
        lock.withLock { log }
    }

    /// Every transmission of the packet with this ID (as hex, the same as a
    /// `ChatMessage.id` for public messages), with the link it crossed.
    public func frames(carrying packetIDHex: String) -> [(from: String, to: String)] {
        let entries = lock.withLock { log }
        return entries.compactMap { entry in
            guard let packet = try? Packet.decode(entry.frame),
                  packet.packetID.map({ String(format: "%02x", $0) }).joined() == packetIDHex
            else { return nil }
            return (entry.from, entry.to)
        }
    }

    func neighbors(of name: String) -> [String] {
        lock.withLock {
            edges.compactMap { edge in
                guard edge.contains(name) else { return nil }
                return edge.first { $0 != name }
            }
        }
    }

    func deliver(_ frame: Data, from: String, to: String) {
        let target = lock.withLock { () -> InMemoryLink? in
            guard edges.contains([from, to].sorted()),
                  links[from]?.isRunning != false, links[to]?.isRunning != false
            else { return nil }
            log.append((from, to, frame))
            return links[to]
        }
        target?.emit(.frame(frame, from: from))
    }
}

public final class InMemoryLink: LinkLayer, @unchecked Sendable {
    public let name: String
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private weak var radio: InMemoryRadio?

    init(name: String, radio: InMemoryRadio) {
        self.name = name
        self.radio = radio
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    func emit(_ event: LinkEvent) {
        continuation.yield(event)
    }

    private let stateLock = NSLock()
    private var running = true

    /// Like a real radio, a stopped link neither sends nor receives frames.
    public var isRunning: Bool { stateLock.withLock { running } }

    public func start() {
        stateLock.withLock { running = true }
        emit(.radio(.ready))
    }

    public func stop() {
        stateLock.withLock { running = false }
    }

    public func send(_ frame: Data, to link: LinkID) {
        radio?.deliver(frame, from: name, to: link)
    }

    public func broadcast(_ frame: Data, excluding link: LinkID?) {
        for neighbor in radio?.neighbors(of: name) ?? [] where neighbor != link {
            radio?.deliver(frame, from: name, to: neighbor)
        }
    }
}
