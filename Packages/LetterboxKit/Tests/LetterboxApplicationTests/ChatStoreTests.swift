import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxApplication

// MARK: - Fakes for the ports

private actor FakeMesh: MeshTransport {
    nonisolated let events: AsyncStream<MeshEvent>
    nonisolated let continuation: AsyncStream<MeshEvent>.Continuation
    nonisolated let myFingerprint = Fingerprint(hex: String(repeating: "a", count: 64))
    private(set) var publicSent: [String] = []
    private(set) var privateSent: [(String, Fingerprint)] = []
    private(set) var readReceipts: [[String]] = []
    private(set) var nickname = ""
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init() {
        (events, continuation) = AsyncStream.makeStream(of: MeshEvent.self)
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func setNickname(_ nickname: String) { self.nickname = nickname }

    func sendPublic(_ text: String) -> ChatMessage {
        publicSent.append(text)
        return ChatMessage(id: UUID().uuidString, channel: .mesh, senderName: nickname, senderKey: myFingerprint.hex,
                           text: text, timestamp: Date(), isOwn: true, isVerified: true)
    }

    func sendPrivate(_ text: String, to recipient: Fingerprint) -> ChatMessage {
        privateSent.append((text, recipient))
        return ChatMessage(id: "dm-\(privateSent.count)", channel: .direct(recipient), senderName: nickname,
                           senderKey: myFingerprint.hex, text: text, timestamp: Date(), isOwn: true,
                           isVerified: true, delivery: .sent)
    }

    func markRead(messageIDs: [String], from sender: Fingerprint) {
        readReceipts.append(messageIDs)
    }

    private(set) var sealable: Set<Fingerprint> = []
    func canSeal(to recipient: Fingerprint) -> Bool { sealable.contains(recipient) }
    func setSealable(_ fingerprint: Fingerprint) { sealable.insert(fingerprint) }
}

private actor FakeLocationChannels: LocationChannelTransport {
    nonisolated let events: AsyncStream<LocationEvent>
    nonisolated let continuation: AsyncStream<LocationEvent>.Continuation
    private(set) var joined: String?
    private(set) var leaveCount = 0
    private(set) var sentNicknames: [String] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: LocationEvent.self)
    }

    func join(geohash: String) { joined = geohash }
    func leave() { joined = nil; leaveCount += 1 }

    func send(_ text: String, nickname: String) -> ChatMessage? {
        guard let joined else { return nil }
        sentNicknames.append(nickname)
        return ChatMessage(id: UUID().uuidString, channel: .location(geohash: joined), senderName: nickname,
                           senderKey: "me", text: text, timestamp: Date(), isOwn: true, isVerified: true)
    }
}

private struct FakeLocation: LocationProvider {
    var result: Result<Coordinate, LocationError>
    func currentCoordinate() async throws -> Coordinate { try result.get() }
}

private final class MemorySettings: SettingsStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func string(for key: String) -> String? { values[key] }
    func set(_ value: String?, for key: String) { values[key] = value }
}

private let bob = Peer(
    peerID: .random(), nickname: "bob", fingerprint: Fingerprint(hex: String(repeating: "b", count: 64)),
    isDirect: true, hasSecureSession: true, lastSeen: Date()
)

@MainActor
private func makeStore(
    location: Result<Coordinate, LocationError> = .success(Coordinate(latitude: 57.64911, longitude: 10.40744)),
    settings: MemorySettings = MemorySettings()
) -> (ChatStore, FakeMesh, FakeLocationChannels) {
    let mesh = FakeMesh()
    let channels = FakeLocationChannels()
    let store = ChatStore(mesh: mesh, locationChannels: channels, locationProvider: FakeLocation(result: location), settings: settings)
    return (store, mesh, channels)
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

// MARK: - Tests

@Suite("Composer commands")
struct ComposerInputTests {
    @Test func parsesCommands() {
        #expect(ComposerInput.parse("  hello ") == .text("hello"))
        #expect(ComposerInput.parse("/nick Ana Lee") == .nick("Ana Lee"))
        #expect(ComposerInput.parse("/msg @bob see you soon") == .directMessage(to: "bob", text: "see you soon"))
        #expect(ComposerInput.parse("/msg bob") == .unknown("/msg bob"))
        #expect(ComposerInput.parse("/WHO") == .who)
        #expect(ComposerInput.parse("/dance") == .unknown("/dance"))
        #expect(ComposerInput.parse("   ") == .empty)
    }
}

@Suite("Chat store")
@MainActor
struct ChatStoreTests {
    @Test func routesTextByChannel() async {
        let (store, mesh, channels) = makeStore()
        await store.start()

        await store.submit("hi everyone")
        #expect(await mesh.publicSent == ["hi everyone"])
        #expect(store.messages(in: .mesh).map(\.text) == ["hi everyone"])

        await store.joinLocation(.city)
        #expect(await channels.joined == "u4pru")
        #expect(store.selectedChannel == .location(geohash: "u4pru"))
        await store.submit("hi city")
        #expect(store.messages(in: .location(geohash: "u4pru")).map(\.text) == ["hi city"])
        #expect(await mesh.publicSent == ["hi everyone"])
    }

    @Test func msgCommandOpensADirectChannel() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.peersChanged([bob]))
        await settle()

        await store.submit("/msg bob are you near the station?")
        #expect(store.selectedChannel == .direct(bob.fingerprint))
        let sent = await mesh.privateSent
        #expect(sent.count == 1)
        #expect(sent.first?.1 == bob.fingerprint)
        #expect(store.title(for: .direct(bob.fingerprint)) == "@bob")
    }

    @Test func unknownRecipientGivesAHelpfulNotice() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await store.submit("/msg nobody hello")
        #expect(await mesh.privateSent.isEmpty)
        #expect(store.messages(in: .mesh).last?.text == "No one called nobody is nearby.")
    }

    @Test func deliveryStateOnlyMovesForward() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        store.openDirect(with: bob)
        await store.submit("ping")
        let id = "dm-1"

        mesh.continuation.yield(.deliveryChanged(messageID: id, state: .read))
        mesh.continuation.yield(.deliveryChanged(messageID: id, state: .delivered))
        mesh.continuation.yield(.deliveryChanged(messageID: id, state: .failed))
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .read)
    }

    @Test func incomingMessagesCountAsUnreadUntilOpened() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        let incoming = ChatMessage(id: "x1", channel: .direct(bob.fingerprint), senderName: "bob",
                                   senderKey: bob.fingerprint.hex, text: "hey", timestamp: Date(),
                                   isOwn: false, isVerified: true)
        mesh.continuation.yield(.privateMessage(incoming))
        await settle()
        #expect(store.unread[.direct(bob.fingerprint)] == 1)
        #expect(store.directChannels == [.direct(bob.fingerprint)])

        store.selectedChannel = .direct(bob.fingerprint)
        await settle()
        #expect(store.unread[.direct(bob.fingerprint)] == nil)
        #expect(await mesh.readReceipts.contains(["x1"]))
    }

    @Test func locationDeniedShowsAnError() async {
        let (store, _, channels) = makeStore(location: .failure(.denied))
        await store.joinLocation(.block)
        #expect(store.locationError != nil)
        #expect(await channels.joined == nil)
    }

    @Test func nicknamePersists() async {
        let settings = MemorySettings()
        let store = ChatStore(mesh: FakeMesh(), locationChannels: FakeLocationChannels(),
                              locationProvider: FakeLocation(result: .failure(.unavailable)), settings: settings)
        await store.setNickname("  ana  ")
        #expect(store.nickname == "ana")
        #expect(settings.values["nickname"] == "ana")
    }
}

// MARK: - More fixtures

private let carol = Peer(
    peerID: .random(), nickname: "Carol", fingerprint: Fingerprint(hex: String(repeating: "c", count: 64)),
    isDirect: false, hasSecureSession: false, lastSeen: Date()
)

private func incoming(
    _ id: String,
    _ text: String = "hi",
    in channel: ChannelID = .mesh,
    from sender: String = "bob",
    key: String = String(repeating: "b", count: 64)
) -> ChatMessage {
    ChatMessage(id: id, channel: channel, senderName: sender, senderKey: key, text: text, timestamp: Date(),
                isOwn: false, isVerified: true)
}

@Suite("Composer command parsing")
struct ComposerParsingTests {
    @Test(arguments: [
        ("/m bob hi", ComposerInput.directMessage(to: "bob", text: "hi")),
        ("/MSG Bob  hi  there ", .directMessage(to: "Bob", text: "hi  there")),
        ("/msg @bob    spaced", .directMessage(to: "bob", text: "spaced")),
        ("/w", .who),
        ("/?", .help),
        ("/HELP", .help),
        ("/clear", .clear),
        ("/clear now", .clear),
        ("/NICK  Ana", .nick("Ana")),
        ("/nick", .unknown("/nick")),
        ("/msg", .unknown("/msg")),
        ("/", .unknown("/")),
        ("/hide", .unknown("/hide")),
        ("hello /nick ana", .text("hello /nick ana")),
        ("\n\t hi \n", .text("hi")),
        ("", .empty),
    ])
    func parses(raw: String, expected: ComposerInput) {
        #expect(ComposerInput.parse(raw) == expected)
    }

    @Test func helpMentionsEveryCommandAndNoJargon() {
        for command in ["/nick", "/msg", "/who", "/clear", "/help"] {
            #expect(ComposerInput.helpText.contains(command))
        }
        #expect(!ComposerInput.helpText.contains("mesh"))
    }
}

@Suite("Chat store: privacy mode")
@MainActor
struct ChatStorePrivacyTests {
    @Test func startsVisibleByDefault() {
        let (store, _, _) = makeStore()
        #expect(store.hidesMessages == false)
    }

    @Test func toggleFlipsAndPersists() {
        let settings = MemorySettings()
        let (store, _, _) = makeStore(settings: settings)
        store.toggleHidesMessages()
        #expect(store.hidesMessages)
        #expect(settings.values[ChatStore.hideMessagesKey] == "1")
        store.toggleHidesMessages()
        #expect(!store.hidesMessages)
        #expect(settings.values[ChatStore.hideMessagesKey] == "0")
    }

    @Test func choiceIsRestoredOnNextLaunch() {
        let settings = MemorySettings()
        makeStore(settings: settings).0.setHidesMessages(true)
        #expect(makeStore(settings: settings).0.hidesMessages)
        makeStore(settings: settings).0.setHidesMessages(false)
        #expect(!makeStore(settings: settings).0.hidesMessages)
    }

    @Test func unexpectedStoredValuesMeanVisible() {
        let settings = MemorySettings()
        settings.values[ChatStore.hideMessagesKey] = "yes"
        #expect(!makeStore(settings: settings).0.hidesMessages)
    }

    @Test func hidingDoesNotChangeMessagesOrDelivery() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.publicMessage(incoming("p1", "secret plans")))
        await settle()
        store.setHidesMessages(true)
        // Hiding is purely visual: the text is still there for when you tap to peek, and still arrives.
        #expect(store.messages(in: .mesh).map(\.text) == ["secret plans"])
        await store.submit("still sending")
        #expect(await mesh.publicSent == ["still sending"])
    }

    @Test func settingTheSameValueTwiceIsHarmless() {
        let (store, _, _) = makeStore()
        store.setHidesMessages(true)
        store.setHidesMessages(true)
        #expect(store.hidesMessages)
    }
}

@Suite("Chat store: channels and titles")
@MainActor
struct ChatStoreChannelTests {
    @Test func nearbyChannelIsCalledNearby() {
        let (store, _, _) = makeStore()
        #expect(store.title(for: .mesh) == "#nearby")
        #expect(store.selectedChannel == .mesh)
    }

    @Test func titlesForLocationAndDirectChannels() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        #expect(store.title(for: .location(geohash: "u4pru")) == "#u4pru")
        // Unknown person: fall back to the short fingerprint.
        #expect(store.title(for: .direct(carol.fingerprint)) == "@" + carol.fingerprint.short)
        mesh.continuation.yield(.peersChanged([carol]))
        await settle()
        #expect(store.title(for: .direct(carol.fingerprint)) == "@Carol")
    }

    @Test func directContactKeepsLastKnownNameAfterLeaving() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.peersChanged([bob]))
        await settle()
        store.openDirect(with: bob)
        var renamed = bob
        renamed.nickname = "robert"
        mesh.continuation.yield(.peersChanged([renamed]))
        await settle()
        mesh.continuation.yield(.peersChanged([]))
        await settle()
        #expect(store.title(for: .direct(bob.fingerprint)) == "@robert")
        #expect(store.directChannels == [.direct(bob.fingerprint)])
    }

    @Test func directChannelsAreListedInAStableOrder() async {
        let (store, _, _) = makeStore()
        store.openDirect(with: carol)
        store.openDirect(with: bob)
        #expect(store.directChannels == [.direct(bob.fingerprint), .direct(carol.fingerprint)])
    }

    @Test func peerLookupByFingerprint() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.peersChanged([bob, carol]))
        await settle()
        #expect(store.peer(for: carol.fingerprint)?.nickname == "Carol")
        #expect(store.peer(for: Fingerprint(hex: String(repeating: "e", count: 64))) == nil)
    }
}

@Suite("Chat store: commands")
@MainActor
struct ChatStoreCommandTests {
    @Test func whoListsPeopleOrSaysNoneAreNearby() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await store.submit("/who")
        #expect(store.messages(in: .mesh).last?.text == "No one nearby yet.")
        mesh.continuation.yield(.peersChanged([bob, carol]))
        await settle()
        await store.submit("/who")
        #expect(store.messages(in: .mesh).last?.text == "Nearby: bob, Carol")
    }

    @Test func helpAndUnknownCommandsPostLocalNotices() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await store.submit("/help")
        await store.submit("/dance")
        let notices = store.messages(in: .mesh)
        #expect(notices.map(\.text) == [ComposerInput.helpText, "Unknown command /dance. Type /help."])
        #expect(notices.allSatisfy { $0.senderKey == "system" && $0.isOwn })
        #expect(await mesh.publicSent.isEmpty) // never sent over the air
        #expect(store.unread.isEmpty)
    }

    @Test func clearOnlyEmptiesTheCurrentConversation() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.publicMessage(incoming("p1")))
        mesh.continuation.yield(.privateMessage(incoming("d1", in: .direct(bob.fingerprint))))
        await settle()
        await store.submit("/clear")
        #expect(store.messages(in: .mesh).isEmpty)
        #expect(store.messages(in: .direct(bob.fingerprint)).count == 1)
    }

    @Test func msgMatchesNicknamesCaseInsensitively() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.peersChanged([carol]))
        await settle()
        await store.submit("/msg carol lunch?")
        #expect(store.selectedChannel == .direct(carol.fingerprint))
        #expect(await mesh.privateSent.first?.0 == "lunch?")
    }

    @Test func nickCommandRenamesAndTellsTheMesh() async {
        let settings = MemorySettings()
        let (store, mesh, _) = makeStore(settings: settings)
        await store.start()
        await store.submit("/nick  Zoë ")
        #expect(store.nickname == "Zoë")
        #expect(await mesh.nickname == "Zoë")
        #expect(settings.values["nickname"] == "Zoë")
    }

    @Test func blankInputDoesNothing() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await store.submit("   \n ")
        #expect(store.messages(in: .mesh).isEmpty)
        #expect(await mesh.publicSent.isEmpty)
    }
}

@Suite("Chat store: timelines and unread")
@MainActor
struct ChatStoreTimelineTests {
    @Test func duplicateMessagesAreShownOnce() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        for _ in 0..<3 { mesh.continuation.yield(.publicMessage(incoming("same"))) }
        await settle()
        #expect(store.messages(in: .mesh).count == 1)
    }

    @Test func timelinesKeepOnlyTheNewestThousand() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        for index in 0..<1005 { mesh.continuation.yield(.publicMessage(incoming("m\(index)", "\(index)"))) }
        for _ in 0..<200 where store.messages(in: .mesh).last?.text != "1004" { await settle() }
        let texts = store.messages(in: .mesh).map(\.text)
        #expect(texts.count == 1000)
        #expect(texts.first == "5")
        #expect(texts.last == "1004")
    }

    @Test func unreadCountsOnlyOtherPeoplesMessagesInOtherChannels() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.publicMessage(incoming("here"))) // current channel: not unread
        mesh.continuation.yield(.privateMessage(incoming("d1", in: .direct(bob.fingerprint))))
        mesh.continuation.yield(.privateMessage(incoming("d2", in: .direct(bob.fingerprint))))
        await settle()
        #expect(store.unread[.mesh] == nil)
        #expect(store.unread[.direct(bob.fingerprint)] == 2)

        store.openDirect(with: bob)
        await store.submit("my own reply")
        store.selectedChannel = .mesh
        await settle()
        #expect(store.unread[.direct(bob.fingerprint)] == nil) // opening cleared it; my reply didn't add to it
    }

    @Test func privateMessageInTheOpenConversationIsMarkedReadImmediately() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        store.openDirect(with: bob)
        await settle()
        mesh.continuation.yield(.privateMessage(incoming("live", in: .direct(bob.fingerprint))))
        await settle()
        #expect(await mesh.readReceipts.contains(["live"]))
        #expect(store.unread[.direct(bob.fingerprint)] == nil)
    }

    @Test func messagesFromSomeoneNewCreateAContact() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.privateMessage(incoming("d1", in: .direct(carol.fingerprint), from: "Carol")))
        await settle()
        #expect(store.directChannels == [.direct(carol.fingerprint)])
        #expect(store.title(for: .direct(carol.fingerprint)) == "@Carol")
    }
}

@Suite("Chat store: delivery states")
@MainActor
struct ChatStoreDeliveryTests {
    private func sendOne() async -> (ChatStore, FakeMesh) {
        let (store, mesh, _) = makeStore()
        await store.start()
        store.openDirect(with: bob)
        await store.submit("ping") // FakeMesh returns id "dm-1" in state .sent
        return (store, mesh)
    }

    private func delivery(_ store: ChatStore) -> DeliveryState? {
        store.messages(in: .direct(bob.fingerprint)).first?.delivery
    }

    @Test func advancesThroughTheNormalStates() async {
        let (store, mesh) = await sendOne()
        #expect(delivery(store) == .sent)
        mesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .delivered))
        await settle()
        #expect(delivery(store) == .delivered)
        mesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .read))
        await settle()
        #expect(delivery(store) == .read)
    }

    @Test func failureOnlyAppliesBeforeDelivery() async {
        let (store, mesh) = await sendOne()
        mesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .failed))
        await settle()
        #expect(delivery(store) == .failed)

        let (other, otherMesh) = await sendOne()
        otherMesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .delivered))
        otherMesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .failed))
        await settle()
        #expect(delivery(other) == .delivered)
    }

    @Test func aLateDeliveryStillRescuesAFailedMessage() async {
        let (store, mesh) = await sendOne()
        mesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .failed))
        mesh.continuation.yield(.deliveryChanged(messageID: "dm-1", state: .delivered))
        await settle()
        #expect(delivery(store) == .delivered)
    }

    @Test func updatesForUnknownMessagesTouchNothing() async {
        let (store, mesh) = await sendOne()
        mesh.continuation.yield(.deliveryChanged(messageID: "someone-else", state: .read))
        await settle()
        #expect(delivery(store) == .sent)
    }

    @Test func publicMessagesNeverGetDeliveryStates() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.publicMessage(incoming("p1")))
        await settle()
        mesh.continuation.yield(.deliveryChanged(messageID: "p1", state: .read))
        await settle()
        #expect(store.messages(in: .mesh).first?.delivery == nil)
    }
}

@Suite("Chat store: location channels")
@MainActor
struct ChatStoreLocationTests {
    @Test(arguments: GeohashLevel.allCases)
    func joiningUsesTheLevelsPrecision(level: GeohashLevel) async {
        let (store, _, channels) = makeStore()
        await store.joinLocation(level)
        let joined = await channels.joined
        #expect(joined?.count == level.precision)
        #expect(store.location?.level == level)
        #expect(store.selectedChannel == .location(geohash: joined ?? ""))
        #expect(store.locationError == nil)
    }

    @Test func unavailableLocationExplainsWhatToTry() async {
        let (store, _, channels) = makeStore(location: .failure(.unavailable))
        await store.joinLocation(.city)
        #expect(store.locationError?.contains("Try again") == true)
        #expect(store.location == nil)
        #expect(await channels.joined == nil)
        #expect(store.selectedChannel == .mesh)
    }

    @Test func aSuccessfulJoinClearsAnOldError() async {
        let settings = MemorySettings()
        let (failing, _, _) = makeStore(location: .failure(.denied), settings: settings)
        await failing.joinLocation(.city)
        #expect(failing.locationError != nil)
        let (store, _, _) = makeStore(settings: settings)
        await store.joinLocation(.city)
        #expect(store.locationError == nil)
    }

    @Test func leavingReturnsToNearby() async {
        let (store, _, channels) = makeStore()
        await store.joinLocation(.city)
        await store.leaveLocation()
        #expect(store.selectedChannel == .mesh)
        #expect(store.location == nil)
        #expect(await channels.joined == nil)
    }

    @Test func leavingWhileInADirectChatStaysThere() async {
        let (store, _, _) = makeStore()
        await store.joinLocation(.city)
        store.openDirect(with: bob)
        await store.leaveLocation()
        #expect(store.selectedChannel == .direct(bob.fingerprint))
    }

    @Test func sendingWithoutAConnectedChannelSaysSo() async {
        let (store, _, _) = makeStore()
        store.selectedChannel = .location(geohash: "u4pru") // selected but never joined
        await store.submit("anyone here?")
        #expect(store.messages(in: .location(geohash: "u4pru")).last?.text == "Not connected to a location channel.")
    }

    @Test func locationPostsUseTheCurrentNickname() async {
        let (store, _, channels) = makeStore()
        await store.setNickname("ana")
        await store.joinLocation(.city)
        await store.submit("hi city")
        #expect(await channels.sentNicknames == ["ana"])
    }

    @Test func relayStatusAndIncomingPostsAreApplied() async {
        let (store, _, channels) = makeStore()
        await store.start()
        await store.joinLocation(.city)
        channels.continuation.yield(.relaysChanged(connected: 3, total: 4))
        channels.continuation.yield(.message(incoming("n1", "hello from the city", in: .location(geohash: "u4pru"), from: "ana#1a2b")))
        await settle()
        #expect(store.relays.connected == 3 && store.relays.total == 4)
        #expect(store.messages(in: .location(geohash: "u4pru")).map(\.text) == ["hello from the city"])
    }
}

@Suite("Chat store: lifecycle and identity")
@MainActor
struct ChatStoreLifecycleTests {
    @Test func firstLaunchPicksAndSavesARandomNickname() {
        let settings = MemorySettings()
        let (store, _, _) = makeStore(settings: settings)
        #expect(store.nickname.hasPrefix("anon"))
        #expect(settings.values["nickname"] == store.nickname)
        #expect(makeStore(settings: settings).0.nickname == store.nickname)
    }

    @Test func savedNicknameIsSanitizedOnLoad() {
        let settings = MemorySettings()
        settings.values["nickname"] = "  ana\n"
        #expect(makeStore(settings: settings).0.nickname == "ana")
        settings.values["nickname"] = " \n "
        #expect(makeStore(settings: settings).0.nickname.hasPrefix("anon"))
    }

    @Test func blankNicknamesAreIgnored() async {
        let (store, _, _) = makeStore()
        let before = store.nickname
        await store.setNickname("  \n")
        #expect(store.nickname == before)
    }

    @Test func startTellsTheMeshOurNameAndOnlyStartsOnce() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await store.start()
        #expect(await mesh.startCount == 1)
        #expect(await mesh.nickname == store.nickname)
        #expect(store.myFingerprint == mesh.myFingerprint)
    }

    @Test func stopShutsTransportsDownAndCanStartAgain() async {
        let (store, mesh, channels) = makeStore()
        await store.start()
        await store.stop()
        #expect(await mesh.stopCount == 1)
        #expect(await channels.leaveCount == 1)
        await store.start()
        #expect(await mesh.startCount == 2)
    }

    @Test func radioStateIsApplied() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        #expect(store.radio == .unknown)
        mesh.continuation.yield(.radioChanged(.poweredOff))
        await settle()
        #expect(store.radio == .poweredOff)
    }
}

@Suite("Chat store: restored and carried messages")
@MainActor
struct ChatStoreRestoredTests {
    private func restored(_ id: String, to fingerprint: Fingerprint, delivery: DeliveryState = .queued) -> ChatMessage {
        ChatMessage(id: id, channel: .direct(fingerprint), senderName: "me", senderKey: "me", text: "from before",
                    timestamp: Date(), isOwn: true, isVerified: true, delivery: delivery)
    }

    @Test func restoredMessagesReappearInTheirConversation() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.outgoingRestored(restored("r1", to: carol.fingerprint), recipientName: "Carol"))
        await settle()
        #expect(store.messages(in: .direct(carol.fingerprint)).map(\.id) == ["r1"])
        #expect(store.directChannels == [.direct(carol.fingerprint)])
        #expect(store.title(for: .direct(carol.fingerprint)) == "@Carol")
        #expect(store.unread.isEmpty) // our own messages never count as unread
    }

    @Test func restoredMessagesKeepTheirStateAndAdvance() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.outgoingRestored(restored("r1", to: bob.fingerprint, delivery: .inEnvelope), recipientName: "bob"))
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .inEnvelope)
        mesh.continuation.yield(.deliveryChanged(messageID: "r1", state: .delivered))
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .delivered)
    }

    @Test func carriedSitsBetweenQueuedAndSent() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.outgoingRestored(restored("r1", to: bob.fingerprint), recipientName: "bob"))
        await settle()
        mesh.continuation.yield(.deliveryChanged(messageID: "r1", state: .inEnvelope))
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .inEnvelope)
        mesh.continuation.yield(.deliveryChanged(messageID: "r1", state: .queued)) // never backwards
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .inEnvelope)
        mesh.continuation.yield(.deliveryChanged(messageID: "r1", state: .sent)) // met in person later
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .sent)
    }

    @Test func aCarriedMessageCanStillFail() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.outgoingRestored(restored("r1", to: bob.fingerprint, delivery: .inEnvelope), recipientName: "bob"))
        mesh.continuation.yield(.deliveryChanged(messageID: "r1", state: .failed))
        await settle()
        #expect(store.messages(in: .direct(bob.fingerprint)).first?.delivery == .failed)
    }

    @Test func aRestoredContactKeepsANameWeAlreadyKnow() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        store.openDirect(with: bob)
        mesh.continuation.yield(.outgoingRestored(restored("r1", to: bob.fingerprint), recipientName: "old name"))
        await settle()
        #expect(store.title(for: .direct(bob.fingerprint)) == "@bob")
    }
}

// MARK: - Connections, permissions and envelopes

private final class FakeConnectivity: ConnectivityMonitor, @unchecked Sendable {
    let updates: AsyncStream<SystemConnectivity>
    let continuation: AsyncStream<SystemConnectivity>.Continuation
    private(set) var startCount = 0
    init() { (updates, continuation) = AsyncStream.makeStream(of: SystemConnectivity.self) }
    func start() { startCount += 1 }
}

private let offlineEverywhere = SystemConnectivity(internet: InternetStatus(path: .offline), cellular: .noService,
                                                   canSendTexts: true, location: .notDetermined)

@Suite("Connection report")
struct ConnectionReportTests {
    private func rows(
        system: SystemConnectivity = offlineEverywhere, radio: RadioState = .ready,
        permissions: TransportPermissions = TransportPermissions(), nearby: Int = 0,
        relays: (Int, Int) = (0, 0), inChannel: Bool = false, envelopes: EnvelopeSummary = .empty
    ) -> [ConnectionKind: ConnectionStatus] {
        Dictionary(uniqueKeysWithValues: ConnectionReport.rows(
            system: system, radio: radio, permissions: permissions, nearby: nearby,
            relays: relays, inLocationChannel: inChannel, envelopes: envelopes
        ).map { ($0.kind, $0.status) })
    }

    @Test func listsEveryWayOfCommunicatingOnceInOrder() {
        let all = ConnectionReport.rows(system: .unknown, radio: .unknown, permissions: TransportPermissions(), nearby: 0,
                                        relays: (0, 0), inLocationChannel: false, envelopes: .empty)
        #expect(all.map(\.kind) == ConnectionKind.allCases)
        #expect(all.allSatisfy { !$0.title.isEmpty && !$0.enables.isEmpty && !$0.status.detail.isEmpty })
    }

    @Test func bluetoothStates() {
        #expect(rows(nearby: 3)[.bluetooth] == .working("On. 3 people nearby"))
        #expect(rows(nearby: 1)[.bluetooth] == .working("On. 1 person nearby"))
        #expect(rows()[.bluetooth] == .working("On. No one in range yet"))
        #expect(rows(radio: .poweredOff)[.bluetooth]?.detail.contains("Control Center") == true)
        guard case .notAllowed = rows(radio: .unauthorized)[.bluetooth] else { Issue.record("unauthorized"); return }
        guard case .unavailable = rows(radio: .unsupported)[.bluetooth] else { Issue.record("unsupported"); return }
        guard case .checking = rows(radio: .unknown)[.bluetooth] else { Issue.record("unknown"); return }
        // The user's choice wins over whatever the radio says.
        guard case .blockedByYou = rows(radio: .ready, permissions: TransportPermissions(bluetooth: false))[.bluetooth] else {
            Issue.record("blocked"); return
        }
    }

    @Test func internetAndWiFiStates() {
        func with(_ path: InternetPath, constrained: Bool = false) -> SystemConnectivity {
            var system = offlineEverywhere
            system.internet = InternetStatus(path: path, isConstrained: constrained)
            return system
        }
        #expect(rows(system: with(.wifi))[.internet] == .working("Connected via Wi-Fi"))
        #expect(rows(system: with(.cellular, constrained: true))[.internet] == .working("Connected via mobile data (Low Data Mode)"))
        #expect(rows(system: with(.wired))[.internet] == .working("Connected via cable"))
        #expect(rows(system: with(.offline))[.internet] == .off("No internet connection"))
        guard case .checking = rows(system: .unknown)[.internet] else { Issue.record("unknown"); return }
        guard case .blockedByYou = rows(system: with(.wifi), permissions: TransportPermissions(internet: false))[.internet] else {
            Issue.record("blocked"); return
        }
        #expect(rows(system: with(.wifi))[.wifi] == .working("Connected"))
        #expect(rows(system: with(.cellular))[.wifi] == .off("Not connected to Wi-Fi"))
    }

    @Test func mobileStates() {
        func with(_ cellular: CellularStatus, texts: Bool? = true) -> SystemConnectivity {
            var system = offlineEverywhere
            system.cellular = cellular
            system.canSendTexts = texts
            return system
        }
        #expect(rows(system: with(.connected(radio: "5G")))[.mobile] == .working("Signal (5G). Can send texts"))
        #expect(rows(system: with(.connected(radio: "LTE"), texts: false))[.mobile] == .working("Signal (LTE)"))
        #expect(rows(system: with(.noService))[.mobile] == .off("No mobile signal"))
        #expect(rows(system: with(.unsupported))[.mobile] == .unavailable("Not available on this device"))
    }

    @Test func satelliteIsHonestlyUndetectable() {
        guard case let .notDetectable(text) = rows()[.satellite] else { Issue.record("satellite"); return }
        #expect(text.contains("Apps can't check this"))
    }

    @Test func locationStates() {
        func with(_ access: LocationAccess) -> SystemConnectivity {
            var system = offlineEverywhere
            system.location = access
            return system
        }
        #expect(rows(system: with(.allowed))[.location] == .working("Allowed"))
        guard case .notAllowed = rows(system: with(.denied))[.location] else { Issue.record("denied"); return }
        guard case .notAllowed = rows(system: with(.restricted))[.location] else { Issue.record("restricted"); return }
        guard case .off = rows(system: with(.notDetermined))[.location] else { Issue.record("not asked"); return }
    }

    @Test func relayStates() {
        guard case .off = rows()[.relays] else { Issue.record("not in a channel"); return }
        guard case .checking = rows(inChannel: true)[.relays] else { Issue.record("connecting"); return }
        #expect(rows(relays: (2, 4), inChannel: true)[.relays] == .working("2 of 4 connected"))
        guard case .off = rows(relays: (0, 4), inChannel: true)[.relays] else { Issue.record("none connected"); return }
        guard case .blockedByYou = rows(permissions: TransportPermissions(internet: false), relays: (2, 4), inChannel: true)[.relays] else {
            Issue.record("blocked"); return
        }
    }

    @Test func envelopeStates() {
        let fingerprint = Fingerprint(hex: String(repeating: "a", count: 64))
        let one = OutgoingEnvelope(messageID: "m", recipient: fingerprint, carriers: 2, expires: Date())
        #expect(rows()[.envelopes] == .working("None right now"))
        #expect(rows(envelopes: EnvelopeSummary(outgoing: [one], carryingForOthers: 5))[.envelopes]
                == .working("1 of yours on its way, carrying 5 for others"))
        #expect(rows(envelopes: EnvelopeSummary(outgoing: [one, one], carryingForOthers: 0))[.envelopes]
                == .working("2 of yours on their way, carrying 0 for others"))
        guard case .blockedByYou = rows(permissions: TransportPermissions(bluetooth: false))[.envelopes] else {
            Issue.record("blocked"); return
        }
    }
}

@Suite("Chat store: permissions and connections")
@MainActor
struct ChatStorePermissionTests {
    @Test func bothAllowedByDefault() {
        let (store, _, _) = makeStore()
        #expect(store.permissions == TransportPermissions(bluetooth: true, internet: true))
    }

    @Test func choicesAreSavedAndRestored() async {
        let settings = MemorySettings()
        let (store, _, _) = makeStore(settings: settings)
        await store.setBluetoothAllowed(false)
        await store.setInternetAllowed(false)
        #expect(settings.values[ChatStore.bluetoothKey] == "0")
        #expect(settings.values[ChatStore.internetKey] == "0")
        #expect(makeStore(settings: settings).0.permissions == TransportPermissions(bluetooth: false, internet: false))
        await store.setBluetoothAllowed(true)
        #expect(makeStore(settings: settings).0.permissions.bluetooth)
    }

    @Test func turningBluetoothOffStopsTheMeshAndOnStartsItAgain() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        mesh.continuation.yield(.peersChanged([bob]))
        await settle()
        await store.setBluetoothAllowed(false)
        #expect(await mesh.stopCount == 1)
        #expect(store.peers.isEmpty)
        await store.setBluetoothAllowed(true)
        #expect(await mesh.startCount == 2)
        await store.setBluetoothAllowed(true) // no change, no extra start
        #expect(await mesh.startCount == 2)
    }

    @Test func startRespectsBluetoothBeingOff() async {
        let settings = MemorySettings()
        settings.values[ChatStore.bluetoothKey] = "0"
        let (store, mesh, _) = makeStore(settings: settings)
        await store.start()
        #expect(await mesh.startCount == 0)
    }

    @Test func nearbyChatExplainsWhenBluetoothIsOff() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await store.setBluetoothAllowed(false)
        await store.submit("anyone?")
        #expect(await mesh.publicSent.isEmpty)
        #expect(store.messages(in: .mesh).last?.text.contains("Bluetooth is off in Letterbox") == true)
    }

    @Test func privateMessagesQueueWithANoticeWhenBluetoothIsOff() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        await mesh.setSealable(bob.fingerprint)
        store.openDirect(with: bob)
        await store.setBluetoothAllowed(false)
        await store.submit("later")
        #expect(await mesh.privateSent.count == 1) // queued in the engine
        #expect(store.messages(in: .direct(bob.fingerprint)).last?.text.contains("Bluetooth is off") == true)
    }

    @Test func aStrangerCantBeReachedWithEverythingOff() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        store.openDirect(with: carol)
        await store.setBluetoothAllowed(false)
        await store.setInternetAllowed(false)
        await store.submit("hello?")
        #expect(await mesh.privateSent.isEmpty)
        #expect(store.messages(in: .direct(carol.fingerprint)).last?.text.contains("both off") == true)
    }

    @Test func turningInternetOffLeavesAndBlocksLocationChannels() async {
        let (store, _, channels) = makeStore()
        await store.start()
        await store.joinLocation(.city)
        #expect(await channels.joined != nil)
        await store.setInternetAllowed(false)
        #expect(await channels.joined == nil)
        #expect(store.selectedChannel == .mesh)
        await store.joinLocation(.city)
        #expect(await channels.joined == nil)
        #expect(store.locationError?.contains("internet is off") == true)
    }

    @Test func connectivityReadingsFlowIntoTheRows() async {
        let monitor = FakeConnectivity()
        let mesh = FakeMesh()
        let store = ChatStore(mesh: mesh, locationChannels: FakeLocationChannels(),
                              locationProvider: FakeLocation(result: .failure(.unavailable)),
                              settings: MemorySettings(), connectivity: monitor)
        await store.start()
        #expect(monitor.startCount == 1)
        monitor.continuation.yield(SystemConnectivity(internet: InternetStatus(path: .wifi), cellular: .connected(radio: "5G"),
                                                      canSendTexts: true, location: .allowed))
        await settle()
        let rows = Dictionary(uniqueKeysWithValues: store.connectionRows.map { ($0.kind, $0.status) })
        #expect(rows[.internet] == .working("Connected via Wi-Fi"))
        #expect(rows[.mobile] == .working("Signal (5G). Can send texts"))
        #expect(rows[.location] == .working("Allowed"))
    }

    @Test func envelopeSummariesAreApplied() async {
        let (store, mesh, _) = makeStore()
        await store.start()
        let summary = EnvelopeSummary(outgoing: [OutgoingEnvelope(messageID: "m1", recipient: bob.fingerprint, carriers: 3,
                                                                  expires: Date().addingTimeInterval(3600))],
                                      carryingForOthers: 4)
        mesh.continuation.yield(.envelopesChanged(summary))
        await settle()
        #expect(store.envelopes == summary)
        #expect(store.envelopes.carriers(for: "m1") == 3)
    }
}
