import Foundation
import CoreData

/// Runs only while MetadataDatabase owns the metadata writer lock. Models are
/// matched by Core Data compatibility hashes, not just a version label.
enum MetadataMigration {
    private static var readOptions: [AnyHashable: Any] { [
        NSReadOnlyPersistentStoreOption: true,
        NSMigratePersistentStoresAutomaticallyOption: false,
        NSInferMappingModelAutomaticallyOption: false
    ] }
    private static var snapshotOptions: [AnyHashable: Any] { [
        NSSQLitePragmasOption: ["journal_mode": "DELETE"]
    ] }

    static func prepareStore(at url: URL, model: NSManagedObjectModel, readOnly: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: url, options: readOptions
            )
            if model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return }

            let source = MetadataDatabase.makeVersion2Model()
            guard source.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
                throw MetadataDatabaseError.loadFailed(
                    url, "元数据库模型不受当前版本支持。旧数据已保留，请使用支持该模型的应用版本。"
                )
            }
            guard !readOnly else {
                throw MetadataDatabaseError.loadFailed(
                    url, "元数据库需要从版本 2 升级到版本 3，请先正常启动应用完成迁移。只读模式未修改旧数据。"
                )
            }
            try migrateVersion2(at: url, source: source, destination: model)
        } catch let error as MetadataDatabaseError {
            throw error
        } catch {
            throw MetadataDatabaseError.loadFailed(url, error.localizedDescription)
        }
    }

    private static func migrateVersion2(
        at url: URL, source: NSManagedObjectModel, destination: NSManagedObjectModel
    ) throws {
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("metadata-backups", isDirectory: true)
            .appendingPathComponent("v2-to-v3-\(UUID().uuidString)", isDirectory: true)
        let backup = directory.appendingPathComponent("metadata-v2.sqlite")
        let upgraded = directory.appendingPathComponent("metadata-v3.sqlite")
        do {
            let mapping = try NSMappingModel.inferredMappingModel(
                forSourceModel: source, destinationModel: destination
            )
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: source)
            // Core Data copies a consistent SQLite snapshot, including committed
            // WAL transactions. A raw copy of metadata.sqlite could lose them.
            try coordinator.replacePersistentStore(
                at: backup, destinationOptions: snapshotOptions,
                withPersistentStoreFrom: url, sourceOptions: readOptions, ofType: NSSQLiteStoreType
            )
            let originalCounts = try counts(at: backup, model: source)
            try autoreleasepool {
                let manager = NSMigrationManager(sourceModel: source, destinationModel: destination)
                // Existing v2 stores may retain persistent history and older
                // indexes that the SQLite in-place migrator cannot rewrite.
                // Use inferred object mappings into the isolated destination.
                manager.usesStoreSpecificMigrationManager = false
                try manager.migrateStore(
                    from: backup, sourceType: NSSQLiteStoreType, options: readOptions,
                    with: mapping, toDestinationURL: upgraded,
                    destinationType: NSSQLiteStoreType, destinationOptions: snapshotOptions
                )
            }
            guard try counts(at: upgraded, model: destination) == originalCounts else {
                throw MetadataDatabaseError.loadFailed(url, "迁移前后记录数不一致，未替换原数据库。")
            }

            do {
                try coordinator.replacePersistentStore(
                    at: url, destinationOptions: nil,
                    withPersistentStoreFrom: upgraded, sourceOptions: readOptions, ofType: NSSQLiteStoreType
                )
            } catch {
                let replacementError = error
                do {
                    try coordinator.replacePersistentStore(
                        at: url, destinationOptions: nil,
                        withPersistentStoreFrom: backup, sourceOptions: readOptions, ofType: NSSQLiteStoreType
                    )
                } catch {
                    throw MetadataDatabaseError.loadFailed(
                        url, "替换数据库失败：\(replacementError.localizedDescription)；恢复失败：\(error.localizedDescription)。完整旧库备份位于 \(backup.path)，请保留该目录。"
                    )
                }
                throw MetadataDatabaseError.loadFailed(
                    url, "替换数据库失败，已恢复旧库：\(replacementError.localizedDescription)"
                )
            }
            // Retain both snapshots: the v2 backup permits an explicit rollback;
            // the verified v3 snapshot can recover an interrupted replacement.
        } catch {
            throw MetadataDatabaseError.loadFailed(
                url, "版本 2 → 3 迁移未完成：\(error.localizedDescription)。迁移备份目录：\(directory.path)。未自动清空任何数据。"
            )
        }
    }

    /// Opening each snapshot also verifies that it is readable with its model.
    /// All stores close before the live database is replaced.
    private static func counts(at url: URL, model: NSManagedObjectModel) throws -> [String: Int] {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: readOptions
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let entityNames = model.entities.compactMap(\.name)
        let result = Result {
            try context.performAndWait {
                var counts: [String: Int] = [:]
                for name in entityNames {
                    counts[name] = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: name))
                }
                context.reset()
                return counts
            }
        }
        try coordinator.remove(store)
        return try result.get()
    }
}
