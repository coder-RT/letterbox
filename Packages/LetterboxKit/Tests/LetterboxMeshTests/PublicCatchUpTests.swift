import Foundation
import Testing
import LetterboxCrypto
import LetterboxDomain
@testable import LetterboxMesh
import LetterboxTestSupport
import LetterboxWire

// Catching up on #nearby: a phone that was out of range, switched off, or arrived late
// gets the recent public messages it missed from the first neighbour it meets.

private actor Log {
    private(set) var events: [MeshEvent] = []
    init(_ node: MeshNode) {
        let stream = node.events
        Task { [weak self] in for await event in stream { await self?.add(event) } }
    }
    private func add(_ event: MeshEvent) { events.append(event) }

    var live: [ChatMessage] { events.compactMap { if case let .publicMessage(m) = $0 { m } else { nil } } }
    var history: [ChatMessage] { events.compactMap { if case let .publicHistory(m) = $0 { m } else { nil } } }
    var peerCount: Int {
        for event in events.reversed() { if case let .peersChanged(p) = event { return p.count } }
        return 0
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

private func fast() -> MeshNode.Configuration {
    var config = MeshNode.Configuration()
    config.relayJitter = 0...0
    config.announceInterval = 0.2
    config.maintenanceInterval = 0.1
    config.peerTimeout = 30
    return config
}

private func node(_ name: String, _ radio: InMemoryRadio, identity: IdentityKeys = .generate(),
                  config: MeshNode.Configuration = fast()) -> (mesh: MeshNode, log: Log, keys: IdentityKeys) {
    let mesh = MeshNode(identity: identity, nickname: name, link: radio.makeLink(name), configuration: config)
    return (mesh, Log(mesh), identity)
}

private func ms(_ offset: TimeInterval = 0) -> UInt64 { UInt64((Date().timeIntervalSince1970 + offset) * 1000) }

/// A person the attacker controls or impersonates: keys, a PeerID and a signed announce.
private struct Author {
    let keys = IdentityKeys.generate()
    let peerID = PeerID.random()
    let name: String

    var announce: Packet {
        var packet = Packet(type: .announce, ttl: 7, timestamp: ms(), packetID: Packet.randomPacketID(), sender: peerID,
                            payload: AnnouncePayload(nickname: name, noiseKey: keys.noisePublic, signingKey: keys.signingPublic).encoded())
        packet.signature = keys.sign(packet.signingBytes())
        return packet
    }

    func message(_ text: String, age: TimeInterval = 0, signedBy signer: IdentityKeys? = nil) -> Packet {
        var packet = Packet(type: .publicMessage, ttl: 7, timestamp: ms(-age), packetID: Packet.randomPacketID(), sender: peerID,
                            payload: PublicMessagePayload(nickname: name, text: text).encoded())
        packet.signature = (signer ?? keys).sign(packet.signingBytes())
        return packet
    }
}

private func sentFrames(_ radio: InMemoryRadio, from: String, to: String, type: PacketType) -> Int {
    radio.transmissions.filter { $0.from == from && $0.to == to && (try? Packet.decode($0.frame))?.type == type }.count
}

private func syncResponse(_ message: Packet, _ announce: Packet, from sender: PeerID) -> Data {
    Packet(type: .syncResponse, ttl: 1, timestamp: ms(), packetID: Packet.randomPacketID(), sender: sender,
           payload: SyncResponsePayload(message: message.encoded(), announce: announce.encoded()).encoded()).encoded()
}

@Suite("Catching up on #nearby", .timeLimit(.minutes(1)))
struct PublicCatchUpTests {
    @Test func latecomerGetsWhatWasSaidBeforeTheyArrived() async {
        let radio = InMemoryRadio()
        let alice = node("alice", radio), bob = node("bob", radio), carol = node("carol", radio)
        radio.connect("alice", "bob")
        for n in [alice, bob, carol] { await n.mesh.start() }
        #expect(await until { await bob.log.peerCount == 1 })
        let texts = ["Meet at the hut at 5", "Bring water", "Trail is icy past the bridge"]
        for text in texts {
            _ = await alice.mesh.sendPublic(text)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await until { await bob.log.live.count == 3 })

        radio.connect("bob", "carol") // Carol walks up later
        #expect(await until { await carol.log.history.count == 3 })
        let caught = await carol.log.history
        #expect(caught.map(\.text) == texts, "In the order they were written")
        #expect(caught.allSatisfy { $0.isVerified && $0.senderName == "alice" && $0.senderKey == alice.keys.fingerprint.hex })
        #expect(await carol.log.live.isEmpty)
    }

    @Test func messagesCrossFromOneGroupToAnotherWithAWalker() async {
        let radio = InMemoryRadio()
        let alice = node("alice", radio), bob = node("bob", radio), carol = node("carol", radio)
        radio.connect("alice", "bob")
        for n in [alice, bob, carol] { await n.mesh.start() }
        #expect(await until { await bob.log.peerCount == 1 })
        _ = await alice.mesh.sendPublic("Camp moved to the lake")
        #expect(await until { await bob.log.live.count == 1 })

        radio.disconnect("alice", "bob") // Bob walks from Alice's group to Carol's
        radio.connect("bob", "carol")
        #expect(await until { await carol.log.history.contains { $0.text == "Camp moved to the lake" } })
        let message = await carol.log.history.first
        #expect(message?.senderKey == alice.keys.fingerprint.hex && message?.isVerified == true,
                "Checked against Alice's own signature although she's out of reach")
    }

    @Test func phoneSwitchedOffCatchesUpAndSeesItsOwnMessagesAsOwn() async {
        let radio = InMemoryRadio()
        let aliceKeys = IdentityKeys.generate()
        let alice = node("alice", radio, identity: aliceKeys), bob = node("bob", radio)
        radio.connect("alice", "bob")
        for n in [alice, bob] { await n.mesh.start() }
        #expect(await until { await bob.log.peerCount == 1 })
        _ = await alice.mesh.sendPublic("mine, from before the restart")
        #expect(await until { await bob.log.live.count == 1 })

        // Alice's app is killed; while it's gone Bob says something. A fresh process with
        // the same identity comes back with an empty timeline.
        await alice.mesh.stop()
        radio.disconnect("alice", "bob")
        _ = await bob.mesh.sendPublic("said while you were off")
        let again = node("alice", radio, identity: aliceKeys)
        await again.mesh.start()
        radio.connect("alice", "bob")
        #expect(await until { await again.log.history.count == 2 })
        let history = await again.log.history
        #expect(history.first { $0.text == "mine, from before the restart" }?.isOwn == true)
        #expect(history.first { $0.text == "said while you were off" }?.isOwn == false)
    }

    @Test func onlyWhatIsMissingIsSentAndNothingTwice() async {
        let radio = InMemoryRadio()
        let alice = node("alice", radio), bob = node("bob", radio)
        radio.connect("alice", "bob")
        for n in [alice, bob] { await n.mesh.start() }
        #expect(await until { await bob.log.peerCount == 1 })
        for index in 0..<5 { _ = await alice.mesh.sendPublic("m\(index)") }
        #expect(await until { await bob.log.live.count == 5 })
        // A brief drop and reconnect: both already hold everything, so nothing is resent.
        radio.disconnect("alice", "bob")
        radio.connect("alice", "bob")
        try? await Task.sleep(for: .milliseconds(400))
        let resent = radio.transmissions.filter { (try? Packet.decode($0.frame))?.type == .syncResponse }
        #expect(resent.isEmpty)
        #expect(await bob.log.history.isEmpty)
        #expect(await alice.log.history.isEmpty)
    }

    @Test func historyIsBoundedByAgeAndCount() {
        var archive = PublicArchive(capacity: 3)
        let author = Author(name: "a")
        let announce = author.announce
        for index in 0..<5 { archive.insert(.init(message: author.message("\(index)", age: Double(10 - index)), announce: announce)) }
        #expect(archive.count == 3, "Oldest dropped beyond the cap")
        archive.prune(olderThan: ms(-7.5)) // ages 8, 7, 6 left; 8 goes
        #expect(archive.count == 2)
        let missing = archive.missing(from: [], since: 0, limit: 1)
        #expect(missing.count == 1 && (try? PublicMessagePayload.decode(missing[0].message.payload))?.text == "4",
                "The newest go first when the answer is capped")
    }

    // MARK: Attacks (a hostile phone in range)

    @Test func unsolicitedHistoryIsIgnored() async {
        let radio = InMemoryRadio()
        let bob = node("bob", radio)
        let mallory = radio.makeLink("mallory")
        await bob.mesh.start()
        radio.connect("bob", "mallory")
        let victim = Author(name: "alice")
        // No announce from Mallory, so Bob never asked her for anything.
        mallory.send(syncResponse(victim.message("pay me"), victim.announce, from: .random()), to: "bob")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await bob.log.history.isEmpty)
    }

    @Test func forgedStaleOrExcessiveHistoryIsRejected() async {
        let radio = InMemoryRadio()
        var config = fast()
        config.maxSyncMessages = 5
        let bob = node("bob", radio, config: config)
        let mallory = Author(name: "mallory")
        let link = radio.makeLink("mallory")
        await bob.mesh.start()
        radio.connect("bob", "mallory")
        link.send(mallory.announce.encoded(), to: "bob") // Bob now asks her to catch him up
        let asked = await until { sentFrames(radio, from: "bob", to: "mallory", type: .syncRequest) > 0 }
        #expect(asked)

        let alice = Author(name: "alice")
        let replies = [
            syncResponse(alice.message("forged", signedBy: mallory.keys), alice.announce, from: mallory.peerID), // wrong signer
            syncResponse(alice.message("too old", age: 13 * 3600), alice.announce, from: mallory.peerID),     // past the window
            syncResponse(alice.message("from the future", age: -3600), alice.announce, from: mallory.peerID),
            syncResponse(alice.message("mismatch"), mallory.announce, from: mallory.peerID),                  // someone else's announce
            syncResponse(alice.message("genuine"), alice.announce, from: mallory.peerID),
        ] + (0..<10).map { syncResponse(alice.message("spam \($0)"), alice.announce, from: mallory.peerID) }
        for reply in replies { link.send(reply, to: "bob") }

        #expect(await until { await bob.log.history.contains { $0.text == "genuine" } })
        try? await Task.sleep(for: .milliseconds(200))
        let texts = await bob.log.history.map(\.text)
        #expect(!texts.contains("forged") && !texts.contains("too old") && !texts.contains("from the future") && !texts.contains("mismatch"))
        #expect(texts == ["genuine"], "Five answers allowed and four used on rejects: no spam gets through")
    }

    @Test func historyCannotClaimALivePersonsID() async {
        let radio = InMemoryRadio()
        let alice = node("alice", radio), bob = node("bob", radio)
        let link = radio.makeLink("mallory")
        let mallory = Author(name: "mallory")
        radio.connect("alice", "bob")
        for n in [alice, bob] { await n.mesh.start() }
        #expect(await until { await bob.log.peerCount == 1 })
        radio.connect("bob", "mallory")
        link.send(mallory.announce.encoded(), to: "bob")
        try? await Task.sleep(for: .milliseconds(100))
        // An impostor with Alice's live PeerID but its own keys and valid signatures.
        let alicePeerID = await alice.mesh.peerID
        let impostor = Author(name: "alice")
        var message = Packet(type: .publicMessage, ttl: 7, timestamp: ms(-60), packetID: Packet.randomPacketID(), sender: alicePeerID,
                             payload: PublicMessagePayload(nickname: "alice", text: "I'm Alice, trust me").encoded())
        message.signature = impostor.keys.sign(message.signingBytes())
        var announce = Packet(type: .announce, ttl: 7, timestamp: ms(-60), packetID: Packet.randomPacketID(), sender: alicePeerID,
                              payload: AnnouncePayload(nickname: "alice", noiseKey: impostor.keys.noisePublic,
                                                       signingKey: impostor.keys.signingPublic).encoded())
        announce.signature = impostor.keys.sign(announce.signingBytes())
        link.send(syncResponse(message, announce, from: mallory.peerID), to: "bob")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await !bob.log.history.contains { $0.text == "I'm Alice, trust me" })
    }

    @Test func requestAndResponseAreNeverRelayed() async {
        let radio = InMemoryRadio()
        let alice = node("alice", radio), bob = node("bob", radio), carol = node("carol", radio)
        radio.connect("alice", "bob")
        radio.connect("bob", "carol")
        for n in [alice, bob, carol] { await n.mesh.start() }
        #expect(await until { await alice.log.peerCount == 2 })
        #expect(await until { await carol.log.peerCount == 2 })
        _ = await alice.mesh.sendPublic("hello")
        radio.disconnect("bob", "carol")
        radio.connect("bob", "carol")
        try? await Task.sleep(for: .milliseconds(300))
        let syncFrames = radio.transmissions.filter {
            guard let type = (try? Packet.decode($0.frame))?.type else { return false }
            return type == .syncRequest || type == .syncResponse
        }
        for frame in syncFrames {
            let packet = try? Packet.decode(frame.frame)
            #expect(packet?.ttl == 1)
        }
        let passedOn = syncFrames.contains { $0.from == "bob" && $0.to == "alice" && (try? Packet.decode($0.frame))?.type == .syncResponse }
        #expect(!passedOn, "Bob doesn't pass Carol's catch-up on to Alice")
    }
}
