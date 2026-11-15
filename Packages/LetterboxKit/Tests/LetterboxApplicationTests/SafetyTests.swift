import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxApplication
import LetterboxTestSupport

// Guideline 1.2 safety features: the word filter, reporting, and a build without
// location channels.

@Suite("Word filter")
struct ContentFilterTests {
    @Test func masksOffensiveWordsKeepingTheFirstLetter() {
        #expect(ContentFilter.mask("you shit") == "you s***")
        #expect(ContentFilter.mask("What the FUCK, mate") == "What the F***, mate")
        #expect(ContentFilter.mask("fucking hell") == "f****** hell")
    }

    @Test func catchesDisguisedSpellings() {
        #expect(ContentFilter.containsOffensiveWords("sh1t"))
        #expect(ContentFilter.containsOffensiveWords("fuuuuck"))
        #expect(ContentFilter.containsOffensiveWords("b!tch"))
        #expect(ContentFilter.containsOffensiveWords("Fück"))
    }

    @Test func leavesOrdinaryWordsAlone() {
        let ordinary = [
            "Meet at the hut as soon as you can", "Scunthorpe", "assessment", "class", "passing",
            "niggle", "Fukushima", "shiitake", "cocktail", "Dickens", "therapist", "grass", "Essex",
            "Trail is icy past the bridge", "5 km to go, 3 hours left",
        ]
        for text in ordinary {
            #expect(ContentFilter.mask(text) == text, "\(text) should not be masked")
        }
    }

    @Test func keepsPunctuationAndEmoji() {
        #expect(ContentFilter.mask("shit! 🏔️ ok?") == "s***! 🏔️ ok?")
    }
}

@Suite("Reporting")
struct ReportTextTests {
    private let message = ChatMessage(id: "m1", channel: .mesh, senderName: "Mallory", senderKey: String(repeating: "c", count: 64),
                                      text: "something nasty", timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                                      isOwn: false, isVerified: true)

    @Test func emailHasTheMessageAndSenderButNothingAboutTheReporter() throws {
        let url = try #require(ReportText.mailURL(to: "safety@example.org", for: message, appVersion: "0.1.0"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto" && components.path == "safety@example.org")
        let body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("something nasty") && body.contains("Mallory") && body.contains(String(repeating: "c", count: 64)))
        #expect(body.contains("#nearby") && body.contains("Letterbox 0.1.0"))
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "Letterbox report: message from Mallory")
    }

    @Test func noAddressMeansNoEmail() {
        #expect(ReportText.mailURL(to: nil, for: message, appVersion: "1") == nil)
        #expect(ReportText.mailURL(to: "", for: message, appVersion: "1") == nil)
        #expect(ReportText.mailURL(to: "$(LETTERBOX_SUPPORT_EMAIL)", for: message, appVersion: "1") == nil, "Unset build setting")
        #expect(SupportContact.address(from: " help@example.org ") == "help@example.org")
        #expect(SupportContact.address(from: "not an email") == nil)
    }
}

private struct StillMesh: MeshTransport {
    let events = AsyncStream<MeshEvent> { _ in }
    let myFingerprint = Fingerprint(hex: String(repeating: "a", count: 64))
    func start() async {}
    func stop() async {}
    func setNickname(_ nickname: String) async {}
    func sendPublic(_ text: String) async -> ChatMessage {
        ChatMessage(id: UUID().uuidString, channel: .mesh, senderName: "me", senderKey: myFingerprint.hex, text: text,
                    timestamp: Date(), isOwn: true, isVerified: true)
    }
    func sendPrivate(_ text: String, to recipient: Fingerprint) async -> ChatMessage { await sendPublic(text) }
    func markRead(messageIDs: [String], from sender: Fingerprint) async {}
    func canSeal(to recipient: Fingerprint) async -> Bool { false }
}

private actor PushMesh: MeshTransport {
    nonisolated let events: AsyncStream<MeshEvent>
    nonisolated let continuation: AsyncStream<MeshEvent>.Continuation
    nonisolated let myFingerprint = Fingerprint(hex: String(repeating: "a", count: 64))
    init() { (events, continuation) = AsyncStream.makeStream(of: MeshEvent.self) }
    func start() {}
    func stop() {}
    func setNickname(_ nickname: String) {}
    func sendPublic(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, channel: .mesh, senderName: "me", senderKey: myFingerprint.hex, text: text,
                    timestamp: Date(), isOwn: true, isVerified: true)
    }
    func sendPrivate(_ text: String, to recipient: Fingerprint) -> ChatMessage { sendPublic(text) }
    func markRead(messageIDs: [String], from sender: Fingerprint) {}
    func canSeal(to recipient: Fingerprint) -> Bool { false }
}

private struct NoChannels: LocationChannelTransport {
    let events = AsyncStream<LocationEvent> { _ in }
    func join(geohash: String) async {}
    func leave() async {}
    func send(_ text: String, nickname: String) async -> ChatMessage? { nil }
}

private struct HereLocation: LocationProvider {
    func currentCoordinate() async throws -> Coordinate { Coordinate(latitude: 52.23, longitude: 21.01) }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@Suite("Safety in the store")
@MainActor
struct StoreSafetyTests {
    private let mallory = String(repeating: "d", count: 64)

    private func incoming(_ text: String, key: String, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(id: id, channel: .mesh, senderName: "Mallory", senderKey: key, text: text, timestamp: Date(),
                    isOwn: false, isVerified: key.count == 64)
    }

    @Test func filterIsOnByDefaultMasksOnScreenAndCanBeTurnedOff() async {
        let mesh = PushMesh()
        let settings = InMemorySettingsStore()
        let store = ChatStore(mesh: mesh, locationChannels: NoChannels(), locationProvider: HereLocation(), settings: settings)
        await store.start()
        let message = incoming("you shit", key: mallory)
        mesh.continuation.yield(.publicMessage(message))
        await settle()
        #expect(store.filtersOffensiveWords)
        #expect(store.messages(in: .mesh).first?.text == "you s***")
        #expect(store.original(store.messages(in: .mesh)[0]).text == "you shit", "A report carries the real words")

        store.setFiltersOffensiveWords(false)
        #expect(store.messages(in: .mesh).first?.text == "you shit")
        #expect(settings.string(for: ChatStore.filterKey) == "0")
    }

    @Test func reportingBlocksAKnownSenderOrHidesAnUnknownOne() async {
        let mesh = PushMesh()
        let store = ChatStore(mesh: mesh, locationChannels: NoChannels(), locationProvider: HereLocation(),
                              settings: InMemorySettingsStore(), appState: InMemoryBlobStore())
        await store.start()
        mesh.continuation.yield(.publicMessage(incoming("first", key: mallory, id: "a")))
        mesh.continuation.yield(.publicMessage(incoming("unsigned", key: "peer:0011223344556677", id: "b")))
        mesh.continuation.yield(.publicMessage(incoming("bystander", key: String(repeating: "e", count: 64), id: "c")))
        await settle()

        store.report(store.messages(in: .mesh).first { $0.id == "a" }!)
        #expect(store.isBlocked(Fingerprint(hex: mallory)))
        store.report(store.messages(in: .mesh).first { $0.id == "b" }!)
        #expect(store.messages(in: .mesh).map(\.id) == ["c"], "Unknown sender: just that message is hidden")
    }

    @Test func withoutLocationChannelsNothingAboutThemIsOfferedOrUsed() async {
        let store = ChatStore(mesh: StillMesh(), locationChannels: NoChannels(), locationProvider: HereLocation(),
                              settings: InMemorySettingsStore(), offersLocationChannels: false)
        await store.joinLocation(.city)
        #expect(store.location == nil && store.selectedChannel == .mesh)
        let kinds = store.connectionRows.map(\.kind)
        #expect(!kinds.contains(.location) && !kinds.contains(.relays))
        #expect(store.connectionRows.first { $0.kind == .internet }?.enables == "Nothing in Letterbox: it works without internet")
    }
}
