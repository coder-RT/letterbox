import CryptoKit
import Foundation
import Testing
@testable import LetterboxCrypto

/// The X pattern written out step by step with raw CryptoKit, straight from the Noise
/// spec, as an independent check on `NoiseXSeal` (no published X vectors are bundled).
private func referenceSealX(
    plaintext: Data, recipientStatic: Data, senderStatic: Curve25519.KeyAgreement.PrivateKey,
    ephemeral: Curve25519.KeyAgreement.PrivateKey, prologue: Data
) throws -> Data {
    func sha(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    func hmac(_ key: Data, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
    func hkdf(_ ck: Data, _ input: Data) -> (Data, Data) {
        let temp = hmac(ck, input)
        let one = hmac(temp, Data([1]))
        return (one, hmac(temp, one + Data([2])))
    }
    func dh(_ key: Curve25519.KeyAgreement.PrivateKey, _ pub: Data) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: pub)).withUnsafeBytes { Data($0) }
    }
    func encrypt(_ key: Data, ad: Data, _ plaintext: Data) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 12)) // counter 0 after every MixKey
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: ad)
        return box.ciphertext + box.tag
    }

    let name = Data("Noise_X_25519_ChaChaPoly_SHA256".utf8)
    var h = name + Data(count: 32 - name.count)
    var ck = h
    h = sha(h + prologue)
    h = sha(h + recipientStatic)
    let e = ephemeral.publicKey.rawRepresentation
    h = sha(h + e)
    var key: Data
    (ck, key) = hkdf(ck, try dh(ephemeral, recipientStatic))
    let encryptedStatic = try encrypt(key, ad: h, senderStatic.publicKey.rawRepresentation)
    h = sha(h + encryptedStatic)
    (ck, key) = hkdf(ck, try dh(senderStatic, recipientStatic))
    let encryptedPayload = try encrypt(key, ad: h, plaintext)
    return e + encryptedStatic + encryptedPayload
}

@Suite("Noise X seal")
struct NoiseXSealTests {
    private let prologue = Data("letterbox/courier/test".utf8)

    @Test func matchesAStepByStepReferenceOfTheSpec() throws {
        let sender = IdentityKeys.generate()
        let recipient = IdentityKeys.generate()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data("meet at the hut".utf8)
        let ours = try NoiseXSeal.seal(plaintext, to: recipient.noisePublic, from: sender, prologue: prologue,
                                       ephemeral: ephemeral.rawRepresentation)
        let reference = try referenceSealX(
            plaintext: plaintext, recipientStatic: recipient.noisePublic,
            senderStatic: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: sender.noisePrivate),
            ephemeral: ephemeral, prologue: prologue
        )
        #expect(ours == reference)
    }

    @Test func recipientOpensItAndLearnsTheSender() throws {
        let sender = IdentityKeys.generate()
        let recipient = IdentityKeys.generate()
        let sealed = try NoiseXSeal.seal(Data("hello".utf8), to: recipient.noisePublic, from: sender, prologue: prologue)
        let opened = try NoiseXSeal.open(sealed, with: recipient, prologue: prologue)
        #expect(opened.plaintext == Data("hello".utf8))
        #expect(opened.senderStatic == sender.noisePublic)
        #expect(sealed.count == 5 + NoiseXSeal.overhead)
    }

    @Test func nobodyElseCanOpenIt() throws {
        let sealed = try NoiseXSeal.seal(Data("x".utf8), to: IdentityKeys.generate().noisePublic, from: .generate(), prologue: prologue)
        #expect(throws: NoiseError.decryptFailed) { try NoiseXSeal.open(sealed, with: .generate(), prologue: prologue) }
    }

    @Test func plaintextAndSenderKeyAreNotVisible() throws {
        let sender = IdentityKeys.generate()
        let secret = Data("the plaintext secret".utf8)
        let sealed = try NoiseXSeal.seal(secret, to: IdentityKeys.generate().noisePublic, from: sender, prologue: prologue)
        #expect(sealed.range(of: secret) == nil)
        #expect(sealed.range(of: sender.noisePublic) == nil)
    }

    @Test func prologueMustMatch() throws {
        let recipient = IdentityKeys.generate()
        let sealed = try NoiseXSeal.seal(Data("x".utf8), to: recipient.noisePublic, from: .generate(), prologue: prologue)
        #expect(throws: NoiseError.decryptFailed) { try NoiseXSeal.open(sealed, with: recipient, prologue: Data("other".utf8)) }
    }

    @Test func everyByteIsAuthenticated() throws {
        let recipient = IdentityKeys.generate()
        let sealed = try NoiseXSeal.seal(Data("tamper me".utf8), to: recipient.noisePublic, from: .generate(), prologue: prologue)
        for index in sealed.indices {
            var tampered = sealed
            tampered[index] ^= 0x01
            #expect(throws: (any Error).self) { try NoiseXSeal.open(tampered, with: recipient, prologue: prologue) }
        }
    }

    @Test func freshEphemeralEachTime() throws {
        let recipient = IdentityKeys.generate()
        let sender = IdentityKeys.generate()
        let one = try NoiseXSeal.seal(Data("same".utf8), to: recipient.noisePublic, from: sender, prologue: prologue)
        let two = try NoiseXSeal.seal(Data("same".utf8), to: recipient.noisePublic, from: sender, prologue: prologue)
        #expect(one != two)
    }

    @Test func shortOrBadInputIsRejected() throws {
        let recipient = IdentityKeys.generate()
        #expect(throws: NoiseError.malformedMessage) { try NoiseXSeal.open(Data(count: NoiseXSeal.overhead - 1), with: recipient, prologue: prologue) }
        #expect(throws: (any Error).self) { try NoiseXSeal.open(Data(count: NoiseXSeal.overhead), with: recipient, prologue: prologue) }
        #expect(throws: (any Error).self) { try NoiseXSeal.seal(Data(), to: Data(count: 5), from: .generate(), prologue: prologue) }
        #expect(throws: NoiseError.invalidKey) {
            try NoiseXSeal.seal(Data(), to: recipient.noisePublic, from: .generate(), prologue: prologue, ephemeral: Data(count: 3))
        }
    }

    @Test func emptyAndLargePayloadsWork() throws {
        let recipient = IdentityKeys.generate()
        for size in [0, 1, 4000] {
            let plaintext = Data((0..<size).map { UInt8($0 & 0xFF) })
            let sealed = try NoiseXSeal.seal(plaintext, to: recipient.noisePublic, from: .generate(), prologue: prologue)
            #expect(try NoiseXSeal.open(sealed, with: recipient, prologue: prologue).plaintext == plaintext)
        }
    }
}
