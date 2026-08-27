import AppKit
import Foundation
import UserNotifications
import CoolDownloadCore

@MainActor
final class NotificationController {
    static let shared = NotificationController()
    private var activeCustomSounds: [NSSound] = []
    private var previewSound: NSSound?

    private init() {}

    func notifyCompletion(record: DownloadRecord, soundEnabled: Bool, soundPath: String? = nil) {
        notify(
            title: "下载完成",
            body: record.name,
            identifier: "com.cooldownloadmanager.completed.\(record.id).\(record.revision)",
            soundEnabled: soundEnabled,
            soundPath: soundPath
        )
    }

    func notifyFailure(record: DownloadRecord, soundEnabled: Bool, soundPath: String? = nil) {
        notify(
            title: "下载失败",
            body: record.error.map { "\(record.name)：\($0)" } ?? record.name,
            identifier: "com.cooldownloadmanager.failed.\(record.id).\(record.revision)",
            soundEnabled: soundEnabled,
            soundPath: soundPath
        )
    }

    func preview(soundPath: String?) {
        previewSound?.stop()
        previewSound = nil

        guard let sound = sound(at: soundPath), sound.play() else {
            NSSound.beep()
            return
        }

        previewSound = sound
        releasePreviewSoundAfterPlayback(sound)
    }

    private func notify(
        title: String,
        body: String,
        identifier: String,
        soundEnabled: Bool,
        soundPath: String?
    ) {
        let didPlayCustomSound = soundEnabled && playCustomSound(at: soundPath)
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
                // UserNotifications only resolves named sounds shipped inside
                // an app bundle. A selected local file is played through
                // AppKit; otherwise the system notification sound remains the
                // dependable fallback.
                content.sound = didPlayCustomSound ? nil : .default
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

    private func playCustomSound(at soundPath: String?) -> Bool {
        guard let sound = sound(at: soundPath), sound.play() else {
            return false
        }

        activeCustomSounds.append(sound)
        let lifetime = min(max(sound.duration + 0.5, 1), 600)
        Task { @MainActor [weak self, weak sound] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard let sound else { return }
            self?.activeCustomSounds.removeAll { $0 === sound }
        }
        return true
    }

    private func sound(at soundPath: String?) -> NSSound? {
        guard let soundPath,
              !soundPath.isEmpty,
              FileManager.default.fileExists(atPath: soundPath) else {
            return nil
        }
        return NSSound(contentsOf: URL(fileURLWithPath: soundPath), byReference: false)
    }

    private func releasePreviewSoundAfterPlayback(_ sound: NSSound) {
        let lifetime = min(max(sound.duration + 0.5, 1), 600)
        Task { @MainActor [weak self, weak sound] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard let self, let sound, self.previewSound === sound else { return }
            self.previewSound = nil
        }
    }
}
