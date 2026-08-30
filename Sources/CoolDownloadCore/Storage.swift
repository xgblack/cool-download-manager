import Foundation
import CoreData

/// Core Data façade for download metadata. The actor owns the value-type
/// cache used by `DownloadService`; managed objects never cross the actor
/// boundary. File contents and `.cooldm.part` files remain outside this store.
public actor DownloadStore {
    public let rootURL: URL
    public let metadataURL: URL

    private let database: MetadataDatabase
    private var records: [DownloadID: DownloadRecord] = [:]
    private var loaded = false
    private var metrics: any DownloadMetricsSink = NoopDownloadMetricsSink()
    private var metricsEnabled = false

    public init(rootURL: URL) throws {
        try self.init(rootURL: rootURL, database: MetadataDatabase.shared(rootURL: rootURL))
    }

    public init(rootURL: URL, database: MetadataDatabase) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.database = database
        self.metadataURL = database.storeURL
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    @discardableResult
    public func load() throws -> [DownloadRecord] {
        let loadedRecords: [DownloadRecord] = try database.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            do {
                return try context.fetch(request).map(Self.decodeRecord)
            } catch {
                throw DownloadCoreError.corruptRecord(metadataURL, error.localizedDescription)
            }
        }
        records = Dictionary(uniqueKeysWithValues: loadedRecords.map { ($0.id, $0) })
        loaded = true
        return loadedRecords
    }

    public func all() -> [DownloadRecord] {
        records.values.sorted { $0.id < $1.id }
    }

    public func record(id: DownloadID) -> DownloadRecord? {
        records[id]
    }

    public func nextID() -> DownloadID {
        let maximum = (try? database.perform { context -> Int64 in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.fetchLimit = 1
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: false)]
            return (try context.fetch(request).first?.value(forKey: "id") as? NSNumber)?.int64Value ?? 0
        }) ?? records.keys.max() ?? 0
        return max(maximum, records.keys.max() ?? 0) + 1
    }

    public func updateMetrics(_ metrics: any DownloadMetricsSink) {
        self.metrics = metrics
        metricsEnabled = metrics.isEnabled
    }

    public func save(_ record: DownloadRecord) throws {
        if let current = records[record.id], current.revision > record.revision {
            return
        }
        let startedAt = metricsEnabled ? downloadMetricsNow() : 0
        let resources = metricsEnabled ? DownloadResourceSnapshot.capture() : nil
        do {
            let encodedBytes = try database.perform { context -> Int64 in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                request.predicate = NSPredicate(format: "id == %lld", record.id)
                request.fetchLimit = 1
                let task = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(
                    forEntityName: "DownloadTask",
                    into: context
                )
                try Self.encode(record, into: task, context: context)
                try context.save()
                return Int64(try MetadataJSON.encode(record).utf8.count)
            }
            records[record.id] = record
            if metricsEnabled, let resources {
                metrics.record(.checkpointPhase(
                    id: record.id,
                    phase: .recordEncode,
                    elapsedNanoseconds: downloadMetricsElapsed(since: startedAt),
                    bytes: encodedBytes
                ))
                metrics.record(.checkpoint(
                    id: record.id,
                    elapsedNanoseconds: downloadMetricsElapsed(since: startedAt),
                    encodedBytes: encodedBytes,
                    logicalWriteBytes: encodedBytes,
                    kernelAccountedWriteBytes: DownloadResourceSnapshot.capture().diskWriteDelta(from: resources),
                    synchronizeCount: 1,
                    succeeded: true
                ))
            }
        } catch let error as DownloadCoreError {
            throw error
        } catch {
            if metricsEnabled, let resources {
                metrics.record(.checkpoint(
                    id: record.id,
                    elapsedNanoseconds: downloadMetricsElapsed(since: startedAt),
                    encodedBytes: 0,
                    logicalWriteBytes: 0,
                    kernelAccountedWriteBytes: DownloadResourceSnapshot.capture().diskWriteDelta(from: resources),
                    synchronizeCount: 0,
                    succeeded: false
                ))
            }
            throw DownloadCoreError.permissionDenied(metadataURL.path)
        }
    }

    public func remove(id: DownloadID) throws {
        do {
            try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                request.predicate = NSPredicate(format: "id == %lld", id)
                request.fetchLimit = 1
                guard let task = try context.fetch(request).first else {
                    throw DownloadCoreError.notFound(id)
                }
                context.delete(task)
                try context.save()
            }
            records[id] = nil
        } catch let error as DownloadCoreError {
            throw error
        } catch {
            throw DownloadCoreError.permissionDenied(metadataURL.path)
        }
    }

    private static func decodeRecord(_ task: NSManagedObject) throws -> DownloadRecord {
        guard let id = (task.value(forKey: "id") as? NSNumber)?.int64Value,
              let sourceKind = task.value(forKey: "sourceKind") as? String,
              let kind = DownloadKind(rawValue: sourceKind),
              let link = task.value(forKey: "link") as? String,
              let folder = task.value(forKey: "folder") as? String,
              let name = task.value(forKey: "name") as? String,
              let statusValue = task.value(forKey: "status") as? String,
              let status = DownloadStatus(rawValue: statusValue),
              let createdAt = task.value(forKey: "createdAt") as? Date,
              let updatedAt = task.value(forKey: "updatedAt") as? Date else {
            throw DownloadCoreError.corruptRecord(
                URL(fileURLWithPath: "DownloadTask"),
                "元数据字段缺失或类型无效"
            )
        }

        let headers: [String: String]?
        if let headersJSON = task.value(forKey: "headersJSON") as? String {
            headers = try MetadataJSON.decode([String: String].self, from: headersJSON)
        } else {
            headers = nil
        }
        let taskSettings: DownloadTaskSettings?
        if let settingsJSON = task.value(forKey: "taskSettingsJSON") as? String {
            taskSettings = try MetadataJSON.decode(DownloadTaskSettings.self, from: settingsJSON)
        } else {
            taskSettings = nil
        }
        let source = DownloadSource(
            kind: kind,
            link: link,
            headers: headers,
            downloadPage: task.value(forKey: "downloadPage") as? String,
            suggestedName: task.value(forKey: "suggestedName") as? String
        )
        let parts = ((task.value(forKey: "parts") as? NSSet)?.allObjects as? [NSManagedObject] ?? [])
            .sorted {
                (($0.value(forKey: "partID") as? NSNumber)?.int64Value ?? 0)
                    < (($1.value(forKey: "partID") as? NSNumber)?.int64Value ?? 0)
            }
            .map { part in
                DownloadPart(
                    id: Int((part.value(forKey: "partID") as? NSNumber)?.int64Value ?? 0),
                    from: (part.value(forKey: "from") as? NSNumber)?.int64Value ?? 0,
                    to: (part.value(forKey: "to") as? NSNumber)?.int64Value,
                    downloaded: (part.value(forKey: "downloaded") as? NSNumber)?.int64Value ?? 0,
                    completed: (part.value(forKey: "completed") as? NSNumber)?.boolValue ?? false
                )
            }
        let queueID = (task.value(forKey: "queue") as? NSManagedObject)
            .flatMap { ($0.value(forKey: "id") as? NSNumber)?.int64Value }
        let categoryID = (task.value(forKey: "category") as? NSManagedObject)
            .flatMap { ($0.value(forKey: "id") as? NSNumber)?.int64Value }

        return DownloadRecord(
            id: id,
            source: source,
            folder: folder,
            name: name,
            status: status,
            downloadedBytes: (task.value(forKey: "downloadedBytes") as? NSNumber)?.int64Value ?? 0,
            totalBytes: (task.value(forKey: "totalBytes") as? NSNumber)?.int64Value,
            etag: task.value(forKey: "etag") as? String,
            lastModified: task.value(forKey: "lastModified") as? String,
            supportsResume: (task.value(forKey: "supportsResume") as? NSNumber)?.boolValue,
            parts: parts,
            queueID: queueID,
            categoryID: categoryID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            error: task.value(forKey: "error") as? String,
            fileChecksum: task.value(forKey: "fileChecksum") as? String,
            taskSettings: taskSettings,
            incompleteFileName: task.value(forKey: "incompleteFileName") as? String,
            revision: (task.value(forKey: "revision") as? NSNumber)?.int64Value ?? 1
        )
    }

    private static func encode(
        _ record: DownloadRecord,
        into task: NSManagedObject,
        context: NSManagedObjectContext
    ) throws {
        task.setValue(record.id, forKey: "id")
        task.setValue(record.source.kind.rawValue, forKey: "sourceKind")
        task.setValue(record.source.link, forKey: "link")
        task.setValue(try record.source.headers.map(MetadataJSON.encode), forKey: "headersJSON")
        task.setValue(record.source.downloadPage, forKey: "downloadPage")
        task.setValue(record.source.suggestedName, forKey: "suggestedName")
        task.setValue(record.folder, forKey: "folder")
        task.setValue(record.name, forKey: "name")
        task.setValue(record.status.rawValue, forKey: "status")
        task.setValue(record.downloadedBytes, forKey: "downloadedBytes")
        task.setValue(record.totalBytes, forKey: "totalBytes")
        task.setValue(record.etag, forKey: "etag")
        task.setValue(record.lastModified, forKey: "lastModified")
        task.setValue(record.supportsResume, forKey: "supportsResume")
        task.setValue(record.createdAt, forKey: "createdAt")
        task.setValue(record.updatedAt, forKey: "updatedAt")
        task.setValue(record.error, forKey: "error")
        task.setValue(record.fileChecksum, forKey: "fileChecksum")
        task.setValue(try record.taskSettings.map(MetadataJSON.encode), forKey: "taskSettingsJSON")
        task.setValue(record.incompleteFileName, forKey: "incompleteFileName")
        task.setValue(record.revision, forKey: "revision")

        let queue: NSManagedObject?
        if let queueID = record.queueID {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue")
            request.predicate = NSPredicate(format: "id == %lld", queueID)
            request.fetchLimit = 1
            queue = try context.fetch(request).first
        } else {
            queue = nil
        }
        task.setValue(queue, forKey: "queue")

        let category: NSManagedObject?
        if let categoryID = record.categoryID {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory")
            request.predicate = NSPredicate(format: "id == %lld", categoryID)
            request.fetchLimit = 1
            category = try context.fetch(request).first
        } else {
            category = nil
        }
        task.setValue(category, forKey: "category")

        let oldParts = ((task.value(forKey: "parts") as? NSSet)?.allObjects as? [NSManagedObject] ?? [])
        oldParts.forEach(context.delete)
        let parts = record.parts.map { value -> NSManagedObject in
            let object = NSEntityDescription.insertNewObject(forEntityName: "DownloadPart", into: context)
            object.setValue(Int64(value.id), forKey: "partID")
            object.setValue(value.from, forKey: "from")
            object.setValue(value.to, forKey: "to")
            object.setValue(value.downloaded, forKey: "downloaded")
            object.setValue(value.completed, forKey: "completed")
            object.setValue(task, forKey: "task")
            return object
        }
        task.setValue(NSSet(array: parts), forKey: "parts")
    }
}
