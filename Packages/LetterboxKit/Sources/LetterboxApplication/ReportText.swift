import Foundation
import LetterboxDomain

/// The email a user can send to report a message. Letterbox has no server, so a report
/// goes by email, only when the user chooses to send it; Mail sends it once there's
/// signal. It carries the reported message and who sent it, never anything about the
/// person reporting.
public enum ReportText {
    public static func subject(for message: ChatMessage) -> String {
        "HelloLetter report: message from \(message.senderName)"
    }

    public static func body(for message: ChatMessage, appVersion: String) -> String {
        let place = switch message.channel {
        case .mesh: "#nearby"
        case let .location(geohash): "location channel #\(geohash)"
        case .direct: "a private message"
        }
        return """
        I'm reporting this message in HelloLetter.

        From: \(message.senderName)
        Sender's key: \(message.senderKey)
        Where: \(place)
        Sent: \(ISO8601DateFormatter().string(from: message.timestamp))

        Message:
        \(message.text)

        (Optional: tell us what's wrong.)

        HelloLetter \(appVersion)
        """
    }

    /// A `mailto:` link, or nil when no support address is configured.
    public static func mailURL(to address: String?, for message: ChatMessage, appVersion: String) -> URL? {
        guard let address, SupportContact.isValidEmail(address) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject(for: message)),
            URLQueryItem(name: "body", value: body(for: message, appVersion: appVersion)),
        ]
        return components.url
    }
}

/// Who to contact about Letterbox. The address is set per build (from the publisher's
/// own domain, configured outside the repository), so nothing personal is committed.
public enum SupportContact {
    public static let website = URL(string: "https://github.com/coder-RT/letterbox")!
    /// docs/privacy-policy.md and docs/support.md, published with GitHub Pages.
    public static let privacyPolicy = URL(string: "https://coder-rt.github.io/letterbox/privacy-policy")!
    public static let questions = URL(string: "https://coder-rt.github.io/letterbox/support")!

    /// Accepts only something that looks like an email address; an unset build setting
    /// (empty, or the literal `$(…)`) counts as no address.
    public static func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains("$"), !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
    }

    public static func address(from raw: String?) -> String? {
        guard let raw, isValidEmail(raw) else { return nil }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}
