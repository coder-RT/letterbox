import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxNostr

// DAST for the internet side: hostile relay traffic fed into a running relay pool and
// location channel. A relay is untrusted: it can send anything.

private actor Inbox {
    private(set) var messages: [ChatMessage] = []
    init(_ channel: NostrLocationChannel) {
        let stream = channel.events
        Task { [weak self] in
            for await event in stream { if case let .message(m) = event { await self?.add(m) } }
        }
    }
    private func add(_ message: ChatMessage) { messages.append(message) }
}

@Suite("Security DAST: hostile relay traffic", .timeLimit(.minutes(1)))
struct SecurityRelayFuzzTests {
    @Test func hostileRelayMessagesNeverCrashOrForgePosts() async throws {
        let pool = RelayPool(relays: [])
        let channel = NostrLocationChannel(seed: Data(repeating: 9, count: 32), pool: pool)
        let inbox = Inbox(channel)
        await channel.join(geohash: "u4pru")

        var rng = SystemRandomNumberGenerator()
        let valid = try NostrKeys.generate().sign(kind: NostrLocationChannel.kind, tags: [["g", "u4pru"]], content: "real post")
        let validJSON = String(data: try JSONEncoder().encode(valid), encoding: .utf8)!

        // 1. Random bytes and broken JSON.
        for _ in 0..<1500 {
            let bytes = Data((0..<Int.random(in: 0...400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            await pool.handle(bytes)
        }
        // 2. Structurally valid frames with hostile content.
        let hostile: [String] = [
            #"["EVENT","geo-u4pru",{"id":1,"pubkey":null}]"#,
            #"["EVENT","geo-u4pru",[]]"#,
            #"["EVENT",42,{}]"#,
            String(repeating: "[", count: 5000),                       // deep nesting
            #"["EVENT","geo-u4pru",\#(validJSON.replacingOccurrences(of: "real post", with: "forged post"))]"#, // edited content
            #"["EVENT","geo-u4pru",\#(validJSON.replacingOccurrences(of: "\"u4pru\"", with: "\"u4prv\""))]"#,  // moved cell
            "[\"NOTICE\",\"" + String(repeating: "A", count: 200_000) + "\"]", // huge notice
        ]
        for text in hostile { await pool.handle(Data(text.utf8)) }
        // 3. The genuine event still arrives, exactly once, and nothing forged did.
        await pool.handle(Data(#"["EVENT","geo-u4pru",\#(validJSON)]"#.utf8))
        await pool.handle(Data(#"["EVENT","geo-u4pru",\#(validJSON)]"#.utf8))

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while clock.now < deadline, await inbox.messages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await inbox.messages.map(\.text) == ["real post"])
    }
}

@Suite("Security DAST: hostile event keys")
struct SecurityEventKeyFuzzTests {
    /// SEC-DAST-10: events carrying random x-only keys (about half are not points on the
    /// curve) and random signatures, with a correctly computed id so they reach the
    /// signature check. swift-secp256k1 0.24.0 doesn't validate x-only keys at construction
    /// (0.25.0 does), so this guards against a remote crash through `isValid`.
    @Test func randomPublicKeysAndSignaturesAreRejectedWithoutCrashing() {
        var rng = SystemRandomNumberGenerator()
        var accepted = 0
        for _ in 0..<2000 {
            let pubkey = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }).hexString
            let sig = Data((0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }).hexString
            let created = 1_700_000_000
            let tags = [["g", "u4pru"]]
            let id = NostrEvent.computeID(pubkey: pubkey, createdAt: created, kind: NostrLocationChannel.kind, tags: tags, content: "x").hexString
            let event = NostrEvent(id: id, pubkey: pubkey, created_at: created, kind: NostrLocationChannel.kind, tags: tags, content: "x", sig: sig)
            if event.isValid { accepted += 1 }
        }
        #expect(accepted == 0)
    }
}
