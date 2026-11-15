import Foundation
import LetterboxDomain
import UserNotifications

/// Local notifications for the `MessageNotifier` port. Scheduled on the device itself
/// (no push server, so nothing about you or your messages leaves the phone). Each
/// conversation has one alert, replaced as more messages arrive.
public final class SystemMessageNotifier: MessageNotifier {
    private static let prefix = "letterbox.conversation."

    public init() {}

    public func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func show(_ alert: MessageAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.conversation
        let request = UNNotificationRequest(identifier: Self.prefix + alert.conversation, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public func clear(conversation: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.prefix + conversation])
    }

    public func clearAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }
}
