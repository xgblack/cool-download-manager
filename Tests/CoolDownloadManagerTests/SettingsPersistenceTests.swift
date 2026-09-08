import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("设置持久化")
struct SettingsPersistenceTests {
    @Test("new HTTP settings require authentication and legacy anonymous settings require explicit acceptance")
    func httpAuthenticationMigration() async throws {
        #expect(AppSettingsModel.defaults().apiAuthEnabled)
        let root = URL(fileURLWithPath: "/tmp/cdm-auth-\(UUID().uuidString)")
        let store = try SettingsStore(dataRoot: root)
        store.defaults.defaults.set(false, forKey: "apiAuthEnabled")
        store.defaults.defaults.set(true, forKey: "apiEnabled")
        let legacy = try await store.load()
        #expect(legacy.apiEnabled)
        #expect(!legacy.apiAuthEnabled)
        #expect(!legacy.apiAnonymousAccessConfirmed)
        #expect(legacy.httpIntegrationConfigurationError != nil)
        var confirmed = legacy
        confirmed.apiAnonymousAccessConfirmed = true
        _ = try await store.save(confirmed)
        let reopened = try SettingsStore(dataRoot: root)
        #expect(try await reopened.load().httpIntegrationConfigurationError == nil)
        var emptyKey = AppSettingsModel.defaults()
        emptyKey.apiAuthKey = "  "
        #expect(emptyKey.httpIntegrationConfigurationError != nil)
        await #expect(throws: (any Error).self) { _ = try await store.save(emptyKey) }
    }

    @Test("下载核心不可用时仍保存轻量设置")
    @MainActor
    func savesPreferencesWhenCoreIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-download-settings-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("Caches", isDirectory: true)
        var lockedDatabase: MetadataDatabase?
        defer {
            lockedDatabase = nil
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockedDatabase = try MetadataDatabase(rootURL: root)
        let store = AppStore(dataRoot: root, cacheRoot: cacheRoot)
        let initializationError = try #require(store.errorMessage)

        var updated = store.settings
        updated.theme = "dark"
        try await store.saveSettings(updated)

        #expect(store.settings == updated)
        #expect(store.errorMessage == initializationError)
        let persisted = try await SettingsStore(dataRoot: root).load()
        #expect(persisted.theme == "dark")
        withExtendedLifetime(lockedDatabase) {}
    }

    @Test("设置初始化错误不会被重复包装")
    @MainActor
    func reportsSettingsInitializationErrorOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-download-settings-error-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("Caches", isDirectory: true)
        var lockedDatabase: MetadataDatabase?
        defer {
            lockedDatabase = nil
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockedDatabase = try MetadataDatabase(rootURL: root)
        let expected = SettingsStoreError.writeFailed(
            root.appendingPathComponent("appSettings.json"),
            "无法创建 UserDefaults 存储"
        )
        let store = AppStore(
            dataRoot: root,
            cacheRoot: cacheRoot,
            settingsStoreFactory: { _ in throw expected }
        )

        do {
            try await store.saveSettings(store.settings)
            Issue.record("设置存储初始化失败后不应报告保存成功")
        } catch let error as SettingsStoreError {
            #expect(error == expected)
            #expect(error.localizedDescription == "无法保存设置 \(root.path)/appSettings.json：无法创建 UserDefaults 存储")
        }
        withExtendedLifetime(lockedDatabase) {}
    }
}
