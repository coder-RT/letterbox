import Foundation
import Testing
import LetterboxCrypto
import LetterboxDomain
@testable import LetterboxMesh
import LetterboxTestSupport
import LetterboxWire

// Dynamic application security testing (DAST) for the mesh engine: attacks against a
// *running* node, the way a malicious phone in Bluetooth range would send them.
//
// Each test names the finding it covers (see docs/security-assessment.md). Where an
// attack currently succeeds, the expected-safe assertion is wrapped in `withKnownIssue`:
// the suite stays green while the weakness is documented, and turns red the moment a
// fix lands (an unexpectedly passing known issue is reported), so it can't go stale.

private actor Watch {
    private(set) var events: [MeshEvent] = []
    init(_ node: MeshNode) {
        let stream = node.events
        Task { [weak self] in for await event in stream { await self?.add(event) } }
    }
    private func add(_ event: MeshEvent) { events.append(event) }

    var publicMessages: [ChatMessage] { events.compactMap { if case let .publicMessage(m) = $0 { m } else { nil } } }
    var privateMessages: [ChatMessage] { events.compactMap { if case let .privateMessage(m) = $0 { m } else { nil } } }
    var peers: [Peer] {
        for event in events.reversed() { if case let .peersChanged(p) = event { return p } }
        return []
    }
    var envelopes: EnvelopeSummary? {
        for event in events.reversed() { if case let .envelopesChanged(s) = event { return s } }
        return nil
    }
}

private func until(_ timeout: Duration = .seconds(4), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func config(courierDelay: TimeInterval = 10) -> MeshNode.Configuration {
    var config = MeshNode.Configuration()
    config.relayJitter = 0...0
    config.announceInterval = 0.2
    config.maintenanceInterval = 0.1
    config.peerTimeout = 30
    config.courierDelay = courierDelay
    return config
}

private func ms(_ offset: TimeInterval = 0) -> UInt64 { UInt64((Date().timeIntervalSince1970 + offset) * 1000) }

private func node(_ name: String, _ radio: InMemoryRadio, identity: IdentityKeys = .generate(),
                  config: MeshNode.Configuration = config(), store: (any BlobStore)? = nil) -> (MeshNode, Watch, IdentityKeys) {
    let mesh = MeshNode(identity: identity, nickname: name, link: radio.makeLink(name), configuration: config, store: store)
    return (mesh, Watch(mesh), identity)
}

/// A signed announce for a fresh identity: what an attacker can mint for free.
private func forgedAnnounce(name: String) -> Data {
    let keys = IdentityKeys.generate()
    var packet = Packet(type: .announce, ttl: 7, timestamp: ms(), packetID: Packet.randomPacketID(), sender: .random(),
                        payload: AnnouncePayload(nickname: name, noiseKey: keys.noisePublic, signingKey: keys.signingPublic).encoded())
    packet.signature = keys.sign(packet.signingBytes())
    return packet.encoded()
}

private func frames(_ radio: InMemoryRadio, from: String, to: String, type: PacketType) -> Int {
    radio.transmissions.filter { $0.from == from && $0.to == to && (try? Packet.decode($0.frame))?.type == type }.count
}

@Suite("Security DAST: mesh engine under attack", .timeLimit(.minutes(2)))
struct SecurityDASTTests {
    // SEC-DAST-01
    @Test func randomAndCorruptedFramesNeverCrashOrWedgeANode() async throws {
        let radio = InMemoryRadio()
        let (alice, _, _) = node("alice", radio)
        let (bob, bobWatch, _) = node("bob", radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        await alice.start()
        await bob.start()
        #expect(await until { await bobWatch.peers.count == 1 })

        var rng = SystemRandomNumberGenerator()
        for index in 0..<4000 {
            let length = Int.random(in: 0...600, using: &rng)
            var frame = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if index.isMultiple(of: 2), frame.count > 6 { frame[0] = 0x4C; frame[1] = 0x42; frame[2] = 1 } // valid magic/version
            attacker.send(frame, to: "bob")
        }
        // Still healthy: a legitimate message gets through afterwards.
        _ = await alice.sendPublic("still standing")
        #expect(await until { await bobWatch.publicMessages.contains { $0.text == "still standing" } })
    }

    // SEC-DAST-02
    @Test func mutatedCopiesOfARealPacketNeverImpersonateItsSender() async throws {
        let radio = InMemoryRadio()
        let (alice, _, aliceKeys) = node("alice", radio)
        let (bob, bobWatch, _) = node("bob", radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        await alice.start()
        await bob.start()
        #expect(await until { await bobWatch.peers.contains { $0.fingerprint == aliceKeys.fingerprint } })

        let sent = await alice.sendPublic("the real message")
        #expect(await until { await bobWatch.publicMessages.contains { $0.id == sent.id } })
        let original = try #require(radio.transmissions.compactMap { try? Packet.decode($0.frame) }
            .first { $0.type == .publicMessage && $0.sender == alice.peerID })

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            var mutated = original
            mutated.packetID = Packet.randomPacketID() // bypass dedup
            mutated.timestamp = ms()
            var payload = mutated.payload
            for _ in 0..<Int.random(in: 1...4, using: &rng) where !payload.isEmpty {
                payload[Int.random(in: 0..<payload.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
            }
            mutated.payload = payload
            attacker.send(mutated.encoded(), to: "bob")
        }
        try await Task.sleep(for: .milliseconds(400))
        // Nothing but the original may carry Alice's identity.
        let fromAlice = await bobWatch.publicMessages.filter { $0.senderKey == aliceKeys.fingerprint.hex }
        #expect(fromAlice.map(\.text) == ["the real message"])
    }

    // SEC-DAST-03 → finding SEC-01 (fixed)
    @Test func peerTableFloodWithFreshIdentities() async throws {
        let radio = InMemoryRadio()
        let (bob, bobWatch, _) = node("bob", radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "bob")
        await bob.start()

        for index in 0..<1000 { attacker.send(forgedAnnounce(name: "ghost\(index)"), to: "bob") }
        _ = await until(.seconds(5)) { await bobWatch.peers.count >= 1000 }
        let peers = await bobWatch.peers.count
        print("SEC-DAST-03: peer list grew to \(peers) entries from 1000 forged identities")
        // Fixed (SEC-01): new identities are rate-limited per link.
        #expect(peers <= 32)
    }

    // SEC-DAST-03b → SEC-01: many links at once still can't push past the table cap.
    @Test func peerTableStaysCappedAcrossManyLinks() async throws {
        let radio = InMemoryRadio()
        let (bob, bobWatch, _) = node("bob", radio)
        let attackers = (0..<10).map { radio.makeLink("mallory\($0)") }
        for index in 0..<10 { radio.connect("mallory\(index)", "bob") }
        await bob.start()
        for (index, attacker) in attackers.enumerated() {
            for n in 0..<40 { attacker.send(forgedAnnounce(name: "ghost\(index)-\(n)"), to: "bob") }
        }
        _ = await until(.seconds(5)) { await bobWatch.peers.count >= 256 }
        try await Task.sleep(for: .milliseconds(300))
        let peers = await bobWatch.peers.count
        print("SEC-DAST-03b: 400 forged identities over 10 links gave \(peers) peers")
        #expect(peers <= 256)
    }

    // SEC-DAST-04 → finding SEC-02 (fixed)
    @Test func envelopesFromAStrangerAmplifyIntoQueuedReceiptsAndCourierTraffic() async throws {
        let radio = InMemoryRadio()
        let (bob, _, bobKeys) = node("bob", radio, config: config(courierDelay: 0.2))
        let (carol, _, _) = node("carol", radio, config: config(courierDelay: 0.2)) // an honest neighbour/courier
        let attacker = radio.makeLink("mallory")
        radio.connect("bob", "carol")
        radio.connect("mallory", "bob")
        await bob.start()
        await carol.start()

        // Mallory knows Bob's public key (it's in every announce) and seals 300 messages to him.
        let mallory = IdentityKeys.generate()
        let bobContact = Contact(fingerprint: bobKeys.fingerprint, nickname: "bob", noiseKey: bobKeys.noisePublic, lastSeen: Date())
        for index in 0..<300 {
            let envelope = try #require(Courier.seal(.message(id: "spam-\(index)", nickname: "m", text: "x", timestamp: ms()),
                                                     to: bobContact, from: mallory, expiry: Date().addingTimeInterval(3600)))
            var packet = Packet(type: .courier, ttl: 1, timestamp: ms(), packetID: Packet.randomPacketID(), sender: .random(),
                                payload: envelope.encoded())
            packet.ttl = 1
            attacker.send(packet.encoded(), to: "bob")
        }
        radio.disconnect("mallory", "bob")
        try await Task.sleep(for: .seconds(1.5)) // past the courier delay: Bob seals receipts and hands them to Carol
        let handedToCarol = frames(radio, from: "bob", to: "carol", type: .courier)
        print("SEC-DAST-04: 300 attacker envelopes made Bob hand \(handedToCarol) receipt envelopes to one neighbour")
        // Fixed (SEC-02): receipts per person are merged and capped.
        #expect(handedToCarol <= 2)
    }

    // SEC-DAST-05 → finding SEC-03 (fixed)
    @Test func publicMessageFloodIsRateLimited() async throws {
        let radio = InMemoryRadio()
        let (bob, _, _) = node("bob", radio)
        let (carol, _, _) = node("carol", radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("bob", "carol")
        radio.connect("mallory", "bob")
        await bob.start()
        await carol.start()
        let spammer = PeerID.random()

        for index in 0..<500 {
            let packet = Packet(type: .publicMessage, ttl: 7, timestamp: ms(), packetID: Packet.randomPacketID(), sender: spammer,
                                payload: PublicMessagePayload(nickname: "spam", text: "spam \(index)").encoded())
            attacker.send(packet.encoded(), to: "bob")
        }
        try await Task.sleep(for: .milliseconds(500))
        let relayed = frames(radio, from: "bob", to: "carol", type: .publicMessage)
        print("SEC-DAST-05: Bob relayed \(relayed) of 500 spam messages from one sender to his neighbour")
        // Fixed (SEC-03): senders we can't check share a small allowance per link.
        #expect(relayed <= 30)
    }

    // SEC-DAST-06
    @Test func envelopeStorageFloodStaysCapped() async throws {
        let radio = InMemoryRadio()
        let (bob, bobWatch, _) = node("bob", radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "bob")
        await bob.start()

        let sender = IdentityKeys.generate()
        for index in 0..<1000 {
            let stranger = IdentityKeys.generate()
            let contact = Contact(fingerprint: stranger.fingerprint, nickname: "s", noiseKey: stranger.noisePublic, lastSeen: Date())
            let envelope = try #require(Courier.seal(.message(id: "e\(index)", nickname: "m", text: "x", timestamp: ms()),
                                                     to: contact, from: sender, expiry: Date().addingTimeInterval(3600)))
            var packet = Packet(type: .courier, ttl: 1, timestamp: ms(), packetID: Packet.randomPacketID(), sender: .random(),
                                payload: envelope.encoded())
            packet.ttl = 1
            attacker.send(packet.encoded(), to: "bob")
        }
        #expect(await until(.seconds(5)) { (await bobWatch.envelopes?.carryingForOthers ?? 0) >= 256 })
        try await Task.sleep(for: .milliseconds(300))
        let carried = await bobWatch.envelopes?.carryingForOthers ?? 0
        print("SEC-DAST-06: Bob carries \(carried) envelopes after 1000 were pushed at him")
        #expect(carried == 256)
    }

    // SEC-DAST-07 → finding SEC-07 (fixed)
    @Test func aReplayedEnvelopeIsIgnoredEvenAfterTheRecipientRestarts() async throws {
        let radio = InMemoryRadio()
        let bobKeys = IdentityKeys.generate()
        let bobStore = InMemoryBlobStore() // the app always has storage
        let (bob, bobWatch, _) = node("bob", radio, identity: bobKeys, store: bobStore)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "bob")
        await bob.start()

        let alice = IdentityKeys.generate()
        let contact = Contact(fingerprint: bobKeys.fingerprint, nickname: "bob", noiseKey: bobKeys.noisePublic, lastSeen: Date())
        let envelope = try #require(Courier.seal(.message(id: "once", nickname: "alice", text: "meet at 6", timestamp: ms()),
                                                 to: contact, from: alice, expiry: Date().addingTimeInterval(3600)))
        func handOver() {
            var packet = Packet(type: .courier, ttl: 1, timestamp: ms(), packetID: Packet.randomPacketID(), sender: .random(),
                                payload: envelope.encoded())
            packet.ttl = 1
            attacker.send(packet.encoded(), to: "bob")
        }
        handOver()
        #expect(await until { await bobWatch.privateMessages.contains { $0.id == "once" } })
        handOver() // replay before a restart: dropped
        try await Task.sleep(for: .milliseconds(200))
        #expect(await bobWatch.privateMessages.filter { $0.id == "once" }.count == 1)

        // Bob's phone restarts and the courier replays it.
        await bob.stop()
        let (restarted, restartedWatch, _) = node("bob", radio, identity: bobKeys, store: bobStore)
        await restarted.start()
        handOver()
        try await Task.sleep(for: .milliseconds(400))
        let shownAgain = await restartedWatch.privateMessages.contains { $0.id == "once" }
        print("SEC-DAST-07: replayed envelope after restart shown again: \(shownAgain)")
        #expect(!shownAgain)
    }

    // SEC-DAST-08
    @Test func oversizedAndStaleFramesAreRejected() async throws {
        let radio = InMemoryRadio()
        let (bob, bobWatch, _) = node("bob", radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "bob")
        await bob.start()
        let stranger = PeerID.random()

        // A payload length field claiming more than the 32 KB limit.
        var huge = Packet(type: .publicMessage, ttl: 7, timestamp: ms(), packetID: Packet.randomPacketID(), sender: stranger,
                          payload: Data()).encoded()
        huge[30] = 0xFF // payload length field: after the 30-byte header (no recipient)
        huge[31] = 0xFF
        attacker.send(huge, to: "bob")
        // Text over the 2000-byte limit.
        let tooLong = Packet(type: .publicMessage, ttl: 7, timestamp: ms(), packetID: Packet.randomPacketID(), sender: stranger,
                             payload: PublicMessagePayload(nickname: "e", text: String(repeating: "a", count: 2001)).encoded())
        attacker.send(tooLong.encoded(), to: "bob")
        // Ten minutes and one second old.
        let stale = Packet(type: .publicMessage, ttl: 7, timestamp: ms(-601), packetID: Packet.randomPacketID(), sender: stranger,
                           payload: PublicMessagePayload(nickname: "e", text: "old news").encoded())
        attacker.send(stale.encoded(), to: "bob")
        // A fresh, valid one as a marker.
        let fresh = Packet(type: .publicMessage, ttl: 7, timestamp: ms(), packetID: Packet.randomPacketID(), sender: stranger,
                           payload: PublicMessagePayload(nickname: "e", text: "marker").encoded())
        attacker.send(fresh.encoded(), to: "bob")

        #expect(await until { await bobWatch.publicMessages.contains { $0.text == "marker" } })
        #expect(await bobWatch.publicMessages.map(\.text) == ["marker"])
    }
}
