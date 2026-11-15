import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxApplication
import LetterboxTestSupport

// Lock-screen alerts, blocking, and erasing everything.

private actor QuietMesh: MeshTransport {
    nonisolated let events: AsyncStream<MeshEvent>
    nonisolated let continuation: AsyncStream<MeshEvent>.Continuation
    nonisolated let myFingerprint = Fingerprint(hex: String(repeating: "a", count: 64))
    private(set) var stopCount = 0

    init() { (events, continuation) = AsyncStream.makeStream(of: MeshEvent.self) }

    func start() {}
    func stop() { stopCount += 1 }
    func setNickname(_ nickname: String) {}
    func sendPublic(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, channel: .mesh, senderName: "me", senderKey: myFingerprint.hex,
                    text: text, timestamp: Date(), isOwn: true, isVerified: true)
    }
    func sendPrivate(_ text: String, to recipient: Fingerprint) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, channel: .direct(recipient), senderName: "me", senderKey: myFingerprint.hex,
                    text: text, timestamp: Date(), isOwn: true, isVerified: true, delivery: .sent)
    }
    func markRead(messageIDs: [String], from sender: Fingerprint) {}
    func canSeal(to recipient: Fingerprint) -> Bool { false }
}

private struct NoChannels: LocationChannelTransport {
    let events = AsyncStream<LocationEvent> { _ in }
    func join(geohash: String) async {}
    func leave() async {}
    func send(_ text: String, nickname: String) async -> ChatMessage? { nil }
}

private struct NowhereLocation: LocationProvider {
    func currentCoordinate() async throws -> Coordinate { throw LocationError.unavailable }
}

private final class Alerts: MessageNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _shown: [MessageAlert] = []
    private var _cleared: [String] = []
    private var _permissionAsks = 0
    private var _clearedAll = 0
    var shown: [MessageAlert] { lock.withLock { _shown } }
    var cleared: [String] { lock.withLock { _cleared } }
    var permissionAsks: Int { lock.withLock { _permissionAsks } }
    var clearedAll: Int { lock.withLock { _clearedAll } }
    func requestPermission() async { lock.withLock { _permissionAsks += 1 } }
    func show(_ alert: MessageAlert) { lock.withLock { _shown.append(alert) } }
    func clear(conversation: String) { lock.withLock { _cleared.append(conversation) } }
    func clearAll() { lock.withLock { _clearedAll += 1 } }
}

private final class Eraser: LocalDataEraser, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func eraseAll() { lock.withLock { _count += 1 } }
}

private let sam = Fingerprint(hex: String(repeating: "5", count: 64))

private func from(_ fingerprint: Fingerprint, _ text: String, in channel: ChannelID = .mesh, id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(id: id, channel: channel, senderName: "Sam", senderKey: fingerprint.hex, text: text,
                timestamp: Date(), isOwn: false, isVerified: true)
}

@MainActor
private struct Setup {
    let store: ChatStore
    let mesh = QuietMesh()
    let alerts = Alerts()
    let eraser = Eraser()
    let settings = InMemorySettingsStore()
    let blob: InMemoryBlobStore

    init(blob: InMemoryBlobStore = InMemoryBlobStore()) {
        self.blob = blob
        store = ChatStore(mesh: mesh, locationChannels: NoChannels(), locationProvider: NowhereLocation(), settings: settings,
                          appState: blob, notifier: alerts, eraser: eraser)
    }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@Suite("Lock-screen alerts")
@MainActor
struct AlertTests {
    @Test func noAlertWhileLetterboxIsOnScreen() async {
        let setup = Setup()
        await setup.store.start()
        setup.mesh.continuation.yield(.publicMessage(from(sam, "hi")))
        await settle()
        #expect(setup.alerts.shown.isEmpty)
    }

    @Test func alertsHideNameAndTextByDefault() async {
        let setup = Setup()
        await setup.store.start()
        setup.store.setActive(false) // phone locked in a pocket
        setup.mesh.continuation.yield(.publicMessage(from(sam, "meet at the hut")))
        setup.mesh.continuation.yield(.privateMessage(from(sam, "secret", in: .direct(sam))))
        setup.mesh.continuation.yield(.privateMessage(from(sam, "another", in: .direct(sam))))
        await settle()
        let shown = setup.alerts.shown
        #expect(shown.map(\.body) == ["New message in #nearby", "New private message", "2 new private messages"])
        #expect(shown.allSatisfy { $0.title == "Letterbox" && !$0.body.contains("Sam") && !$0.body.contains("secret") })
        #expect(shown[1].conversation == shown[2].conversation, "One alert per conversation, replaced")
    }

    @Test func namesAndTextOnlyWhenChosenAndNotWithThePrivacyScreen() async {
        let setup = Setup()
        await setup.store.start()
        setup.store.setActive(false)
        setup.store.setShowsTextInNotifications(true)
        setup.mesh.continuation.yield(.privateMessage(from(sam, "on my way", in: .direct(sam))))
        await settle()
        #expect(setup.alerts.shown.last == MessageAlert(conversation: "direct:\(sam.hex)", title: "Sam", body: "on my way"))

        setup.store.setHidesMessages(true)
        setup.mesh.continuation.yield(.publicMessage(from(sam, "visible?")))
        await settle()
        #expect(setup.alerts.shown.last?.body == "New message in #nearby")
        #expect(setup.settings.string(for: ChatStore.notificationTextKey) == "1", "The choice is remembered")
    }

    @Test func noAlertForOwnHistoryLocationOrDuplicateMessages() async {
        let setup = Setup()
        await setup.store.start()
        setup.store.setActive(false)
        setup.mesh.continuation.yield(.publicHistory(from(sam, "said an hour ago")))
        setup.mesh.continuation.yield(.publicMessage(from(sam, "once", id: "dup")))
        setup.mesh.continuation.yield(.publicMessage(from(sam, "once", id: "dup")))
        await settle()
        #expect(setup.alerts.shown.count == 1)
    }

    @Test func openingTheAppOrConversationClearsItsAlert() async {
        let setup = Setup()
        await setup.store.start()
        setup.store.setActive(false)
        setup.mesh.continuation.yield(.privateMessage(from(sam, "hello", in: .direct(sam))))
        await settle()
        setup.store.setActive(true)
        #expect(setup.alerts.cleared.contains("nearby"))
        setup.store.selectedChannel = .direct(sam)
        #expect(setup.alerts.cleared.contains("direct:\(sam.hex)"))
        // The count starts again after the conversation was looked at.
        setup.store.selectedChannel = .mesh
        setup.store.setActive(false)
        setup.mesh.continuation.yield(.privateMessage(from(sam, "again", in: .direct(sam))))
        await settle()
        #expect(setup.alerts.shown.last?.body == "New private message")
    }

    @Test func permissionIsAskedOnceWhenYouFirstSend() async {
        let setup = Setup()
        await setup.store.start()
        #expect(setup.alerts.permissionAsks == 0, "Not on launch")
        await setup.store.submit("hello")
        await setup.store.submit("again")
        #expect(setup.alerts.permissionAsks == 1)
    }
}

@Suite("Blocking")
@MainActor
struct BlockingTests {
    @Test func blockedPeopleAreHiddenEverywhereAndItSurvivesARestart() async {
        let blob = InMemoryBlobStore()
        let setup = Setup(blob: blob)
        await setup.store.start()
        setup.mesh.continuation.yield(.publicMessage(from(sam, "before")))
        await settle()
        setup.store.block(sam, nickname: "Sam")
        #expect(setup.store.messages(in: .mesh).isEmpty, "Earlier messages disappear too")

        setup.store.setActive(false)
        setup.mesh.continuation.yield(.publicMessage(from(sam, "spam")))
        setup.mesh.continuation.yield(.publicHistory(from(sam, "old spam")))
        setup.mesh.continuation.yield(.privateMessage(from(sam, "dm spam", in: .direct(sam))))
        await settle()
        #expect(setup.store.messages(in: .mesh).isEmpty)
        #expect(setup.store.messages(in: .direct(sam)).isEmpty)
        #expect(setup.alerts.shown.isEmpty)

        let again = Setup(blob: blob)
        #expect(again.store.isBlocked(sam))
        again.store.unblock(sam)
        #expect(!Setup(blob: blob).store.isBlocked(sam))
    }
}

@Suite("Erase everything")
@MainActor
struct EraseTests {
    @Test func erasingStopsTheMeshWipesStorageAndClearsTheScreen() async {
        let setup = Setup()
        await setup.store.start()
        setup.store.markVerified(sam, nickname: "Sam")
        setup.mesh.continuation.yield(.publicMessage(from(sam, "hello")))
        await settle()

        await setup.store.eraseEverything()
        #expect(await setup.mesh.stopCount == 1)
        #expect(setup.eraser.count == 1)
        #expect(setup.alerts.clearedAll == 1)
        #expect(setup.store.isErased)
        #expect(setup.store.messages(in: .mesh).isEmpty && setup.store.verified.isEmpty)

        // Nothing new is shown or saved afterwards.
        let savedBefore = setup.blob.load()
        setup.mesh.continuation.yield(.publicMessage(from(sam, "after")))
        await setup.store.submit("still there?")
        setup.store.block(sam, nickname: "Sam")
        await settle()
        #expect(setup.store.messages(in: .mesh).isEmpty)
        #expect(setup.blob.load() == savedBefore, "Nothing written after the wipe")
    }
}

@Suite("Notification wording")
struct NotificationTextTests {
    @Test func wording() {
        let nearby = from(sam, "Trail closed")
        #expect(NotificationText.alert(for: nearby, count: 1, showText: false).body == "New message in #nearby")
        #expect(NotificationText.alert(for: nearby, count: 3, showText: false).body == "3 new messages in #nearby")
        let shown = NotificationText.alert(for: nearby, count: 3, showText: true)
        #expect(shown.title == "Sam in #nearby" && shown.body == "Trail closed (+2 more)")
        #expect(NotificationText.conversation(.location(geohash: "u4pru")) == "location:u4pru")
    }
}
