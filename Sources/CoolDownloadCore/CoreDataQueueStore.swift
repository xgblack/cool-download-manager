import Foundation
import CoreData

/// Core Data implementation of the queue façade. Queue membership is stored
/// on the `DownloadTask.queue` relationship and exposed as ordered IDs.
public actor QueueStore {
    public nonisolated let queuesURL: URL
    public nonisolated let metadataURL: URL
    private let database: MetadataDatabase
    private var loaded = false
    private var models: [DownloadID: DownloadQueueModel] = [:]

    public init(dataRoot: URL) throws {
        try self.init(dataRoot: dataRoot, database: MetadataDatabase.shared(rootURL: dataRoot))
    }

    public init(dataRoot: URL, database: MetadataDatabase) throws {
        queuesURL = dataRoot.standardizedFileURL
        self.database = database
        metadataURL = database.storeURL
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    public func load() throws -> [DownloadQueueModel] {
        if loaded { return sortedModels() }
        do {
            let values: [DownloadQueueModel] = try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue")
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                return try context.fetch(request).map(Self.decode)
            }
            models = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            if models.isEmpty {
                let main = DownloadQueueModel(id: 0, name: "主队列")
                try database.transaction { context in
                    try persist(main, in: context)
                }
                models[main.id] = main
            }
            loaded = true
            return sortedModels()
        } catch let error as QueueStoreError {
            throw error
        } catch {
            throw QueueStoreError.corrupt(metadataURL, error.localizedDescription)
        }
    }

    public func list() throws -> [DownloadQueueModel] { try load() }

    public func model(id: DownloadID) throws -> DownloadQueueModel {
        _ = try load()
        guard let model = models[id] else { throw QueueStoreError.notFound(id) }
        return model
    }

    @discardableResult
    public func create(name: String) throws -> DownloadQueueModel {
        _ = try load()
        let id = max(models.keys.max() ?? 0, 10) + 1
        let value = try DownloadQueueModel(id: id, name: name).validated()
        do {
            try database.transaction { context in
                try persist(value, in: context)
            }
        } catch let error as QueueStoreError {
            throw error
        } catch {
            throw QueueStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
        models[id] = value
        return value
    }

    @discardableResult
    public func save(_ model: DownloadQueueModel) throws -> DownloadQueueModel {
        _ = try load()
        let value = try model.validated()
        guard models[value.id] != nil else { throw QueueStoreError.notFound(value.id) }
        do {
            try database.transaction { context in
                try persist(value, in: context)
                try persistMembership(value, in: context)
            }
            models[value.id] = value
        } catch let error as QueueStoreError {
            throw error
        } catch {
            throw QueueStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
        return value
    }

    /// Moves task IDs to one queue and removes stale membership from all other
    /// queues in the same Core Data context transaction.
    public func assignItems(_ ids: [DownloadID], to queueID: DownloadID?) throws {
        _ = try load()
        var seen = Set<DownloadID>()
        let uniqueIDs = ids.filter { $0 > 0 && seen.insert($0).inserted }
        if let queueID, models[queueID] == nil {
            throw QueueStoreError.notFound(queueID)
        }
        do {
            try database.transaction { context in
                let taskRequest = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                let tasks = try context.fetch(taskRequest)
                let queues = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue"))
                let target = queues.first {
                    (($0.value(forKey: "id") as? NSNumber)?.int64Value) == queueID
                }
                let selected = Set(uniqueIDs)
                let orderByID = Dictionary(uniqueKeysWithValues: uniqueIDs.enumerated().map {
                    ($0.element, Int64($0.offset))
                })
                var nextOrder: Int64 = 0
                if let target {
                    let orders = ((target.value(forKey: "items") as? NSSet)?.allObjects as? [NSManagedObject] ?? [])
                        .filter {
                            !selected.contains(($0.value(forKey: "id") as? NSNumber)?.int64Value ?? 0)
                        }
                    .compactMap { ($0.value(forKey: "queueOrder") as? NSNumber)?.int64Value }
                    nextOrder = (orders.max() ?? -1) + 1
                }
                for task in tasks {
                    guard let taskID = (task.value(forKey: "id") as? NSNumber)?.int64Value,
                          selected.contains(taskID) else { continue }
                    if let target {
                        task.setValue(target, forKey: "queue")
                        task.setValue(nextOrder + (orderByID[taskID] ?? 0), forKey: "queueOrder")
                    } else {
                        task.setValue(nil, forKey: "queue")
                        task.setValue(nil, forKey: "queueOrder")
                    }
                }
            }
            loaded = false
            _ = try load()
        } catch let error as QueueStoreError {
            throw error
        } catch {
            throw QueueStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
    }

    public func remove(id: DownloadID) throws {
        _ = try load()
        guard id != 0 else { throw QueueStoreError.cannotDeleteMainQueue }
        guard models[id] != nil else { throw QueueStoreError.notFound(id) }
        do {
            try database.transaction { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue")
                request.predicate = NSPredicate(format: "id == %lld", id)
                request.fetchLimit = 1
                guard let object = try context.fetch(request).first else {
                    throw QueueStoreError.notFound(id)
                }
                context.delete(object)
            }
            models[id] = nil
        } catch let error as QueueStoreError {
            throw error
        } catch {
            throw QueueStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
    }

    public func replaceItems(queueID: DownloadID, itemIDs: [DownloadID]) throws {
        var value = try model(id: queueID)
        value.queueItems = itemIDs
        _ = try save(value)
    }

    private func sortedModels() -> [DownloadQueueModel] {
        models.values.sorted { lhs, rhs in
            if lhs.id == 0 { return true }
            if rhs.id == 0 { return false }
            return lhs.id < rhs.id
        }
    }

    private func persist(_ model: DownloadQueueModel, in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue")
        request.predicate = NSPredicate(format: "id == %lld", model.id)
        request.fetchLimit = 1
        let object = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(
            forEntityName: "DownloadQueue",
            into: context
        )
        object.setValue(model.id, forKey: "id")
        object.setValue(model.name, forKey: "name")
        object.setValue(model.maxConcurrent, forKey: "maxConcurrent")
        object.setValue(try MetadataJSON.encode(model.scheduledTimes), forKey: "scheduledTimesJSON")
        object.setValue(model.stopQueueOnEmpty, forKey: "stopQueueOnEmpty")
        object.setValue(model.completionAction.rawValue, forKey: "completionAction")
    }

    private func persistMembership(_ model: DownloadQueueModel, in context: NSManagedObjectContext) throws {
        let queues = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue"))
        guard let target = queues.first(where: {
            (($0.value(forKey: "id") as? NSNumber)?.int64Value) == model.id
        }) else { throw QueueStoreError.notFound(model.id) }
        let tasks = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
        let desired = Set(model.queueItems)
        let orderByID = Dictionary(uniqueKeysWithValues: model.queueItems.enumerated().map {
            ($0.element, Int64($0.offset))
        })
        for task in tasks {
            guard let id = (task.value(forKey: "id") as? NSNumber)?.int64Value else { continue }
            let currentQueueID = (task.value(forKey: "queue") as? NSManagedObject)
                .flatMap { ($0.value(forKey: "id") as? NSNumber)?.int64Value }
            if desired.contains(id) {
                task.setValue(target, forKey: "queue")
                task.setValue(orderByID[id], forKey: "queueOrder")
            } else if currentQueueID == model.id {
                task.setValue(nil, forKey: "queue")
                task.setValue(nil, forKey: "queueOrder")
            }
        }
    }

    private static func decode(_ object: NSManagedObject) throws -> DownloadQueueModel {
        guard let id = (object.value(forKey: "id") as? NSNumber)?.int64Value,
              let name = object.value(forKey: "name") as? String,
              let scheduleJSON = object.value(forKey: "scheduledTimesJSON") as? String,
              let completionValue = object.value(forKey: "completionAction") as? String,
              let completionAction = QueueCompletionAction(rawValue: completionValue) else {
            throw QueueStoreError.invalid("队列元数据字段无效")
        }
        let items = ((object.value(forKey: "items") as? NSSet)?.allObjects as? [NSManagedObject] ?? [])
            .sorted {
                let lhs = ($0.value(forKey: "queueOrder") as? NSNumber)?.int64Value ?? Int64.max
                let rhs = ($1.value(forKey: "queueOrder") as? NSNumber)?.int64Value ?? Int64.max
                return lhs == rhs
                    ? (($0.value(forKey: "id") as? NSNumber)?.int64Value ?? 0)
                        < (($1.value(forKey: "id") as? NSNumber)?.int64Value ?? 0)
                    : lhs < rhs
            }
            .compactMap { ($0.value(forKey: "id") as? NSNumber)?.int64Value }
        return try DownloadQueueModel(
            id: id,
            name: name,
            maxConcurrent: Int((object.value(forKey: "maxConcurrent") as? NSNumber)?.int64Value ?? 2),
            queueItems: items,
            scheduledTimes: try MetadataJSON.decode(QueueSchedule.self, from: scheduleJSON),
            stopQueueOnEmpty: (object.value(forKey: "stopQueueOnEmpty") as? NSNumber)?.boolValue ?? false,
            completionAction: completionAction
        ).validated()
    }
}
