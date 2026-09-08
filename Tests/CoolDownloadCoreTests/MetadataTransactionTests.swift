import Foundation
import CoreData
import Testing
@testable import CoolDownloadCore

@Suite("Metadata transaction rollback")
struct MetadataTransactionTests {
    @Test("failed first-load defaults do not leak into another façade save", arguments: [false, true])
    func failedDefaults(category: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try MetadataDatabase(rootURL: root)
        let queues = try QueueStore(dataRoot: root, database: database)
        let categories = try CategoryStore(dataRoot: root, defaultFolder: root, database: database)
        let entity = category ? "DownloadCategory" : "DownloadQueue"
        let observer = failSaves(in: database)
        do {
            if category { _ = try await categories.load() }
            else { _ = try await queues.load() }
            Issue.record("Expected a real Core Data save failure")
        } catch {
            #expect(error is CategoryStoreError || error is QueueStoreError)
        }
        NotificationCenter.default.removeObserver(observer)
        #expect(database.perform { !$0.hasChanges })
        #expect(try count(entity, database: database) == 0)

        if category { _ = try await queues.create(name: "unrelated") }
        else { _ = try await categories.create(name: "unrelated") }
        let reader = try MetadataDatabase(rootURL: root, readOnly: true)
        #expect(try count(entity, database: reader) == 0)
        if category { #expect(try await categories.load().count == 6) }
        else { #expect(try await queues.load().map(\.id) == [0]) }
    }

    @Test("failed queue mutations preserve cache, relationships and disk", arguments: ["create", "update", "remove", "assign"])
    func failedQueueMutation(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try MetadataDatabase(rootURL: root)
        let queues = try QueueStore(dataRoot: root, database: database)
        let queue = try await queues.create(name: "original")
        let downloads = try DownloadStore(rootURL: root, database: database)
        try await downloads.save(DownloadRecord(
            id: 1, source: DownloadSource(kind: .http, link: "https://example.test/file"),
            folder: root.path, name: "file.bin", queueID: queue.id
        ))
        let observer = failSaves(in: database)
        do {
            switch operation {
            case "create": _ = try await queues.create(name: "failed")
            case "update":
                var changed = queue
                changed.name = "failed"
                changed.queueItems = []
                _ = try await queues.save(changed)
            case "remove": try await queues.remove(id: queue.id)
            default: try await queues.assignItems([1], to: nil)
            }
            Issue.record("Expected a real Core Data save failure")
        } catch { #expect(error is QueueStoreError) }
        NotificationCenter.default.removeObserver(observer)
        #expect(database.perform { !$0.hasChanges })
        #expect(try await queues.model(id: queue.id).name == "original")
        let categories = try CategoryStore(dataRoot: root, defaultFolder: root, database: database)
        _ = try await categories.load()
        let reader = try MetadataDatabase(rootURL: root, readOnly: true)
        let freshQueues = try QueueStore(dataRoot: root, database: reader)
        #expect(try await freshQueues.list().count == 2)
        #expect(try await freshQueues.model(id: queue.id).name == "original")
        #expect(try await freshQueues.model(id: queue.id).queueItems == [1])
    }

    @Test("failed category mutations preserve cache, relationships and disk", arguments: ["create", "update", "remove", "assign"])
    func failedCategoryMutation(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try MetadataDatabase(rootURL: root)
        let categories = try CategoryStore(dataRoot: root, defaultFolder: root, database: database)
        let category = try await categories.create(name: "original")
        let downloads = try DownloadStore(rootURL: root, database: database)
        try await downloads.save(DownloadRecord(
            id: 1, source: DownloadSource(kind: .http, link: "https://example.test/file"),
            folder: root.path, name: "file.bin", categoryID: category.id
        ))
        let observer = failSaves(in: database)
        do {
            switch operation {
            case "create": _ = try await categories.create(name: "failed")
            case "update":
                var changed = category
                changed.name = "failed"
                changed.items = []
                _ = try await categories.save(changed)
            case "remove": try await categories.remove(id: category.id)
            default: try await categories.assignItems([1], to: nil)
            }
            Issue.record("Expected a real Core Data save failure")
        } catch { #expect(error is CategoryStoreError) }
        NotificationCenter.default.removeObserver(observer)
        #expect(database.perform { !$0.hasChanges })
        #expect(try await categories.model(id: category.id).name == "original")
        let queues = try QueueStore(dataRoot: root, database: database)
        _ = try await queues.load()
        let reader = try MetadataDatabase(rootURL: root, readOnly: true)
        let freshCategories = try CategoryStore(dataRoot: root, defaultFolder: root, database: reader)
        #expect(try await freshCategories.list().count == 7)
        #expect(try await freshCategories.model(id: category.id).name == "original")
        #expect(try await freshCategories.model(id: category.id).items == [1])
    }

    @Test("failed host removal does not get committed by an unrelated queue save")
    func failedHostRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try MetadataDatabase(rootURL: root)
        try database.transaction { context in
            let host = NSEntityDescription.insertNewObject(forEntityName: "PerHostSettings", into: context)
            host.setValue("example.test", forKey: "host")
        }
        // No credential references: this test does not access the user's Keychain.
        let hosts = try PerHostSettingsStore(dataRoot: root, database: database)
        #expect(try await hosts.load().map(\.host) == ["example.test"])
        let observer = failSaves(in: database)
        do {
            _ = try await hosts.save([])
            Issue.record("Expected a real Core Data save failure")
        } catch { #expect(error is PerHostSettingsError) }
        NotificationCenter.default.removeObserver(observer)
        #expect(database.perform { !$0.hasChanges })
        #expect(try await hosts.load().map(\.host) == ["example.test"])
        let queues = try QueueStore(dataRoot: root, database: database)
        _ = try await queues.load()
        let reader = try MetadataDatabase(rootURL: root, readOnly: true)
        let freshHosts = try PerHostSettingsStore(dataRoot: root, database: reader)
        #expect(try await freshHosts.load().map(\.host) == ["example.test"])
    }

    @Test("errors before save also discard partial mutations")
    func mutationBodyFailure() throws {
        enum Failure: Error { case injected }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try MetadataDatabase(rootURL: root)
        #expect(throws: Failure.self) {
            try database.transaction { context in
                let host = NSEntityDescription.insertNewObject(forEntityName: "PerHostSettings", into: context)
                host.setValue("failed.test", forKey: "host")
                throw Failure.injected
            }
        }
        #expect(database.perform { !$0.hasChanges })
        #expect(try count("PerHostSettings", database: database) == 0)
    }

    private func count(_ entity: String, database: MetadataDatabase) throws -> Int {
        try database.perform { try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity)) }
    }

    private func failSaves(in database: MetadataDatabase) -> NSObjectProtocol {
        database.perform { context in
            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextWillSave, object: context, queue: nil
            ) { notification in
                guard let context = notification.object as? NSManagedObjectContext else { return }
                // A missing required host forces Core Data's own save validation
                // to fail, after the façade has already mutated the shared context.
                if !context.insertedObjects.contains(where: {
                    $0.entity.name == "PerHostSettings" && $0.value(forKey: "host") == nil
                }) {
                    _ = NSEntityDescription.insertNewObject(forEntityName: "PerHostSettings", into: context)
                }
            }
        }
    }
}
