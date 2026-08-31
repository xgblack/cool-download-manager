import Foundation
import CoreData
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

    @Test("application preferences use the standard defaults domain")
    func applicationPreferencesUseStandardDefaults() throws {
        let store = try SettingsStore(dataRoot: AppPaths.applicationSupportDirectory())
        #expect(store.defaults.defaults === UserDefaults.standard)
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
                headers: nil
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

    @Test("download checkpoints update only dirty parts and skip no-op saves")
    func incrementalDownloadCheckpoint() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        var record = DownloadRecord(
            id: 9,
            source: DownloadSource(kind: .http, link: "https://example.test/file"),
            folder: root.path,
            name: "file.bin",
            totalBytes: 20,
            parts: [
                DownloadPart(id: 0, from: 0, to: 9),
                DownloadPart(id: 1, from: 10, to: 19)
            ]
        )

        try await store.save(record)
        #expect(await store.lastMutationStats().partsInserted == 2)

        record.parts[1].downloaded = 5
        record.downloadedBytes = 5
        record.revision += 1
        try await store.save(record)
        let progressStats = await store.lastMutationStats()
        #expect(progressStats.partsInserted == 0)
        #expect(progressStats.partsUpdated == 1)
        #expect(progressStats.partsDeleted == 0)
        #expect(progressStats.contextSaved)

        try await store.save(record)
        let noOpStats = await store.lastMutationStats()
        #expect(noOpStats.partsUpdated == 0)
        #expect(noOpStats.taskAttributesUpdated == 0)
        #expect(!noOpStats.contextSaved)

        let reopened = try DownloadStore(rootURL: root, database: database)
        #expect(try await reopened.load().first?.parts == record.parts)
    }

    @Test("v1 SQLite metadata migrates to v2 without losing tasks or parts")
    func migratesV1MetadataStore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createV1Fixture(at: root)

        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        let records = try await store.load()
        let first = try #require(records.first)

        #expect(MetadataDatabase.modelVersion == "2")
        #expect(first.id == 71)
        #expect(first.source.link == "https://example.test/archive.bin?signature=v1")
        #expect(first.source.credentialReference == nil)
        #expect(first.sourceRefreshReason == nil)
        #expect(first.hlsResumeSnapshot == nil)
        #expect(first.hlsRenditions == nil)
        #expect(first.parts == [
            DownloadPart(id: 0, from: 0, to: 9, downloaded: 4, completed: false)
        ])

        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: database.storeURL
        )
        #expect(MetadataDatabase.makeModel().isConfiguration(
            withName: nil,
            compatibleWithStoreMetadata: metadata
        ))
    }

    @Test("v1 source migration failure persists waiting state without erasing legacy source")
    func sourceMigrationFailurePreservesV1Source() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createV1Fixture(at: root)
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        let service = DownloadService(
            store: store,
            defaultFolder: root,
            credentialStore: UnavailableCredentialStore()
        )

        try await service.boot()
        let record = try #require(await service.snapshot().downloads.first)
        #expect(record.status == .waitingForSourceRefresh)
        #expect(record.sourceRefreshReason == .credentialsUnavailable)
        #expect(record.source.link == "https://example.test/archive.bin")
        #expect(record.source.credentialReference
            == DownloadSourceSecurity.credentialReference(for: 71))

        let persisted = try database.perform { context -> (String?, String?, String?) in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.fetchLimit = 1
            let task = try context.fetch(request).first
            return (
                task?.value(forKey: "link") as? String,
                task?.value(forKey: "status") as? String,
                task?.value(forKey: "sourceRefreshReason") as? String
            )
        }
        #expect(persisted.0 == "https://example.test/archive.bin?signature=v1")
        #expect(persisted.1 == DownloadStatus.waitingForSourceRefresh.rawValue)
        #expect(persisted.2 == DownloadSourceRefreshReason.credentialsUnavailable.rawValue)
        await service.shutdown()
    }

    @Test("invalid part layout does not change the last committed record")
    func invalidPartLayoutIsAtomic() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        var record = DownloadRecord(
            id: 10,
            source: DownloadSource(kind: .http, link: "https://example.test/file"),
            folder: root.path,
            name: "file.bin",
            parts: [DownloadPart(id: 0, from: 0, to: 9)]
        )
        try await store.save(record)

        record.parts.append(DownloadPart(id: 0, from: 10, to: 19))
        record.revision += 1
        do {
            try await store.save(record)
            Issue.record("duplicate part IDs should fail")
        } catch let error as DownloadCoreError {
            guard case .corruptRecord = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }

        let reopened = try DownloadStore(rootURL: root, database: database)
        #expect(try await reopened.load().first?.parts.count == 1)
    }

    @Test("a corrupt stored part relationship rolls back task changes")
    func corruptStoredPartsDoNotLeakTaskMutations() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        var record = DownloadRecord(
            id: 11,
            source: DownloadSource(kind: .http, link: "https://example.test/file"),
            folder: root.path,
            name: "original.bin",
            parts: [DownloadPart(id: 0, from: 0, to: 9)]
        )
        try await store.save(record)

        try database.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.predicate = NSPredicate(format: "id == %lld", record.id)
            request.fetchLimit = 1
            let task = try #require(context.fetch(request).first)
            let duplicate = NSEntityDescription.insertNewObject(
                forEntityName: "DownloadPart",
                into: context
            )
            duplicate.setValue(Int64(0), forKey: "partID")
            duplicate.setValue(Int64(10), forKey: "from")
            duplicate.setValue(Int64(19), forKey: "to")
            duplicate.setValue(Int64(0), forKey: "downloaded")
            duplicate.setValue(false, forKey: "completed")
            duplicate.setValue(task, forKey: "task")
            try context.save()
        }

        record.name = "must-not-persist.bin"
        record.revision += 1
        do {
            try await store.save(record)
            Issue.record("corrupt stored part IDs should fail")
        } catch let error as DownloadCoreError {
            guard case .corruptRecord = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }

        let persisted = try database.perform { context -> (String?, Int64) in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.predicate = NSPredicate(format: "id == %lld", record.id)
            request.fetchLimit = 1
            let task = try #require(context.fetch(request).first)
            return (
                task.value(forKey: "name") as? String,
                (task.value(forKey: "revision") as? NSNumber)?.int64Value ?? -1
            )
        }
        #expect(persisted.0 == "original.bin")
        #expect(persisted.1 == 1)
        #expect(await store.record(id: record.id)?.name == "original.bin")
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

    private func createV1Fixture(at root: URL) throws {
        let storeURL = root.appendingPathComponent("metadata.sqlite")
        let container = NSPersistentContainer(
            name: "CoolDownloadManagerMetadataV1Fixture",
            managedObjectModel: MetadataDatabase.makeModel(version: "1")
        )
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError { throw loadError }

        let context = container.newBackgroundContext()
        try context.performAndWait {
            let task = NSEntityDescription.insertNewObject(
                forEntityName: "DownloadTask",
                into: context
            )
            task.setValue(Int64(71), forKey: "id")
            task.setValue(DownloadKind.http.rawValue, forKey: "sourceKind")
            task.setValue(
                "https://example.test/archive.bin?signature=v1",
                forKey: "link"
            )
            task.setValue(root.path, forKey: "folder")
            task.setValue("archive.bin", forKey: "name")
            task.setValue(DownloadStatus.paused.rawValue, forKey: "status")
            task.setValue(Int64(4), forKey: "downloadedBytes")
            task.setValue(Int64(10), forKey: "totalBytes")
            task.setValue(Date(timeIntervalSince1970: 1_000), forKey: "createdAt")
            task.setValue(Date(timeIntervalSince1970: 2_000), forKey: "updatedAt")
            task.setValue(Int64(3), forKey: "revision")

            let part = NSEntityDescription.insertNewObject(
                forEntityName: "DownloadPart",
                into: context
            )
            part.setValue(Int64(0), forKey: "partID")
            part.setValue(Int64(0), forKey: "from")
            part.setValue(Int64(9), forKey: "to")
            part.setValue(Int64(4), forKey: "downloaded")
            part.setValue(false, forKey: "completed")
            part.setValue(task, forKey: "task")
            try context.save()
        }
        if let persistentStore = container.persistentStoreCoordinator.persistentStores.first {
            try container.persistentStoreCoordinator.remove(persistentStore)
        }
    }
}

private struct UnavailableCredentialStore: DownloadCredentialStore {
    func read(reference: String) throws -> DownloadSecureSource? {
        throw CredentialUnavailableFixtureError()
    }

    func write(_ source: DownloadSecureSource, reference: String) throws {
        throw CredentialUnavailableFixtureError()
    }

    func remove(reference: String) throws {
        throw CredentialUnavailableFixtureError()
    }
}

private struct CredentialUnavailableFixtureError: Error {}
