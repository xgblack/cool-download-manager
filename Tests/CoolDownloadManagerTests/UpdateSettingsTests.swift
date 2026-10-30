import AppKit
import CryptoKit
import Foundation
import Sparkle
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("更新偏好与设置草稿")
@MainActor
struct UpdateSettingsTests {
    @Test("发行默认值与已有偏好读取一致，关闭检查后仍保留下载偏好")
    func sparklePreferencesPersistWithoutOverwritingDefaults() throws {
        let fixture = try bundleFixture()
        let controller = AppUpdateController(bundle: fixture.bundle)
        #expect(controller.settings == .defaults)
        let changed = AppUpdateSettings(automaticallyChecksForUpdates: false,
                                        checkInterval: 48 * 3_600,
                                        automaticallyDownloadsUpdates: true)
        controller.applySettings(changed)
        #expect(controller.settings == changed)
        let reopened = AppUpdateController(bundle: fixture.bundle)
        #expect(reopened.settings == changed)
        #expect(fixture.defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
        #expect(fixture.defaults.double(forKey: "SUScheduledCheckInterval") == 48 * 3_600)
        #expect(fixture.defaults.object(forKey: "SUAutomaticallyUpdate") == nil)
        var enabled = reopened.settings
        enabled.automaticallyChecksForUpdates = true
        reopened.applySettings(enabled)
        #expect(reopened.settings.allowsAutomaticDownload)
        #expect(controller.settings.automaticallyDownloadsUpdates)
    }

    @Test("已有关闭下载的偏好重开和恢复默认都正确持久化")
    func restoresDefaultsAndPreservesExistingChoices() throws {
        let fixture = try bundleFixture()
        fixture.defaults.set(false, forKey: "SUEnableAutomaticChecks")
        fixture.defaults.set(false, forKey: "SUAutomaticallyUpdate")
        fixture.defaults.set(12 * 3_600, forKey: "SUScheduledCheckInterval")
        let controller = AppUpdateController(bundle: fixture.bundle)
        #expect(!controller.settings.automaticallyChecksForUpdates)
        #expect(!controller.settings.automaticallyDownloadsUpdates)
        #expect(controller.settings.checkInterval == 12 * 3_600)
        controller.applySettings(.defaults)
        #expect(AppUpdateController(bundle: fixture.bundle).settings == .defaults)
    }

    @Test("更新设置先编辑草稿，放弃修改和恢复默认不立即写入 Sparkle")
    func draftsSaveDiscardAndReset() throws {
        let fixture = try bundleFixture()
        let controller = AppUpdateController(bundle: fixture.bundle)
        let state = SettingsViewState(model: .defaults(), perHostItems: [], updateSettings: controller.settings)
        state.updateSettings.checkInterval = 6 * 3_600
        state.updateSettings.automaticallyDownloadsUpdates = false
        #expect(state.isDirty)
        #expect(controller.settings == .defaults)
        state.markAllSaved(model: .defaults(), perHostItems: [], updateSettings: controller.settings)
        #expect(!state.isDirty)
        #expect(state.updateSettings == .defaults)
        state.updateSettings.automaticallyChecksForUpdates = false
        controller.applySettings(state.updateSettings)
        state.markUpdateSettingsSaved(controller.settings)
        #expect(!state.isDirty)
        state.resetToDefaults()
        #expect(state.isDirty)
        #expect(state.updateSettings == .defaults)
        #expect(!controller.settings.automaticallyChecksForUpdates)
    }

    @Test("外部更新偏好同步不覆盖未保存字段，并正确更新干净字段")
    func mergesExternalPreferencesIntoDraft() {
        let state = SettingsViewState(model: .defaults(), perHostItems: [])
        state.updateSettings.checkInterval = 6 * 3_600
        let external = AppUpdateSettings(automaticallyChecksForUpdates: false,
                                         checkInterval: 48 * 3_600,
                                         automaticallyDownloadsUpdates: false)
        state.mergeUpdateSettings(external)
        #expect(state.updateSettings.checkInterval == 6 * 3_600)
        #expect(!state.updateSettings.automaticallyChecksForUpdates)
        #expect(!state.updateSettings.automaticallyDownloadsUpdates)
        #expect(state.isDirty)
        state.markUpdateSettingsSaved(external)
        #expect(!state.isDirty)
    }

    @Test("24 小时到期边界、首次检查和关闭检查后的网络恢复")
    func scheduleBoundaries() {
        let now = Date(timeIntervalSince1970: 100_000)
        var settings = AppUpdateSettings.defaults
        #expect(settings.isCheckDue(lastCheck: nil, now: now))
        #expect(!settings.isCheckDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        #expect(settings.isCheckDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(!settings.isCheckDue(lastCheck: now.addingTimeInterval(60), now: now))
        settings.automaticallyChecksForUpdates = false
        #expect(!settings.isCheckDue(lastCheck: nil, now: now))
        #expect(!settings.allowsAutomaticDownload)
        settings.automaticallyChecksForUpdates = true
        settings.automaticallyDownloadsUpdates = false
        #expect(!settings.allowsAutomaticDownload)
    }

    @Test("关闭后台检查会拒绝后台检查但仍允许手动更新路径")
    func disabledBackgroundChecksDoNotBecomeFailures() throws {
        let fixture = try bundleFixture()
        let controller = AppUpdateController(bundle: fixture.bundle)
        var settings = controller.settings
        settings.automaticallyChecksForUpdates = false
        controller.applySettings(settings)
        let updater = makeUpdater(fixture.bundle)
        let backgroundError = #expect(throws: NSError.self) {
            try controller.updater(updater, mayPerform: .updatesInBackground)
        }
        controller.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: backgroundError)
        #expect(controller.state == .unavailable)
        #expect(controller.errorMessage == nil)
        // Manual checks reach the route-refresh path instead of the disabled path.
        let manualError = #expect(throws: NSError.self) {
            try controller.updater(updater, mayPerform: .updates)
        }
        #expect(manualError?.code != backgroundError?.code)
    }

    @Test("关闭自动下载时只提示，点击下载前不请求 ZIP")
    func manualDownloadRequiresExplicitAction() async throws {
        let fixture = try bundleFixture()
        let counter = RequestCounter()
        let router = GitHubUpdateRouter(defaults: fixture.defaults, transport: { _, _ in
            await counter.record()
            throw URLError(.notConnectedToInternet)
        })
        let controller = AppUpdateController(bundle: fixture.bundle, router: router)
        var settings = controller.settings
        settings.automaticallyDownloadsUpdates = false
        controller.applySettings(settings)
        let item = try updateItem()
        let replies = AsyncStream<SPUUserUpdateChoice>.makeStream()
        controller.userDriverFound(item, stage: .notDownloaded) { replies.continuation.yield($0) }
        #expect(controller.state == .available(version: "1.0.20"))
        #expect(await counter.count == 0)
        controller.performAction()
        for await reply in replies.stream {
            #expect(reply == .install)
            break
        }
        #expect(await counter.count == 4)
    }

    @Test("用户取消下载准备后，迟到的测速结果不能开始安装包下载")
    func cancelsExplicitDownloadRouteProbe() async throws {
        let fixture = try bundleFixture()
        let started = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        let router = GitHubUpdateRouter(defaults: fixture.defaults, transport: { _, _ in
            started.continuation.yield(())
            defer { finished.continuation.yield(()) }
            try await Task.sleep(for: .seconds(10))
            throw URLError(.notConnectedToInternet)
        })
        let controller = AppUpdateController(bundle: fixture.bundle, router: router)
        var settings = controller.settings
        settings.automaticallyDownloadsUpdates = false
        controller.applySettings(settings)
        var choices: [SPUUserUpdateChoice] = []
        controller.userDriverFound(try updateItem(), stage: .notDownloaded) { choices.append($0) }
        controller.performAction()
        for await _ in started.stream { break }
        #expect(controller.canCancel)
        controller.cancel()
        for await _ in finished.stream { break }
        controller.updater(makeUpdater(fixture.bundle), didFinishUpdateCycleFor: .updates, error: nil)
        #expect(choices == [.dismiss])
        #expect(controller.state == .available(version: "1.0.20"))
    }

    @Test("停用自动检查后手动发现更新不会被保留的自动下载偏好直接下载")
    func dormantDownloadPreferenceDoesNotStartManualDiscovery() throws {
        let fixture = try bundleFixture()
        let controller = AppUpdateController(bundle: fixture.bundle)
        var settings = controller.settings
        settings.automaticallyChecksForUpdates = false
        controller.applySettings(settings)
        var choices: [SPUUserUpdateChoice] = []
        controller.userDriverFound(try updateItem(), stage: .notDownloaded) { choices.append($0) }
        #expect(choices.isEmpty)
        #expect(controller.state == .available(version: "1.0.20"))
        #expect(controller.settings.automaticallyDownloadsUpdates)
    }

    @Test("测速过程中关闭自动检查会取消后续请求且不污染线路缓存")
    func disablesAutomaticWorkWhileProbing() async throws {
        let fixture = try bundleFixture()
        let started = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        let router = GitHubUpdateRouter(defaults: fixture.defaults, transport: { _, _ in
            started.continuation.yield(())
            defer { finished.continuation.yield(()) }
            try await Task.sleep(for: .seconds(10))
            throw URLError(.notConnectedToInternet)
        })
        let controller = AppUpdateController(bundle: fixture.bundle, router: router)
        let updater = makeUpdater(fixture.bundle)
        let deferred = #expect(throws: NSError.self) {
            try controller.updater(updater, mayPerform: .updatesInBackground)
        }
        controller.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: deferred)
        for await _ in started.stream { break }
        var settings = controller.settings
        settings.automaticallyChecksForUpdates = false
        controller.applySettings(settings)
        for await _ in finished.stream { break }
        #expect(controller.state == .unavailable)
        #expect(fixture.defaults.object(forKey: "updateFeedRouteOrder") == nil)
        #expect(fixture.defaults.object(forKey: "updateArchiveProbeDate") == nil)
    }

    @Test("检查途中关闭自动下载阻止后续自动下载并保留新版本提醒")
    func disablesDownloadWhileLoadingFeed() throws {
        let fixture = try bundleFixture()
        let controller = AppUpdateController(bundle: fixture.bundle)
        let updater = makeUpdater(fixture.bundle)
        #expect(throws: NSError.self) {
            try controller.updater(updater, mayPerform: .updatesInBackground)
        }
        var settings = controller.settings
        settings.automaticallyDownloadsUpdates = false
        controller.applySettings(settings)
        #expect(throws: NSError.self) {
            try controller.updater(updater, shouldProceedWithUpdate: updateItem(), updateCheck: .updatesInBackground)
        }
        #expect(controller.state == .available(version: "1.0.20"))
    }

    @Test("关闭更新开关不会清除已经准备好的更新")
    func disablingSettingsPreservesReadyUpdate() throws {
        let fixture = try bundleFixture()
        let controller = AppUpdateController(bundle: fixture.bundle)
        var installed = false
        controller.readyToInstall(.init(build: "1020", version: "1.0.20")) { installed = true }
        controller.applySettings(.init(automaticallyChecksForUpdates: false,
                                       checkInterval: 24 * 3_600,
                                       automaticallyDownloadsUpdates: false))
        #expect(controller.state == .ready(version: "1.0.20"))
        #expect(!installed)
    }

    private func makeUpdater(_ bundle: Bundle) -> SPUUpdater {
        SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                   userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
    }

    private func updateItem() throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "1020", "sparkle:shortVersionString": "1.0.20",
            "enclosure": ["url": "https://github.com/xgblack/cool-download-manager/releases/download/v1.0.20/CoolDownloadManager-macOS-arm64.zip", "length": "524288"]
        ]))
    }

    private func bundleFixture() throws -> (bundle: Bundle, defaults: UserDefaults) {
        let identifier = "cooldm-update-settings-tests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "更新设置测试", "CFBundleVersion": "1019",
            "SUFeedURL": "https://github.com/xgblack/cool-download-manager/releases/latest/download/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": true,
            "SUAllowsAutomaticUpdates": true, "SUScheduledCheckInterval": 86_400
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return (try #require(Bundle(url: root)), try #require(UserDefaults(suiteName: identifier)))
    }
}

private actor RequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
