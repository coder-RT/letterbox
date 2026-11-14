import CryptoKit
import Foundation
import LetterboxDomain

/// A number two people compare in person to make sure they have each other's real keys,
/// not an impostor's. Both phones show the same digits, whoever computes it.
///
/// 8 groups of 4 digits: easy to read aloud, and VoiceOver reads it group by group.
public enum SafetyNumber {
    public static let groups = 8

    public static func make(_ a: Fingerprint, _ b: Fingerprint) -> [String] {
        let (first, second) = a.hex <= b.hex ? (a.hex, b.hex) : (b.hex, a.hex)
        let digest = [UInt8](SHA256.hash(data: Data("letterbox/safety/1/\(first)/\(second)".utf8)))
        return (0..<groups).map { index in
            let chunk = digest[(index * 4)..<(index * 4 + 4)]
            let value = chunk.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10_000
            return String(format: "%04u", value)
        }
    }
}

/// What a Letterbox QR code holds: just the owner's fingerprint, versioned.
public enum VerifyCode {
    static let prefix = "letterbox:verify:1:"

    public static func payload(for fingerprint: Fingerprint) -> String {
        prefix + fingerprint.hex
    }

    /// The fingerprint in a scanned code, or nil if it isn't a Letterbox code.
    public static func parse(_ text: String) -> Fingerprint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let hex = String(trimmed.dropFirst(prefix.count)).lowercased()
        guard hex.count == 64, Data(hexString: hex) != nil else { return nil }
        return Fingerprint(hex: hex)
    }
}
