import Foundation
import UserNotifications
import CoolDownloadCore

@MainActor
final class NotificationController {
    static let shared = NotificationController()

    private init() {}

    func notifyCompletion(record: DownloadRecord, soundEnabled: Bool, soundName: String? = nil) {
        notify(
            title: "下载完成",
            body: record.name,
            identifier: "com.cooldownloadmanager.completed.\(record.id).\(record.revision)",
            soundEnabled: soundEnabled,
            soundName: soundName
        )
    }

    func notifyFailure(record: DownloadRecord, soundEnabled: Bool, soundName: String? = nil) {
        notify(
            title: "下载失败",
            body: record.error.map { "\(record.name)：\($0)" } ?? record.name,
            identifier: "com.cooldownloadmanager.failed.\(record.id).\(record.revision)",
            soundEnabled: soundEnabled,
            soundName: soundName
        )
    }

    private func notify(
        title: String,
        body: String,
        identifier: String,
        soundEnabled: Bool,
        soundName: String?
    ) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if soundEnabled {
                let trimmedName = soundName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                content.sound = trimmedName.isEmpty
                    ? .default
                    : UNNotificationSound(named: UNNotificationSoundName(rawValue: trimmedName))
            }
            let request = UNNotificationRequest(
                identifier: identifier,
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
