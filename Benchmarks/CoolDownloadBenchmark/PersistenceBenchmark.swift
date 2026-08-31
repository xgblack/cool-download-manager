import CoreData
import CoolDownloadCore
import Foundation

/// A benchmark-only comparison of the production incremental Core Data
/// mutation path with the former delete-and-reinsert relationship pattern.
/// The reference path intentionally stays here so it cannot become a second
/// production persistence implementation.
struct PersistenceBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let environment: BenchmarkEnvironment
    let configuration: BenchmarkConfiguration
    let taskCount: Int
    let partCount: Int
    let iterations: Int
    let incremental: PersistenceBenchmarkSeries
    let fullRebuildReference: PersistenceBenchmarkSeries
    let noOp: PersistenceNoOpSummary
    let verified: Bool
}

struct PersistenceBenchmarkSeries: Codable, Sendable {
    let operationCount: Int
    let totalMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let fetchP95Milliseconds: Double
    let attributeUpdateP95Milliseconds: Double
    let partDiffP95Milliseconds: Double
    let contextSaveP95Milliseconds: Double
    let changedPartRows: Int
    let insertedPartRows: Int
    let deletedPartRows: Int
    let sqliteFileDeltaBytes: Int64
    let userCPUMilliseconds: Double
    let systemCPUMilliseconds: Double
    let peakResidentMemoryBytes: UInt64
    let peakOpenFileDescriptorCount: Int
}

struct PersistenceNoOpSummary: Codable, Sendable {
    let operationCount: Int
    let contextSaveCount: Int
    let p95Milliseconds: Double
    let verifiedSkippedSave: Bool
}

enum PersistenceBenchmarkRunner {
    static func run(configuration: BenchmarkConfiguration) async throws -> PersistenceBenchmarkReport {
        let incrementalRoot = try makeRoot(prefix: "cooldm-persistence-incremental")
        let referenceRoot = try makeRoot(prefix: "cooldm-persistence-reference")
        let keepFiles = configuration.keepFiles
        defer {
            if !keepFiles {
                try? FileManager.default.removeItem(at: incrementalRoot)
                try? FileManager.default.removeItem(at: referenceRoot)
            } else {
                fputs("persistence files: \(incrementalRoot.path), \(referenceRoot.path)\n", stderr)
            }
        }

        let fixture = makeRecords(
            root: incrementalRoot,
            taskCount: configuration.persistenceTaskCount,
            partCount: configuration.persistencePartCount
        )
        let incrementalResult = try await measureIncremental(
            root: incrementalRoot,
            records: fixture,
            iterations: configuration.persistenceIterations
        )
        let referenceFixture = makeRecords(
            root: referenceRoot,
            taskCount: configuration.persistenceTaskCount,
            partCount: configuration.persistencePartCount
        )
        let referenceResult = try await measureFullRebuild(
            root: referenceRoot,
            records: referenceFixture,
            iterations: configuration.persistenceIterations
        )

        let noOp = incrementalResult.noOp
        let verified = incrementalResult.verified
            && referenceResult.verified
            && noOp.verifiedSkippedSave
            && incrementalResult.series.changedPartRows == configuration.persistenceIterations
            && incrementalResult.series.insertedPartRows == 0
            && incrementalResult.series.deletedPartRows == 0
            && referenceResult.series.insertedPartRows
                == configuration.persistenceIterations * configuration.persistencePartCount
            && referenceResult.series.deletedPartRows
                == configuration.persistenceIterations * configuration.persistencePartCount

        return PersistenceBenchmarkReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: .current,
            configuration: configuration.redactedForReport(),
            taskCount: configuration.persistenceTaskCount,
            partCount: configuration.persistencePartCount,
            iterations: configuration.persistenceIterations,
            incremental: incrementalResult.series,
            fullRebuildReference: referenceResult.series,
            noOp: noOp,
            verified: verified
        )
    }

    private struct IncrementalResult {
        let series: PersistenceBenchmarkSeries
        let noOp: PersistenceNoOpSummary
        let verified: Bool
    }

    private struct ReferenceResult {
        let series: PersistenceBenchmarkSeries
        let verified: Bool
    }

    private static func measureIncremental(
        root: URL,
        records: [DownloadRecord],
        iterations: Int
    ) async throws -> IncrementalResult {
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        let metrics = DownloadMetricsCollector(maximumEventCount: max(10_000, iterations * 8))
        await store.updateMetrics(metrics)
        for record in records {
            try await store.save(record)
        }
        metrics.reset()

        var current = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var durations: [Double] = []
        var sqliteDelta: Int64 = 0
        var changedPartRows = 0
        var insertedPartRows = 0
        var deletedPartRows = 0
        var startResources = DownloadResourceSnapshot.capture()
        var peakResources = startResources
        startResources = DownloadResourceSnapshot.capture()

        for index in 0..<iterations {
            let id = records[index % records.count].id
            guard var record = current[id], !record.parts.isEmpty else {
                throw PersistenceBenchmarkError.invalidFixture
            }
            let partIndex = index % record.parts.count
            let partLength = record.parts[partIndex].to.map {
                $0 - record.parts[partIndex].from + 1
            } ?? 1
            record.parts[partIndex].downloaded = min(
                partLength,
                record.parts[partIndex].downloaded + 1
            )
            record.parts[partIndex].completed = record.parts[partIndex].downloaded == partLength
            record.downloadedBytes = record.parts.reduce(0) { $0 + $1.downloaded }
            record.updatedAt = Date(timeIntervalSince1970: Double(index + 1))
            record.revision += 1

            let before = sqliteFileSize(root)
            let started = DispatchTime.now().uptimeNanoseconds
            try await store.save(record)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            durations.append(Double(elapsed) / 1_000_000)
            sqliteDelta += max(0, sqliteFileSize(root) - before)
            let stats = await store.lastMutationStats()
            changedPartRows += stats.partsUpdated
            insertedPartRows += stats.partsInserted
            deletedPartRows += stats.partsDeleted
            current[id] = record
            peakResources = maxResources(peakResources, DownloadResourceSnapshot.capture())
        }

        let incrementalEvents = metrics.snapshot()
        guard let noOpRecord = current.values.first else {
            throw PersistenceBenchmarkError.invalidFixture
        }
        metrics.reset()
        let noOpStarted = DispatchTime.now().uptimeNanoseconds
        try await store.save(noOpRecord)
        let noOpElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - noOpStarted
        ) / 1_000_000
        let noOpStats = await store.lastMutationStats()
        let noOp = PersistenceNoOpSummary(
            operationCount: 1,
            contextSaveCount: noOpStats.contextSaved ? 1 : 0,
            p95Milliseconds: noOpElapsed,
            verifiedSkippedSave: !noOpStats.contextSaved
        )

        let phases = phaseValues(incrementalEvents)
        let endResources = DownloadResourceSnapshot.capture()
        peakResources = maxResources(peakResources, endResources)
        let series = PersistenceBenchmarkSeries(
            operationCount: durations.count,
            totalMilliseconds: durations.reduce(0, +),
            p50Milliseconds: percentile(durations, 0.50),
            p95Milliseconds: percentile(durations, 0.95),
            fetchP95Milliseconds: percentile(phases[.fetch] ?? [], 0.95),
            attributeUpdateP95Milliseconds: percentile(phases[.attributeUpdate] ?? [], 0.95),
            partDiffP95Milliseconds: percentile(phases[.partDiff] ?? [], 0.95),
            contextSaveP95Milliseconds: percentile(phases[.contextSave] ?? [], 0.95),
            changedPartRows: changedPartRows,
            insertedPartRows: insertedPartRows,
            deletedPartRows: deletedPartRows,
            sqliteFileDeltaBytes: sqliteDelta,
            userCPUMilliseconds: cpuDelta(
                endResources.userCPUTimeNanoseconds,
                startResources.userCPUTimeNanoseconds
            ),
            systemCPUMilliseconds: cpuDelta(
                endResources.systemCPUTimeNanoseconds,
                startResources.systemCPUTimeNanoseconds
            ),
            peakResidentMemoryBytes: peakResources.residentMemoryBytes,
            peakOpenFileDescriptorCount: peakResources.openFileDescriptorCount
        )
        let reopened = try DownloadStore(rootURL: root, database: database)
        let loaded = try await reopened.load()
        let verified = loaded.count == records.count
            && loaded.allSatisfy { current[$0.id] == $0 }
        try? database.reset()
        return IncrementalResult(series: series, noOp: noOp, verified: verified)
    }

    private static func measureFullRebuild(
        root: URL,
        records: [DownloadRecord],
        iterations: Int
    ) async throws -> ReferenceResult {
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        for record in records {
            try await store.save(record)
        }

        var current = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var durations: [Double] = []
        var fetchDurations: [Double] = []
        var attributeDurations: [Double] = []
        var partDurations: [Double] = []
        var saveDurations: [Double] = []
        var sqliteDelta: Int64 = 0
        var insertedPartRows = 0
        var deletedPartRows = 0
        let startResources = DownloadResourceSnapshot.capture()
        var peakResources = startResources

        for index in 0..<iterations {
            let id = records[index % records.count].id
            guard var record = current[id], !record.parts.isEmpty else {
                throw PersistenceBenchmarkError.invalidFixture
            }
            let partIndex = index % record.parts.count
            let partLength = record.parts[partIndex].to.map {
                $0 - record.parts[partIndex].from + 1
            } ?? 1
            record.parts[partIndex].downloaded = min(
                partLength,
                record.parts[partIndex].downloaded + 1
            )
            record.parts[partIndex].completed = record.parts[partIndex].downloaded == partLength
            record.downloadedBytes = record.parts.reduce(0) { $0 + $1.downloaded }
            record.updatedAt = Date(timeIntervalSince1970: Double(index + 1))
            record.revision += 1

            let before = sqliteFileSize(root)
            let operationStart = DispatchTime.now().uptimeNanoseconds
            let timings = try database.perform { context -> ReferenceTimings in
                let fetchStart = DispatchTime.now().uptimeNanoseconds
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
                request.predicate = NSPredicate(format: "id == %lld", id)
                request.fetchLimit = 1
                guard let task = try context.fetch(request).first else {
                    throw PersistenceBenchmarkError.missingTask(id)
                }
                let fetch = elapsedMilliseconds(since: fetchStart)

                let attributeStart = DispatchTime.now().uptimeNanoseconds
                task.setValue(record.downloadedBytes, forKey: "downloadedBytes")
                task.setValue(record.revision, forKey: "revision")
                task.setValue(record.updatedAt, forKey: "updatedAt")
                let attribute = elapsedMilliseconds(since: attributeStart)

                let partStart = DispatchTime.now().uptimeNanoseconds
                let oldParts = (task.value(forKey: "parts") as? NSSet)?.allObjects
                    as? [NSManagedObject] ?? []
                oldParts.forEach(context.delete)
                for value in record.parts {
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "DownloadPart",
                        into: context
                    )
                    object.setValue(Int64(value.id), forKey: "partID")
                    object.setValue(value.from, forKey: "from")
                    object.setValue(value.to, forKey: "to")
                    object.setValue(value.downloaded, forKey: "downloaded")
                    object.setValue(value.completed, forKey: "completed")
                    object.setValue(task, forKey: "task")
                }
                let part = elapsedMilliseconds(since: partStart)

                let saveStart = DispatchTime.now().uptimeNanoseconds
                try context.save()
                let save = elapsedMilliseconds(since: saveStart)
                return ReferenceTimings(
                    fetch: fetch,
                    attribute: attribute,
                    part: part,
                    save: save,
                    inserted: record.parts.count,
                    deleted: oldParts.count
                )
            }
            durations.append(elapsedMilliseconds(since: operationStart))
            fetchDurations.append(timings.fetch)
            attributeDurations.append(timings.attribute)
            partDurations.append(timings.part)
            saveDurations.append(timings.save)
            insertedPartRows += timings.inserted
            deletedPartRows += timings.deleted
            sqliteDelta += max(0, sqliteFileSize(root) - before)
            current[id] = record
            peakResources = maxResources(peakResources, DownloadResourceSnapshot.capture())
        }

        let endResources = DownloadResourceSnapshot.capture()
        peakResources = maxResources(peakResources, endResources)
        let series = PersistenceBenchmarkSeries(
            operationCount: durations.count,
            totalMilliseconds: durations.reduce(0, +),
            p50Milliseconds: percentile(durations, 0.50),
            p95Milliseconds: percentile(durations, 0.95),
            fetchP95Milliseconds: percentile(fetchDurations, 0.95),
            attributeUpdateP95Milliseconds: percentile(attributeDurations, 0.95),
            partDiffP95Milliseconds: percentile(partDurations, 0.95),
            contextSaveP95Milliseconds: percentile(saveDurations, 0.95),
            changedPartRows: 0,
            insertedPartRows: insertedPartRows,
            deletedPartRows: deletedPartRows,
            sqliteFileDeltaBytes: sqliteDelta,
            userCPUMilliseconds: cpuDelta(
                endResources.userCPUTimeNanoseconds,
                startResources.userCPUTimeNanoseconds
            ),
            systemCPUMilliseconds: cpuDelta(
                endResources.systemCPUTimeNanoseconds,
                startResources.systemCPUTimeNanoseconds
            ),
            peakResidentMemoryBytes: peakResources.residentMemoryBytes,
            peakOpenFileDescriptorCount: peakResources.openFileDescriptorCount
        )
        let loaded = try database.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.predicate = NSPredicate(format: "id == %lld", records[0].id)
            guard let task = try context.fetch(request).first,
                  let parts = (task.value(forKey: "parts") as? NSSet)?.allObjects
                    as? [NSManagedObject] else {
                return false
            }
            return parts.count == records[0].parts.count
        }
        try? database.reset()
        return ReferenceResult(series: series, verified: loaded)
    }

    private struct ReferenceTimings {
        let fetch: Double
        let attribute: Double
        let part: Double
        let save: Double
        let inserted: Int
        let deleted: Int
    }

    private static func makeRecords(
        root: URL,
        taskCount: Int,
        partCount: Int
    ) -> [DownloadRecord] {
        (0..<taskCount).map { taskIndex in
            let parts = (0..<partCount).map { partIndex in
                let from = Int64(partIndex) * 1_024
                return DownloadPart(
                    id: partIndex,
                    from: from,
                    to: from + 1_023
                )
            }
            return DownloadRecord(
                id: Int64(taskIndex + 1),
                source: DownloadSource(
                    kind: .http,
                    link: "https://benchmark.invalid/persistence-\(taskIndex).bin"
                ),
                folder: root.path,
                name: "persistence-\(taskIndex).bin",
                status: .paused,
                totalBytes: Int64(partCount) * 1_024,
                supportsResume: true,
                parts: parts
            )
        }
    }

    private static func makeRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func sqliteFileSize(_ root: URL) -> Int64 {
        let store = root.appendingPathComponent("metadata.sqlite")
        return [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm")]
            .reduce(0) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
    }

    private static func phaseValues(
        _ events: [DownloadMetricEvent]
    ) -> [DownloadCheckpointPhase: [Double]] {
        events.reduce(into: [:]) { result, event in
            guard case .checkpointPhase(_, let phase, let elapsed, _) = event else { return }
            result[phase, default: []].append(Double(elapsed) / 1_000_000)
        }
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func cpuDelta(_ end: UInt64, _ start: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }

    private static func maxResources(
        _ lhs: DownloadResourceSnapshot,
        _ rhs: DownloadResourceSnapshot
    ) -> DownloadResourceSnapshot {
        DownloadResourceSnapshot(
            userCPUTimeNanoseconds: max(lhs.userCPUTimeNanoseconds, rhs.userCPUTimeNanoseconds),
            systemCPUTimeNanoseconds: max(lhs.systemCPUTimeNanoseconds, rhs.systemCPUTimeNanoseconds),
            residentMemoryBytes: max(lhs.residentMemoryBytes, rhs.residentMemoryBytes),
            openFileDescriptorCount: max(lhs.openFileDescriptorCount, rhs.openFileDescriptorCount),
            diskWriteBytes: max(lhs.diskWriteBytes, rhs.diskWriteBytes)
        )
    }
}

enum PersistenceBenchmarkError: Error, LocalizedError {
    case invalidFixture
    case missingTask(DownloadID)

    var errorDescription: String? {
        switch self {
        case .invalidFixture:
            return "Persistence benchmark fixture is invalid"
        case .missingTask(let id):
            return "Persistence benchmark task is missing: \(id)"
        }
    }
}
