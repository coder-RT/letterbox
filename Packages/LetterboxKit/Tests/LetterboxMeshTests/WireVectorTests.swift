import Foundation
import Testing
import LetterboxCrypto
import LetterboxDomain
@testable import LetterboxMesh
import LetterboxWire

// Golden vectors for Letterbox's wire format, kept in docs/wire-test-vectors.json so
// another implementation (an Android port, a desktop client) can check itself against
// them. Every value is recomputed here from the real code: change the format without
// meaning to and this fails, instead of phones silently ignoring each other.
//
// Regenerate after an intentional change:
//   LETTERBOX_WRITE_VECTORS=1 swift test --filter WireVectorTests
// then review the diff, and bump `Packet.version` or the context strings if old and new
// phones can no longer understand each other.

private let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // LetterboxMeshTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // LetterboxKit
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appendingPathComponent("docs/wire-test-vectors.json")

private func bytes(_ range: ClosedRange<UInt8>) -> Data { Data(range) }

/// Synthetic inputs, not derived from any real key.
private enum Input {
    static let noisePrivate = bytes(0x01...0x20)
    static let signingPrivate = bytes(0x21...0x40)
    static let otherNoisePrivate = bytes(0x41...0x60)
    static let timestamp: UInt64 = 1_800_000_000_000 // milliseconds
    static let packetID = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    static let sender = PeerID(bytes: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]))!
    static let recipient = PeerID(bytes: Data([0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00]))!
    static let placeholderSignature = Data(repeating: 0xAB, count: 64)
    static let envelopeID = bytes(0x00...0x0F)
    static let expiry: UInt64 = 1_800_259_200_000 // three days later, milliseconds
}

private func computeVectors() throws -> [String: String] {
    let me = try IdentityKeys(noisePrivate: Input.noisePrivate, signingPrivate: Input.signingPrivate)
    let other = try IdentityKeys(noisePrivate: Input.otherNoisePrivate, signingPrivate: Input.signingPrivate)
    let message = PublicMessagePayload(nickname: "ana", text: "meet at the hut").encoded()
    var publicPacket = Packet(type: .publicMessage, ttl: 7, timestamp: Input.timestamp, packetID: Input.packetID,
                              sender: Input.sender, payload: message)
    let signingBytes = publicPacket.signingBytes()
    publicPacket.signature = Input.placeholderSignature
    let directed = Packet(type: .encrypted, ttl: 7, timestamp: Input.timestamp, packetID: Input.packetID,
                          sender: Input.sender, recipient: Input.recipient, payload: Data([0xDE, 0xAD]))
    let announce = AnnouncePayload(nickname: "ana", noiseKey: me.noisePublic, signingKey: me.signingPublic).encoded()
    let syncRequest = SyncRequestPayload(since: Input.timestamp - 3_600_000, have: [Input.packetID, Data(repeating: 0x09, count: 8)])
    let tag = Courier.tag(for: other.fingerprint, envelopeID: Input.envelopeID)

    return [
        "identity.noisePublic": me.noisePublic.hexString,
        "identity.signingPublic": me.signingPublic.hexString,
        "identity.fingerprint (SHA-256 of noisePublic)": me.fingerprint.hex,
        "payload.announce": announce.hexString,
        "payload.publicMessage": message.hexString,
        "packet.publicMessage.signingBytes (ttl 0, no signature, hasSignature flag clear)": signingBytes.hexString,
        "packet.publicMessage.encoded (placeholder signature 0xAB x 64)": publicPacket.encoded().hexString,
        "packet.directed.encoded (hasRecipient flag, no signature)": directed.encoded().hexString,
        "payload.syncRequest": syncRequest.encoded().hexString,
        "courier.recipientTag": tag.hexString,
        "courier.associatedData (Noise X prologue)": CourierEnvelope.associatedData(
            id: Input.envelopeID, recipientTag: tag, expiry: Input.expiry
        ).hexString,
        "verify.safetyNumber": SafetyNumber.make(me.fingerprint, other.fingerprint).joined(separator: " "),
        "verify.qrPayload": VerifyCode.payload(for: me.fingerprint),
    ]
}

@Suite("Wire format golden vectors")
struct WireVectorTests {
    @Test func codeMatchesThePublishedVectors() throws {
        let computed = try computeVectors()
        if ProcessInfo.processInfo.environment["LETTERBOX_WRITE_VECTORS"] == "1" {
            let document: [String: Any] = [
                "_comment": [
                    "Golden vectors for the HelloLetter wire format (packet version \(Packet.version), magic \"LB\").",
                    "Generated from the Swift implementation and asserted by WireVectorTests, so they can't drift",
                    "from the code without a test failing. Hex is lowercase; integers are big-endian.",
                    "Inputs are synthetic: noise private 01..20, signing private 21..40, other noise private 41..60,",
                    "timestamp 1800000000000 ms, packetID 0102030405060708, sender 1122334455667788,",
                    "recipient 99aabbccddeeff00, envelope id 00..0f, expiry 1800259200000 ms.",
                    "Traps for other implementations:",
                    "  1. Timestamps and expiry are MILLISECONDS. Seconds read as 1970 and are dropped as stale.",
                    "  2. Signatures cover signingBytes (TTL 0, no signature, hasSignature flag clear), not the wire bytes.",
                    "  3. Ed25519 signatures from CryptoKit are randomised: pin the bytes signed, not the signature.",
                    "  4. syncRequest and syncResponse travel with TTL 1 and are never relayed.",
                ],
                "vectors": computed,
            ]
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: vectorsURL)
        }
        let data = try Data(contentsOf: vectorsURL)
        let published = try #require(
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["vectors"] as? [String: String]
        )
        #expect(published.keys.sorted() == computed.keys.sorted())
        for (name, value) in computed {
            #expect(published[name] == value, "\(name) changed")
        }
    }

    @Test func aRealSignatureOverTheSigningBytesVerifies() throws {
        let me = try IdentityKeys(noisePrivate: Input.noisePrivate, signingPrivate: Input.signingPrivate)
        var packet = Packet(type: .publicMessage, ttl: 7, timestamp: Input.timestamp, packetID: Input.packetID,
                            sender: Input.sender, payload: PublicMessagePayload(nickname: "ana", text: "hi").encoded())
        packet.signature = me.sign(packet.signingBytes())
        let relayed = try Packet.decode({ var copy = packet; copy.ttl = 3; return copy.encoded() }())
        #expect(IdentityKeys.verify(relayed.signature!, for: relayed.signingBytes(), signingKey: me.signingPublic),
                "Relays lower TTL without breaking the signature")
    }
}
