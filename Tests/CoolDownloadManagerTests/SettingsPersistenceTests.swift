import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("设置持久化")
struct SettingsPersistenceTests {
    @Test("下载核心不可用时仍保存轻量设置")
    @MainActor
    func savesPreferencesWhenCoreIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-download-settings-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("Caches", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockedDatabase = try MetadataDatabase(rootURL: root)
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
}
