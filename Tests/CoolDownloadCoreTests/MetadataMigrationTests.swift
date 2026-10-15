import Foundation
import CoreData
import SQLite3
import Darwin
import Testing
@testable import CoolDownloadCore

@Suite("Metadata startup migration")
struct MetadataMigrationTests {
    @Test("v2 startup preserves attributes, relationships, progress and download files", arguments: [false, true])
    func migrateVersion2(historyTracking: Bool) async throws {
        let fixture = try Fixture(historyTracking: historyTracking)
        try fixture.populate()
        let original = try fixture.perform(Self.graph)
        try fixture.close()
        let partialURL = fixture.root.appendingPathComponent("download.cooldm.part")
        let partial = Data("partially downloaded content".utf8)
        try partial.write(to: partialURL)

        let database = try MetadataDatabase(rootURL: fixture.root)
        #expect(try database.perform(Self.graph) == original)
        let downloads = try DownloadStore(rootURL: fixture.root, database: database)
        let records = try await downloads.load()
        #expect(records.map(\.id) == [41, 42])
        #expect(records.map(\.status) == [.paused, .completed])
        #expect(records[0].downloadedBytes == 14)
        #expect(records[0].parts == [
            DownloadPart(id: 0, from: 0, to: 9, downloaded: 10, completed: true),
            DownloadPart(id: 1, from: 10, to: 19, downloaded: 4)
        ])
        #expect(records.allSatisfy { $0.startedAt == nil && $0.completedAt == nil })
        let queues = try QueueStore(dataRoot: fixture.root, database: database)
        let categories = try CategoryStore(dataRoot: fixture.root, defaultFolder: fixture.root, database: database)
        #expect(try await queues.model(id: 7).queueItems == [42, 41])
        #expect(try await categories.model(id: 8).items == [41, 42])
        #expect(try Data(contentsOf: partialURL) == partial)

        let backupDirectory = try #require(try backupDirectories(in: fixture.root).first)
        let backup = try Fixture(root: backupDirectory, name: "metadata-v2.sqlite", readOnly: true)
        #expect(try backup.perform(Self.graph) == original)
        try backup.close()
        #expect(try backupDirectories(in: fixture.root).count == 1)
    }

    @Test("a second startup does not migrate again or lose new dates")
    func reopenAfterMigration() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.close()
        let started = Date(timeIntervalSince1970: 100)
        let completed = Date(timeIntervalSince1970: 200)
        try autoreleasepool {
            let database = try MetadataDatabase(rootURL: fixture.root)
            try database.transaction { context in
                let tasks = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
                tasks.forEach {
                    $0.setValue(started, forKey: "startedAt")
                    $0.setValue(completed, forKey: "completedAt")
                }
            }
        }
        let backups = try backupDirectories(in: fixture.root)
        let database = try MetadataDatabase(rootURL: fixture.root)
        try database.perform { context in
            let tasks = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
            #expect(tasks.count == 2)
            #expect(tasks.allSatisfy { $0.value(forKey: "startedAt") as? Date == started })
            #expect(tasks.allSatisfy { $0.value(forKey: "completedAt") as? Date == completed })
        }
        #expect(try backupDirectories(in: fixture.root) == backups)
    }

    @Test("read-only startup preserves v2 and asks for a writable migration")
    func readOnlyDoesNotMigrate() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.close()
        do {
            _ = try MetadataDatabase(rootURL: fixture.root, readOnly: true)
            Issue.record("A read-only opener must not migrate v2")
        } catch {
            #expect(error.localizedDescription.contains("只读"))
        }
        #expect(try backupDirectories(in: fixture.root).isEmpty)
        let original = try Fixture(root: fixture.root, readOnly: true)
        #expect(try original.perform {
            try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "DownloadTask"))
        } == 2)
        try original.close()
    }

    @Test("backup failure leaves v2 readable and a later startup can retry")
    func backupFailurePreservesSource() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let original = try fixture.perform(Self.graph)
        try fixture.close()
        let obstacle = fixture.root.appendingPathComponent("metadata-backups")
        try Data("blocks backup directory creation".utf8).write(to: obstacle)
        #expect(throws: MetadataDatabaseError.self) {
            _ = try MetadataDatabase(rootURL: fixture.root)
        }
        let reader = try Fixture(root: fixture.root, readOnly: true)
        #expect(try reader.perform(Self.graph) == original)
        try reader.close()
        // Preserve the deliberately obstructing fixture rather than deleting it.
        try FileManager.default.moveItem(at: obstacle, to: fixture.root.appendingPathComponent("obstacle.txt"))
        let database = try MetadataDatabase(rootURL: fixture.root)
        #expect(try database.perform(Self.graph) == original)
    }

    @Test("version labels cannot disguise an unsupported schema")
    func incompatibleHashesAreRejected() throws {
        let model = MetadataDatabase.makeVersion2Model()
        let extra = NSAttributeDescription()
        extra.name = "unknownField"
        extra.attributeType = .stringAttributeType
        extra.isOptional = true
        model.entitiesByName["DownloadTask"]!.properties.append(extra)
        // Deliberately keep the label at 2: compatibility must use entity hashes.
        let fixture = try Fixture(model: model)
        try fixture.populate()
        let original = try fixture.perform(Self.graph)
        try fixture.close()
        #expect(throws: MetadataDatabaseError.self) {
            _ = try MetadataDatabase(rootURL: fixture.root)
        }
        let reader = try Fixture(root: fixture.root, model: model, readOnly: true)
        #expect(try reader.perform(Self.graph) == original)
        try reader.close()
        #expect(try backupDirectories(in: fixture.root).isEmpty)
    }

    @Test("an existing writer blocks migration before a backup is made")
    func writerLockProtectsMigration() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.close()
        let lockURL = fixture.root.appendingPathComponent("metadata.sqlite.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: DownloadCoreError.storageLocked(lockURL)) {
            _ = try MetadataDatabase(rootURL: fixture.root)
        }
        #expect(try backupDirectories(in: fixture.root).isEmpty)
    }

    @Test("failed replacement retains the original and readable recovery snapshots")
    func replacementFailurePreservesSource() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let original = try fixture.perform(Self.graph)
        try fixture.close()
        let url = fixture.root.appendingPathComponent("metadata.sqlite")
        let rootPath = fixture.root.path + "/"
        // Make the live store immutable only after its backup exists and the
        // migration destination opens. Copying an immutable source would also
        // make the backup immutable and fail before reaching replacement.
        let observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreCoordinatorStoresDidChange, object: nil, queue: nil
        ) { notification in
            let stores = notification.userInfo?[NSAddedPersistentStoresKey] as? [NSPersistentStore] ?? []
            if stores.contains(where: {
                $0.url?.lastPathComponent == "metadata-v3.sqlite" && $0.url?.path.hasPrefix(rootPath) == true
            }) {
                #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = chflags(url.path, 0)
        }
        do {
            _ = try MetadataDatabase(rootURL: fixture.root)
            Issue.record("Replacement of the immutable live store must fail")
        } catch {
            #expect(error.localizedDescription.contains("替换数据库失败"))
        }
        // An immutable destination rejects replacement and rollback writes.
        // Both snapshots and the original must nevertheless remain readable.
        #expect(chflags(url.path, 0) == 0)
        let reader = try Fixture(root: fixture.root, readOnly: true)
        #expect(try reader.perform(Self.graph) == original)
        try reader.close()
        let directory = try #require(try backupDirectories(in: fixture.root).first)
        for (name, model) in [("metadata-v2.sqlite", MetadataDatabase.makeVersion2Model()),
                              ("metadata-v3.sqlite", MetadataDatabase.makeModel())] {
            let snapshot = try Fixture(root: directory, name: name, model: model, readOnly: true)
            #expect(try snapshot.perform(Self.graph) == original)
            try snapshot.close()
        }
    }

    @Test("migration includes committed data that exists only in the WAL")
    func committedWALIsPreserved() async throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.close()
        let url = fixture.root.appendingPathComponent("metadata.sqlite")
        let before = try Data(contentsOf: url)
        var reader: OpaquePointer?
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        #expect(sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        // A read snapshot prevents the final writer's close from checkpointing
        // its new transaction; the read-only handle then leaves that WAL intact.
        #expect(sqlite3_exec(reader, "BEGIN; SELECT * FROM ZDOWNLOADTASK;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0; UPDATE ZDOWNLOADTASK SET ZNAME='wal-only.bin' WHERE ZID=41;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(writer) == SQLITE_OK)
        #expect(sqlite3_close(reader) == SQLITE_OK)
        #expect(try Data(contentsOf: url) == before)
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

        let database = try MetadataDatabase(rootURL: fixture.root)
        let downloads = try DownloadStore(rootURL: fixture.root, database: database)
        #expect(try await downloads.load().first(where: { $0.id == 41 })?.name == "wal-only.bin")
        let directory = try #require(try backupDirectories(in: fixture.root).first)
        let backup = try Fixture(root: directory, name: "metadata-v2.sqlite", readOnly: true)
        try backup.perform { context in
            let tasks = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
            #expect(tasks.contains { $0.value(forKey: "name") as? String == "wal-only.bin" })
        }
        try backup.close()
    }

    @Test("new and empty v2 stores open without manufacturing records", arguments: [false, true])
    func emptyStore(version2: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-migrate-\(UUID().uuidString)")
        if version2 {
            let fixture = try Fixture(root: root)
            try fixture.close()
        }
        let database = try MetadataDatabase(rootURL: root)
        #expect(try database.perform { try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "DownloadTask")) } == 0)
        #expect(try backupDirectories(in: root).count == (version2 ? 1 : 0))
    }

    private func backupDirectories(in root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("metadata-backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.path < $1.path }
    }

    /// Compare all pre-existing attributes and relationship memberships using
    /// business identities, since migration is allowed to change object IDs.
    private static func graph(_ context: NSManagedObjectContext) throws -> [String: [String: NSDictionary]] {
        let entities = ["DownloadTask", "DownloadPart", "DownloadQueue", "DownloadCategory", "PerHostSettings"]
        func identity(_ object: NSManagedObject) -> String {
            if object.entity.name == "PerHostSettings" { return object.value(forKey: "host") as! String }
            if object.entity.name == "DownloadPart" {
                let task = object.value(forKey: "task") as! NSManagedObject
                return "\(task.value(forKey: "id")!)-\(object.value(forKey: "partID")!)"
            }
            return "\(object.value(forKey: "id")!)"
        }
        var result: [String: [String: NSDictionary]] = [:]
        for entity in entities {
            var rows: [String: NSDictionary] = [:]
            for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) {
                let keys = object.entity.attributesByName.keys.filter { !["startedAt", "completedAt"].contains($0) }
                var values = object.dictionaryWithValues(forKeys: Array(keys))
                for (name, relation) in object.entity.relationshipsByName {
                    if relation.isToMany {
                        let objects = (object.value(forKey: name) as? NSSet)?.allObjects as? [NSManagedObject] ?? []
                        values[name] = objects.map(identity).sorted()
                    } else {
                        values[name] = (object.value(forKey: name) as? NSManagedObject).map(identity) ?? "nil"
                    }
                }
                rows[identity(object)] = values as NSDictionary
            }
            result[entity] = rows
        }
        return result
    }

    private final class Fixture {
        let root: URL
        let coordinator: NSPersistentStoreCoordinator
        let store: NSPersistentStore
        let context: NSManagedObjectContext

        init(
            root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-migrate-\(UUID().uuidString)"),
            name: String = "metadata.sqlite",
            model: NSManagedObjectModel = MetadataDatabase.makeVersion2Model(),
            readOnly: Bool = false,
            historyTracking: Bool = false
        ) throws {
            self.root = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            var options: [AnyHashable: Any] = [NSReadOnlyPersistentStoreOption: readOnly]
            if historyTracking { options[NSPersistentHistoryTrackingKey] = true }
            store = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: root.appendingPathComponent(name),
                options: options
            )
            context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }

        func perform<T>(_ body: @Sendable (NSManagedObjectContext) throws -> T) rethrows -> T {
            let context = self.context
            return try context.performAndWait { try body(context) }
        }

        func close() throws {
            perform { $0.reset() }
            try coordinator.remove(store)
        }

        func populate() throws {
            let rootPath = root.path
            let schedule = try MetadataJSON.encode(QueueSchedule.default)
            try perform { context in
                func insert(_ entity: String, _ values: [String: Any]) -> NSManagedObject {
                    let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
                    object.setValuesForKeys(values)
                    return object
                }
                let queue = insert("DownloadQueue", [
                    "id": 7, "name": "夜间", "maxConcurrent": 2, "scheduledTimesJSON": schedule,
                    "stopQueueOnEmpty": true, "completionAction": "none"
                ])
                let category = insert("DownloadCategory", [
                    "id": 8, "name": "资料", "icon": "doc", "path": rootPath,
                    "usePath": true, "acceptedFileTypesJSON": "[\"bin\"]", "acceptedURLPatternsJSON": "[]"
                ])
                _ = insert("PerHostSettings", [
                    "host": "fixture.invalid", "userAgent": "Fixture/2", "threadCount": 4,
                    "speedLimit": 1024, "sortOrder": 0
                ])
                for (index, id) in [41, 42].enumerated() {
                    let task = insert("DownloadTask", [
                        "id": id, "sourceKind": "http", "link": "https://fixture.invalid/\(id)",
                        "headersJSON": "{\"X-Fixture\":\"keep\"}", "downloadPage": "https://fixture.invalid/page",
                        "suggestedName": "suggested.bin", "folder": rootPath, "name": "\(id).bin",
                        "status": index == 0 ? "paused" : "completed", "downloadedBytes": index == 0 ? 14 : 20,
                        "totalBytes": 20, "etag": "fixture-etag", "supportsResume": true,
                        "createdAt": Date(timeIntervalSince1970: 10), "updatedAt": Date(timeIntervalSince1970: 20),
                        "revision": 3, "queueOrder": 1 - index, "categoryOrder": index,
                        "queue": queue, "category": category, "incompleteFileName": "download.cooldm.part"
                    ])
                    for partID in 0..<2 {
                        _ = insert("DownloadPart", [
                            "partID": partID, "from": partID * 10, "to": partID * 10 + 9,
                            "downloaded": index == 0 && partID == 1 ? 4 : 10,
                            "completed": index == 1 || partID == 0, "task": task
                        ])
                    }
                }
                try context.save()
            }
        }
    }
}
