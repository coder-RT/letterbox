import Foundation
import Testing
@testable import LetterboxDomain

@Suite("Domain")
struct DomainTests {
    @Test func geohashMatchesKnownValues() {
        // Reference values from the original geohash.org examples.
        #expect(Geohash.encode(Coordinate(latitude: 57.64911, longitude: 10.40744), precision: 11) == "u4pruydqqvj")
        #expect(Geohash.encode(Coordinate(latitude: 42.6, longitude: -5.6), precision: 5) == "ezs42")
        #expect(Geohash.encode(Coordinate(latitude: 57.64911, longitude: 10.40744), precision: GeohashLevel.city.precision) == "u4pru")
    }

    @Test func geohashValidation() {
        #expect(Geohash.isValid("u4pru"))
        #expect(!Geohash.isValid(""))
        #expect(!Geohash.isValid("abc")) // "a" is not in the geohash alphabet
    }

    @Test func nicknameSanitizing() {
        #expect(Nickname.sanitize("  ana  ") == "ana")
        #expect(Nickname.sanitize("a\nb") == "ab")
        #expect(Nickname.sanitize(String(repeating: "x", count: 40)).count == Nickname.maxLength)
    }

    @Test func fingerprintShortForm() {
        let fingerprint = Fingerprint(hex: "3FA9C21077BE01D4" + String(repeating: "0", count: 48))
        #expect(fingerprint.short == "3fa9 c210 77be 01d4")
    }

    @Test func hexRoundTrip() {
        let bytes = Data([0x00, 0x7F, 0xFF, 0x10])
        #expect(Data(hexString: bytes.hexString) == bytes)
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}

@Suite("Geohash")
struct GeohashTests {
    private let aalborg = Coordinate(latitude: 57.64911, longitude: 10.40744)

    @Test(arguments: GeohashLevel.allCases)
    func eachLevelProducesItsPrecision(level: GeohashLevel) {
        let hash = Geohash.encode(aalborg, precision: level.precision)
        #expect(hash.count == level.precision)
        #expect(Geohash.isValid(hash))
        // Every level is a prefix of the most precise hash: smaller cells nest inside larger ones.
        #expect(Geohash.encode(aalborg, precision: 12).hasPrefix(hash))
    }

    @Test func levelsGetSmallerAsPrecisionGrows() {
        let precisions = GeohashLevel.allCases.map(\.precision)
        #expect(precisions == precisions.sorted())
        #expect(Set(GeohashLevel.allCases.map(\.title)).count == GeohashLevel.allCases.count)
    }

    @Test func knownEdgesOfTheMap() {
        #expect(Geohash.encode(Coordinate(latitude: 0, longitude: 0), precision: 5) == "s0000")
        #expect(Geohash.encode(Coordinate(latitude: -90, longitude: -180), precision: 5) == "00000")
        #expect(Geohash.encode(Coordinate(latitude: 90, longitude: 180), precision: 5) == "zzzzz")
        #expect(Geohash.encode(Coordinate(latitude: 0, longitude: 0), precision: 0) == "")
    }

    @Test func nearbyPointsShareACellAndDistantOnesDont() {
        let neighbour = Coordinate(latitude: 57.64920, longitude: 10.40750) // ~10 m away
        let copenhagen = Coordinate(latitude: 55.6761, longitude: 12.5683)
        #expect(Geohash.encode(aalborg, precision: 6) == Geohash.encode(neighbour, precision: 6))
        #expect(Geohash.encode(aalborg, precision: 4) != Geohash.encode(copenhagen, precision: 4))
    }

    @Test(arguments: ["u4pruydqqvjx", "0", "zzzzzzzzzzzz", "bcdefghjkmnp"])
    func acceptsValidHashes(hash: String) {
        #expect(Geohash.isValid(hash))
    }

    @Test(arguments: ["", "u4pruydqqvjxx", "U4PRU", "u4pr i", "u4prl", "u4pro", "u4pra", "#u4pru", "u4pru\n"])
    func rejectsInvalidHashes(hash: String) {
        #expect(!Geohash.isValid(hash))
    }
}

@Suite("Nicknames")
struct NicknameTests {
    @Test func stripsControlCharactersAndNewlines() {
        #expect(Nickname.sanitize("a\u{0}b\u{7}c") == "abc")
        #expect(Nickname.sanitize("a\r\nb\tc") == "abc")
        #expect(Nickname.sanitize("\n\n") == "")
        #expect(Nickname.sanitize("   ") == "")
    }

    @Test func keepsUnicodeAndCountsCharactersNotBytes() {
        #expect(Nickname.sanitize("zoë 🙂") == "zoë 🙂")
        let emoji = String(repeating: "🙂", count: 30)
        #expect(Nickname.sanitize(emoji) == String(repeating: "🙂", count: Nickname.maxLength))
        let exact = String(repeating: "x", count: Nickname.maxLength)
        #expect(Nickname.sanitize(exact) == exact)
    }

    @Test func keepsInnerSpaces() {
        #expect(Nickname.sanitize("  Ana  Lee ") == "Ana  Lee")
    }

    @Test func isIdempotent() {
        for raw in ["  ana ", "a\nb", String(repeating: "y", count: 50), "🙂\u{1}"] {
            let once = Nickname.sanitize(raw)
            #expect(Nickname.sanitize(once) == once)
        }
    }

    @Test func randomNamesAreValidAndVaried() {
        let names = (0..<50).map { _ in Nickname.random() }
        for name in names {
            #expect(name.hasPrefix("anon"))
            #expect(name.count == 8)
            #expect(Nickname.sanitize(name) == name)
        }
        #expect(Set(names).count > 1)
    }
}

@Suite("Identifiers")
struct IdentifierTests {
    @Test func peerIDNeedsExactlyEightBytes() {
        #expect(PeerID(bytes: Data(count: 7)) == nil)
        #expect(PeerID(bytes: Data(count: 9)) == nil)
        #expect(PeerID(bytes: Data()) == nil)
        let id = PeerID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(id?.hex == "0102030405060708")
        #expect(id?.description == "0102030405060708")
    }

    @Test func randomPeerIDsDiffer() {
        let ids = Set((0..<200).map { _ in PeerID.random() })
        #expect(ids.count == 200)
    }

    @Test func peerIDsOrderByBytes() {
        let low = PeerID(bytes: Data([0, 0, 0, 0, 0, 0, 0, 1]))!
        let high = PeerID(bytes: Data([0, 0, 0, 0, 0, 0, 1, 0]))!
        #expect(low < high)
        #expect(!(high < low))
        #expect(!(low < low))
    }

    @Test func fingerprintsCompareCaseInsensitively() {
        let upper = Fingerprint(hex: "ABCDEF" + String(repeating: "0", count: 58))
        let lower = Fingerprint(hex: "abcdef" + String(repeating: "0", count: 58))
        #expect(upper == lower)
        #expect(upper.hashValue == lower.hashValue)
        #expect(upper.description == lower.hex)
    }

    @Test func fingerprintSurvivesCodable() throws {
        let fingerprint = Fingerprint(hex: String(repeating: "7", count: 64))
        let decoded = try JSONDecoder().decode(Fingerprint.self, from: JSONEncoder().encode(fingerprint))
        #expect(decoded == fingerprint)
    }

    @Test func shortFormHandlesShortInputWithoutCrashing() {
        #expect(Fingerprint(hex: "abcdef").short == "abcd ef")
        #expect(Fingerprint(hex: "").short == "")
        #expect(Fingerprint(hex: "abcd").short == "abcd")
    }

    @Test func hexParsingAcceptsBothCasesAndEmpty() {
        #expect(Data(hexString: "") == Data())
        #expect(Data(hexString: "DEADbeef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(Data(hexString: "0g") == nil)
        #expect(Data(hexString: " 00") == nil)
    }

    @Test func hexRoundTripsEveryByte() {
        let all = Data((0...255).map(UInt8.init))
        #expect(all.hexString.count == 512)
        #expect(Data(hexString: all.hexString) == all)
        #expect(Data(hexString: all.hexString.uppercased()) == all)
    }
}

@Suite("Chat models")
struct ChatModelTests {
    @Test func peerIdentityIsItsFingerprint() {
        let fingerprint = Fingerprint(hex: String(repeating: "c", count: 64))
        let peer = Peer(peerID: .random(), nickname: "c", fingerprint: fingerprint, isDirect: true,
                        hasSecureSession: false, lastSeen: Date())
        #expect(peer.id == fingerprint)
    }

    @Test func channelsAreDistinctKeys() {
        let fingerprint = Fingerprint(hex: String(repeating: "d", count: 64))
        let channels: Set<ChannelID> = [.mesh, .location(geohash: "u4pru"), .location(geohash: "u4prv"), .direct(fingerprint)]
        #expect(channels.count == 4)
        #expect(ChannelID.location(geohash: "u4pru") == .location(geohash: "u4pru"))
    }

    @Test func messagesDefaultToNoDeliveryState() {
        let message = ChatMessage(id: "1", channel: .mesh, senderName: "a", senderKey: "k", text: "t",
                                  timestamp: Date(), isOwn: false, isVerified: false)
        #expect(message.delivery == nil)
    }
}

@Suite("Route planner")
struct RoutePlannerTests {
    private func route(
        _ kind: OutgoingKind = .text, nearby: Bool = false, keyKnown: Bool = false, internetAddress: Bool = false,
        bluetooth: Bool = true, internet: Bool = true, online: Bool = true
    ) -> Route {
        RoutePlanner.route(for: kind, recipientNearby: nearby, recipientKeyKnown: keyKnown,
                           recipientHasInternetAddress: internetAddress,
                           permissions: TransportPermissions(bluetooth: bluetooth, internet: internet), internetOnline: online)
    }

    @Test func nearbyPeopleGetBluetooth() {
        #expect(route(nearby: true) == .mesh)
        #expect(route(nearby: true, internetAddress: true) == .mesh) // nearby beats internet
    }

    @Test func farAwayPeopleGetInternetWhenPossible() {
        #expect(route(internetAddress: true) == .internet)
        #expect(route(nearby: true, internetAddress: true, bluetooth: false) == .internet)
    }

    @Test func otherwiseAnEnvelopeIfWeKnowTheirKey() {
        #expect(route(keyKnown: true) == .envelope)
        #expect(route(keyKnown: true, internetAddress: true, online: false) == .envelope)
        #expect(route(keyKnown: true, internetAddress: true, internet: false) == .envelope)
    }

    @Test func otherwiseQueuedWithAReason() {
        guard case .queue = route() else { Issue.record("expected a queue"); return }
        guard case .queue = route(internetAddress: true, bluetooth: false, online: false) else { Issue.record("expected a queue"); return }
    }

    @Test func bluetoothOffStillQueuesForSomeoneWeKnow() {
        guard case let .queue(reason) = route(keyKnown: true, bluetooth: false, internet: false) else {
            Issue.record("expected a queue"); return
        }
        #expect(reason.contains("Bluetooth is off"))
    }

    @Test func everythingOffForAStrangerIsImpossible() {
        guard case let .impossible(reason) = route(bluetooth: false, internet: false) else { Issue.record("expected impossible"); return }
        #expect(reason.contains("both off"))
    }

    @Test func photosOnlyGoOverTheInternet() {
        #expect(route(.photo, nearby: true, keyKnown: true, internetAddress: true) == .internet)
        guard case .impossible = route(.photo, nearby: true, keyKnown: true, internetAddress: true, internet: false) else {
            Issue.record("photo with internet off should be impossible"); return
        }
        guard case .impossible = route(.photo, nearby: true) else { Issue.record("photo with no internet address"); return }
        guard case .queue = route(.photo, internetAddress: true, online: false) else { Issue.record("photo offline should queue"); return }
    }

    @Test(arguments: [true, false])
    func everyCombinationGivesAnAnswer(seed: Bool) {
        for kind in [OutgoingKind.text, .photo] {
            for bits in 0..<64 {
                let flags = (0..<6).map { bits & (1 << $0) != 0 }
                let result = route(kind, nearby: flags[0], keyKnown: flags[1], internetAddress: flags[2],
                                   bluetooth: flags[3], internet: flags[4], online: flags[5] != seed || flags[5])
                switch result {
                case .mesh: #expect(kind == .text && flags[0] && flags[3])
                case .internet: #expect(flags[4] && flags[2])
                case .envelope: #expect(kind == .text && flags[1] && flags[3])
                case let .queue(reason), let .impossible(reason): #expect(!reason.isEmpty)
                }
            }
        }
    }
}

@Suite("Envelope summary")
struct EnvelopeSummaryTests {
    @Test func looksUpCarriersByMessage() {
        let fingerprint = Fingerprint(hex: String(repeating: "a", count: 64))
        let summary = EnvelopeSummary(outgoing: [OutgoingEnvelope(messageID: "m1", recipient: fingerprint, carriers: 3, expires: Date())],
                                      carryingForOthers: 2)
        #expect(summary.carriers(for: "m1") == 3)
        #expect(summary.carriers(for: "m2") == nil)
        #expect(EnvelopeSummary.empty.outgoing.isEmpty && EnvelopeSummary.empty.carryingForOthers == 0)
    }
}
