import AppKit
import SwiftUI
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("主题")
struct ThemeTests {
    @Test("新安装和恢复默认使用跟随系统")
    func defaultsFollowSystem() {
        #expect(AppSettingsModel.defaults(home: URL(fileURLWithPath: "/tmp")).theme == "system")
    }

    @Test("主题解析在切换系统模式时清除固定外观")
    func resolvesThemeModes() {
        #expect(AppTheme("SYSTEM") == .system)
        #expect(AppTheme("unknown") == .system)
        #expect(AppTheme("dark").preferredColorScheme == .dark)
        #expect(AppTheme("light").preferredColorScheme == .light)
        #expect(AppTheme("system").preferredColorScheme == nil)
        #expect(AppTheme("system").windowAppearance == nil)
        #expect(AppTheme("dark").windowAppearance?.name == .darkAqua)
    }
}
