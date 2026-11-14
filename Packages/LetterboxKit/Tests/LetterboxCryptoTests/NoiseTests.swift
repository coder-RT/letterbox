import Foundation
import Testing
@testable import LetterboxCrypto

private struct Vector: Decodable {
    struct Message: Decodable {
        let payload: String
        let ciphertext: String
    }

    let protocol_name: String
    let init_prologue: String
    let init_static: String
    let init_ephemeral: String
    let resp_prologue: String
    let resp_static: String
    let resp_ephemeral: String
    let handshake_hash: String?
    let messages: [Message]
}

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func loadVectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(forResource: "NoiseXXVectors", withExtension: "json"))
    return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
}

@Suite("Noise XX")
struct NoiseTests {
    /// Standard Noise conformance vectors (public domain): byte-exact handshake and transport.
    @Test func matchesPublishedVectors() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty)
        for vector in vectors where vector.protocol_name == NoiseXXHandshake.protocolName {
            var initiator = try NoiseXXHandshake(
                role: .initiator, staticKey: hex(vector.init_static),
                prologue: hex(vector.init_prologue), ephemeral: hex(vector.init_ephemeral)
            )
            var responder = try NoiseXXHandshake(
                role: .responder, staticKey: hex(vector.resp_static),
                prologue: hex(vector.resp_prologue), ephemeral: hex(vector.resp_ephemeral)
            )

            var initiatorTransport: NoiseTransport?
            var responderTransport: NoiseTransport?

            for (index, message) in vector.messages.enumerated() {
                let initiatorSends = index.isMultiple(of: 2)
                let payload = hex(message.payload)
                let expected = hex(message.ciphertext)

                if index < 3 {
                    if initiatorSends {
                        #expect(try initiator.writeMessage(payload: payload) == expected, "handshake message \(index)")
                        #expect(try responder.readMessage(expected) == payload)
                    } else {
                        #expect(try responder.writeMessage(payload: payload) == expected, "handshake message \(index)")
                        #expect(try initiator.readMessage(expected) == payload)
                    }
                    if index == 2 {
                        if let hash = vector.handshake_hash { #expect(initiator.handshakeHash == hex(hash)) }
                        #expect(initiator.handshakeHash == responder.handshakeHash)
                        initiatorTransport = try initiator.finish()
                        responderTransport = try responder.finish()
                    }
                } else if initiatorSends {
                    #expect(try initiatorTransport!.send.encryptWithAd(Data(), payload) == expected, "transport \(index)")
                    #expect(try responderTransport!.receive.decryptWithAd(Data(), expected) == payload)
                } else {
                    #expect(try responderTransport!.send.encryptWithAd(Data(), payload) == expected, "transport \(index)")
                    #expect(try initiatorTransport!.receive.decryptWithAd(Data(), expected) == payload)
                }
            }
        }
    }

    @Test func handshakeAuthenticatesBothStaticKeys() throws {
        let alice = IdentityKeys.generate()
        let bob = IdentityKeys.generate()
        var a = try NoiseXXHandshake(role: .initiator, identity: alice, prologue: Data("p".utf8))
        var b = try NoiseXXHandshake(role: .responder, identity: bob, prologue: Data("p".utf8))

        _ = try b.readMessage(try a.writeMessage())
        _ = try a.readMessage(try b.writeMessage())
        _ = try b.readMessage(try a.writeMessage())

        let ta = try a.finish()
        let tb = try b.finish()
        #expect(ta.remoteStaticKey == bob.noisePublic)
        #expect(tb.remoteStaticKey == alice.noisePublic)
        #expect(ta.handshakeHash == tb.handshakeHash)

        let ct = try ta.send.encrypt(nonce: 7, ad: Data("ad".utf8), plaintext: Data("hi".utf8))
        #expect(try tb.receive.decrypt(nonce: 7, ad: Data("ad".utf8), ciphertext: ct) == Data("hi".utf8))
        // Wrong AD or nonce must fail.
        #expect(throws: NoiseError.decryptFailed) { try tb.receive.decrypt(nonce: 7, ad: Data(), ciphertext: ct) }
        #expect(throws: NoiseError.decryptFailed) { try tb.receive.decrypt(nonce: 8, ad: Data("ad".utf8), ciphertext: ct) }
    }

    @Test func mismatchedProloguesFail() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data("one".utf8))
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data("two".utf8))
        _ = try b.readMessage(try a.writeMessage())
        let second = try b.writeMessage()
        #expect(throws: NoiseError.decryptFailed) { try a.readMessage(second) }
    }

    @Test func tamperedHandshakeIsRejectedAndStateKept() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        _ = try b.readMessage(try a.writeMessage())
        var second = try b.writeMessage()
        let good = second
        second[second.count - 1] ^= 0x01
        #expect(throws: (any Error).self) { try a.readMessage(second) }
        // The failed read must not have advanced the handshake.
        _ = try a.readMessage(good)
        #expect(a.isMyTurn)
    }

    @Test func outOfTurnIsRejected() throws {
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        #expect(throws: NoiseError.outOfOrder) { try b.writeMessage() }
    }
}

@Suite("Replay window")
struct ReplayWindowTests {
    @Test func acceptsEachNonceOnceAndToleratesReordering() {
        var window = ReplayWindow()
        for nonce: UInt64 in [5, 3, 9, 4] {
            #expect(window.wouldAccept(nonce))
            window.record(nonce)
        }
        #expect(!window.wouldAccept(3))
        #expect(!window.wouldAccept(9))
        #expect(window.wouldAccept(6))
    }

    @Test func rejectsNoncesBehindTheWindow() {
        var window = ReplayWindow()
        window.record(5000)
        #expect(!window.wouldAccept(5000 - ReplayWindow.size))
        #expect(window.wouldAccept(5000 - ReplayWindow.size + 1))
    }
}

@Suite("Identity keys")
struct IdentityKeyTests {
    @Test func signsAndVerifies() throws {
        let keys = IdentityKeys.generate()
        let sig = keys.sign(Data("hello".utf8))
        #expect(IdentityKeys.verify(sig, for: Data("hello".utf8), signingKey: keys.signingPublic))
        #expect(!IdentityKeys.verify(sig, for: Data("hellp".utf8), signingKey: keys.signingPublic))
        #expect(!IdentityKeys.verify(sig, for: Data("hello".utf8), signingKey: IdentityKeys.generate().signingPublic))
    }

    @Test func roundTripsThroughRawBytes() throws {
        let keys = IdentityKeys.generate()
        let restored = try IdentityKeys(noisePrivate: keys.noisePrivate, signingPrivate: keys.signingPrivate)
        #expect(restored.fingerprint == keys.fingerprint)
        #expect(keys.fingerprint.hex.count == 64)
    }
}
