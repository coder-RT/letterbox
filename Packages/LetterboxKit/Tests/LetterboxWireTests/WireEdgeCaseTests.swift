import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxWire

private let alice = PeerID(bytes: Data(repeating: 0x0A, count: 8))!
private let bob = PeerID(bytes: Data(repeating: 0x0B, count: 8))!

private func packet(
    _ type: PacketType = .publicMessage,
    recipient: PeerID? = nil,
    payload: Data = Data([1, 2, 3]),
    signature: Data? = nil
) -> Packet {
    Packet(type: type, ttl: 5, timestamp: 1_731_600_000_123, packetID: Data(repeating: 0xCD, count: 8),
           sender: alice, recipient: recipient, payload: payload, signature: signature)
}

/// Deterministic generator so fuzz failures can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Packet encoding")
struct PacketEncodingTests {
    @Test(arguments: PacketType.allCases)
    func everyTypeRoundTrips(type: PacketType) throws {
        for candidate in [
            packet(type),
            packet(type, recipient: bob),
            packet(type, signature: Data(repeating: 0x55, count: 64)),
            packet(type, recipient: bob, payload: Data(), signature: Data(repeating: 0x66, count: 64)),
        ] {
            #expect(try Packet.decode(candidate.encoded()) == candidate)
        }
    }

    @Test func headerLayoutMatchesTheDocumentedFormat() {
        let encoded = packet(recipient: bob, payload: Data([0xEE]), signature: Data(repeating: 0x77, count: 64)).encoded()
        let bytes = [UInt8](encoded)
        #expect(bytes[0...1] == [0x4C, 0x42]) // "LB"
        #expect(bytes[2] == Packet.version)
        #expect(bytes[3] == PacketType.publicMessage.rawValue)
        #expect(bytes[4] == 5) // TTL
        #expect(bytes[5] == 0x03) // has recipient + has signature
        #expect(Array(bytes[6..<14]) == [0x00, 0x00, 0x01, 0x93, 0x2B, 0x67, 0x24, 0x7B]) // timestamp, big-endian
        #expect(Array(bytes[22..<30]) == Array(repeating: 0x0A, count: 8)) // sender
        #expect(Array(bytes[30..<38]) == Array(repeating: 0x0B, count: 8)) // recipient
        #expect(Array(bytes[38..<40]) == [0x00, 0x01]) // payload length
        #expect(bytes[40] == 0xEE)
        #expect(encoded.count == Packet.headerLength + 8 + 2 + 1 + 64)
    }

    @Test func unsupportedVersionIsRejected() {
        var bytes = packet().encoded()
        bytes[2] = 9
        #expect(throws: WireError.unsupportedVersion(9)) { try Packet.decode(bytes) }
    }

    @Test func unknownTypeIsRejected() {
        var bytes = packet().encoded()
        bytes[3] = 0x7F
        #expect(throws: WireError.unknownType(0x7F)) { try Packet.decode(bytes) }
    }

    @Test func oversizedPayloadLengthIsRejectedBeforeReading() {
        var bytes = packet(payload: Data()).encoded()
        let lengthOffset = Packet.headerLength
        let tooBig = UInt16(Packet.maxPayload + 1)
        bytes[lengthOffset] = UInt8(tooBig >> 8)
        bytes[lengthOffset + 1] = UInt8(tooBig & 0xFF)
        #expect(throws: WireError.tooLarge) { try Packet.decode(bytes) }
    }

    @Test func flagsPromisingMissingFieldsAreRejected() {
        var claimsRecipient = packet().encoded()
        claimsRecipient[5] |= 0x01
        #expect(throws: (any Error).self) { try Packet.decode(claimsRecipient) }

        var claimsSignature = packet().encoded()
        claimsSignature[5] |= 0x02
        #expect(throws: (any Error).self) { try Packet.decode(claimsSignature) }
    }

    @Test func unknownFlagBitsAreIgnoredForForwardCompatibility() throws {
        let original = packet()
        var bytes = original.encoded()
        bytes[5] |= 0xF0
        #expect(try Packet.decode(bytes) == original)
    }

    @Test func signatureIsNotPartOfWhatIsSigned() {
        let unsigned = packet()
        let signed = packet(signature: Data(repeating: 1, count: 64))
        #expect(unsigned.signingBytes() == signed.signingBytes())
        #expect(signed.signingBytes()[4] == 0) // TTL zeroed
        #expect(signed.encoded().count == unsigned.encoded().count + 64)
    }

    @Test func recipientAndTimestampAreCoveredBySigning() {
        let base = packet().signingBytes()
        #expect(packet(recipient: bob).signingBytes() != base)
        var later = packet()
        later.timestamp += 1
        #expect(later.signingBytes() != base)
        var otherSender = packet()
        otherSender.sender = bob
        #expect(otherSender.signingBytes() != base)
    }

    @Test func randomPacketIDsAreEightBytesAndUnique() {
        let ids = (0..<500).map { _ in Packet.randomPacketID() }
        #expect(ids.allSatisfy { $0.count == Packet.packetIDLength })
        #expect(Set(ids).count == ids.count)
    }

    @Test func randomBytesNeverCrashTheDecoder() {
        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<2000 {
            let length = Int.random(in: 0...200, using: &rng)
            var bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if length >= 2, Bool.random(using: &rng) { bytes[0] = 0x4C; bytes[1] = 0x42 } // get past the magic
            _ = try? Packet.decode(bytes)
        }
    }

    @Test func everySingleBitFlipIsHandled() throws {
        let good = packet(recipient: bob, payload: Data("payload".utf8), signature: Data(repeating: 3, count: 64)).encoded()
        for index in good.indices {
            for bit in 0..<8 {
                var flipped = good
                flipped[index] ^= UInt8(1 << bit)
                // Must either throw or decode to a packet that re-encodes stably.
                // (Unused flag bits are ignored, so the bytes themselves may differ.)
                if let decoded = try? Packet.decode(flipped) {
                    #expect(try Packet.decode(decoded.encoded()) == decoded)
                    if index != 5 { #expect(decoded.encoded() == flipped) }
                }
            }
        }
    }
}

@Suite("TLV")
struct TLVTests {
    @Test func roundTripsFieldsIncludingEmptyValues() throws {
        let encoded = TLV.encode([(0x01, Data("a".utf8)), (0x02, Data()), (0xFF, Data(repeating: 9, count: 300))])
        let fields = try TLV.decode(encoded)
        #expect(fields[0x01] == Data("a".utf8))
        #expect(fields[0x02] == Data())
        #expect(fields[0xFF]?.count == 300)
        #expect(try TLV.decode(Data()).isEmpty)
    }

    @Test func truncatedFieldsThrow() {
        let encoded = TLV.encode([(0x01, Data(repeating: 1, count: 10))])
        for length in 1..<encoded.count {
            #expect(throws: WireError.truncated) { try TLV.decode(encoded.prefix(length)) }
        }
    }

    @Test func laterDuplicateFieldWins() throws {
        let fields = try TLV.decode(TLV.encode([(0x01, Data([1])), (0x01, Data([2]))]))
        #expect(fields[0x01] == Data([2]))
    }
}

@Suite("Payloads")
struct PayloadTests {
    private let noiseKey = Data(repeating: 1, count: 32)
    private let signingKey = Data(repeating: 2, count: 32)

    @Test func unknownFieldsAreIgnoredForForwardCompatibility() throws {
        var announce = AnnouncePayload(nickname: "ana", noiseKey: noiseKey, signingKey: signingKey).encoded()
        announce.append(TLV.encode([(0x7E, Data("future field".utf8))]))
        #expect(try AnnouncePayload.decode(announce).nickname == "ana")

        var message = PublicMessagePayload(nickname: "ana", text: "hi").encoded()
        message.append(TLV.encode([(0x40, Data([1, 2, 3]))]))
        #expect(try PublicMessagePayload.decode(message).text == "hi")
    }

    @Test func missingFieldsAreNamed() {
        let noNickname = TLV.encode([(0x02, noiseKey), (0x03, signingKey)])
        #expect(throws: WireError.invalidField("nickname")) { try AnnouncePayload.decode(noNickname) }
        let noText = TLV.encode([(0x01, Data("ana".utf8))])
        #expect(throws: WireError.invalidField("text")) { try PublicMessagePayload.decode(noText) }
        let wrongSigningKey = AnnouncePayload(nickname: "x", noiseKey: noiseKey, signingKey: Data(count: 33)).encoded()
        #expect(throws: WireError.invalidField("signingKey")) { try AnnouncePayload.decode(wrongSigningKey) }
    }

    @Test func invalidUTF8IsRejected() {
        let bad = TLV.encode([(0x01, Data("ana".utf8)), (0x02, Data([0xFF, 0xFE, 0xFD]))])
        #expect(throws: WireError.invalidField("text")) { try PublicMessagePayload.decode(bad) }
    }

    @Test func publicTextHasAByteLimit() throws {
        let atLimit = String(repeating: "a", count: PublicMessagePayload.maxTextBytes)
        #expect(try PublicMessagePayload.decode(PublicMessagePayload(nickname: "a", text: atLimit).encoded()).text == atLimit)
        let over = atLimit + "a"
        #expect(throws: WireError.tooLarge) { try PublicMessagePayload.decode(PublicMessagePayload(nickname: "a", text: over).encoded()) }
        // The limit is in bytes: 1000 two-byte characters fit, 1001 don't.
        let accented = String(repeating: "é", count: PublicMessagePayload.maxTextBytes / 2 + 1)
        #expect(throws: WireError.tooLarge) { try PublicMessagePayload.decode(PublicMessagePayload(nickname: "a", text: accented).encoded()) }
    }

    @Test func handshakeStagesAreLimitedToThree() throws {
        for stage: UInt8 in 0...2 {
            #expect(try HandshakePayload.decode(HandshakePayload(stage: stage, noiseMessage: Data([9])).encoded()).stage == stage)
        }
        #expect(throws: WireError.invalidField("stage")) { try HandshakePayload.decode(Data([3, 0])) }
        #expect(throws: WireError.truncated) { try HandshakePayload.decode(Data()) }
        #expect(try HandshakePayload.decode(Data([1])).noiseMessage.isEmpty)
    }

    @Test func encryptedPayloadNeedsAFullTag() throws {
        #expect(throws: WireError.truncated) { try EncryptedPayload.decode(Data(count: 8 + 15)) }
        #expect(throws: WireError.truncated) { try EncryptedPayload.decode(Data(count: 7)) }
        let minimal = try EncryptedPayload.decode(Data(count: 8 + 16))
        #expect(minimal.nonce == 0)
        let max = EncryptedPayload(nonce: .max, ciphertext: Data(count: 16))
        #expect(try EncryptedPayload.decode(max.encoded()) == max)
    }

    @Test func privatePayloadEdgeCases() throws {
        for payload in [
            PrivatePayload.message(id: "", nickname: "", text: "", timestamp: 0),
            .message(id: "id", nickname: "zoë", text: String(repeating: "🙂", count: 500), timestamp: .max),
            .delivered(ids: []),
            .read(ids: (0..<100).map { "id-\($0)" }),
        ] {
            #expect(try PrivatePayload.decode(payload.encoded()) == payload)
        }
        #expect(throws: WireError.unknownType(0x09)) { try PrivatePayload.decode(Data([0x09])) }
        #expect(throws: WireError.truncated) { try PrivatePayload.decode(Data()) }
        // A message missing its timestamp.
        let noTimestamp = Data([0x01]) + TLV.encode([(0x01, Data("id".utf8)), (0x02, Data("n".utf8)), (0x03, Data("t".utf8))])
        #expect(throws: WireError.invalidField("timestamp")) { try PrivatePayload.decode(noTimestamp) }
    }
}

@Suite("Link framing")
struct LinkFramingTests {
    private func reassemble(_ chunks: [Data], using reassembler: inout FrameReassembler) -> Data? {
        var result: Data?
        for chunk in chunks { result = reassembler.accept(chunk) ?? result }
        return result
    }

    @Test(arguments: [23, 100, 185, 512])
    func roundTripsAcrossMTUs(mtu: Int) {
        for size in [1, mtu - LinkFramer.headerLength, mtu - LinkFramer.headerLength + 1, 3000] {
            let frame = Data((0..<size).map { UInt8($0 & 0xFF) })
            let chunks = LinkFramer.chunks(for: frame, frameID: 42, mtu: mtu)
            #expect(chunks.allSatisfy { $0.count <= mtu })
            var reassembler = FrameReassembler()
            #expect(reassemble(chunks, using: &reassembler) == frame, "mtu \(mtu) size \(size)")
        }
    }

    @Test func exactMultipleOfBodySizeHasNoEmptyTail() {
        let chunks = LinkFramer.chunks(for: Data(count: 96 * 3), frameID: 1, mtu: 100)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 100 })
    }

    @Test func framesNeedingMoreThan255ChunksAreRefused() {
        #expect(LinkFramer.chunks(for: Data(count: 255 * 16), frameID: 1, mtu: 20).count == 255)
        #expect(LinkFramer.chunks(for: Data(count: 255 * 16 + 1), frameID: 1, mtu: 20).isEmpty)
    }

    @Test func tinyMTUStillMakesProgress() {
        let chunks = LinkFramer.chunks(for: Data([1, 2, 3]), frameID: 1, mtu: 2)
        #expect(chunks.count == 3)
        var reassembler = FrameReassembler()
        #expect(reassemble(chunks, using: &reassembler) == Data([1, 2, 3]))
    }

    @Test func interleavedFramesOnOneLinkBothComplete() {
        let first = Data(repeating: 1, count: 500)
        let second = Data(repeating: 2, count: 500)
        let a = LinkFramer.chunks(for: first, frameID: 1, mtu: 100)
        let b = LinkFramer.chunks(for: second, frameID: 2, mtu: 100)
        var reassembler = FrameReassembler()
        var done: [Data] = []
        for (x, y) in zip(a, b) {
            if let frame = reassembler.accept(x) { done.append(frame) }
            if let frame = reassembler.accept(y) { done.append(frame) }
        }
        #expect(done == [first, second])
    }

    @Test func duplicateChunksDoNotCompleteAFrameEarly() {
        let chunks = LinkFramer.chunks(for: Data(count: 300), frameID: 5, mtu: 104)
        #expect(chunks.count == 3)
        var reassembler = FrameReassembler()
        #expect(reassembler.accept(chunks[0]) == nil)
        #expect(reassembler.accept(chunks[0]) == nil)
        #expect(reassembler.accept(chunks[1]) == nil)
        #expect(reassembler.accept(chunks[2]) == Data(count: 300))
    }

    @Test func malformedChunksAreIgnored() {
        var reassembler = FrameReassembler()
        #expect(reassembler.accept(Data()) == nil)
        #expect(reassembler.accept(Data([0, 1, 0, 2])) == nil) // header only
        #expect(reassembler.accept(Data([0, 1, 2, 2, 9])) == nil) // index >= count
        #expect(reassembler.accept(Data([0, 1, 0, 0, 9])) == nil) // count 0
    }

    @Test func chunkCountMismatchDropsThePartialFrame() {
        let three = LinkFramer.chunks(for: Data(count: 300), frameID: 9, mtu: 104)
        let two = LinkFramer.chunks(for: Data(count: 150), frameID: 9, mtu: 104)
        var reassembler = FrameReassembler()
        #expect(reassembler.accept(three[0]) == nil)
        #expect(reassembler.accept(two[1]) == nil) // conflicting count for frame 9
        // The old partial is gone, so finishing the three-chunk frame no longer works.
        #expect(reassembler.accept(three[1]) == nil)
        #expect(reassembler.accept(three[2]) == nil)
    }

    @Test func oldestPartialIsEvictedWhenFull() {
        var reassembler = FrameReassembler(maxConcurrent: 2)
        let frames = (1...3).map { LinkFramer.chunks(for: Data(repeating: UInt8($0), count: 200), frameID: UInt16($0), mtu: 104) }
        let start = Date()
        for (offset, chunks) in frames.enumerated() {
            #expect(reassembler.accept(chunks[0], now: start.addingTimeInterval(Double(offset))) == nil)
        }
        // Frames 2 and 3 are still there; frame 1 was evicted to make room for frame 3.
        #expect(reassembler.accept(frames[1][1], now: start.addingTimeInterval(3)) == Data(repeating: 2, count: 200))
        #expect(reassembler.accept(frames[2][1], now: start.addingTimeInterval(3)) == Data(repeating: 3, count: 200))
        #expect(reassembler.accept(frames[0][1], now: start.addingTimeInterval(3)) == nil)
    }

    @Test func aFullPacketSurvivesFramingOverBLE() throws {
        let original = packet(recipient: bob, payload: Data(repeating: 0x42, count: 1500), signature: Data(repeating: 1, count: 64))
        let chunks = LinkFramer.chunks(for: original.encoded(), frameID: 77, mtu: 185)
        var reassembler = FrameReassembler()
        let rebuilt = try #require(reassemble(chunks.shuffled(), using: &reassembler))
        #expect(try Packet.decode(rebuilt) == original)
    }
}

@Suite("Courier envelope")
struct CourierEnvelopeTests {
    private func sample(sealedSize: Int = 120) -> CourierEnvelope {
        CourierEnvelope(id: Data(repeating: 1, count: 16), recipientTag: Data(repeating: 2, count: 16),
                        expiry: 1_731_600_000_000, sealed: Data(repeating: 3, count: sealedSize))
    }

    @Test func roundTrips() throws {
        let envelope = sample()
        #expect(try CourierEnvelope.decode(envelope.encoded()) == envelope)
        let max = sample(sealedSize: CourierEnvelope.maxSealedBytes)
        #expect(try CourierEnvelope.decode(max.encoded()) == max)
    }

    @Test func rejectsWrongSizesAndMissingFields() {
        #expect(throws: WireError.tooLarge) { try CourierEnvelope.decode(sample(sealedSize: CourierEnvelope.maxSealedBytes + 1).encoded()) }
        var shortID = sample()
        shortID.id = Data(count: 15)
        #expect(throws: WireError.invalidField("id")) { try CourierEnvelope.decode(shortID.encoded()) }
        var longTag = sample()
        longTag.recipientTag = Data(count: 17)
        #expect(throws: WireError.invalidField("tag")) { try CourierEnvelope.decode(longTag.encoded()) }
        #expect(throws: WireError.invalidField("sealed")) { try CourierEnvelope.decode(sample(sealedSize: 0).encoded()) }
        #expect(throws: WireError.invalidField("expiry")) { try CourierEnvelope.decode(TLV.encode([(0x01, Data(count: 16))])) }
        #expect(throws: (any Error).self) { try CourierEnvelope.decode(Data([0x01, 0x00])) }
    }

    @Test func associatedDataCoversEverythingACourierSees() {
        let base = sample().associatedData
        var later = sample()
        later.expiry += 1
        var redirected = sample()
        redirected.recipientTag = Data(repeating: 9, count: 16)
        var renamed = sample()
        renamed.id = Data(repeating: 8, count: 16)
        #expect(later.associatedData != base)
        #expect(redirected.associatedData != base)
        #expect(renamed.associatedData != base)
        var resealed = sample()
        resealed.sealed = Data(repeating: 7, count: 50)
        #expect(resealed.associatedData == base) // the sealed bytes authenticate themselves
    }

    @Test func fitsInACourierPacket() throws {
        let packet = Packet(type: .courier, ttl: 1, timestamp: 1, packetID: Data(count: 8),
                            sender: PeerID(bytes: Data(count: 8))!, payload: sample(sealedSize: CourierEnvelope.maxSealedBytes).encoded())
        #expect(try Packet.decode(packet.encoded()) == packet)
    }
}

@Suite("Letterbox protocol identity")
struct ProtocolIdentityTests {
    @Test func framesFromTheOldHoplineProtocolAreRejected() {
        var old = Packet(type: .publicMessage, ttl: 7, timestamp: 1, packetID: Data(count: 8),
                         sender: PeerID(bytes: Data(count: 8))!, payload: Data([1])).encoded()
        #expect(Array(old.prefix(2)) == [0x4C, 0x42]) // "LB"
        old[0] = 0x48; old[1] = 0x4C                    // "HL", the old Hopline magic
        #expect(throws: WireError.badMagic) { try Packet.decode(old) }
    }

    @Test func courierBindingNamesLetterbox() {
        let ad = CourierEnvelope.associatedData(id: Data(count: 16), recipientTag: Data(count: 16), expiry: 0)
        #expect(ad.starts(with: Data("letterbox/courier/1".utf8)))
    }
}
