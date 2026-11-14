import Foundation
import LetterboxDomain

/// Nostr adapter for the `LocationChannelTransport` port.
///
/// Messages are ephemeral events (kind 23471): relays forward them live and do not
/// store them, so joining a channel shows what is said from then on, not history.
/// Each geohash gets its own derived key pair (see `NostrKeys.forGeohash`).
public actor NostrLocationChannel: LocationChannelTransport {
    /// Letterbox's own event kind (ephemeral range 20000–29999). Other Nostr apps ignore it.
    public static let kind = 23471
    public static let maxTextLength = 2000

    public nonisolated let events: AsyncStream<LocationEvent>
    private let continuation: AsyncStream<LocationEvent>.Continuation
    private let pool: RelayPool
    private let seed: Data
    private var geohash: String?
    private var keys: NostrKeys?
    private var seenIDs: [String] = []
    private var seenSet: Set<String> = []
    private var consumer: Task<Void, Never>?

    /// - Parameter seed: 32 secret bytes, stored by the app; all per-geohash keys derive from it.
    public init(seed: Data, pool: RelayPool = RelayPool()) {
        self.seed = seed
        self.pool = pool
        (events, continuation) = AsyncStream.makeStream(of: LocationEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    public func join(geohash newGeohash: String) async {
        guard Geohash.isValid(newGeohash) else { return }
        if geohash == newGeohash { return }
        await leave()
        startConsumingIfNeeded()
        geohash = newGeohash
        keys = NostrKeys.forGeohash(newGeohash, seed: seed)
        await pool.connect()
        let since = Int(Date().timeIntervalSince1970) - 60
        await pool.subscribe(
            id: subscriptionID(newGeohash),
            filter: NostrFilter(kinds: [Self.kind], geohashes: [newGeohash], since: since, limit: 200)
        )
    }

    public func leave() async {
        guard let current = geohash else { return }
        await pool.unsubscribe(id: subscriptionID(current))
        geohash = nil
        keys = nil
    }

    public func send(_ text: String, nickname: String) async -> ChatMessage? {
        guard let geohash, let keys else { return nil }
        let content = String(text.prefix(Self.maxTextLength))
        let tags = [["g", geohash], ["n", Nickname.sanitize(nickname)]]
        guard let event = try? keys.sign(kind: Self.kind, tags: tags, content: content) else { return nil }
        remember(event.id)
        await pool.publish(event)
        return message(from: event, geohash: geohash, isOwn: true)
    }

    // MARK: - Inbound

    private func startConsumingIfNeeded() {
        guard consumer == nil else { return }
        let inbound = pool.inbound
        consumer = Task {
            for await item in inbound {
                self.handle(item)
            }
        }
    }

    private func handle(_ item: RelayPool.Inbound) {
        switch item {
        case let .status(connected, total):
            continuation.yield(.relaysChanged(connected: connected, total: total))
        case let .event(event, subscription):
            guard let geohash, subscription == subscriptionID(geohash),
                  event.kind == Self.kind,
                  event.firstTag("g") == geohash,
                  !seenSet.contains(event.id),
                  event.content.count <= Self.maxTextLength,
                  event.isValid
            else { return }
            remember(event.id)
            continuation.yield(.message(message(from: event, geohash: geohash, isOwn: event.pubkey == keys?.publicKeyHex)))
        }
    }

    private func message(from event: NostrEvent, geohash: String, isOwn: Bool) -> ChatMessage {
        let nickname = Nickname.sanitize(event.firstTag("n") ?? "")
        let display = (nickname.isEmpty ? "anon" : nickname) + "#" + event.pubkey.suffix(4)
        return ChatMessage(
            id: event.id,
            channel: .location(geohash: geohash),
            senderName: display,
            senderKey: event.pubkey,
            text: event.content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            isOwn: isOwn,
            isVerified: true
        )
    }

    private func remember(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        seenIDs.append(id)
        if seenIDs.count > 5000 { seenSet.remove(seenIDs.removeFirst()) }
    }

    private func subscriptionID(_ geohash: String) -> String {
        "geo-\(geohash)"
    }
}
