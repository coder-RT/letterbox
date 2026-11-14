import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxNostr

@Suite("Nostr")
struct NostrTests {
    @Test func canonicalSerializationFollowsNIP01() {
        let json = NostrEvent.canonicalJSON(
            pubkey: "ab",
            createdAt: 1_700_000_000,
            kind: 23333,
            tags: [["g", "u4pru"], ["n", "ana"]],
            content: "line1\n\"quoted\" \\ tab\t/slash é"
        )
        #expect(json == #"[0,"ab",1700000000,23333,[["g","u4pru"],["n","ana"]],"line1\n\"quoted\" \\ tab\t/slash é"]"#)
    }

    @Test func controlCharactersUseUnicodeEscapes() {
        #expect(NostrEvent.quote("a\u{01}b") == #""a\u0001b""#)
        #expect(NostrEvent.quote("\u{08}\u{0C}") == #""\b\f""#)
    }

    @Test func signedEventsVerifyAndTamperingIsDetected() throws {
        let keys = NostrKeys.generate()
        let event = try keys.sign(kind: 23333, tags: [["g", "u4pru"]], content: "hello")
        #expect(event.isValid)
        #expect(event.pubkey == keys.publicKeyHex)
        #expect(event.sig.count == 128)

        let edited = NostrEvent(
            id: event.id, pubkey: event.pubkey, created_at: event.created_at,
            kind: event.kind, tags: event.tags, content: "hellO", sig: event.sig
        )
        #expect(!edited.isValid)

        let reSigned = try NostrKeys.generate().sign(kind: 23333, tags: event.tags, content: "hello")
        let forged = NostrEvent(
            id: reSigned.id, pubkey: event.pubkey, created_at: reSigned.created_at,
            kind: reSigned.kind, tags: reSigned.tags, content: reSigned.content, sig: reSigned.sig
        )
        #expect(!forged.isValid)
    }

    @Test func eventsSurviveAJSONRoundTrip() throws {
        let event = try NostrKeys.generate().sign(kind: 23333, tags: [["n", "zoë"]], content: "emoji 🙂")
        let decoded = try JSONDecoder().decode(NostrEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        #expect(decoded.isValid)
    }

    @Test func geohashIdentitiesAreStableAndUnlinkable() {
        let seed = Data(repeating: 7, count: 32)
        let here = NostrKeys.forGeohash("u4pru", seed: seed)
        #expect(NostrKeys.forGeohash("u4pru", seed: seed) == here)
        #expect(NostrKeys.forGeohash("u4prv", seed: seed).publicKeyHex != here.publicKeyHex)
        #expect(NostrKeys.forGeohash("u4pru", seed: Data(repeating: 8, count: 32)).publicKeyHex != here.publicKeyHex)
    }

    @Test func filterEncodesTagQueryKey() throws {
        let filter = NostrFilter(kinds: [23333], geohashes: ["u4pru"], since: 10, limit: 5)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filter)) as? [String: Any]
        #expect(object?["#g"] as? [String] == ["u4pru"])
        #expect(object?["kinds"] as? [Int] == [23333])
        #expect(object?["since"] as? Int == 10)
        #expect(object?["limit"] as? Int == 5)
    }
}

@Suite("Nostr edge cases")
struct NostrEdgeCaseTests {
    @Test func canonicalJSONWithNoTagsAndUnicode() {
        let json = NostrEvent.canonicalJSON(pubkey: "ab", createdAt: 0, kind: 1, tags: [], content: "🙂 \u{2028}")
        #expect(json == "[0,\"ab\",0,1,[],\"🙂 \u{2028}\"]")
    }

    @Test func idIsSHA256OfTheCanonicalForm() throws {
        let event = try NostrKeys.generate().sign(kind: 23333, tags: [["g", "u4pru"]], content: "x")
        let recomputed = NostrEvent.computeID(pubkey: event.pubkey, createdAt: event.created_at, kind: event.kind,
                                              tags: event.tags, content: event.content)
        #expect(recomputed.hexString == event.id)
        #expect(event.id.count == 64)
    }

    @Test func uppercaseIDStillVerifies() throws {
        let event = try NostrKeys.generate().sign(kind: 23333, tags: [], content: "x")
        let upper = NostrEvent(id: event.id.uppercased(), pubkey: event.pubkey, created_at: event.created_at,
                               kind: event.kind, tags: event.tags, content: event.content, sig: event.sig)
        #expect(upper.isValid)
    }

    @Test func malformedKeysAndSignaturesAreInvalidNotCrashes() throws {
        let event = try NostrKeys.generate().sign(kind: 23333, tags: [], content: "x")
        func variant(pubkey: String? = nil, sig: String? = nil, createdAt: Int? = nil, kind: Int? = nil, tags: [[String]]? = nil) -> NostrEvent {
            NostrEvent(id: event.id, pubkey: pubkey ?? event.pubkey, created_at: createdAt ?? event.created_at,
                       kind: kind ?? event.kind, tags: tags ?? event.tags, content: event.content, sig: sig ?? event.sig)
        }
        #expect(!variant(pubkey: "zz").isValid)
        #expect(!variant(pubkey: String(event.pubkey.dropLast(2))).isValid)
        #expect(!variant(sig: "00").isValid)
        #expect(!variant(sig: String(repeating: "0", count: 128)).isValid)
        #expect(!variant(createdAt: event.created_at + 1).isValid)
        #expect(!variant(kind: 1).isValid)
        #expect(!variant(tags: [["g", "u4pru"]]).isValid)
    }

    @Test func firstTagSkipsMalformedTags() throws {
        let event = try NostrKeys.generate().sign(kind: 1, tags: [["g"], ["n", "ana"], ["g", "u4pru"], ["g", "later"]], content: "")
        #expect(event.firstTag("g") == "u4pru")
        #expect(event.firstTag("n") == "ana")
        #expect(event.firstTag("missing") == nil)
    }

    @Test func invalidPrivateKeysAreRejected() {
        #expect(throws: (any Error).self) { try NostrKeys(privateKey: Data(count: 32)) } // zero scalar
        #expect(throws: (any Error).self) { try NostrKeys(privateKey: Data(repeating: 1, count: 31)) }
        #expect(throws: (any Error).self) { try NostrKeys(privateKey: Data(repeating: 0xFF, count: 32)) } // above curve order
    }

    @Test func keysRoundTripThroughRawBytes() throws {
        let keys = NostrKeys.generate()
        #expect(try NostrKeys(privateKey: keys.privateKey) == keys)
        #expect(keys.publicKeyHex.count == 64)
    }

    @Test func signingUsesTheGivenTime() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_123.9)
        let event = try NostrKeys.generate().sign(kind: 1, tags: [], content: "", createdAt: date)
        #expect(event.created_at == 1_700_000_123)
        #expect(event.isValid)
    }

    @Test func filterOmitsOptionalFields() throws {
        let filter = NostrFilter(kinds: [1], geohashes: [])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filter)) as? [String: Any]
        #expect(object?.keys.sorted() == ["kinds"])
    }

    @Test func geohashKeysDifferFromEachOtherAcrossManyCells() {
        let seed = Data(repeating: 1, count: 32)
        let cells = ["u", "u4", "u4p", "u4pr", "u4pru", "u4prv", "ezs42", "s0000"]
        let keys = cells.map { NostrKeys.forGeohash($0, seed: seed).publicKeyHex }
        #expect(Set(keys).count == cells.count)
    }
}
