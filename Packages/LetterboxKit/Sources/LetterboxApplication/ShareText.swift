import Foundation
import LetterboxDomain

/// Text Letterbox hands to the system share sheet (AirDrop, Messages, Mail…) to reach
/// people who don't have the app. Bluetooth messaging needs Letterbox on both phones;
/// AirDrop is the offline way to reach anyone else nearby, and they tap Accept.
public enum ShareText {
    /// Where to get Letterbox. The public repository for now; the App Store link later.
    public static let inviteLink = "https://github.com/coder-RT/letterbox"

    /// A short note asking someone to install Letterbox before going off-grid.
    public static func invite(from nickname: String) -> String {
        let name = Nickname.sanitize(nickname)
        let intro = isPersonal(name) ? "\(name) here. I'm using HelloLetter" : "I'm using HelloLetter"
        return "\(intro) to chat with no internet or signal, over Bluetooth. "
            + "Get it before the trip so we can message each other offline: \(inviteLink)"
    }

    /// A one-way message for someone without Letterbox. Nil when there's nothing to send.
    public static func outside(_ text: String, addInvite: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard addInvite else { return trimmed }
        return trimmed + "\n\n— Sent from HelloLetter. Get it to reply offline: \(inviteLink)"
    }

    /// Random names like "anon4821" say nothing to a friend, so they're left out.
    private static func isPersonal(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.range(of: #"^anon\d{4}$"#, options: .regularExpression) == nil
    }
}
