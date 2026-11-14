import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxWire

@Suite("Wire format")
struct WireTests {
    private func samplePacket(recipient: PeerID? = nil, signature: Data? = nil) -> Packet {
        Packet(
            type: .publicMessage,
            ttl: 7,
            timestamp: 1_731_600_000_000,
            packetID: Data(repeating: 0xAB, count: 8),
            sender: PeerID(bytes: Data(repeating: 0x01, count: 8))!,
            recipient: recipient,
            payload: PublicMessagePayload(nickname: "ana", text: "hi").encoded(),
            signature: signature
        )
    }

    @Test func packetRoundTripsWithAndWithoutOptionalFields() throws {
        let plain = samplePacket()
        #expect(try Packet.decode(plain.encoded()) == plain)

        let full = samplePacket(recipient: PeerID(bytes: Data(repeating: 0x02, count: 8)), signature: Data(repeating: 0x09, count: 64))
        #expect(try Packet.decode(full.encoded()) == full)
    }

    @Test func signingBytesIgnoreTTLAndSignature() {
        var packet = samplePacket()
        let before = packet.signingBytes()
        packet.ttl = 3
        packet.signature = Data(repeating: 0x07, count: 64)
        #expect(packet.signingBytes() == before)
        packet.payload.append(0x00)
        #expect(packet.signingBytes() != before)
    }

    @Test func malformedInputThrowsInsteadOfCrashing() {
        let good = samplePacket().encoded()
        for length in 0..<good.count {
            #expect(throws: (any Error).self) { try Packet.decode(good.prefix(length)) }
        }
        var badMagic = good
        badMagic[0] = 0x00
        #expect(throws: WireError.badMagic) { try Packet.decode(badMagic) }
        var trailing = good
        trailing.append(0x00)
        #expect(throws: (any Error).self) { try Packet.decode(trailing) }
    }

    @Test func payloadsRoundTrip() throws {
        let announce = AnnouncePayload(nickname: "zoë", noiseKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 2, count: 32))
        #expect(try AnnouncePayload.decode(announce.encoded()) == announce)

        let handshake = HandshakePayload(stage: 2, noiseMessage: Data([1, 2, 3]))
        #expect(try HandshakePayload.decode(handshake.encoded()) == handshake)

        let encrypted = EncryptedPayload(nonce: 42, ciphertext: Data(repeating: 9, count: 20))
        #expect(try EncryptedPayload.decode(encrypted.encoded()) == encrypted)

        for payload in [
            PrivatePayload.message(id: "m1", nickname: "ana", text: "hello\nthere", timestamp: 99),
            .delivered(ids: ["a", "b"]),
            .read(ids: ["c"]),
        ] {
            #expect(try PrivatePayload.decode(payload.encoded()) == payload)
        }
    }

    @Test func announceRejectsWrongKeyLength() {
        let bad = AnnouncePayload(nickname: "x", noiseKey: Data(count: 31), signingKey: Data(count: 32))
        #expect(throws: WireError.invalidField("noiseKey")) { try AnnouncePayload.decode(bad.encoded()) }
    }

    @Test func framerSplitsAndReassemblesOutOfOrder() {
        let frame = Data((0..<1000).map { UInt8($0 % 251) })
        let chunks = LinkFramer.chunks(for: frame, frameID: 7, mtu: 100)
        #expect(chunks.count == 11)
        #expect(chunks.allSatisfy { $0.count <= 100 })

        var reassembler = FrameReassembler()
        var result: Data?
        for chunk in chunks.reversed() {
            result = reassembler.accept(chunk) ?? result
        }
        #expect(result == frame)
    }

    @Test func framerPassesSingleChunkFramesStraightThrough() {
        var reassembler = FrameReassembler()
        let chunks = LinkFramer.chunks(for: Data([1, 2, 3]), frameID: 1, mtu: 185)
        #expect(chunks.count == 1)
        #expect(reassembler.accept(chunks[0]) == Data([1, 2, 3]))
    }

    @Test func reassemblerDropsStalePartials() {
        let frame = Data(repeating: 5, count: 300)
        let chunks = LinkFramer.chunks(for: frame, frameID: 3, mtu: 104)
        var reassembler = FrameReassembler(timeout: 1)
        let start = Date()
        #expect(reassembler.accept(chunks[0], now: start) == nil)
        #expect(reassembler.accept(chunks[1], now: start.addingTimeInterval(5)) == nil)
        // The first chunk expired, so even the last chunk cannot complete the frame.
        #expect(reassembler.accept(chunks[2], now: start.addingTimeInterval(5)) == nil)
    }
}
