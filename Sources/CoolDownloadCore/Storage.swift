import Foundation
import CoreData

public struct DownloadStoreMutationStats: Sendable, Equatable {
    public let taskInserted: Bool
    public let taskAttributesUpdated: Int
    public let partsInserted: Int
    public let partsUpdated: Int
    public let partsDeleted: Int
    public let contextSaved: Bool

    public init(
        taskInserted: Bool = false,
        taskAttributesUpdated: Int = 0,
        partsInserted: Int = 0,
        partsUpdated: Int = 0,
        partsDeleted: Int = 0,
        contextSaved: Bool = false
    ) {
        self.taskInserted = taskInserted
        self.taskAttributesUpdated = taskAttributesUpdated
        self.partsInserted = partsInserted
        self.partsUpdated = partsUpdated
        self.partsDeleted = partsDeleted
        self.contextSaved = contextSaved
    }
}

/// Core Data façade for download metadata. The actor owns the value-type
/// cache used by `DownloadService`; managed objects never cross the actor
/// boundary. File contents and `.cooldm.part` files remain outside this store.
public actor DownloadStore {
    public let rootURL: URL
    public let metadataURL: URL

    private let database: MetadataDatabase
    private var records: [DownloadID: DownloadRecord] = [:]
    private var loaded = false
    private var reservedID: DownloadID = 0
    private var metrics: any DownloadMetricsSink = NoopDownloadMetricsSink()
    private var metricsEnabled = false
    private var latestMutationStats = DownloadStoreMutationStats()

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
        let loadedRecords: [DownloadRecord]
        do {
            loadedRecords = try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                return try context.fetch(request).map(Self.decodeRecord)
            }
        } catch let error as DownloadCoreError {
            throw error
        } catch {
            throw MetadataDatabaseError.loadFailed(metadataURL, error.localizedDescription)
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

    /// Reserves an integer ID before yielding back to a caller. Failed adds
    /// leave gaps; an ID is never returned twice by this store instance.
    public func reserveNextID() throws -> DownloadID {
        let maximum: Int64
        do {
            maximum = try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                request.fetchLimit = 1
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: false)]
                return (try context.fetch(request).first?.value(forKey: "id") as? NSNumber)?.int64Value ?? 0
            }
        } catch {
            throw MetadataDatabaseError.loadFailed(metadataURL, error.localizedDescription)
        }
        let highWater = max(maximum, reservedID)
        guard highWater < DownloadID.max else {
            throw DownloadCoreError.identifierExhausted
        }
        reservedID = highWater + 1
        return reservedID
    }

    public func updateMetrics(_ metrics: any DownloadMetricsSink) {
        self.metrics = metrics
        metricsEnabled = metrics.isEnabled
    }

    public func lastMutationStats() -> DownloadStoreMutationStats {
        latestMutationStats
    }

    public func save(_ record: DownloadRecord) throws {
        if let current = records[record.id], current.revision > record.revision {
            return
        }
        let startedAt = metricsEnabled ? downloadMetricsNow() : 0
        let resources = metricsEnabled ? DownloadResourceSnapshot.capture() : nil
        let projectionStartedAt = metricsEnabled ? downloadMetricsNow() : 0
        let encodedBytes = metricsEnabled
            ? Int64(try MetadataJSON.encode(record).utf8.count)
            : 0
        if metricsEnabled {
            metrics.record(.checkpointPhase(
                id: record.id,
                phase: .projectionEncode,
                elapsedNanoseconds: downloadMetricsElapsed(since: projectionStartedAt),
                bytes: encodedBytes
            ))
        }
        let sqliteSizeBefore = metricsEnabled ? databaseFileSize() : 0
        do {
            let result = try database.perform { context -> SaveMutationResult in
                try Self.performMutation(in: context) {
                    let fetchStartedAt = self.metricsEnabled ? downloadMetricsNow() : 0
                    let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                    request.predicate = NSPredicate(format: "id == %lld", record.id)
                    request.fetchLimit = 1
                    let existingTask = try context.fetch(request).first
                    if self.metricsEnabled {
                        self.metrics.record(.checkpointPhase(
                            id: record.id,
                            phase: .fetch,
                            elapsedNanoseconds: downloadMetricsElapsed(since: fetchStartedAt),
                            bytes: 0
                        ))
                    }
                    if let storedRevision = (existingTask?.value(forKey: "revision") as? NSNumber)?.int64Value,
                       storedRevision > record.revision {
                        return SaveMutationResult(stats: DownloadStoreMutationStats(), stale: true)
                    }

                    try Self.validateParts(record.parts)
                    let task = existingTask ?? NSEntityDescription.insertNewObject(
                        forEntityName: "DownloadTask",
                        into: context
                    )
                    let attributeStartedAt = self.metricsEnabled ? downloadMetricsNow() : 0
                    let updatedAttributes = try Self.syncAttributes(
                        record,
                        into: task,
                        context: context
                    )
                    if self.metricsEnabled {
                        self.metrics.record(.checkpointPhase(
                            id: record.id,
                            phase: .attributeUpdate,
                            elapsedNanoseconds: downloadMetricsElapsed(since: attributeStartedAt),
                            bytes: Int64(updatedAttributes)
                        ))
                    }

                    let partStartedAt = self.metricsEnabled ? downloadMetricsNow() : 0
                    let partChanges = try Self.syncParts(record.parts, task: task, context: context)
                    if self.metricsEnabled {
                        self.metrics.record(.checkpointPhase(
                            id: record.id,
                            phase: .partDiff,
                            elapsedNanoseconds: downloadMetricsElapsed(since: partStartedAt),
                            bytes: Int64(partChanges.inserted + partChanges.updated + partChanges.deleted)
                        ))
                    }

                    let shouldSave = context.hasChanges
                    if shouldSave {
                        let saveStartedAt = self.metricsEnabled ? downloadMetricsNow() : 0
                        do {
                            try context.save()
                        } catch {
                            context.rollback()
                            throw MetadataDatabaseError.saveFailed(
                                self.metadataURL,
                                error.localizedDescription
                            )
                        }
                        if self.metricsEnabled {
                            self.metrics.record(.checkpointPhase(
                                id: record.id,
                                phase: .contextSave,
                                elapsedNanoseconds: downloadMetricsElapsed(since: saveStartedAt),
                                bytes: 0
                            ))
                        }
                    }
                    return SaveMutationResult(
                        stats: DownloadStoreMutationStats(
                            taskInserted: existingTask == nil,
                            taskAttributesUpdated: updatedAttributes,
                            partsInserted: partChanges.inserted,
                            partsUpdated: partChanges.updated,
                            partsDeleted: partChanges.deleted,
                            contextSaved: shouldSave
                        ),
                        stale: false
                    )
                }
            }
            guard !result.stale else { return }
            records[record.id] = record
            latestMutationStats = result.stats
            if metricsEnabled, let resources {
                let sqliteDelta = max(0, databaseFileSize() - sqliteSizeBefore)
                metrics.record(.checkpointPhase(
                    id: record.id,
                    phase: .sqliteFileDelta,
                    elapsedNanoseconds: 0,
                    bytes: sqliteDelta
                ))
                metrics.record(.checkpoint(
                    id: record.id,
                    elapsedNanoseconds: downloadMetricsElapsed(since: startedAt),
                    encodedBytes: encodedBytes,
                    logicalWriteBytes: sqliteDelta,
                    kernelAccountedWriteBytes: DownloadResourceSnapshot.capture().diskWriteDelta(from: resources),
                    synchronizeCount: result.stats.contextSaved ? 1 : 0,
                    succeeded: true
                ))
            }
        } catch let error as DownloadCoreError {
            throw error
        } catch let error as MetadataDatabaseError {
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
            throw MetadataDatabaseError.saveFailed(metadataURL, error.localizedDescription)
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
            suggestedName: task.value(forKey: "suggestedName") as? String,
            credentialReference: task.value(forKey: "credentialReference") as? String
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
            sourceRefreshReason: (task.value(forKey: "sourceRefreshReason") as? String)
                .flatMap(DownloadSourceRefreshReason.init(rawValue:)),
            hlsResumeSnapshot: try (task.value(forKey: "hlsResumeSnapshotJSON") as? String)
                .map { try MetadataJSON.decode(HLSResumeSnapshot.self, from: $0) },
            hlsRenditions: try (task.value(forKey: "hlsRenditionsJSON") as? String)
                .map { try MetadataJSON.decode([HLSRendition].self, from: $0) },
            revision: (task.value(forKey: "revision") as? NSNumber)?.int64Value ?? 1
        )
    }

    private struct SaveMutationResult {
        let stats: DownloadStoreMutationStats
        let stale: Bool
    }

    private struct PartMutationCounts {
        var inserted = 0
        var updated = 0
        var deleted = 0
    }

    private func databaseFileSize() -> Int64 {
        [
            metadataURL,
            URL(fileURLWithPath: metadataURL.path + "-wal"),
            URL(fileURLWithPath: metadataURL.path + "-shm")
        ]
            .reduce(0) { partial, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return partial + Int64(size)
            }
    }

    private static func validateParts(_ parts: [DownloadPart]) throws {
        guard Set(parts.map(\.id)).count == parts.count else {
            throw DownloadCoreError.corruptRecord(
                URL(fileURLWithPath: "DownloadPart"),
                "分片 ID 重复"
            )
        }
        for part in parts {
            guard part.id >= 0,
                  part.from >= 0,
                  part.downloaded >= 0,
                  part.to.map({ $0 >= part.from && part.downloaded <= $0 - part.from + 1 }) ?? true else {
                throw DownloadCoreError.corruptRecord(
                    URL(fileURLWithPath: "DownloadPart"),
                    "分片范围或进度无效"
                )
            }
        }
    }

    /// A failed diff must not leave modified managed objects for a later save.
    private static func performMutation<T>(
        in context: NSManagedObjectContext,
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    private static func setIfChanged(
        _ value: Any?,
        forKey key: String,
        on object: NSManagedObject
    ) -> Bool {
        let current = object.value(forKey: key)
        let equal: Bool
        switch (current, value) {
        case (nil, nil):
            equal = true
        case let (lhs as NSObject, rhs as NSObject):
            equal = lhs == rhs
        default:
            equal = false
        }
        guard !equal else { return false }
        object.setValue(value, forKey: key)
        return true
    }

    private static func syncAttributes(
        _ record: DownloadRecord,
        into task: NSManagedObject,
        context: NSManagedObjectContext
    ) throws -> Int {
        try DownloadSourceSecurity.validate(record.source)
        var count = 0
        func set(_ value: Any?, _ key: String) {
            if setIfChanged(value, forKey: key, on: task) { count += 1 }
        }
        set(record.id, "id")
        set(record.source.kind.rawValue, "sourceKind")
        set(record.source.link, "link")
        set(try record.source.headers.map(MetadataJSON.encode), "headersJSON")
        set(record.source.downloadPage, "downloadPage")
        set(record.source.suggestedName, "suggestedName")
        set(record.source.credentialReference, "credentialReference")
        set(record.folder, "folder")
        set(record.name, "name")
        set(record.status.rawValue, "status")
        set(record.downloadedBytes, "downloadedBytes")
        set(record.totalBytes, "totalBytes")
        set(record.etag, "etag")
        set(record.lastModified, "lastModified")
        set(record.supportsResume, "supportsResume")
        set(record.createdAt, "createdAt")
        set(record.updatedAt, "updatedAt")
        set(record.error, "error")
        set(record.fileChecksum, "fileChecksum")
        set(try record.taskSettings.map(MetadataJSON.encode), "taskSettingsJSON")
        set(record.incompleteFileName, "incompleteFileName")
        set(record.sourceRefreshReason?.rawValue, "sourceRefreshReason")
        set(try record.hlsResumeSnapshot.map(MetadataJSON.encode), "hlsResumeSnapshotJSON")
        set(try record.hlsRenditions.map(MetadataJSON.encode), "hlsRenditionsJSON")
        set(record.revision, "revision")

        let queue: NSManagedObject?
        if let queueID = record.queueID {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadQueue")
            request.predicate = NSPredicate(format: "id == %lld", queueID)
            request.fetchLimit = 1
            queue = try context.fetch(request).first
        } else {
            queue = nil
        }
        if setIfChanged(queue, forKey: "queue", on: task) { count += 1 }

        let category: NSManagedObject?
        if let categoryID = record.categoryID {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory")
            request.predicate = NSPredicate(format: "id == %lld", categoryID)
            request.fetchLimit = 1
            category = try context.fetch(request).first
        } else {
            category = nil
        }
        if setIfChanged(category, forKey: "category", on: task) { count += 1 }
        return count
    }

    private static func syncParts(
        _ parts: [DownloadPart],
        task: NSManagedObject,
        context: NSManagedObjectContext
    ) throws -> PartMutationCounts {
        let oldParts = (task.value(forKey: "parts") as? NSSet)?.allObjects as? [NSManagedObject] ?? []
        let grouped = Dictionary(grouping: oldParts) {
            Int(($0.value(forKey: "partID") as? NSNumber)?.int64Value ?? -1)
        }
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw DownloadCoreError.corruptRecord(
                URL(fileURLWithPath: "DownloadPart"),
                "数据库中存在重复分片 ID"
            )
        }
        var existing = grouped.mapValues { $0[0] }
        var counts = PartMutationCounts()

        for value in parts {
            if let object = existing.removeValue(forKey: value.id) {
                var changed = false
                changed = setIfChanged(Int64(value.id), forKey: "partID", on: object) || changed
                changed = setIfChanged(value.from, forKey: "from", on: object) || changed
                changed = setIfChanged(value.to, forKey: "to", on: object) || changed
                changed = setIfChanged(value.downloaded, forKey: "downloaded", on: object) || changed
                changed = setIfChanged(value.completed, forKey: "completed", on: object) || changed
                if changed { counts.updated += 1 }
                continue
            }
            let object = NSEntityDescription.insertNewObject(forEntityName: "DownloadPart", into: context)
            object.setValue(Int64(value.id), forKey: "partID")
            object.setValue(value.from, forKey: "from")
            object.setValue(value.to, forKey: "to")
            object.setValue(value.downloaded, forKey: "downloaded")
            object.setValue(value.completed, forKey: "completed")
            object.setValue(task, forKey: "task")
            counts.inserted += 1
        }
        for object in existing.values {
            context.delete(object)
            counts.deleted += 1
        }
        return counts
    }
}
