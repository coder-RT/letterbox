#if DEBUG
import Foundation
import LetterboxApplication
import LetterboxCrypto
import LetterboxDomain
import LetterboxMesh
import LetterboxTestSupport

/// The app's world when launched by UI tests (`-ui-testing`): the real store and the
/// real mesh engine, but on a simulated radio with simulated phones, in-memory storage
/// and a scripted connectivity reading. Every run starts clean.
///
/// Environment:
/// - `UITEST_CONNECTIVITY`: `wifi` (default), `offline`, `cellular5G`
/// - `UITEST_SCENARIO`:
///   - `nearby` (default): Sam is in range and answers.
///   - `envelope`: Dave is in range for a few seconds and then leaves; later Bob, a
///     courier, walks past and stays.
@MainActor
final class UITestWorld {
    let store: ChatStore
    private let radio = InMemoryRadio()
    private let scenario: String
    private var phones: [SimulatedPhone] = []
    private var script: Task<Void, Never>?

    init(environment: [String: String]) {
        scenario = environment["UITEST_SCENARIO"] ?? "nearby"
        var config = MeshNode.Configuration()
        config.relayJitter = 0...0
        config.announceInterval = 1
        config.maintenanceInterval = 0.25
        config.peerTimeout = 3
        config.courierDelay = 1
        let me = MeshNode(identity: .generate(), nickname: "", link: radio.makeLink("me"), configuration: config)
        store = ChatStore(
            mesh: me,
            locationChannels: OfflineLocationChannels(),
            locationProvider: NoLocationProvider(),
            settings: InMemorySettingsStore(),
            connectivity: ScriptedConnectivityMonitor(ScriptedConnectivityMonitor.named(environment["UITEST_CONNECTIVITY"])),
            appState: InMemoryBlobStore()
        )
        switch scenario {
        case "envelope":
            phones = [
                SimulatedPhone(name: "Dave", radio: radio, configuration: config, replyToPrivate: false),
                SimulatedPhone(name: "Bob", radio: radio, configuration: config, replyToPrivate: false),
            ]
        default:
            phones = [SimulatedPhone(name: "Sam", radio: radio, configuration: config, replyToPrivate: true, replyToPublic: true)]
        }
    }

    func start() async {
        await store.setNickname("Me")
        for phone in phones { await phone.start() }
        switch scenario {
        case "envelope":
            radio.connect("me", "Dave")
            let radio = radio
            script = Task {
                try? await Task.sleep(for: .seconds(8))
                radio.disconnect("me", "Dave")   // Dave walks off; forgotten ~3 s later
                try? await Task.sleep(for: .seconds(14))
                radio.connect("me", "Bob")       // a courier walks past and stays
            }
        default:
            radio.connect("me", "Sam")
        }
    }
}

private actor OfflineLocationChannels: LocationChannelTransport {
    nonisolated let events = AsyncStream<LocationEvent> { _ in }
    func join(geohash: String) {}
    func leave() {}
    func send(_ text: String, nickname: String) -> ChatMessage? { nil }
}

private struct NoLocationProvider: LocationProvider {
    func currentCoordinate() async throws -> Coordinate { throw LocationError.unavailable }
}
#endif
