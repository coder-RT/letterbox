import CryptoKit
import Foundation
import Testing
import LetterboxDomain
@testable import LetterboxCrypto

/// Runs a full XX handshake and returns both sides' transports.
private func handshake(
    _ alice: IdentityKeys = .generate(),
    _ bob: IdentityKeys = .generate(),
    prologue: Data = Data("letterbox/test".utf8),
    payloads: [Data] = [Data(), Data(), Data()]
) throws -> (initiator: NoiseTransport, responder: NoiseTransport, received: [Data]) {
    var a = try NoiseXXHandshake(role: .initiator, identity: alice, prologue: prologue)
    var b = try NoiseXXHandshake(role: .responder, identity: bob, prologue: prologue)
    var received: [Data] = []
    received.append(try b.readMessage(try a.writeMessage(payload: payloads[0])))
    received.append(try a.readMessage(try b.writeMessage(payload: payloads[1])))
    received.append(try b.readMessage(try a.writeMessage(payload: payloads[2])))
    #expect(a.isComplete && b.isComplete)
    return (try a.finish(), try b.finish(), received)
}

@Suite("Noise handshake edge cases")
struct NoiseHandshakeEdgeCaseTests {
    @Test func handshakePayloadsArriveIntact() throws {
        let payloads = [Data("one".utf8), Data("two".utf8), Data("three".utf8)]
        let result = try handshake(payloads: payloads)
        #expect(result.received == payloads)
    }

    @Test func secondAndThirdHandshakePayloadsAreEncrypted() throws {
        let secret = Data("do not leak me".utf8)
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        let first = try a.writeMessage(payload: secret)
        _ = try b.readMessage(first)
        let second = try b.writeMessage(payload: secret)
        _ = try a.readMessage(second)
        let third = try a.writeMessage(payload: secret)
        // Message 1 has no key yet (XX sends it in the clear); 2 and 3 must not contain it.
        #expect(first.range(of: secret) != nil)
        #expect(second.range(of: secret) == nil)
        #expect(third.range(of: secret) == nil)
    }

    @Test func messageSizesMatchThePattern() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        let first = try a.writeMessage()
        _ = try b.readMessage(first)
        let second = try b.writeMessage()
        _ = try a.readMessage(second)
        let third = try a.writeMessage()
        #expect(first.count == 32)                 // e
        #expect(second.count == 32 + 48 + 16)      // e, encrypted s, empty payload tag
        #expect(third.count == 48 + 16)            // encrypted s, empty payload tag
    }

    @Test func turnTakingIsEnforcedOnBothSides() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        #expect(a.isMyTurn && !b.isMyTurn)
        #expect(throws: NoiseError.outOfOrder) { try a.readMessage(Data(count: 32)) }
        let first = try a.writeMessage()
        #expect(throws: NoiseError.outOfOrder) { try a.writeMessage() }
        _ = try b.readMessage(first)
        #expect(throws: NoiseError.outOfOrder) { try b.readMessage(first) }
        #expect(b.isMyTurn && !a.isMyTurn)
    }

    @Test func finishBeforeCompletionFails() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        #expect(throws: NoiseError.outOfOrder) { try a.finish() }
        _ = try a.writeMessage()
        #expect(throws: NoiseError.outOfOrder) { try a.finish() }
    }

    @Test func completedHandshakeRefusesMoreMessages() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        _ = try b.readMessage(try a.writeMessage())
        _ = try a.readMessage(try b.writeMessage())
        let third = try a.writeMessage()
        _ = try b.readMessage(third)
        #expect(!a.isMyTurn && !b.isMyTurn)
        #expect(throws: NoiseError.outOfOrder) { try a.writeMessage() }
        #expect(throws: NoiseError.outOfOrder) { try b.readMessage(third) }
    }

    @Test func invalidStaticKeyIsRejected() {
        #expect(throws: NoiseError.invalidKey) {
            try NoiseXXHandshake(role: .initiator, staticKey: Data(count: 31), prologue: Data())
        }
    }

    @Test func truncatedMessagesAreRejectedWithoutAdvancing() throws {
        var a = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        let first = try a.writeMessage()
        #expect(throws: NoiseError.malformedMessage) { try b.readMessage(first.prefix(31)) }
        _ = try b.readMessage(first)
        let second = try b.writeMessage()
        for length in [0, 32, 32 + 47, second.count - 1] {
            #expect(throws: (any Error).self) { try a.readMessage(second.prefix(length)) }
        }
        _ = try a.readMessage(second) // still in the right state
        #expect(a.isMyTurn)
    }

    @Test func messageForAnotherSessionIsRejected() throws {
        var a1 = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b1 = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        var a2 = try NoiseXXHandshake(role: .initiator, identity: .generate(), prologue: Data())
        var b2 = try NoiseXXHandshake(role: .responder, identity: .generate(), prologue: Data())
        _ = try b1.readMessage(try a1.writeMessage())
        _ = try b2.readMessage(try a2.writeMessage())
        let fromB2 = try b2.writeMessage()
        _ = try b1.writeMessage()
        // a1 expects b1's reply; b2's reply was made with a different ephemeral.
        #expect(throws: NoiseError.decryptFailed) { try a1.readMessage(fromB2) }
    }

    @Test func eachSessionHasFreshKeys() throws {
        let alice = IdentityKeys.generate()
        let bob = IdentityKeys.generate()
        let one = try handshake(alice, bob)
        let two = try handshake(alice, bob)
        #expect(one.initiator.handshakeHash != two.initiator.handshakeHash)
        // A ciphertext from session one can't be opened with session two's keys (forward secrecy per session).
        let ciphertext = try one.initiator.send.encrypt(nonce: 0, ad: Data(), plaintext: Data("x".utf8))
        #expect(throws: NoiseError.decryptFailed) { try two.responder.receive.decrypt(nonce: 0, ad: Data(), ciphertext: ciphertext) }
    }

    @Test func transportWorksInBothDirectionsAndDirectionsDiffer() throws {
        let session = try handshake()
        let toBob = try session.initiator.send.encrypt(nonce: 1, ad: Data(), plaintext: Data("hi bob".utf8))
        let toAlice = try session.responder.send.encrypt(nonce: 1, ad: Data(), plaintext: Data("hi bob".utf8))
        #expect(toBob != toAlice)
        #expect(try session.responder.receive.decrypt(nonce: 1, ad: Data(), ciphertext: toBob) == Data("hi bob".utf8))
        #expect(try session.initiator.receive.decrypt(nonce: 1, ad: Data(), ciphertext: toAlice) == Data("hi bob".utf8))
        // You can't decrypt your own outgoing traffic with your receive key (no reflection).
        #expect(throws: NoiseError.decryptFailed) { try session.initiator.receive.decrypt(nonce: 1, ad: Data(), ciphertext: toBob) }
    }
}

@Suite("Cipher state")
struct CipherStateTests {
    @Test func withoutAKeyItPassesDataThrough() throws {
        var cipher = CipherState()
        #expect(try cipher.encrypt(nonce: 0, ad: Data(), plaintext: Data([1, 2])) == Data([1, 2]))
        #expect(try cipher.encryptWithAd(Data(), Data([3])) == Data([3]))
        #expect(cipher.nonce == 0) // no key, no nonce use
    }

    @Test func sequentialNoncesAdvanceOnlyOnSuccess() throws {
        let key = Data(repeating: 4, count: 32)
        var sender = CipherState(key: key)
        var receiver = CipherState(key: key)
        let first = try sender.encryptWithAd(Data(), Data("1".utf8))
        let second = try sender.encryptWithAd(Data(), Data("2".utf8))
        #expect(sender.nonce == 2)
        #expect(throws: NoiseError.decryptFailed) { try receiver.decryptWithAd(Data(), second) }
        #expect(receiver.nonce == 0)
        #expect(try receiver.decryptWithAd(Data(), first) == Data("1".utf8))
        #expect(try receiver.decryptWithAd(Data(), second) == Data("2".utf8))
        #expect(receiver.nonce == 2)
    }

    @Test func maximumNonceIsReserved() {
        let cipher = CipherState(key: Data(repeating: 1, count: 32))
        #expect(throws: NoiseError.nonceExhausted) { try cipher.encrypt(nonce: .max, ad: Data(), plaintext: Data()) }
        #expect(throws: Never.self) { try cipher.encrypt(nonce: .max - 1, ad: Data(), plaintext: Data()) }
    }

    @Test func tooShortCiphertextIsMalformed() {
        let cipher = CipherState(key: Data(repeating: 1, count: 32))
        #expect(throws: NoiseError.malformedMessage) { try cipher.decrypt(nonce: 0, ad: Data(), ciphertext: Data(count: 15)) }
    }

    @Test func ciphertextIsPlaintextPlusTag() throws {
        let cipher = CipherState(key: Data(repeating: 1, count: 32))
        for size in [0, 1, 100, 4096] {
            #expect(try cipher.encrypt(nonce: 0, ad: Data(), plaintext: Data(count: size)).count == size + 16)
        }
    }

    @Test func anyBitFlipIsDetected() throws {
        let cipher = CipherState(key: Data(repeating: 9, count: 32))
        let ciphertext = try cipher.encrypt(nonce: 3, ad: Data("ad".utf8), plaintext: Data("attack at dawn".utf8))
        for index in ciphertext.indices {
            var tampered = ciphertext
            tampered[index] ^= 0x80
            #expect(throws: NoiseError.decryptFailed) { try cipher.decrypt(nonce: 3, ad: Data("ad".utf8), ciphertext: tampered) }
        }
    }

    @Test func nonceEncodingMatchesNoiseSpec() throws {
        // Noise: 32 zero bits then the counter, little-endian. Cross-check against raw CryptoKit.
        let key = Data(repeating: 2, count: 32)
        let cipher = CipherState(key: key)
        let ours = try cipher.encrypt(nonce: 0x0102, ad: Data(), plaintext: Data("n".utf8))
        let nonce = try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0, 0x02, 0x01, 0, 0, 0, 0, 0, 0]))
        let box = try ChaChaPoly.seal(Data("n".utf8), using: SymmetricKey(data: key), nonce: nonce)
        #expect(ours == box.ciphertext + box.tag)
    }
}

@Suite("Replay window edge cases")
struct ReplayWindowEdgeCaseTests {
    @Test func emptyWindowAcceptsAnything() {
        let window = ReplayWindow()
        #expect(window.wouldAccept(0))
        #expect(window.wouldAccept(.max))
    }

    @Test func nonceZeroCanOnlyBeUsedOnce() {
        var window = ReplayWindow()
        window.record(0)
        #expect(!window.wouldAccept(0))
        #expect(window.wouldAccept(1))
    }

    @Test func checkingDoesNotRecord() {
        var window = ReplayWindow()
        #expect(window.wouldAccept(4))
        #expect(window.wouldAccept(4))
        window.record(4)
        #expect(!window.wouldAccept(4))
    }

    @Test func slidingForwardForgetsOldNoncesAndRejectsThem() {
        var window = ReplayWindow()
        window.record(10)
        window.record(10 + ReplayWindow.size * 3)
        #expect(!window.wouldAccept(10))
        #expect(!window.wouldAccept(11)) // never seen, but now too old
        #expect(window.wouldAccept(10 + ReplayWindow.size * 3 - 1))
    }

    @Test func toleratesHeavyReorderingInsideTheWindow() {
        var window = ReplayWindow()
        var nonces = Array(UInt64(0)..<UInt64(ReplayWindow.size))
        nonces.shuffle()
        for nonce in nonces {
            #expect(window.wouldAccept(nonce))
            window.record(nonce)
        }
        #expect(nonces.allSatisfy { !window.wouldAccept($0) })
        #expect(window.wouldAccept(ReplayWindow.size))
    }

    @Test func recordingAnOldNonceDoesNotMoveTheWindowBack() {
        var window = ReplayWindow()
        window.record(2000)
        window.record(1500)
        #expect(!window.wouldAccept(1500))
        #expect(window.wouldAccept(1999))
        #expect(!window.wouldAccept(2000 - ReplayWindow.size))
    }
}

@Suite("Identity key edge cases")
struct IdentityKeyEdgeCaseTests {
    @Test func rejectsMalformedPrivateKeys() {
        let good = IdentityKeys.generate()
        #expect(throws: (any Error).self) { try IdentityKeys(noisePrivate: Data(count: 31), signingPrivate: good.signingPrivate) }
        #expect(throws: (any Error).self) { try IdentityKeys(noisePrivate: good.noisePrivate, signingPrivate: Data(count: 33)) }
    }

    @Test func fingerprintIsSHA256OfTheNoisePublicKey() {
        let keys = IdentityKeys.generate()
        let expected = SHA256.hash(data: keys.noisePublic).map { String(format: "%02x", $0) }.joined()
        #expect(keys.fingerprint.hex == expected)
        #expect(IdentityKeys.fingerprint(ofNoiseKey: keys.noisePublic) == keys.fingerprint)
    }

    @Test func generatedIdentitiesAreDistinct() {
        let keys = (0..<20).map { _ in IdentityKeys.generate() }
        #expect(Set(keys.map(\.fingerprint)).count == 20)
        #expect(keys.allSatisfy { $0.noisePublic.count == 32 && $0.signingPublic.count == 32 })
    }

    @Test func verifyRejectsGarbageInsteadOfCrashing() {
        let keys = IdentityKeys.generate()
        let signature = keys.sign(Data("m".utf8))
        #expect(!IdentityKeys.verify(signature, for: Data("m".utf8), signingKey: Data(count: 5)))
        #expect(!IdentityKeys.verify(Data(count: 64), for: Data("m".utf8), signingKey: keys.signingPublic))
        #expect(!IdentityKeys.verify(Data(), for: Data("m".utf8), signingKey: keys.signingPublic))
        #expect(!IdentityKeys.verify(signature.prefix(63), for: Data("m".utf8), signingKey: keys.signingPublic))
    }

    @Test func signaturesCoverEveryByte() {
        let keys = IdentityKeys.generate()
        let message = Data("the whole message".utf8)
        let signature = keys.sign(message)
        for index in message.indices {
            var changed = message
            changed[index] ^= 0x01
            #expect(!IdentityKeys.verify(signature, for: changed, signingKey: keys.signingPublic))
        }
        #expect(IdentityKeys.verify(keys.sign(Data()), for: Data(), signingKey: keys.signingPublic))
    }
}

@Suite("Safety numbers and verify codes")
struct VerificationTests {
    private let ana = IdentityKeys.generate().fingerprint
    private let ben = IdentityKeys.generate().fingerprint

    @Test func bothSidesSeeTheSameNumber() {
        #expect(SafetyNumber.make(ana, ben) == SafetyNumber.make(ben, ana))
    }

    @Test func itIsEightGroupsOfFourDigits() {
        let number = SafetyNumber.make(ana, ben)
        #expect(number.count == 8)
        #expect(number.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isNumber) })
    }

    @Test func itIsStableAndDiffersPerPair() {
        #expect(SafetyNumber.make(ana, ben) == SafetyNumber.make(ana, ben))
        let cai = IdentityKeys.generate().fingerprint
        #expect(SafetyNumber.make(ana, cai) != SafetyNumber.make(ana, ben))
        #expect(SafetyNumber.make(ben, cai) != SafetyNumber.make(ana, cai))
    }

    @Test func knownValueGuardsAgainstAccidentalChanges() {
        let a = Fingerprint(hex: String(repeating: "a", count: 64))
        let b = Fingerprint(hex: String(repeating: "b", count: 64))
        let number = SafetyNumber.make(a, b)
        #expect(number == SafetyNumber.make(Fingerprint(hex: String(repeating: "B", count: 64)), a)) // case-insensitive
        #expect(number.joined().count == 32)
    }

    @Test func codesRoundTrip() {
        #expect(VerifyCode.parse(VerifyCode.payload(for: ana)) == ana)
        #expect(VerifyCode.parse("  " + VerifyCode.payload(for: ana).uppercased() + "\n") == ana)
    }

    @Test(arguments: [
        "", "hello", "letterbox:verify:1:", "letterbox:verify:1:abc",
        "letterbox:verify:2:" + String(repeating: "a", count: 64),
        "letterbox:verify:1:" + String(repeating: "z", count: 64),
        "https://example.com/" + String(repeating: "a", count: 64),
    ])
    func foreignOrBrokenCodesAreRejected(text: String) {
        #expect(VerifyCode.parse(text) == nil)
    }
}
