import Foundation

/// A settings-window draft. Sparkle owns the persisted preferences and schedule.
struct AppUpdateSettings: Equatable {
    var automaticallyChecksForUpdates = true
    var checkInterval: TimeInterval = 24 * 3_600
    var automaticallyDownloadsUpdates = true

    static let defaults = AppUpdateSettings()
    static let intervalOptions: [TimeInterval] = [6, 12, 24, 48, 168].map { $0 * 3_600 }

    var allowsAutomaticDownload: Bool {
        automaticallyChecksForUpdates && automaticallyDownloadsUpdates
    }

    func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard automaticallyChecksForUpdates else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    static func intervalTitle(_ seconds: TimeInterval) -> String {
        if seconds == 7 * 24 * 3_600 { return "7 天" }
        if seconds == 24 * 3_600 { return "24 小时（默认）" }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600)) 小时" }
        return "自定义（\(Int(seconds)) 秒）"
    }
}
