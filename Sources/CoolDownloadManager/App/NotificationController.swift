import Foundation
import UserNotifications
import CoolDownloadCore

@MainActor
final class NotificationController {
    static let shared = NotificationController()

    private init() {}

    func notifyCompletion(record: DownloadRecord, soundEnabled: Bool) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = "下载完成"
            content.body = record.name
            if soundEnabled {
                content.sound = .default
            }
            let request = UNNotificationRequest(
                identifier: "com.abdownloadmanager.completed.\(record.id).\(record.revision)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                // Notification permission or delivery failure must not affect
                // the completed download itself.
            }
        }
    }
}
