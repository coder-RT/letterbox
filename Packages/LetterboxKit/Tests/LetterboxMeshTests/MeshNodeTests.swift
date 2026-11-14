import Foundation
import Testing
import LetterboxCrypto
import LetterboxDomain
@testable import LetterboxMesh
import LetterboxTestSupport
import LetterboxWire

/// Collects a node's events so tests can wait for specific ones.
private actor Recorder {
    private(set) var events: [MeshEvent] = []

    init(_ node: MeshNode) {
        let stream = node.events
        Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: MeshEvent) {
        events.append(event)
    }

    var publicMessages: [ChatMessage] {
        events.compactMap { if case let .publicMessage(m) = $0 { m } else { nil } }
    }

    var privateMessages: [ChatMessage] {
        events.compactMap { if case let .privateMessage(m) = $0 { m } else { nil } }
    }

    var latestPeers: [Peer] {
        for event in events.reversed() {
            if case let .peersChanged(peers) = event { return peers }
        }
        return []
    }

    func deliveryStates(for id: String) -> [DeliveryState] {
        events.compactMap {
            if case let .deliveryChanged(messageID, state) = $0, messageID == id { state } else { nil }
        }
    }
}

private func eventually(
    timeout: Duration = .seconds(3),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private struct Node {
    let mesh: MeshNode
    let recorder: Recorder
    let identity: IdentityKeys
}

private func fastConfig() -> MeshNode.Configuration {
    var config = MeshNode.Configuration()
    config.relayJitter = 0...0
    config.announceInterval = 0.2
    config.maintenanceInterval = 0.1
    return config
}

private func makeNode(
    _ name: String,
    radio: InMemoryRadio,
    config: MeshNode.Configuration = fastConfig(),
    identity: IdentityKeys = .generate(),
    store: (any BlobStore)? = nil
) -> Node {
    let mesh = MeshNode(identity: identity, nickname: name, link: radio.makeLink(name), configuration: config, store: store)
    return Node(mesh: mesh, recorder: Recorder(mesh), identity: identity)
}

@Suite("Mesh engine", .timeLimit(.minutes(1)))
struct MeshNodeTests {
    @Test func publicMessageHopsAcrossARelay() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let c = makeNode("carol", radio: radio)
        radio.connect("alice", "bob")
        radio.connect("bob", "carol") // alice and carol are out of range of each other
        for node in [a, b, c] { await node.mesh.start() }

        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "carol" && !$0.isDirect } })

        _ = await a.mesh.sendPublic("hello mesh")
        #expect(await eventually { await c.recorder.publicMessages.contains { $0.text == "hello mesh" } })
        let received = await c.recorder.publicMessages.first { $0.text == "hello mesh" }
        #expect(received?.senderName == "alice")
        #expect(received?.isVerified == true)
        #expect(received?.senderKey == a.identity.fingerprint.hex)
    }

    @Test func eachNodeHandlesAFloodedMessageOnce() async {
        let radio = InMemoryRadio()
        let nodes = ["a", "b", "c", "d"].map { makeNode($0, radio: radio) }
        // Fully connected: every message reaches every node over several paths.
        for (i, x) in ["a", "b", "c", "d"].enumerated() {
            for y in ["a", "b", "c", "d"].dropFirst(i + 1) { radio.connect(x, y) }
        }
        for node in nodes { await node.mesh.start() }
        #expect(await eventually { await nodes[0].recorder.latestPeers.count == 3 })

        _ = await nodes[0].mesh.sendPublic("once")
        for node in nodes.dropFirst() {
            #expect(await eventually { await node.recorder.publicMessages.contains { $0.text == "once" } })
        }
        try? await Task.sleep(for: .milliseconds(200))
        for node in nodes.dropFirst() {
            #expect(await node.recorder.publicMessages.filter { $0.text == "once" }.count == 1)
        }
    }

    @Test func directMessageIsEncryptedEndToEndThroughARelay() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let c = makeNode("carol", radio: radio)
        radio.connect("alice", "bob")
        radio.connect("bob", "carol")
        for node in [a, b, c] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "carol" } })

        let secret = "meet at the north gate"
        let sent = await a.mesh.sendPrivate(secret, to: c.identity.fingerprint)
        #expect(sent.channel == .direct(c.identity.fingerprint))

        #expect(await eventually { await c.recorder.privateMessages.contains { $0.text == secret } })
        let received = await c.recorder.privateMessages.first { $0.text == secret }
        #expect(received?.channel == .direct(a.identity.fingerprint))
        #expect(received?.isVerified == true)

        // The sender hears the delivery ack come back.
        #expect(await eventually { await a.recorder.deliveryStates(for: sent.id).contains(.delivered) })

        // The relay never surfaces it, and no frame on any link carries the plaintext.
        #expect(await b.recorder.privateMessages.isEmpty)
        let plaintext = Data(secret.utf8)
        #expect(!radio.transmittedFrames.contains { $0.range(of: plaintext) != nil })

        // Both ends now show a secure session.
        #expect(await eventually { await a.recorder.latestPeers.first { $0.nickname == "carol" }?.hasSecureSession == true })
    }

    @Test func readReceiptReachesTheSender() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "bob" } })

        let sent = await a.mesh.sendPrivate("did you see this?", to: b.identity.fingerprint)
        #expect(await eventually { await b.recorder.privateMessages.contains { $0.id == sent.id } })
        await b.mesh.markRead(messageIDs: [sent.id], from: a.identity.fingerprint)
        #expect(await eventually { await a.recorder.deliveryStates(for: sent.id).contains(.read) })
    }

    @Test func directMessageWaitsUntilTheRecipientAppears() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        await a.mesh.start()

        // Bob is not around yet.
        let sent = await a.mesh.sendPrivate("for later", to: b.identity.fingerprint)
        #expect(sent.delivery == .queued)

        await b.mesh.start()
        radio.connect("alice", "bob")
        #expect(await eventually { await b.recorder.privateMessages.contains { $0.text == "for later" } })
        #expect(await eventually { await a.recorder.deliveryStates(for: sent.id).contains(.delivered) })
    }

    @Test func messagesForgedInAKnownPeersNameAreDropped() async throws {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await b.recorder.latestPeers.contains { $0.nickname == "alice" } })

        // Mallory claims to be Alice's PeerID but signs with her own key.
        let forger = IdentityKeys.generate()
        var packet = Packet(
            type: .publicMessage,
            ttl: 7,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            packetID: Packet.randomPacketID(),
            sender: a.mesh.peerID,
            payload: PublicMessagePayload(nickname: "alice", text: "send me your keys").encoded()
        )
        packet.signature = forger.sign(packet.signingBytes())
        attacker.send(packet.encoded(), to: "bob")

        try await Task.sleep(for: .milliseconds(300))
        #expect(await !b.recorder.publicMessages.contains { $0.text == "send me your keys" })
    }

    @Test func peersExpireWhenTheyGoSilent() async {
        let radio = InMemoryRadio()
        var config = fastConfig()
        config.peerTimeout = 0.5
        let a = makeNode("alice", radio: radio, config: config)
        let b = makeNode("bob", radio: radio, config: config)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.count == 1 })

        radio.disconnect("alice", "bob")
        #expect(await eventually { await a.recorder.latestPeers.isEmpty })
    }

    // MARK: - Hop limit

    @Test func publicMessageStopsAfterSevenHops() async throws {
        let radio = InMemoryRadio()
        // A line of 9 phones: n0 – n1 – … – n8. n7 is 7 hops from n0, n8 is 8.
        let names = (0...8).map { "n\($0)" }
        let nodes = names.map { makeNode($0, radio: radio) }
        for (x, y) in zip(names, names.dropFirst()) { radio.connect(x, y) }
        for node in nodes { await node.mesh.start() }

        let sent = await nodes[0].mesh.sendPublic("how far?")
        for node in nodes[1...7] {
            #expect(await eventually { await node.recorder.publicMessages.contains { $0.id == sent.id } })
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !nodes[8].recorder.publicMessages.contains { $0.id == sent.id })
        // n7 received it with TTL 1 and must not pass it on.
        #expect(radio.frames(carrying: sent.id).allSatisfy { $0.from != "n7" })
    }

    // MARK: - Session recovery

    @Test func lostSessionIsRebuiltAndTheMessageStillArrives() async {
        let radio = InMemoryRadio()
        // Alice forgets silent peers quickly; Bob remembers them for a minute.
        var forgetful = fastConfig()
        forgetful.peerTimeout = 0.5
        let a = makeNode("alice", radio: radio, config: forgetful)
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "bob" } })

        let first = await a.mesh.sendPrivate("first", to: b.identity.fingerprint)
        #expect(await eventually { await a.recorder.deliveryStates(for: first.id).contains(.delivered) })

        // Out of range long enough for Alice to drop Bob, and her session with him.
        radio.disconnect("alice", "bob")
        #expect(await eventually { await a.recorder.latestPeers.isEmpty })
        radio.connect("alice", "bob")
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "bob" } })

        // Bob still holds the old session, so his message reaches Alice as
        // ciphertext she can't read. She starts a new handshake, and Bob resends
        // the unacknowledged message over the new session.
        let reply = await b.mesh.sendPrivate("still there?", to: a.identity.fingerprint)
        #expect(await eventually { await a.recorder.privateMessages.contains { $0.id == reply.id } })
        #expect(await eventually { await b.recorder.deliveryStates(for: reply.id).contains(.delivered) })
        #expect(await a.recorder.privateMessages.filter { $0.id == reply.id }.count == 1)
    }

    @Test func corruptedCiphertextDoesNotBreakTheSession() async throws {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "bob" } })

        let first = await a.mesh.sendPrivate("first", to: b.identity.fingerprint)
        #expect(await eventually { await a.recorder.deliveryStates(for: first.id).contains(.delivered) })

        // Garbage claiming to come from Alice, using nonces she hasn't reached yet.
        for nonce in UInt64(1)...5 {
            let junk = Packet(
                type: .encrypted,
                ttl: 7,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                packetID: Packet.randomPacketID(),
                sender: a.mesh.peerID,
                recipient: b.mesh.peerID,
                payload: EncryptedPayload(nonce: nonce, ciphertext: Data((0..<48).map { _ in .random(in: 0...255) })).encoded()
            )
            attacker.send(junk.encoded(), to: "bob")
        }
        try await Task.sleep(for: .milliseconds(200))

        // Bob drops the junk without burning those nonces, so Alice's next messages get through.
        for text in ["second", "third"] {
            let sent = await a.mesh.sendPrivate(text, to: b.identity.fingerprint)
            #expect(await eventually { await b.recorder.privateMessages.contains { $0.id == sent.id } })
        }
        #expect(await b.recorder.privateMessages.count == 3)
    }

    // MARK: - Larger meshes

    @Test func floodCoversA4x4GridWithEachNodeRelayingOnce() async throws {
        let radio = InMemoryRadio()
        var config = fastConfig()
        config.announceInterval = 1 // 16 nodes flooding announces every 0.2 s is just noise here.
        let size = 4
        let name = { (row: Int, col: Int) in "r\(row)c\(col)" }
        let names = (0..<size).flatMap { row in (0..<size).map { name(row, $0) } }
        let nodes = names.map { makeNode($0, radio: radio, config: config) }
        var edgeCount = 0
        for row in 0..<size {
            for col in 0..<size {
                if col + 1 < size { radio.connect(name(row, col), name(row, col + 1)); edgeCount += 1 }
                if row + 1 < size { radio.connect(name(row, col), name(row + 1, col)); edgeCount += 1 }
            }
        }
        for node in nodes { await node.mesh.start() }

        let corner = nodes[0], farCorner = nodes[nodes.count - 1] // 6 hops apart
        let sent = await corner.mesh.sendPublic("grid")
        for node in nodes.dropFirst() {
            #expect(await eventually(timeout: .seconds(5)) {
                await node.recorder.publicMessages.contains { $0.id == sent.id }
            })
        }
        try await Task.sleep(for: .milliseconds(300))
        for node in nodes.dropFirst() {
            #expect(await node.recorder.publicMessages.filter { $0.id == sent.id }.count == 1)
        }
        // The sender sends once per neighbour; every other node relays once per
        // neighbour except the one it heard from: 2·edges − (nodes − 1) transmissions.
        let transmissions = radio.frames(carrying: sent.id).count
        #expect(transmissions <= 2 * edgeCount - (nodes.count - 1))

        // An encrypted DM between opposite corners finds its way across too.
        #expect(await eventually(timeout: .seconds(5)) {
            await corner.recorder.latestPeers.contains { $0.fingerprint == farCorner.identity.fingerprint }
        })
        let dm = await corner.mesh.sendPrivate("corner to corner", to: farCorner.identity.fingerprint)
        #expect(await eventually(timeout: .seconds(5)) {
            await farCorner.recorder.privateMessages.contains { $0.id == dm.id }
        })
        #expect(await eventually(timeout: .seconds(5)) {
            await corner.recorder.deliveryStates(for: dm.id).contains(.delivered)
        })
    }
}

private func nowMilliseconds(offset: TimeInterval = 0) -> UInt64 {
    UInt64((Date().timeIntervalSince1970 + offset) * 1000)
}

private func decodedPackets(_ radio: InMemoryRadio) -> [(from: String, to: String, packet: Packet)] {
    radio.transmissions.compactMap { entry in
        (try? Packet.decode(entry.frame)).map { (entry.from, entry.to, $0) }
    }
}

extension Recorder {
    func count(of state: DeliveryState, for id: String) -> Int {
        deliveryStates(for: id).filter { $0 == state }.count
    }
}

@Suite("Mesh engine: security, lifecycle and routing", .timeLimit(.minutes(1)))
struct MeshNodeSecurityAndLifecycleTests {
    // MARK: Sessions

    @Test func simultaneousFirstMessagesBothArrive() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually {
            let aPeers = await a.recorder.latestPeers.count
            let bPeers = await b.recorder.latestPeers.count
            return aPeers == 1 && bPeers == 1
        })

        // Both start a handshake at the same moment; the PeerID tie-break must settle on one session.
        async let fromAlice = a.mesh.sendPrivate("hi bob", to: b.identity.fingerprint)
        async let fromBob = b.mesh.sendPrivate("hi alice", to: a.identity.fingerprint)
        let (sentA, sentB) = await (fromAlice, fromBob)

        #expect(await eventually { await b.recorder.privateMessages.contains { $0.id == sentA.id } })
        #expect(await eventually { await a.recorder.privateMessages.contains { $0.id == sentB.id } })
        #expect(await eventually { await a.recorder.deliveryStates(for: sentA.id).contains(.delivered) })
        #expect(await eventually { await b.recorder.deliveryStates(for: sentB.id).contains(.delivered) })
    }

    @Test func manyMessagesArriveOnceAndInOrderThroughARelay() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let c = makeNode("carol", radio: radio)
        radio.connect("alice", "bob")
        radio.connect("bob", "carol")
        for node in [a, b, c] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "carol" } })

        var sent: [ChatMessage] = []
        for index in 0..<25 {
            sent.append(await a.mesh.sendPrivate("message \(index)", to: c.identity.fingerprint))
        }
        #expect(await eventually { await c.recorder.privateMessages.count == 25 })
        #expect(await c.recorder.privateMessages.map(\.text) == sent.map(\.text))
        #expect(await eventually {
            for message in sent where await !a.recorder.deliveryStates(for: message.id).contains(.delivered) { return false }
            return true
        })
        #expect(await b.recorder.privateMessages.isEmpty)
    }

    @Test func undeliverableMessagesFailAfterTheirLifetime() async {
        let radio = InMemoryRadio()
        var config = fastConfig()
        config.outboxLifetime = 0.3
        let a = makeNode("alice", radio: radio, config: config)
        await a.mesh.start()

        let stranger = IdentityKeys.generate().fingerprint // never shows up
        let sent = await a.mesh.sendPrivate("anyone?", to: stranger)
        #expect(sent.delivery == .queued)
        #expect(await eventually { await a.recorder.deliveryStates(for: sent.id).contains(.failed) })
        // It fails once, not on every maintenance pass.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await a.recorder.count(of: .failed, for: sent.id) == 1)
    }

    @Test func messageWaitsForAPartitionToHeal() async {
        let radio = InMemoryRadio()
        let nodes = ["a", "b", "c", "d"].map { makeNode($0, radio: radio) }
        radio.connect("a", "b")
        radio.connect("c", "d") // two separate groups
        for node in nodes { await node.mesh.start() }
        #expect(await eventually { await nodes[0].recorder.latestPeers.count == 1 })

        let sent = await nodes[0].mesh.sendPrivate("across the gap", to: nodes[3].identity.fingerprint)
        #expect(sent.delivery == .queued)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await nodes[3].recorder.privateMessages.isEmpty)

        radio.connect("b", "c") // someone walks between the groups
        #expect(await eventually { await nodes[3].recorder.privateMessages.contains { $0.id == sent.id } })
        #expect(await eventually { await nodes[0].recorder.deliveryStates(for: sent.id).contains(.delivered) })
    }

    @Test func groupsThatMeetCanTalkWithoutWaitingForThePeriodicAnnounce() async {
        let radio = InMemoryRadio()
        var config = fastConfig()
        config.announceInterval = 30 // far longer than the test: only event-driven announces count
        let nodes = ["a", "b", "c", "d"].map { makeNode($0, radio: radio, config: config) }
        radio.connect("a", "b")
        radio.connect("c", "d")
        for node in nodes { await node.mesh.start() }
        #expect(await eventually { await nodes[0].recorder.latestPeers.count == 1 })

        radio.connect("b", "c")
        // Both far ends learn each other quickly, not only the side that heard first.
        #expect(await eventually(timeout: .seconds(1)) { await nodes[0].recorder.latestPeers.contains { $0.nickname == "d" } })
        #expect(await eventually(timeout: .seconds(1)) { await nodes[3].recorder.latestPeers.contains { $0.nickname == "a" } })

        let sent = await nodes[0].mesh.sendPrivate("hello, other group", to: nodes[3].identity.fingerprint)
        #expect(await eventually(timeout: .seconds(1)) { await nodes[3].recorder.privateMessages.contains { $0.id == sent.id } })
    }

    // MARK: Peers

    @Test func leavingRemovesThePeerRightAway() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio) // default 60 s peer timeout
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.count == 1 })

        await b.mesh.stop()
        #expect(await eventually(timeout: .seconds(1)) { await a.recorder.latestPeers.isEmpty })
    }

    @Test func peersReachedThroughRelaysAreNotDirect() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let c = makeNode("carol", radio: radio)
        radio.connect("alice", "bob")
        radio.connect("bob", "carol")
        for node in [a, b, c] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.count == 2 })

        let peers = await a.recorder.latestPeers
        #expect(peers.first { $0.nickname == "bob" }?.isDirect == true)
        #expect(peers.first { $0.nickname == "carol" }?.isDirect == false)

        // Losing the link to Bob makes him indirect straight away (he may still be heard via others later).
        radio.disconnect("alice", "bob")
        #expect(await eventually { await a.recorder.latestPeers.first { $0.nickname == "bob" }?.isDirect == false })
    }

    @Test func nicknameChangesReachOtherPeers() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await b.recorder.latestPeers.contains { $0.nickname == "alice" } })

        await a.mesh.setNickname("  Alicia\n")
        #expect(await eventually { await b.recorder.latestPeers.contains { $0.nickname == "Alicia" } })
        #expect(await b.recorder.latestPeers.count == 1)

        _ = await a.mesh.sendPublic("new name")
        #expect(await eventually { await b.recorder.publicMessages.contains { $0.text == "new name" && $0.senderName == "Alicia" } })
    }

    @Test func peersMoreThanSevenHopsAwayAreNotListed() async {
        let radio = InMemoryRadio()
        let names = (0...8).map { "n\($0)" }
        let nodes = names.map { makeNode($0, radio: radio) }
        for (x, y) in zip(names, names.dropFirst()) { radio.connect(x, y) }
        for node in nodes { await node.mesh.start() }

        #expect(await eventually { await nodes[0].recorder.latestPeers.contains { $0.nickname == "n7" } })
        try? await Task.sleep(for: .milliseconds(400)) // a couple of announce rounds
        #expect(await !nodes[0].recorder.latestPeers.contains { $0.nickname == "n8" })
    }

    // MARK: Attacks and malformed traffic

    @Test func announceClaimingAKnownPeerIDWithOtherKeysIsIgnored() async throws {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await b.recorder.latestPeers.contains { $0.nickname == "alice" } })

        // A validly signed announce, but with Mallory's keys behind Alice's PeerID.
        let forger = IdentityKeys.generate()
        var announce = Packet(
            type: .announce, ttl: 7, timestamp: nowMilliseconds(), packetID: Packet.randomPacketID(),
            sender: a.mesh.peerID,
            payload: AnnouncePayload(nickname: "alice", noiseKey: forger.noisePublic, signingKey: forger.signingPublic).encoded()
        )
        announce.signature = forger.sign(announce.signingBytes())
        attacker.send(announce.encoded(), to: "bob")

        try await Task.sleep(for: .milliseconds(300))
        let peers = await b.recorder.latestPeers
        #expect(peers.first { $0.peerID == a.mesh.peerID }?.fingerprint == a.identity.fingerprint)
        #expect(!peers.contains { $0.fingerprint == forger.fingerprint })
    }

    @Test func forgedLeaveDoesNotKickAPeer() async throws {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await b.recorder.latestPeers.contains { $0.nickname == "alice" } })

        for signature in [nil, IdentityKeys.generate().sign(Data("x".utf8))] {
            var leave = Packet(type: .leave, ttl: 7, timestamp: nowMilliseconds(), packetID: Packet.randomPacketID(),
                               sender: a.mesh.peerID, payload: Data())
            leave.signature = signature
            attacker.send(leave.encoded(), to: "bob")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await b.recorder.latestPeers.contains { $0.nickname == "alice" })
    }

    @Test func messagesWithBadTimestampsAreDropped() async throws {
        let radio = InMemoryRadio()
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "bob")
        await b.mesh.start()
        let stranger = PeerID.random()

        func send(_ text: String, offset: TimeInterval) {
            let packet = Packet(type: .publicMessage, ttl: 7, timestamp: nowMilliseconds(offset: offset),
                                packetID: Packet.randomPacketID(), sender: stranger,
                                payload: PublicMessagePayload(nickname: "eve", text: text).encoded())
            attacker.send(packet.encoded(), to: "bob")
        }
        send("fresh", offset: 0)
        send("an hour old", offset: -3600)
        send("from the future", offset: 3600)

        #expect(await eventually { await b.recorder.publicMessages.contains { $0.text == "fresh" } })
        try await Task.sleep(for: .milliseconds(200))
        let texts = await b.recorder.publicMessages.map(\.text)
        #expect(texts == ["fresh"])
    }

    @Test func unsignedMessagesFromStrangersAreShownAsUnverified() async {
        let radio = InMemoryRadio()
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "bob")
        await b.mesh.start()

        let stranger = PeerID.random()
        let packet = Packet(type: .publicMessage, ttl: 7, timestamp: nowMilliseconds(), packetID: Packet.randomPacketID(),
                            sender: stranger, payload: PublicMessagePayload(nickname: "eve\n", text: "trust me").encoded())
        attacker.send(packet.encoded(), to: "bob")

        #expect(await eventually { await b.recorder.publicMessages.contains { $0.text == "trust me" } })
        let message = await b.recorder.publicMessages.first { $0.text == "trust me" }
        #expect(message?.isVerified == false)
        #expect(message?.senderName == "eve")
        #expect(message?.senderKey == "peer:\(stranger.hex)")
    }

    @Test func replayedReceiptWithANewPacketIDIsIgnored() async throws {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "alice")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.contains { $0.nickname == "bob" } })

        let sent = await a.mesh.sendPrivate("read this", to: b.identity.fingerprint)
        #expect(await eventually { await b.recorder.privateMessages.contains { $0.id == sent.id } })
        await b.mesh.markRead(messageIDs: [sent.id], from: a.identity.fingerprint)
        #expect(await eventually { await a.recorder.deliveryStates(for: sent.id).contains(.read) })

        // Mallory captured Bob's read receipt off the air and re-sends it, unchanged and re-wrapped.
        let receipt = try #require(decodedPackets(radio).last {
            $0.from == "bob" && $0.packet.type == .encrypted && $0.packet.sender == b.mesh.peerID
        }?.packet)
        attacker.send(receipt.encoded(), to: "alice")
        var rewrapped = receipt
        rewrapped.packetID = Packet.randomPacketID()
        rewrapped.timestamp = nowMilliseconds()
        attacker.send(rewrapped.encoded(), to: "alice")

        try await Task.sleep(for: .milliseconds(300))
        #expect(await a.recorder.count(of: .read, for: sent.id) == 1)
    }

    @Test func garbageFramesAreIgnored() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("alice", "bob")
        radio.connect("mallory", "bob")
        for node in [a, b] { await node.mesh.start() }

        for frame in [Data(), Data([0x4C, 0x42]), Data(repeating: 0xFF, count: 500), Data("LB hello".utf8), Data([0x48, 0x4C, 1, 2]) /* an old Hopline frame */] {
            attacker.send(frame, to: "bob")
        }
        // Bob is still healthy: he relays and receives normally.
        _ = await a.mesh.sendPublic("still alive?")
        #expect(await eventually { await b.recorder.publicMessages.contains { $0.text == "still alive?" } })
    }

    // MARK: Routing

    @Test func directedPacketsGoOnlyTowardTheirRecipient() async {
        let radio = InMemoryRadio()
        let hub = makeNode("hub", radio: radio)
        let spokes = ["b", "c", "d"].map { makeNode($0, radio: radio) }
        for name in ["b", "c", "d"] { radio.connect("hub", name) }
        for node in [hub] + spokes { await node.mesh.start() }
        #expect(await eventually { await hub.recorder.latestPeers.count == 3 })

        let sent = await hub.mesh.sendPrivate("just for b", to: spokes[0].identity.fingerprint)
        #expect(await eventually { await hub.recorder.deliveryStates(for: sent.id).contains(.delivered) })

        let toB = decodedPackets(radio).filter { $0.packet.recipient == spokes[0].mesh.peerID }
        #expect(!toB.isEmpty)
        #expect(toB.allSatisfy { $0.from == "hub" && $0.to == "b" })
    }

    @Test func relaysNeverEchoAPacketBackWhereItCameFrom() async {
        let radio = InMemoryRadio()
        let nodes = ["a", "b", "c"].map { makeNode($0, radio: radio) }
        radio.connect("a", "b")
        radio.connect("b", "c")
        for node in nodes { await node.mesh.start() }

        let sent = await nodes[0].mesh.sendPublic("one way")
        #expect(await eventually { await nodes[2].recorder.publicMessages.contains { $0.id == sent.id } })
        try? await Task.sleep(for: .milliseconds(100))
        let hops = radio.frames(carrying: sent.id).map { "\($0.from)>\($0.to)" }
        #expect(hops.sorted() == ["a>b", "b>c"])
    }

    @Test func aNodeNeverShowsItsOwnEchoedMessages() async {
        let radio = InMemoryRadio()
        let nodes = ["a", "b", "c"].map { makeNode($0, radio: radio) }
        radio.connect("a", "b")
        radio.connect("b", "c")
        radio.connect("c", "a") // a loop sends a's message back to it
        for node in nodes { await node.mesh.start() }

        let sent = await nodes[0].mesh.sendPublic("echo?")
        #expect(await eventually { await nodes[1].recorder.publicMessages.contains { $0.id == sent.id } })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await nodes[0].recorder.publicMessages.isEmpty)
    }
}

// MARK: - Store and forward

/// Fast timings for courier scenarios: peers who leave are forgotten within half a
/// second, and anything waiting 0.2 s goes to couriers.
private func courierConfig() -> MeshNode.Configuration {
    var config = fastConfig()
    config.peerTimeout = 0.5
    config.courierDelay = 0.2
    return config
}

extension Recorder {
    var latestEnvelopes: EnvelopeSummary? {
        for event in events.reversed() {
            if case let .envelopesChanged(summary) = event { return summary }
        }
        return nil
    }

    var restoredMessages: [ChatMessage] {
        events.compactMap { if case let .outgoingRestored(m, _) = $0 { m } else { nil } }
    }
}

/// Alice and Dave meet (so each learns the other's key), then go their separate ways.
private func meetAndPart(_ a: Node, _ aName: String, _ b: Node, _ bName: String, radio: InMemoryRadio) async {
    radio.connect(aName, bName)
    #expect(await eventually { await a.recorder.latestPeers.contains { $0.fingerprint == b.identity.fingerprint } })
    #expect(await eventually { await b.recorder.latestPeers.contains { $0.fingerprint == a.identity.fingerprint } })
    radio.disconnect(aName, bName)
    #expect(await eventually { await a.recorder.latestPeers.allSatisfy { $0.fingerprint != b.identity.fingerprint } })
}

private func courierHandoffs(_ radio: InMemoryRadio, from sender: String) -> [(from: String, to: String, packet: Packet)] {
    decodedPackets(radio).filter { $0.from == sender && $0.packet.type == .courier && $0.packet.ttl == 1 }
}

@Suite("Mesh engine: couriers and persistence", .timeLimit(.minutes(1)))
struct MeshCourierTests {
    @Test func aCourierCarriesTheMessageAndTheReceiptComesBackTheSameWay() async throws {
        let radio = InMemoryRadio()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())     // the hiker who walks between them
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        // Alice writes to Dave, who is out of range. Bob passes Alice and takes a copy.
        radio.connect("alice", "bob")
        let secret = "see you at the lake at 6"
        let sent = await alice.mesh.sendPrivate(secret, to: dave.identity.fingerprint)
        #expect(sent.delivery == .queued)
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })

        // Bob walks on and meets Dave. Alice and Dave are never in range of each other.
        radio.disconnect("alice", "bob")
        radio.connect("bob", "dave")
        #expect(await eventually { await dave.recorder.privateMessages.contains { $0.id == sent.id } })
        let received = try #require(await dave.recorder.privateMessages.first { $0.id == sent.id })
        #expect(received.text == secret)
        #expect(received.channel == .direct(alice.identity.fingerprint))
        #expect(received.senderName == "alice")
        #expect(received.isVerified)

        // Bob carried it but could never read it.
        #expect(await bob.recorder.privateMessages.isEmpty)
        #expect(!radio.transmittedFrames.contains { $0.range(of: Data(secret.utf8)) != nil })

        // Dave's receipt goes back the same way: Bob takes it, walks back, meets Alice.
        #expect(await eventually { courierHandoffs(radio, from: "dave").contains { $0.to == "bob" } })
        radio.disconnect("bob", "dave")
        radio.connect("bob", "alice")
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.delivered) })
    }

    @Test func nothingIsHandedOutForSomeoneWeHaveNeverMet() async throws {
        let radio = InMemoryRadio()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())
        radio.connect("alice", "bob")
        for node in [alice, bob] { await node.mesh.start() }

        let stranger = IdentityKeys.generate().fingerprint // no key known, so nothing to seal to
        let sent = await alice.mesh.sendPrivate("hello?", to: stranger)
        try await Task.sleep(for: .milliseconds(500))
        #expect(courierHandoffs(radio, from: "alice").isEmpty)
        #expect(await !alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope))
    }

    @Test func eachCourierGetsOneCopyUpToTheLimit() async throws {
        let radio = InMemoryRadio()
        var config = courierConfig()
        config.maxCourierCopies = 2
        let alice = makeNode("alice", radio: radio, config: config)
        let dave = makeNode("dave", radio: radio, config: config)
        let hikers = ["h1", "h2", "h3", "h4"].map { makeNode($0, radio: radio, config: config) }
        for node in [alice, dave] + hikers { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        for name in ["h1", "h2", "h3", "h4"] { radio.connect("alice", name) }
        _ = await alice.mesh.sendPrivate("limited", to: dave.identity.fingerprint)
        #expect(await eventually { !courierHandoffs(radio, from: "alice").isEmpty })
        try await Task.sleep(for: .milliseconds(500)) // several maintenance passes

        let recipients = courierHandoffs(radio, from: "alice").map(\.to)
        #expect(recipients.count == 2)        // no repeats
        #expect(Set(recipients).count == 2)   // and no more than the limit
    }

    @Test func someoneWhoArrivesLaterStillGetsACopy() async {
        let radio = InMemoryRadio()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        // Alice waits at camp with no one around...
        let sent = await alice.mesh.sendPrivate("for whoever passes", to: dave.identity.fingerprint)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await !alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope))
        // ...until Bob walks by.
        radio.connect("alice", "bob")
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        #expect(courierHandoffs(radio, from: "alice").contains { $0.to == "bob" })
    }

    @Test func couriersOnlyDeliverToTheRecipientNeverPassItOn() async throws {
        let radio = InMemoryRadio()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())
        let carol = makeNode("carol", radio: radio, config: courierConfig())
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, carol, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        radio.connect("alice", "bob")
        let sent = await alice.mesh.sendPrivate("only for dave", to: dave.identity.fingerprint)
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        radio.disconnect("alice", "bob")
        radio.connect("bob", "carol")
        try await Task.sleep(for: .milliseconds(400))
        #expect(courierHandoffs(radio, from: "bob").isEmpty)
        #expect(!decodedPackets(radio).contains { $0.from == "bob" && $0.packet.type == .courier })
        #expect(await carol.recorder.privateMessages.isEmpty)
    }

    @Test func couriersDropEnvelopesAfterTheirCarryTime() async throws {
        let radio = InMemoryRadio()
        var bobConfig = courierConfig()
        bobConfig.maxCarryTime = 0.3
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: bobConfig)
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        radio.connect("alice", "bob")
        let sent = await alice.mesh.sendPrivate("too slow", to: dave.identity.fingerprint)
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        radio.disconnect("alice", "bob")
        try await Task.sleep(for: .milliseconds(500)) // longer than Bob will carry it
        radio.connect("bob", "dave")
        try await Task.sleep(for: .milliseconds(400))
        #expect(await dave.recorder.privateMessages.isEmpty)
    }

    @Test func aCourierCannotExtendTheExpiryOrForgeTheSender() async throws {
        let radio = InMemoryRadio()
        let dave = makeNode("dave", radio: radio)
        let attacker = radio.makeLink("mallory")
        radio.connect("mallory", "dave")
        await dave.mesh.start()

        let mallory = IdentityKeys.generate()
        let daveContact = Contact(fingerprint: dave.identity.fingerprint, nickname: "dave", noiseKey: dave.identity.noisePublic, lastSeen: Date())
        func handOver(_ envelope: CourierEnvelope) {
            var packet = Packet(type: .courier, ttl: 1, timestamp: nowMilliseconds(), packetID: Packet.randomPacketID(),
                                sender: .random(), payload: envelope.encoded())
            packet.ttl = 1
            attacker.send(packet.encoded(), to: "dave")
        }

        // Extending the expiry breaks the seal.
        var extended = try #require(Courier.seal(.message(id: "m1", nickname: "alice", text: "extended", timestamp: nowMilliseconds()),
                                                 to: daveContact, from: mallory, expiry: Date().addingTimeInterval(60)))
        extended.expiry += 86_400_000
        handOver(extended)
        // Already expired envelopes are refused outright.
        let expired = try #require(Courier.seal(.message(id: "m2", nickname: "alice", text: "expired", timestamp: nowMilliseconds()),
                                                to: daveContact, from: mallory, expiry: Date().addingTimeInterval(-1)))
        handOver(expired)
        // A valid one claiming to be "alice" shows Mallory's real fingerprint, not Alice's.
        let claimed = try #require(Courier.seal(.message(id: "m3", nickname: "alice", text: "it's me, alice", timestamp: nowMilliseconds()),
                                                to: daveContact, from: mallory, expiry: Date().addingTimeInterval(60)))
        handOver(claimed)

        #expect(await eventually { await dave.recorder.privateMessages.contains { $0.id == "m3" } })
        try await Task.sleep(for: .milliseconds(100))
        let messages = await dave.recorder.privateMessages
        #expect(messages.map(\.id) == ["m3"])
        #expect(messages.first?.channel == .direct(mallory.fingerprint))
    }

    @Test func aCourierCanDeliverThroughOtherPhones() async {
        let radio = InMemoryRadio()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())
        let carol = makeNode("carol", radio: radio, config: courierConfig())
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, carol, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)
        radio.connect("carol", "dave")

        radio.connect("alice", "bob")
        let sent = await alice.mesh.sendPrivate("via carol", to: dave.identity.fingerprint)
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        radio.disconnect("alice", "bob")
        // Bob only gets within range of Carol, who is next to Dave.
        radio.connect("bob", "carol")
        #expect(await eventually { await dave.recorder.privateMessages.contains { $0.id == sent.id } })
        #expect(await carol.recorder.privateMessages.isEmpty)
    }

    @Test func aMessageArrivingByCourierAndDirectlyShowsOnce() async {
        let radio = InMemoryRadio()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        radio.connect("alice", "bob")
        let sent = await alice.mesh.sendPrivate("twice?", to: dave.identity.fingerprint)
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        radio.disconnect("alice", "bob")
        radio.connect("bob", "dave")
        #expect(await eventually { await dave.recorder.privateMessages.contains { $0.id == sent.id } })

        // Then Alice and Dave meet in person before the receipt reached her: she sends it again.
        radio.disconnect("bob", "dave")
        radio.connect("alice", "dave")
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.delivered) })
        #expect(await dave.recorder.privateMessages.filter { $0.id == sent.id }.count == 1)
    }

    @Test func queuedMessagesAndContactsSurviveARestart() async throws {
        let radio = InMemoryRadio()
        let store = InMemoryBlobStore()
        let aliceKeys = IdentityKeys.generate()
        let alice = makeNode("alice", radio: radio, config: courierConfig(), identity: aliceKeys, store: store)
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig())
        for node in [alice, dave, bob] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        let sent = await alice.mesh.sendPrivate("written before the battery died", to: dave.identity.fingerprint)
        await alice.mesh.stop()
        #expect(store.contents != nil)

        // The phone restarts: same identity, same storage, new everything else.
        let restarted = makeNode("alice", radio: radio, config: courierConfig(), identity: aliceKeys, store: store)
        await restarted.mesh.start()
        #expect(await eventually { await restarted.recorder.restoredMessages.contains { $0.id == sent.id } })
        let restored = try #require(await restarted.recorder.restoredMessages.first { $0.id == sent.id })
        #expect(restored.isOwn && restored.delivery == .queued)
        #expect(restored.channel == .direct(dave.identity.fingerprint))

        // It still knows Dave's key, so a passing courier can take it...
        radio.connect("alice", "bob")
        #expect(await eventually { await restarted.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        // ...and meeting Dave in person delivers it too.
        radio.connect("alice", "dave")
        #expect(await eventually { await dave.recorder.privateMessages.contains { $0.id == sent.id } })
    }

    @Test func carriedEnvelopesSurviveTheCouriersRestart() async {
        let radio = InMemoryRadio()
        let bobStore = InMemoryBlobStore()
        let bobKeys = IdentityKeys.generate()
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: courierConfig(), identity: bobKeys, store: bobStore)
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        radio.connect("alice", "bob")
        let sent = await alice.mesh.sendPrivate("carry me across a restart", to: dave.identity.fingerprint)
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.inEnvelope) })
        radio.disconnect("alice", "bob")
        await bob.mesh.stop()

        let restartedBob = makeNode("bob", radio: radio, config: courierConfig(), identity: bobKeys, store: bobStore)
        await restartedBob.mesh.start()
        radio.connect("bob", "dave")
        #expect(await eventually { await dave.recorder.privateMessages.contains { $0.id == sent.id } })
    }

    @Test func theOldestQueuedMessagesFailBeyondTheLimit() async {
        let radio = InMemoryRadio()
        var config = fastConfig()
        config.maxQueuedMessages = 3
        let alice = makeNode("alice", radio: radio, config: config)
        await alice.mesh.start()

        let stranger = IdentityKeys.generate().fingerprint
        var sent: [ChatMessage] = []
        for index in 0..<5 { sent.append(await alice.mesh.sendPrivate("m\(index)", to: stranger)) }
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent[1].id).contains(.failed) })
        #expect(await alice.recorder.deliveryStates(for: sent[0].id).contains(.failed))
        for message in sent[2...] {
            #expect(await !alice.recorder.deliveryStates(for: message.id).contains(.failed))
        }
    }

    @Test func corruptOrMissingStorageStartsClean() async {
        let radio = InMemoryRadio()
        let store = InMemoryBlobStore()
        try? store.save(Data("not json".utf8))
        let alice = makeNode("alice", radio: radio, identity: .generate(), store: store)
        await alice.mesh.start()
        let sent = await alice.mesh.sendPrivate("fresh start", to: IdentityKeys.generate().fingerprint)
        #expect(sent.delivery == .queued)
        #expect(await alice.recorder.restoredMessages.isEmpty)
    }
}

@Suite("Mesh engine: envelope summaries and restarts", .timeLimit(.minutes(1)))
struct MeshEnvelopeSummaryTests {
    @Test func summariesFollowAnEnvelopeFromHandOffToReceipt() async {
        let radio = InMemoryRadio()
        var config = courierConfig()
        config.maxCarryTime = 1.5
        let alice = makeNode("alice", radio: radio, config: courierConfig())
        let bob = makeNode("bob", radio: radio, config: config)
        let dave = makeNode("dave", radio: radio, config: courierConfig())
        for node in [alice, bob, dave] { await node.mesh.start() }
        await meetAndPart(alice, "alice", dave, "dave", radio: radio)

        radio.connect("alice", "bob")
        let sent = await alice.mesh.sendPrivate("tracked", to: dave.identity.fingerprint)
        // Alice sees her envelope on its way with one carrier; Bob sees one carried for others.
        #expect(await eventually { await alice.recorder.latestEnvelopes?.carriers(for: sent.id) == 1 })
        #expect(await alice.recorder.latestEnvelopes?.outgoing.first?.recipient == dave.identity.fingerprint)
        #expect(await eventually { await bob.recorder.latestEnvelopes?.carryingForOthers == 1 })

        // A second hiker passing adds a carrier.
        let erin = makeNode("erin", radio: radio, config: courierConfig())
        await erin.mesh.start()
        radio.connect("alice", "erin")
        #expect(await eventually { await alice.recorder.latestEnvelopes?.carriers(for: sent.id) == 2 })

        // Delivered, and the receipt reaches Alice: her envelope is gone from the list.
        radio.disconnect("alice", "bob")
        radio.disconnect("alice", "erin")
        radio.connect("alice", "dave")
        #expect(await eventually { await alice.recorder.deliveryStates(for: sent.id).contains(.delivered) })
        #expect(await eventually { await alice.recorder.latestEnvelopes?.outgoing.isEmpty == true })

        // Bob stops carrying once his carry time runs out.
        #expect(await eventually(timeout: .seconds(3)) { await bob.recorder.latestEnvelopes?.carryingForOthers == 0 })
    }

    @Test func turningTheMeshOffAndOnAgainStillWorks() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.recorder.latestPeers.count == 1 })

        await a.mesh.stop()
        _ = await b.mesh.sendPublic("while you were off")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await !a.recorder.publicMessages.contains { $0.text == "while you were off" })

        await a.mesh.start()
        _ = await b.mesh.sendPublic("welcome back")
        #expect(await eventually { await a.recorder.publicMessages.contains { $0.text == "welcome back" } })
        let sent = await a.mesh.sendPrivate("still private", to: b.identity.fingerprint)
        #expect(await eventually { await b.recorder.privateMessages.contains { $0.id == sent.id } })
    }

    @Test func canSealOnlyToPeopleWeHaveMet() async {
        let radio = InMemoryRadio()
        let a = makeNode("alice", radio: radio)
        let b = makeNode("bob", radio: radio)
        radio.connect("alice", "bob")
        for node in [a, b] { await node.mesh.start() }
        #expect(await eventually { await a.mesh.canSeal(to: b.identity.fingerprint) })
        #expect(await !a.mesh.canSeal(to: IdentityKeys.generate().fingerprint))
    }
}

@Suite("Carried envelopes")
struct CarriedEnvelopesTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func envelope(_ seed: UInt8, for fingerprint: Fingerprint = Fingerprint(hex: String(repeating: "d", count: 64)),
                          expiresIn: TimeInterval = 3600) -> CourierEnvelope {
        let id = Data(repeating: seed, count: 16)
        return CourierEnvelope(id: id, recipientTag: Courier.tag(for: fingerprint, envelopeID: id),
                               expiry: UInt64((start.timeIntervalSince1970 + expiresIn) * 1000), sealed: Data(repeating: 1, count: 100))
    }

    @Test func refusesDuplicatesAndExpiredEnvelopes() {
        var store = CarriedEnvelopes()
        let r1 = store.insert(envelope(1), received: start)
        #expect(r1)
        let r2 = store.insert(envelope(1), received: start)
        #expect(!r2)
        let r3 = store.insert(envelope(2, expiresIn: -1), received: start)
        #expect(!r3)
        #expect(store.count == 1)
    }

    @Test func carryTimeIsCappedWhateverTheEnvelopeSays() {
        var store = CarriedEnvelopes(maxLifetime: 60)
        let r4 = store.insert(envelope(1, expiresIn: 86_400), received: start)
        #expect(r4)
        store.prune(now: start.addingTimeInterval(61))
        #expect(store.count == 0)
    }

    @Test func whenFullTheSoonestToExpireMakesRoom() {
        var store = CarriedEnvelopes(capacity: 2)
        let r5 = store.insert(envelope(1, expiresIn: 100), received: start)
        #expect(r5)
        let r6 = store.insert(envelope(2, expiresIn: 300), received: start)
        #expect(r6)
        let r7 = store.insert(envelope(3, expiresIn: 200), received: start)
        #expect(r7) // evicts 1
        let r8 = store.insert(envelope(4, expiresIn: 50), received: start)
        #expect(!r8) // would expire first: refused
        #expect(Set(store.items.keys) == [Data(repeating: 2, count: 16), Data(repeating: 3, count: 16)])
    }

    @Test func dueReturnsOnlyThatPersonsEnvelopesAndKeepsThemForRetries() {
        var store = CarriedEnvelopes()
        let dave = Fingerprint(hex: String(repeating: "d", count: 64))
        let erin = Fingerprint(hex: String(repeating: "e", count: 64))
        _ = store.insert(envelope(1, for: dave), received: start)
        _ = store.insert(envelope(2, for: erin), received: start)
        _ = store.insert(envelope(3, for: dave), received: start)
        let r9 = store.due(for: dave, now: start, retryInterval: 30)
        #expect(r9.count == 2)
        let r10 = store.due(for: dave, now: start.addingTimeInterval(10), retryInterval: 30)
        #expect(r10.isEmpty) // handed over 10 s ago: not yet
        let r11 = store.due(for: dave, now: start.addingTimeInterval(31), retryInterval: 30)
        #expect(r11.count == 2) // retried after the interval
        let r12 = store.due(for: dave, now: start.addingTimeInterval(32), retryInterval: 0)
        #expect(r12.count == 2) // a direct neighbour gets them straight away
        #expect(store.count == 3) // kept until they expire
    }

    @Test func tagsDependOnBothPersonAndEnvelope() {
        let dave = Fingerprint(hex: String(repeating: "d", count: 64))
        let erin = Fingerprint(hex: String(repeating: "e", count: 64))
        let one = Data(repeating: 1, count: 16)
        let two = Data(repeating: 2, count: 16)
        #expect(Courier.tag(for: dave, envelopeID: one) != Courier.tag(for: erin, envelopeID: one))
        #expect(Courier.tag(for: dave, envelopeID: one) != Courier.tag(for: dave, envelopeID: two))
        #expect(Courier.tag(for: dave, envelopeID: one).count == CourierEnvelope.tagLength)
    }
}
