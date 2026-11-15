import Foundation
import LetterboxDomain

/// What a lock-screen alert says. The lock screen can be read without unlocking the
/// phone, so by default an alert says only that something arrived: no sender, no text.
public enum NotificationText {
    /// A stable name for a conversation, so its alert replaces the previous one.
    public static func conversation(_ channel: ChannelID) -> String {
        switch channel {
        case .mesh: "nearby"
        case let .location(geohash): "location:\(geohash)"
        case let .direct(fingerprint): "direct:\(fingerprint.hex)"
        }
    }

    /// - Parameters:
    ///   - count: Messages waiting in this conversation since the user last looked.
    ///   - showText: The user chose to show names and text on the lock screen.
    public static func alert(for message: ChatMessage, count: Int, showText: Bool) -> MessageAlert {
        let isPrivate: Bool = if case .direct = message.channel { true } else { false }
        let key = conversation(message.channel)
        guard showText else {
            let body = switch (isPrivate, count > 1) {
            case (true, false): "New private message"
            case (true, true): "\(count) new private messages"
            case (false, false): "New message in #nearby"
            case (false, true): "\(count) new messages in #nearby"
            }
            return MessageAlert(conversation: key, title: "HelloLetter", body: body)
        }
        let title = isPrivate ? message.senderName : "\(message.senderName) in #nearby"
        let more = count > 1 ? " (+\(count - 1) more)" : ""
        return MessageAlert(conversation: key, title: title, body: message.text + more)
    }
}
