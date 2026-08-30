import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("Native persistence")
struct StoragePersistenceTests {
    @Test("native paths use system application support and caches directories")
    func nativePathLayout() {
        let support = AppPaths.applicationSupportDirectory()
        let caches = AppPaths.cachesDirectory()
        #expect(support.lastPathComponent == AppPaths.bundleIdentifier)
        #expect(caches.lastPathComponent == AppPaths.bundleIdentifier)
        #expect(AppPaths.metadataStoreURL().deletingLastPathComponent() == support)
        #expect(AppPaths.nativeMessagingSocketURL().deletingLastPathComponent() == support)
        #expect(AppPaths.hostPerformanceURL().deletingLastPathComponent() == caches)
        #expect(!support.path.contains("/.cooldm"))
        #expect(!caches.path.contains("/.cooldm"))
    }

    @Test("metadata uses one SQLite store and preserves task relationships")
    func metadataStoreAndRelationships() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MetadataDatabase(rootURL: root)
        let downloads = try DownloadStore(rootURL: root, database: database)
        let queues = try QueueStore(dataRoot: root, database: database)
        let categories = try CategoryStore(dataRoot: root, defaultFolder: root, database: database)
        let queue = try await queues.create(name: "夜间")
        let category = try await categories.create(name: "测试")
        let record = DownloadRecord(
            id: 1,
            source: DownloadSource(
                kind: .http,
                link: "https://example.test/file",
                headers: ["Cookie": "session=abc", "Authorization": "Bearer value"]
            ),
            folder: root.path,
            name: "file.bin",
            parts: [DownloadPart(id: 0, from: 0, to: 9, downloaded: 4)],
            queueID: queue.id,
            categoryID: category.id
        )
        try await downloads.save(record)
        try await queues.assignItems([record.id], to: queue.id)
        let secondRecord = DownloadRecord(
            id: 2,
            source: DownloadSource(kind: .http, link: "https://example.test/second"),
            folder: root.path,
            name: "second.bin"
        )
        try await downloads.save(secondRecord)
        try await categories.assignItems([secondRecord.id, record.id], to: category.id)

        let reopened = try DownloadStore(rootURL: root, database: database)
        let loaded = try #require(try await reopened.load().first(where: { $0.id == record.id }))
        #expect(loaded.parts == record.parts)
        #expect(loaded.source.headers == record.source.headers)
        #expect(try await queues.model(id: queue.id).queueItems == [record.id])
        #expect(try await categories.model(id: category.id).items == [secondRecord.id, record.id])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata.sqlite").path))
    }

    @Test("共享元数据数据库合并并发创建请求")
    func sharedMetadataDatabaseCoalescesConcurrentCreation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let databases = try await withThrowingTaskGroup(of: MetadataDatabase.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try MetadataDatabase.shared(rootURL: root)
                }
            }

            var values: [MetadataDatabase] = []
            for try await database in group {
                values.append(database)
            }
            return values
        }

        let first = try #require(databases.first)
        #expect(databases.allSatisfy { $0 === first })
    }

    @Test("built-in category paths use the persisted default folder before first load")
    func categoryDefaultsFollowSettings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MetadataDatabase(rootURL: root)
        let categories = try CategoryStore(dataRoot: root, defaultFolder: root, database: database)
        let configuredFolder = root.appendingPathComponent("Configured", isDirectory: true)
        await categories.updateDefaultFolder(configuredFolder)

        let loaded = try await categories.load()
        #expect(loaded.first?.path == configuredFolder.appendingPathComponent("压缩文件").path)
    }

    @Test("typed preferences keep one generated API key and keychain-only proxy secrets")
    func preferencesAndCredentials() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try SettingsStore(dataRoot: root)
        let first = try await settings.load()
        let secondStore = try SettingsStore(dataRoot: root)
        #expect(try await secondStore.load().apiAuthKey == first.apiAuthKey)
        var changed = first
        changed.apiPort = 16200
        changed.proxyUsername = "alice"
        changed.proxyPassword = "secret"
        _ = try await settings.save(changed)
        let reopened = try SettingsStore(dataRoot: root)
        let loaded = try await reopened.load()
        #expect(loaded.apiPort == 16200)
        #expect(loaded.proxyUsername == "alice")
        #expect(loaded.proxyPassword == "secret")
        #expect(!FileManager.default.fileExists(atPath: settings.settingsURL.path))
    }

    @Test("missing API key is generated once even when the schema marker exists")
    func missingAPIKeyIsPersisted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = try SettingsStore(dataRoot: root)
        _ = try await settings.load()
        settings.defaults.defaults.removeObject(forKey: "apiAuthKey")
        settings.defaults.defaults.set(1, forKey: "storage.schemaVersion")

        let reopened = try SettingsStore(dataRoot: root)
        let generated = try await reopened.load()
        #expect(settings.defaults.defaults.object(forKey: "apiAuthKey") as? String == generated.apiAuthKey)

        let loadedAgain = try await SettingsStore(dataRoot: root).load()
        #expect(loadedAgain.apiAuthKey == generated.apiAuthKey)
    }

    @Test("host performance store is disposable cache data")
    func hostPerformanceCachePath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HostPerformanceStore(dataRoot: root)
        #expect(store.settingsURL == root.appendingPathComponent("host-performance.json"))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-download-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
