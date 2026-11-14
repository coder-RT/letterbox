import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxNostr

/// Collects a channel's events.
private actor Collector {
    private(set) var events: [LocationEvent] = []

    init(_ channel: NostrLocationChannel) {
        let stream = channel.events
        Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: LocationEvent) { events.append(event) }

    var messages: [ChatMessage] {
        events.compactMap { if case let .message(m) = $0 { m } else { nil } }
    }

    var relayStatuses: [String] {
        events.compactMap { if case let .relaysChanged(c, t) = $0 { "\(c)/\(t)" } else { nil } }
    }
}

private func eventually(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A relay message as it would arrive on the WebSocket.
private func relayFrame(_ event: NostrEvent, subscription: String) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
    return try JSONSerialization.data(withJSONObject: ["EVENT", subscription, object])
}

private struct Harness {
    let pool = RelayPool(relays: []) // no network
    let seed = Data(repeating: 3, count: 32)
    let channel: NostrLocationChannel
    let collector: Collector

    init() {
        channel = NostrLocationChannel(seed: seed, pool: pool)
        collector = Collector(channel)
    }

    func deliver(_ event: NostrEvent, subscription: String = "geo-u4pru") async throws {
        await pool.handle(try relayFrame(event, subscription: subscription))
    }
}

private func post(
    _ text: String,
    geohash: String = "u4pru",
    nickname: String? = "ana",
    kind: Int = NostrLocationChannel.kind,
    keys: NostrKeys = .generate()
) throws -> NostrEvent {
    var tags = [["g", geohash]]
    if let nickname { tags.append(["n", nickname]) }
    return try keys.sign(kind: kind, tags: tags, content: text)
}

@Suite("Nostr location channel", .timeLimit(.minutes(1)))
struct NostrLocationChannelTests {
    @Test func deliversValidEventsForTheJoinedCell() async throws {
        let h = Harness()
        await h.channel.join(geohash: "u4pru")
        let event = try post("hello area")
        try await h.deliver(event)

        #expect(await eventually { await h.collector.messages.count == 1 })
        let message = try #require(await h.collector.messages.first)
        #expect(message.text == "hello area")
        #expect(message.channel == .location(geohash: "u4pru"))
        #expect(message.senderName == "ana#" + event.pubkey.suffix(4))
        #expect(message.senderKey == event.pubkey)
        #expect(message.id == event.id)
        #expect(!message.isOwn)
        #expect(message.isVerified)
        #expect(message.timestamp == Date(timeIntervalSince1970: TimeInterval(event.created_at)))
    }

    @Test func missingOrBlankNicknamesShowAsAnon() async throws {
        let h = Harness()
        await h.channel.join(geohash: "u4pru")
        try await h.deliver(try post("no name", nickname: nil))
        try await h.deliver(try post("blank name", nickname: " \n "))
        #expect(await eventually { await h.collector.messages.count == 2 })
        #expect(await h.collector.messages.allSatisfy { $0.senderName.hasPrefix("anon#") })
    }

    @Test func duplicateEventsFromSeveralRelaysShowOnce() async throws {
        let h = Harness()
        await h.channel.join(geohash: "u4pru")
        let event = try post("once please")
        for _ in 0..<4 { try await h.deliver(event) }
        try await h.deliver(try post("marker"))
        #expect(await eventually { await h.collector.messages.contains { $0.text == "marker" } })
        #expect(await h.collector.messages.filter { $0.text == "once please" }.count == 1)
    }

    @Test func ignoresEverythingThatDoesNotBelong() async throws {
        let h = Harness()
        await h.channel.join(geohash: "u4pru")

        let valid = try post("ok")
        try await h.deliver(try post("other subscription"), subscription: "geo-u4prv")
        try await h.deliver(try post("other cell tag", geohash: "u4prv"))
        try await h.deliver(try post("other kind", kind: 1))
        try await h.deliver(try post(String(repeating: "x", count: NostrLocationChannel.maxTextLength + 1)))
        let tampered = NostrEvent(id: valid.id, pubkey: valid.pubkey, created_at: valid.created_at, kind: valid.kind,
                                  tags: valid.tags, content: "edited", sig: valid.sig)
        try await h.deliver(tampered)
        try await h.deliver(valid) // marker: arrives after all of the above

        #expect(await eventually { await h.collector.messages.contains { $0.text == "ok" } })
        #expect(await h.collector.messages.map(\.text) == ["ok"])
    }

    @Test func nothingIsDeliveredAfterLeaving() async throws {
        // (Before the first join the pool isn't connected, so there is no traffic to filter.)
        let h = Harness()
        await h.channel.join(geohash: "u4pru")
        await h.channel.leave()
        try await h.deliver(try post("too late"))
        try await Task.sleep(for: .milliseconds(100)) // let the channel process it while it's out of the cell
        await h.channel.join(geohash: "u4pru")
        try await h.deliver(try post("marker"))
        #expect(await eventually { await h.collector.messages.contains { $0.text == "marker" } })
        #expect(await h.collector.messages.map(\.text) == ["marker"])
    }

    @Test func switchingCellsStopsTheOldOne() async throws {
        let h = Harness()
        await h.channel.join(geohash: "u4pru")
        await h.channel.join(geohash: "u4prv")
        try await h.deliver(try post("old cell"))
        try await h.deliver(try post("new cell", geohash: "u4prv"), subscription: "geo-u4prv")
        #expect(await eventually { await h.collector.messages.contains { $0.text == "new cell" } })
        #expect(await h.collector.messages.map(\.text) == ["new cell"])
        #expect(await h.collector.messages.first?.channel == .location(geohash: "u4prv"))
    }

    @Test func invalidGeohashIsNotJoined() async {
        let h = Harness()
        await h.channel.join(geohash: "not a hash")
        #expect(await h.channel.send("hi", nickname: "ana") == nil)
    }

    @Test func sendingSignsWithThePerCellKeyAndEchoesAreNotRepeated() async throws {
        let h = Harness()
        #expect(await h.channel.send("before join", nickname: "ana") == nil)
        await h.channel.join(geohash: "u4pru")

        let sent = try #require(await h.channel.send("hi all", nickname: "  ana\n"))
        let cellKeys = NostrKeys.forGeohash("u4pru", seed: h.seed)
        #expect(sent.isOwn)
        #expect(sent.senderKey == cellKeys.publicKeyHex)
        #expect(sent.senderName == "ana#" + cellKeys.publicKeyHex.suffix(4))
        #expect(sent.channel == .location(geohash: "u4pru"))

        // A relay echoing our post back has the same id (the id doesn't cover the signature).
        let echo = try cellKeys.sign(kind: NostrLocationChannel.kind, tags: [["g", "u4pru"], ["n", "ana"]],
                                     content: "hi all", createdAt: sent.timestamp)
        #expect(echo.id == sent.id)
        try await h.deliver(echo)

        // A different post under our cell key (say, from before an app restart) shows as ours.
        let earlier = try cellKeys.sign(kind: NostrLocationChannel.kind, tags: [["g", "u4pru"], ["n", "ana"]], content: "from before")
        try await h.deliver(earlier)

        #expect(await eventually { await h.collector.messages.contains { $0.id == earlier.id } })
        #expect(await h.collector.messages.first { $0.id == earlier.id }?.isOwn == true)
        #expect(await !h.collector.messages.contains { $0.id == sent.id })
    }

    @Test func outgoingTextIsCappedAtTheLimit() async throws {
        let h = Harness()
        await h.channel.join(geohash: "u4pru")
        let long = String(repeating: "y", count: NostrLocationChannel.maxTextLength + 500)
        let sent = try #require(await h.channel.send(long, nickname: "ana"))
        #expect(sent.text.count == NostrLocationChannel.maxTextLength)
    }

    @Test func relayStatusIsForwarded() async {
        let h = Harness()
        await h.channel.join(geohash: "u4pru") // starts listening to the pool
        await h.pool.disconnect()
        #expect(await eventually { await h.collector.relayStatuses.contains("0/0") })
    }
}

@Suite("Relay message parsing")
struct RelayMessageParsingTests {
    @Test func malformedRelayMessagesAreIgnored() async throws {
        let pool = RelayPool(relays: [])
        let valid = try NostrKeys.generate().sign(kind: 23333, tags: [], content: "ok")
        for raw in [
            "", "not json", "{}", "[]", "[1,2,3]", #"["EVENT"]"#, #"["EVENT","sub"]"#,
            #"["EVENT","sub","string instead of object"]"#, #"["EVENT","sub",{"id":"missing fields"}]"#,
            #"["NOTICE","slow down"]"#, #"["EOSE","sub"]"#, #"["OK","id",true,""]"#,
        ] {
            await pool.handle(Data(raw.utf8))
        }
        await pool.handle(try relayFrame(valid, subscription: "sub"))

        var iterator = pool.inbound.makeAsyncIterator()
        let first = await iterator.next()
        guard case let .event(event, subscription) = first else {
            Issue.record("expected the valid event first, got \(String(describing: first))")
            return
        }
        #expect(event == valid)
        #expect(subscription == "sub")
    }
}
