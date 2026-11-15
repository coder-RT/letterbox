import Foundation
import Testing
import LetterboxCrypto
import LetterboxDomain
@testable import LetterboxApplication
import LetterboxMesh
import LetterboxTestSupport

// The real ChatStore on top of the real mesh engine, talking to simulated phones over
// an in-memory radio. These cover what the unit tests fake out: the two layers together.

private func fast() -> MeshNode.Configuration {
    var config = MeshNode.Configuration()
    config.relayJitter = 0...0
    config.announceInterval = 0.2
    config.maintenanceInterval = 0.1
    config.peerTimeout = 0.6
    config.courierDelay = 0.2
    return config
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(4), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@MainActor
private struct World {
    let radio = InMemoryRadio()
    let store: ChatStore
    let me: MeshNode
    let connectivity: ScriptedConnectivityMonitor
    let settings = InMemorySettingsStore()

    init(name: String = "me", connectivity reading: SystemConnectivity = ScriptedConnectivityMonitor.named("wifi")) {
        me = MeshNode(identity: .generate(), nickname: name, link: radio.makeLink(name), configuration: fast())
        connectivity = ScriptedConnectivityMonitor(reading)
        store = ChatStore(mesh: me, locationChannels: NoLocationChannels(), locationProvider: NoLocation(),
                          settings: settings, connectivity: connectivity)
    }

    func phone(_ name: String, replies: Bool = true, publicReplies: Bool = false) -> SimulatedPhone {
        SimulatedPhone(name: name, radio: radio, configuration: fast(), replyToPrivate: replies, replyToPublic: publicReplies)
    }

    func peer(named name: String) -> Peer? { store.peers.first { $0.nickname == name } }
}

private actor NoLocationChannels: LocationChannelTransport {
    nonisolated let events = AsyncStream<LocationEvent> { _ in }
    func join(geohash: String) {}
    func leave() {}
    func send(_ text: String, nickname: String) -> ChatMessage? { nil }
}

private struct NoLocation: LocationProvider {
    func currentCoordinate() async throws -> Coordinate { throw LocationError.unavailable }
}

@Suite("Store + engine integration", .timeLimit(.minutes(1)))
@MainActor
struct StoreMeshIntegrationTests {
    @Test func privateMessageRoundTripWithReceipts() async throws {
        let world = World()
        let sam = world.phone("Sam")
        world.radio.connect("me", "Sam")
        await world.store.start()
        await sam.start()
        #expect(await waitUntil { world.peer(named: "Sam") != nil })

        world.store.openDirect(with: try #require(world.peer(named: "Sam")))
        await world.store.submit("hi sam")
        let channel = ChannelID.direct(sam.identity.fingerprint)
        #expect(await waitUntil { world.store.messages(in: channel).contains { $0.text == "Got it: hi sam" } })
        let mine = try #require(world.store.messages(in: channel).first { $0.text == "hi sam" })
        // Sam's reply arrived in the open chat, so ours was delivered and then read.
        #expect(await waitUntil { [.delivered, .read].contains(world.store.messages(in: channel).first { $0.id == mine.id }?.delivery) })
        #expect(sam.inbox.contains { $0.text == "hi sam" })
    }

    @Test func connectionRowsFollowTheRealEngine() async {
        let world = World()
        let sam = world.phone("Sam")
        world.radio.connect("me", "Sam")
        await world.store.start()
        await sam.start()
        #expect(await waitUntil {
            world.store.connectionRows.first { $0.kind == .bluetooth }?.status == .working("On. 1 person nearby")
        })
        let rows = Dictionary(uniqueKeysWithValues: world.store.connectionRows.map { ($0.kind, $0.status) })
        #expect(rows[.internet] == .working("Connected via Wi-Fi"))
        #expect(rows[.envelopes] == .working("None right now"))

        world.connectivity.report(ScriptedConnectivityMonitor.named("offline"))
        #expect(await waitUntil {
            world.store.connectionRows.first { $0.kind == .internet }?.status == .off("No internet connection")
        })
    }

    @Test func bluetoothOffThenOnKeepsWorkingBothWays() async throws {
        let world = World()
        let sam = world.phone("Sam", publicReplies: true)
        world.radio.connect("me", "Sam")
        await world.store.start()
        await sam.start()
        #expect(await waitUntil { world.peer(named: "Sam") != nil })

        // Off: nothing goes out, the user is told why, and the panel says so.
        await world.store.setBluetoothAllowed(false)
        #expect(world.store.peers.isEmpty)
        await world.store.submit("anyone?")
        #expect(world.store.messages(in: .mesh).last?.text.contains("Bluetooth is off in HelloLetter") == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!sam.inbox.contains { $0.text == "anyone?" })
        #expect(world.store.connectionRows.first { $0.kind == .bluetooth }?.status == .blockedByYou("Turned off in HelloLetter"))

        // On again: Sam comes back, and messages flow both ways.
        await world.store.setBluetoothAllowed(true)
        #expect(await waitUntil { world.peer(named: "Sam") != nil })
        await world.store.submit("back again")
        #expect(await waitUntil { sam.inbox.contains { $0.text == "back again" } })
        #expect(await waitUntil { world.store.messages(in: .mesh).contains { $0.text == "Sam heard you" } })
    }

    @Test func aPrivateMessageWrittenWhileBluetoothIsOffGoesOutWhenItsBackOn() async throws {
        let world = World()
        let sam = world.phone("Sam")
        world.radio.connect("me", "Sam")
        await world.store.start()
        await sam.start()
        #expect(await waitUntil { world.peer(named: "Sam") != nil })
        let samPeer = try #require(world.peer(named: "Sam"))
        world.store.openDirect(with: samPeer)
        await world.store.submit("first")
        #expect(await waitUntil { sam.inbox.contains { $0.text == "first" } })

        await world.store.setBluetoothAllowed(false)
        await world.store.submit("written offline")
        let channel = ChannelID.direct(samPeer.fingerprint)
        #expect(world.store.messages(in: channel).last?.text.contains("Bluetooth is off") == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!sam.inbox.contains { $0.text == "written offline" })

        await world.store.setBluetoothAllowed(true)
        #expect(await waitUntil { sam.inbox.contains { $0.text == "written offline" } })
        #expect(await waitUntil { world.store.messages(in: channel).contains { $0.text == "Got it: written offline" } })
    }

    @Test func aStrangerCantBeReachedWithEverythingOffButAKnownPersonQueues() async throws {
        let world = World()
        let sam = world.phone("Sam")
        world.radio.connect("me", "Sam")
        await world.store.start()
        await sam.start()
        #expect(await waitUntil { world.peer(named: "Sam") != nil })
        let samPeer = try #require(world.peer(named: "Sam"))
        let stranger = Peer(peerID: .random(), nickname: "Zed", fingerprint: IdentityKeys.generate().fingerprint,
                            isDirect: false, hasSecureSession: false, lastSeen: Date())

        await world.store.setBluetoothAllowed(false)
        await world.store.setInternetAllowed(false)
        world.store.openDirect(with: stranger)
        await world.store.submit("hello?")
        #expect(world.store.messages(in: .direct(stranger.fingerprint)).last?.text.contains("both off") == true)

        world.store.openDirect(with: samPeer) // known key: queued instead of refused
        await world.store.submit("see you later")
        #expect(world.store.messages(in: .direct(samPeer.fingerprint)).contains { $0.text == "see you later" && $0.isOwn })
    }

    @Test func envelopeSummariesReachTheStoreAndClearOnReceipt() async throws {
        let world = World()
        let dave = world.phone("Dave", replies: false)
        let bob = world.phone("Bob", replies: false)
        await world.store.start()
        await dave.start()
        await bob.start()

        // Meet Dave, open his chat, and part ways.
        world.radio.connect("me", "Dave")
        #expect(await waitUntil { world.peer(named: "Dave") != nil })
        world.store.openDirect(with: try #require(world.peer(named: "Dave")))
        world.radio.disconnect("me", "Dave")
        #expect(await waitUntil { world.peer(named: "Dave") == nil })

        await world.store.submit("see you at the lake")
        let channel = ChannelID.direct(dave.identity.fingerprint)
        let sent = try #require(world.store.messages(in: channel).first { $0.text == "see you at the lake" })

        // Bob walks past and takes a copy.
        world.radio.connect("me", "Bob")
        #expect(await waitUntil { world.store.envelopes.carriers(for: sent.id) == 1 })
        #expect(await waitUntil { world.store.messages(in: channel).first { $0.id == sent.id }?.delivery == .inEnvelope })
        #expect(world.store.connectionRows.first { $0.kind == .envelopes }?.status == .working("1 of yours on its way, carrying 0 for others"))

        // Bob meets Dave; Dave's receipt comes back with Bob.
        world.radio.disconnect("me", "Bob")
        world.radio.connect("Bob", "Dave")
        #expect(await waitUntil { dave.inbox.contains { $0.id == sent.id } })
        try await Task.sleep(for: .milliseconds(500))
        world.radio.disconnect("Bob", "Dave")
        world.radio.connect("me", "Bob")
        #expect(await waitUntil(.seconds(6)) { world.store.messages(in: channel).first { $0.id == sent.id }?.delivery == .delivered })
        #expect(await waitUntil { world.store.envelopes.outgoing.isEmpty })
    }
}

@Suite("Chat store: verification")
@MainActor
struct ChatStoreVerificationTests {
    private func makeVerifyingStore(_ blob: InMemoryBlobStore = InMemoryBlobStore()) -> (ChatStore, InMemoryBlobStore) {
        let mesh = MeshNode(identity: .generate(), nickname: "me", link: InMemoryRadio().makeLink("me"))
        let store = ChatStore(mesh: mesh, locationChannels: NoLocationChannels(), locationProvider: NoLocation(),
                              settings: InMemorySettingsStore(), appState: blob)
        return (store, blob)
    }

    @Test func markAndClear() {
        let (store, _) = makeVerifyingStore()
        let ana = IdentityKeys.generate().fingerprint
        #expect(!store.isVerified(ana))
        store.markVerified(ana, nickname: " Ana\n")
        #expect(store.isVerified(ana))
        #expect(store.verified[ana] == "Ana")
        store.clearVerification(ana)
        #expect(!store.isVerified(ana))
    }

    @Test func verificationSurvivesARestart() {
        let blob = InMemoryBlobStore()
        let ana = IdentityKeys.generate().fingerprint
        makeVerifyingStore(blob).0.markVerified(ana, nickname: "Ana")
        #expect(makeVerifyingStore(blob).0.isVerified(ana))
    }

    @Test func impostorsUseAVerifiedNameWithAnotherKey() async {
        let world = World()
        let real = world.phone("Ana")
        let fake = world.phone("ana") // same name, different key
        world.radio.connect("me", "Ana")
        await world.store.start()
        await real.start()
        #expect(await waitUntil { world.peer(named: "Ana") != nil })
        world.store.markVerified(real.identity.fingerprint, nickname: "Ana")
        #expect(world.store.impostors.isEmpty)

        world.radio.connect("me", "ana")
        await fake.start()
        #expect(await waitUntil { world.store.impostors.contains { $0.fingerprint == fake.identity.fingerprint } })
        #expect(!world.store.impostors.contains { $0.fingerprint == real.identity.fingerprint })
    }
}
