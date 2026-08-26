import Foundation

public actor DownloadService {
    private let store: DownloadStore
    private var downloader: HTTPDownloader
    private var hlsDownloader: HLSDownloader
    private var defaultFolder: URL
    private var schedulerConfiguration: DownloadSchedulerConfiguration
    private var retryPolicy: DownloadRetryPolicy
    private var records: [DownloadID: DownloadRecord] = [:]
    private var tasks: [DownloadID: Task<Void, Never>] = [:]
    private var activeIDs: Set<DownloadID> = []
    private var queuedIDs: [DownloadID] = []
    private var queueConcurrencyLimits: [DownloadID: Int] = [:]
    private var queuePolicies: [DownloadID: DownloadQueuePolicy] = [:]
    private var activeQueueIDs: Set<DownloadID> = []
    private var perHostSettings: [PerHostSettingsItem] = []
    private var subscribers: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var queueEventSubscribers: [UUID: AsyncStream<DownloadQueueEvent>.Continuation] = [:]
    private var shuttingDown = false

    public init(
        store: DownloadStore,
        downloader: HTTPDownloader = HTTPDownloader(),
        hlsDownloader: HLSDownloader? = nil,
        defaultFolder: URL,
        schedulerConfiguration: DownloadSchedulerConfiguration = .init(),
        retryPolicy: DownloadRetryPolicy = .init()
    ) {
        self.store = store
        self.downloader = downloader
        self.hlsDownloader = hlsDownloader ?? HLSDownloader()
        self.defaultFolder = defaultFolder.standardizedFileURL
        self.schedulerConfiguration = schedulerConfiguration
        self.retryPolicy = retryPolicy
    }

    public func boot() async throws {
        shuttingDown = false
        var loaded = Dictionary(
            uniqueKeysWithValues: try await store.load().map { ($0.id, $0) }
        )
        // A process cannot safely continue a live task after a restart. Keep
        // its part file and expose it as resumable instead of leaving a stale
        // "downloading" state that has no associated task.
        for id in Array(loaded.keys) {
            guard var record = loaded[id] else { continue }
            var changed = false
            if record.status == .downloading || record.status == .preparing || record.status == .retrying {
                record.status = .paused
                record.updatedAt = Date()
                record.revision += 1
                changed = true
            }
            if changed {
                loaded[id] = record
                try await store.save(record)
            }
        }
        records = loaded
    }

    /// Applies settings that affect future scheduling and new destinations.
    /// Active jobs are left intact; queued jobs are re-evaluated immediately.
    public func updateConfiguration(
        schedulerConfiguration: DownloadSchedulerConfiguration? = nil,
        retryPolicy: DownloadRetryPolicy? = nil,
        defaultFolder: URL? = nil,
        networkConfiguration: HTTPNetworkConfiguration? = nil
    ) {
        if let schedulerConfiguration {
            self.schedulerConfiguration = schedulerConfiguration
        }
        if let retryPolicy {
            self.retryPolicy = retryPolicy
        }
        if let defaultFolder {
            self.defaultFolder = defaultFolder.standardizedFileURL
        }
        if let networkConfiguration {
            downloader = HTTPDownloader(networkConfiguration: networkConfiguration)
            hlsDownloader = HLSDownloader(networkConfiguration: networkConfiguration)
        }
        if !shuttingDown {
            launchQueuedDownloads()
        }
    }

    /// Replaces the host override table used for subsequently started jobs.
    /// Active URLSession tasks retain the headers and credentials with which
    /// they were created; changing this table therefore cannot race a writer.
    public func updatePerHostSettings(_ settings: [PerHostSettingsItem]) {
        perHostSettings = settings
    }

    /// Persists per-task overrides. Running work keeps its current network
    /// operation; the new values are used on the next start/retry so changing
    /// a detail form cannot race an in-flight writer.
    @discardableResult
    public func updateTaskSettings(
        id: DownloadID,
        settings: DownloadTaskSettings?
    ) async throws -> DownloadRecord {
        guard var record = records[id] else {
            throw DownloadCoreError.notFound(id)
        }
        let validated = try settings?.validated()
        record.taskSettings = validated
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        try await store.save(record)
        emit(.updated(record))
        return record
    }

    /// Updates queue-specific concurrency without making the downloader depend
    /// on a UI store. A missing queue entry uses the global scheduler limit.
    public func updateQueueConcurrency(_ limits: [DownloadID: Int]) {
        queueConcurrencyLimits = limits.mapValues { max(1, $0) }
        if !shuttingDown {
            launchQueuedDownloads()
        }
    }

    /// Replaces the queue policies used by the scheduler. Existing active
    /// jobs keep running; queued jobs are re-evaluated against the new limits.
    public func updateQueuePolicies(_ policies: [DownloadID: DownloadQueuePolicy]) {
        queuePolicies = policies
        queueConcurrencyLimits = policies.mapValues { $0.maxConcurrent }
        if !shuttingDown {
            launchQueuedDownloads()
        }
    }

    /// Stop scheduling and persist resumable states before the process exits.
    /// The store lock is released when the service and store are deallocated.
    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true

        // Queued work has no task that can persist its state after cancellation.
        // Mark it paused first, then cancel active tasks so their cancellation
        // handlers preserve the current part file and progress.
        let queued = Set(queuedIDs)
        queuedIDs.removeAll()
        for id in queued {
            guard var record = records[id], record.status == .preparing else { continue }
            record.status = .paused
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            do {
                try await store.save(record)
            } catch {
                reportPersistenceFailure("queued state", id: id, error: error)
            }
            emit(.updated(record))
        }

        let taskIDs = Array(tasks.keys)
        for id in taskIDs {
            if let record = records[id], record.status == .retrying {
                var paused = record
                paused.status = .paused
                paused.error = nil
                paused.updatedAt = Date()
                paused.revision += 1
                records[id] = paused
                do {
                    try await store.save(paused)
                } catch {
                    reportPersistenceFailure("retry state", id: id, error: error)
                }
                emit(.updated(paused))
            }
        }

        let runningTasks = Array(tasks.values)
        runningTasks.forEach { $0.cancel() }
        for task in runningTasks {
            await task.value
        }
        tasks.removeAll()
        activeIDs.removeAll()
        activeQueueIDs.removeAll()
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        queueEventSubscribers.values.forEach { $0.finish() }
        queueEventSubscribers.removeAll()
    }

    public func events() -> AsyncStream<DownloadEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func queueEvents() -> AsyncStream<DownloadQueueEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            queueEventSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeQueueEventSubscriber(id) }
            }
        }
    }

    public func snapshot() -> DownloadSnapshot {
        DownloadSnapshot(downloads: records.values.sorted { $0.id < $1.id })
    }

    /// Removes completed records whose destination was deleted outside the
    /// manager. This mirrors the historical "track deleted files" option and
    /// keeps the persisted queue in sync with the filesystem.
    @discardableResult
    public func removeCompletedDownloadsMissingFiles() async throws -> [DownloadID] {
        let missing = records.values
            .filter { $0.status == .completed && !FileManager.default.fileExists(atPath: $0.destinationURL.path) }
            .map(\.id)
        for id in missing {
            guard let record = records[id], record.status == .completed else { continue }
            try await store.remove(id: id)
            records[id] = nil
            emit(.removed(id: id))
            if let queueID = record.queueID {
                reconcileQueue(queueID)
            }
        }
        return missing
    }

    public func add(_ request: AddDownloadRequest) async throws -> DownloadID {
        guard let url = URL(string: request.source.link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadCoreError.invalidURL(request.source.link)
        }

        let folderURL = URL(fileURLWithPath: request.folder ?? defaultFolder.path, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folderURL.path) else {
            throw DownloadCoreError.permissionDenied(folderURL.path)
        }

        let id = await store.nextID()
        var source = request.source
        let requestedName = request.name?.nilIfBlank
        let suggestedName = source.suggestedName?.nilIfBlank
        // Persist the chosen name as the source hint as well. This lets later
        // HTTP metadata updates distinguish a user/browser-provided name from
        // an automatic URL fallback without adding a new record field.
        source.suggestedName = requestedName ?? suggestedName
        let candidateName = requestedName
            ?? suggestedName
            ?? DownloadFileNameResolver.fromURL(request.source.link)
            ?? "download-\(id)"
        let name = try validatedName(candidateName)
        let destination = folderURL.appendingPathComponent(name)
        if records.values.contains(where: { $0.destinationURL.standardizedFileURL == destination }) {
            throw DownloadCoreError.duplicateDestination(destination.path)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw DownloadCoreError.duplicateDestination(destination.path)
        }

        let now = Date()
        let record = DownloadRecord(
            id: id,
            source: source,
            folder: folderURL.path,
            name: name,
            queueID: request.queueID,
            categoryID: request.categoryID,
            createdAt: now,
            updatedAt: now,
            taskSettings: try request.taskSettings?.validated(),
            incompleteFileName: schedulerConfiguration.appendExtensionToIncompleteDownloads
                ? "\(name).abdm.part"
                : nil
        )
        records[id] = record
        try await store.save(record)
        emit(.created(record))

        if request.start {
            try await start(id: id)
        }
        return id
    }

    public func start(id: DownloadID) async throws {
        guard !shuttingDown else {
            throw DownloadCoreError.cancelled
        }
        guard var record = records[id] else {
            throw DownloadCoreError.notFound(id)
        }
        guard record.status != .completed, tasks[id] == nil else {
            if record.status == .completed {
                throw DownloadCoreError.invalidState(id, record.status)
            }
            return
        }

        record.status = .preparing
        record.error = nil
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        try await store.save(record)
        emit(.updated(record))

        if canLaunch(id) {
            launch(id: id)
        } else if !queuedIDs.contains(id) {
            queuedIDs.append(id)
        }
    }

    public func resume(ids: [DownloadID]) async throws {
        for id in ids {
            try await start(id: id)
        }
    }

    public func startQueue(id queueID: DownloadID, orderedIDs: [DownloadID]? = nil) async throws {
        let available = Set(records.values
            .filter { $0.queueID == queueID && $0.status != .completed }
            .map(\.id))
        let ids: [DownloadID]
        if let orderedIDs {
            ids = orderedIDs.filter { available.contains($0) }
                + available.subtracting(orderedIDs).sorted()
        } else {
            ids = available.sorted()
        }
        activeQueueIDs.insert(queueID)
        for id in ids {
            try await start(id: id)
        }
        reconcileQueue(queueID)
    }

    /// Stops a queue and pauses every task that belongs to it. The queue is
    /// removed from the active set before cancellation so completion checks
    /// cannot immediately restart work while the pause operation is running.
    public func stopQueue(id queueID: DownloadID) async throws {
        activeQueueIDs.remove(queueID)
        let ids = records.values
            .filter { $0.queueID == queueID && ($0.status == .preparing || $0.status == .downloading || $0.status == .retrying) }
            .map(\.id)
        if !ids.isEmpty {
            try await pause(ids: ids)
        }
    }

    public func pause(ids: [DownloadID]) async throws {
        for id in ids {
            guard var record = records[id] else {
                throw DownloadCoreError.notFound(id)
            }
            guard record.status != .completed else {
                throw DownloadCoreError.invalidState(id, record.status)
            }
            queuedIDs.removeAll { $0 == id }
            record.status = .paused
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            try await store.save(record)
            emit(.updated(record))
            if let task = tasks[id] {
                task.cancel()
                await task.value
            }
        }
    }

    public func retry(ids: [DownloadID]) async throws {
        for id in ids {
            guard var record = records[id] else {
                throw DownloadCoreError.notFound(id)
            }
            if let task = tasks[id] {
                task.cancel()
                await task.value
            }
            record.status = .added
            record.error = nil
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            try await store.save(record)
            emit(.updated(record))
            try await start(id: id)
        }
    }

    /// Starts a completed task from scratch. The existing destination and
    /// partial file are removed before the record is reset so the normal
    /// duplicate-destination guard cannot reject the new run.
    public func redownload(ids: [DownloadID]) async throws {
        for id in ids {
            guard var record = records[id] else {
                throw DownloadCoreError.notFound(id)
            }
            if let task = tasks[id] {
                task.cancel()
                await task.value
            }
            queuedIDs.removeAll { $0 == id }
            if FileManager.default.fileExists(atPath: record.destinationURL.path) {
                try FileManager.default.removeItem(at: record.destinationURL)
            }
            if FileManager.default.fileExists(atPath: record.incompleteURL.path) {
                try FileManager.default.removeItem(at: record.incompleteURL)
            }
            record.status = .added
            record.downloadedBytes = 0
            record.totalBytes = nil
            record.etag = nil
            record.lastModified = nil
            record.parts = []
            record.error = nil
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            try await store.save(record)
            emit(.updated(record))
            try await start(id: id)
        }
    }

    public func updateChecksum(id: DownloadID, checksum: FileChecksum?) async throws {
        guard var record = records[id] else { throw DownloadCoreError.notFound(id) }
        record.fileChecksum = checksum?.description
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        try await store.save(record)
        emit(.updated(record))
    }

    public func assignQueue(ids: [DownloadID], queueID: DownloadID?) async throws {
        for id in ids {
            guard var record = records[id] else { throw DownloadCoreError.notFound(id) }
            record.queueID = queueID
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            try await store.save(record)
            emit(.updated(record))
        }
    }

    public func assignCategory(ids: [DownloadID], categoryID: DownloadID?) async throws {
        for id in ids {
            guard var record = records[id] else { throw DownloadCoreError.notFound(id) }
            record.categoryID = categoryID
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            try await store.save(record)
            emit(.updated(record))
        }
    }

    public func remove(ids: [DownloadID], removeFiles: Bool) async throws {
        for id in ids {
            guard let record = records[id] else {
                throw DownloadCoreError.notFound(id)
            }
            let queueID = record.queueID
            if let task = tasks[id] {
                task.cancel()
                await task.value
            }
            queuedIDs.removeAll { $0 == id }
            tasks[id] = nil
            activeIDs.remove(id)
            if removeFiles {
                if FileManager.default.fileExists(atPath: record.destinationURL.path) {
                    try FileManager.default.removeItem(at: record.destinationURL)
                }
            }
            if removeFiles || (schedulerConfiguration.deletePartialFileOnDownloadCancellation && record.status != .completed) {
                if FileManager.default.fileExists(atPath: record.incompleteURL.path) {
                    try FileManager.default.removeItem(at: record.incompleteURL)
                }
            }
            records[id] = nil
            try await store.remove(id: id)
            emit(.removed(id: id))
            if let queueID {
                reconcileQueue(queueID)
            }
        }
    }

    private func launch(id: DownloadID) {
        guard tasks[id] == nil, records[id] != nil else { return }
        activeIDs.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.runAndRelease(id: id)
        }
    }

    private func runAndRelease(id: DownloadID) async {
        await run(id: id)
        taskDidFinish(id: id)
    }

    private func taskDidFinish(id: DownloadID) {
        let queueID = records[id]?.queueID
        tasks[id] = nil
        activeIDs.remove(id)
        if !shuttingDown {
            launchQueuedDownloads()
        }
        if let queueID {
            reconcileQueue(queueID)
        }
    }

    private func launchQueuedDownloads() {
        while activeIDs.count < schedulerConfiguration.maxConcurrentDownloads,
              !queuedIDs.isEmpty {
            guard let queueIndex = queuedIDs.firstIndex(where: canLaunch) else { break }
            let id = queuedIDs.remove(at: queueIndex)
            guard let record = records[id], record.status == .preparing else {
                continue
            }
            launch(id: id)
        }
    }

    private func canLaunch(_ id: DownloadID) -> Bool {
        guard activeIDs.count < schedulerConfiguration.maxConcurrentDownloads else { return false }
        guard let queueID = records[id]?.queueID,
              let queueLimit = queueConcurrencyLimits[queueID] else { return true }
        let activeInQueue = activeIDs.reduce(into: 0) { count, activeID in
            if records[activeID]?.queueID == queueID { count += 1 }
        }
        return activeInQueue < queueLimit
    }

    private func reconcileQueue(_ queueID: DownloadID) {
        guard activeQueueIDs.contains(queueID) else { return }
        let policy = queuePolicies[queueID] ?? DownloadQueuePolicy()
        let items = records.values.filter { $0.queueID == queueID }
        guard !items.isEmpty else {
            guard policy.stopQueueOnEmpty else { return }
            activeQueueIDs.remove(queueID)
            emitQueueEvent(.becameEmpty(queueID: queueID, completionAction: policy.completionAction))
            return
        }

        let hasRemainingWork = items.contains { record in
            switch record.status {
            case .completed, .cancelled:
                return false
            case .added, .preparing, .downloading, .paused, .retrying, .failed:
                return true
            }
        }
        guard !hasRemainingWork else { return }
        activeQueueIDs.remove(queueID)
        emitQueueEvent(.becameEmpty(queueID: queueID, completionAction: policy.completionAction))
    }

    private func run(id: DownloadID) async {
        guard var record = records[id] else {
            return
        }

        do {
            record.status = .downloading
            record.updatedAt = Date()
            record.revision += 1
            records[id] = record
            try await store.save(record)
            emit(.updated(record))

            let writer = try PartFileWriter(record: record)
            let diskLength: Int64
            if record.source.kind == .http, !record.parts.isEmpty {
                diskLength = try contiguousPartBytes(record.parts)
            } else {
                diskLength = try await writer.length()
            }
            if record.downloadedBytes != diskLength {
                record.downloadedBytes = diskLength
                record.updatedAt = Date()
                record.revision += 1
                records[id] = record
                try await store.save(record)
                emit(.updated(record))
            }

            let rateLimiter = DownloadRateLimiter(bytesPerSecond: effectiveSpeedLimit(record))
            let (totalBytes, reportedTotal, etag, lastModified, serverFileName) = try await downloadWithRetry(
                id: id,
                source: effectiveSource(record.source),
                writer: writer,
                rateLimiter: rateLimiter
            )
            try Task.checkCancellation()

            let finalLength = try await writer.length()
            if finalLength < totalBytes {
                throw DownloadCoreError.responseMismatch(
                    "received \(finalLength) bytes, expected \(totalBytes)"
                )
            }
            let completedName = resolvedCompletionName(
                for: record,
                serverFileName: serverFileName
            )
            let completedDestination = URL(fileURLWithPath: record.folder, isDirectory: true)
                .appendingPathComponent(completedName)
            try await writer.finish(destinationURL: completedDestination)

            guard var completed = records[id] else {
                return
            }
            if completed.name != completedName {
                completed.name = completedName
                if completed.incompleteFileName != nil {
                    completed.incompleteFileName = "\(completedName).abdm.part"
                }
            }
            completed.status = .completed
            completed.downloadedBytes = finalLength
            completed.totalBytes = reportedTotal ?? finalLength
            completed.etag = etag ?? completed.etag
            completed.lastModified = lastModified ?? completed.lastModified
            completed.parts = completed.parts.map { part in
                var part = part
                part.completed = true
                return part
            }
            completed.error = nil
            completed.updatedAt = Date()
            completed.revision += 1
            records[id] = completed
            try await store.save(completed)
            if schedulerConfiguration.useServerLastModifiedTime,
               let rawLastModified = completed.lastModified,
               let modifiedDate = HTTPDateParser.date(from: rawLastModified) {
                do {
                    var values = URLResourceValues()
                    values.contentModificationDate = modifiedDate
                    var destinationURL = completed.destinationURL
                    try destinationURL.setResourceValues(values)
                } catch {
                    fputs(
                        "CoolDownloadCore: unable to set Last-Modified time for \(id): \(error)\n",
                        stderr
                    )
                }
            }
            emit(.updated(completed))
        } catch is CancellationError {
            // pause() persists the paused state before cancelling the task.
            if let current = records[id], current.status == .downloading || current.status == .preparing {
                var paused = current
                paused.status = .paused
                paused.updatedAt = Date()
                paused.revision += 1
                records[id] = paused
                do {
                    try await store.save(paused)
                } catch {
                    reportPersistenceFailure("paused state", id: id, error: error)
                }
                emit(.updated(paused))
            }
        } catch {
            if let current = records[id], current.status != .paused {
                var failed = current
                failed.status = .failed
                failed.error = error.localizedDescription
                failed.updatedAt = Date()
                failed.revision += 1
                records[id] = failed
                do {
                    try await store.save(failed)
                } catch {
                    reportPersistenceFailure("failed state", id: id, error: error)
                }
                emit(.updated(failed))
            }
        }
    }

    private func downloadWithRetry(
        id: DownloadID,
        source: DownloadSource,
        writer: PartFileWriter,
        rateLimiter: DownloadRateLimiter
    ) async throws -> (
        totalBytes: Int64,
        reportedTotal: Int64?,
        etag: String?,
        lastModified: String?,
        fileName: String?
    ) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                if attempt > 1 {
                    guard var retrying = records[id] else {
                        throw DownloadCoreError.notFound(id)
                    }
                    retrying.status = .downloading
                    retrying.error = nil
                    retrying.updatedAt = Date()
                    retrying.revision += 1
                    records[id] = retrying
                    try await store.save(retrying)
                    emit(.updated(retrying))
                }

                if source.kind == .hls {
                    let completedSegments = Set(
                        (records[id]?.parts ?? []).filter(\.completed).map(\.id)
                    )
                    let result = try await hlsDownloader.download(
                        source: source,
                        writer: writer,
                        completedSegments: completedSegments,
                        completedPartMetadata: records[id]?.parts ?? [],
                        progress: { [weak self] bytes, segmentIndex, segmentCount, segmentBytes in
                            await self?.persistHLSProgress(
                                id: id,
                                bytes: bytes,
                                segmentIndex: segmentIndex,
                                segmentCount: segmentCount,
                                segmentBytes: segmentBytes
                            )
                        },
                        rateLimiter: rateLimiter
                    )
                    return (result.totalBytes, result.totalBytes, nil, nil, nil)
                }

                let current = records[id]
                let result: HTTPDownloadResult
                if let current,
                   current.source.kind == .http,
                   effectiveThreadCount(current) > 1 || !current.parts.isEmpty {
                    result = try await downloadHTTPWithRanges(
                        id: id,
                        source: source,
                        writer: writer,
                        rateLimiter: rateLimiter
                    )
                } else {
                    result = try await downloader.download(
                        source: source,
                        offset: try await writer.length(),
                        writer: writer,
                        progress: { [weak self] bytes in
                            await self?.persistProgress(id: id, bytes: bytes)
                        },
                        expectedETag: current?.etag,
                        expectedLastModified: current?.lastModified,
                        rateLimiter: rateLimiter
                    )
                }
                let totalBytes: Int64
                if let responseTotal = result.totalBytes {
                    totalBytes = responseTotal
                } else {
                    totalBytes = try await writer.length()
                }
                if let expectedTotal = current?.totalBytes,
                   let responseTotal = result.totalBytes,
                   expectedTotal != responseTotal {
                    throw DownloadCoreError.resourceChanged
                }
                return (
                    totalBytes,
                    result.totalBytes,
                    result.etag,
                    result.lastModified,
                    result.fileName
                )
            } catch {
                guard !Task.isCancelled,
                      attempt < retryPolicy.maxAttempts,
                      isRetryable(error) else {
                    throw error
                }
                if var record = records[id] {
                    record.status = .retrying
                    record.error = error.localizedDescription
                    record.updatedAt = Date()
                    record.revision += 1
                    records[id] = record
                    try await store.save(record)
                    emit(.updated(record))
                }
                try await Task.sleep(for: retryPolicy.delay)
            }
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let error = error as? DownloadCoreError {
            guard case .httpStatus(let status) = error else { return false }
            return status == 408 || status == 425 || status == 429 || status >= 500
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private func downloadHTTPWithRanges(
        id: DownloadID,
        source: DownloadSource,
        writer: PartFileWriter,
        rateLimiter: DownloadRateLimiter
    ) async throws -> HTTPDownloadResult {
        guard var record = records[id] else {
            throw DownloadCoreError.notFound(id)
        }
        let metadata = try await downloader.probe(source: source)
        guard let totalBytes = metadata.totalBytes, totalBytes >= 0 else {
            if record.parts.isEmpty {
                return try await downloader.download(
                    source: source,
                    offset: try await writer.length(),
                    writer: writer,
                    progress: { [weak self] bytes in
                        await self?.persistProgress(id: id, bytes: bytes)
                    },
                    expectedETag: record.etag,
                    expectedLastModified: record.lastModified,
                    rateLimiter: rateLimiter
                )
            }
            throw DownloadCoreError.responseMismatch("parallel download requires a known resource length")
        }
        if let expectedTotal = record.totalBytes, expectedTotal != totalBytes {
            throw DownloadCoreError.resourceChanged
        }
        if let expectedETag = record.etag, metadata.etag != expectedETag {
            throw DownloadCoreError.resourceChanged
        }
        if record.etag == nil,
           let expectedLastModified = record.lastModified,
           metadata.lastModified != expectedLastModified {
            throw DownloadCoreError.resourceChanged
        }
        guard metadata.supportsRanges else {
            guard record.parts.isEmpty else {
                throw DownloadCoreError.resumeNotSupported
            }
            return try await downloader.download(
                source: source,
                offset: try await writer.length(),
                writer: writer,
                progress: { [weak self] bytes in
                    await self?.persistProgress(id: id, bytes: bytes)
                },
                expectedETag: record.etag,
                expectedLastModified: record.lastModified,
                rateLimiter: rateLimiter
            )
        }

        let parts: [DownloadPart]
        if record.parts.isEmpty {
            let existingLength = try await writer.length()
            guard existingLength <= totalBytes else {
                throw DownloadCoreError.resourceChanged
            }
            parts = makeHTTPParts(
                totalBytes: totalBytes,
                existingLength: existingLength,
                count: effectiveThreadCount(record)
            )
        } else {
            parts = try validateHTTPParts(record.parts, totalBytes: totalBytes)
        }

        record.totalBytes = totalBytes
        record.etag = metadata.etag ?? record.etag
        record.lastModified = metadata.lastModified ?? record.lastModified
        record.parts = parts
        record.downloadedBytes = try contiguousPartBytes(parts)
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        try await store.save(record)
        emit(.updated(record))
        try await writer.prepare(length: totalBytes, sparse: schedulerConfiguration.useSparseFileAllocation)

        let expectedETag = record.etag
        let expectedLastModified = record.lastModified
        var results: [HTTPDownloadResult] = []
        try await withThrowingTaskGroup(of: HTTPDownloadResult.self) { group in
            for part in parts where !part.completed {
                let start = part.from + part.downloaded
                guard let end = part.to, start <= end else { continue }
                group.addTask { [downloader, writer] in
                    try await downloader.downloadRange(
                        source: source,
                        start: start,
                        end: end,
                        writer: writer,
                        expectedETag: expectedETag,
                        expectedLastModified: expectedLastModified,
                        progress: { bytes in
                            await self.persistPartProgress(
                                id: id,
                                partID: part.id,
                                downloaded: part.downloaded + bytes
                            )
                        },
                        rateLimiter: rateLimiter
                    )
                }
            }
            for try await result in group {
                results.append(result)
            }
        }

        guard let completed = records[id],
              completed.parts.allSatisfy(\.completed),
              completed.downloadedBytes == totalBytes else {
            throw DownloadCoreError.responseMismatch("parallel ranges did not cover the complete file")
        }
        return HTTPDownloadResult(
            statusCode: 206,
            startOffset: 0,
            totalBytes: totalBytes,
            bytesWritten: totalBytes,
            etag: results.compactMap(\.etag).first ?? metadata.etag,
            lastModified: results.compactMap(\.lastModified).first ?? metadata.lastModified,
            fileName: metadata.fileName ?? results.compactMap(\.fileName).first
        )
    }

    private func makeHTTPParts(
        totalBytes: Int64,
        existingLength: Int64,
        count: Int
    ) -> [DownloadPart] {
        guard totalBytes > 0 else { return [] }
        let partCount = min(max(1, count), Int(totalBytes))
        let chunkSize = (totalBytes + Int64(partCount) - 1) / Int64(partCount)
        var parts: [DownloadPart] = []
        for index in 0..<partCount {
            let from = Int64(index) * chunkSize
            guard from < totalBytes else { break }
            let to = min(totalBytes - 1, from + chunkSize - 1)
            let length = to - from + 1
            let downloaded = max(0, min(length, existingLength - from))
            parts.append(DownloadPart(
                id: index,
                from: from,
                to: to,
                downloaded: downloaded,
                completed: downloaded == length
            ))
        }
        return parts
    }

    private func validateHTTPParts(
        _ parts: [DownloadPart],
        totalBytes: Int64
    ) throws -> [DownloadPart] {
        let sorted = parts.sorted { $0.from < $1.from }
        guard !sorted.isEmpty, totalBytes > 0 else {
            throw DownloadCoreError.responseMismatch("HTTP range metadata is empty")
        }
        var expectedFrom: Int64 = 0
        for part in sorted {
            guard part.from == expectedFrom,
                  let to = part.to,
                  to >= part.from,
                  part.downloaded >= 0,
                  part.downloaded <= to - part.from + 1 else {
                throw DownloadCoreError.responseMismatch("HTTP range metadata is not contiguous")
            }
            expectedFrom = to + 1
        }
        guard expectedFrom == totalBytes else {
            throw DownloadCoreError.responseMismatch("HTTP range metadata does not cover the resource")
        }
        return sorted.map { part in
            var normalized = part
            normalized.completed = normalized.downloaded == normalized.to! - normalized.from + 1
            return normalized
        }
    }

    private func contiguousPartBytes(_ parts: [DownloadPart]) throws -> Int64 {
        var total: Int64 = 0
        for part in parts {
            guard part.downloaded >= 0 else {
                throw DownloadCoreError.responseMismatch("negative downloaded range length")
            }
            total += part.downloaded
        }
        return total
    }

    private func persistPartProgress(
        id: DownloadID,
        partID: Int,
        downloaded: Int64
    ) async {
        guard var record = records[id], record.status == .downloading,
              let index = record.parts.firstIndex(where: { $0.id == partID }),
              let to = record.parts[index].to else { return }
        let maximum = to - record.parts[index].from + 1
        record.parts[index].downloaded = min(max(0, downloaded), maximum)
        record.parts[index].completed = record.parts[index].downloaded == maximum
        record.downloadedBytes = record.parts.reduce(0) { $0 + $1.downloaded }
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        do {
            try await store.save(record)
        } catch {
            reportPersistenceFailure("range progress", id: id, error: error)
        }
        emit(.updated(record))
    }

    private func persistProgress(id: DownloadID, bytes: Int64) async {
        guard var record = records[id], record.status == .downloading else {
            return
        }
        record.downloadedBytes = bytes
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        do {
            try await store.save(record)
        } catch {
            reportPersistenceFailure("progress", id: id, error: error)
        }
        emit(.updated(record))
    }

    private func persistHLSProgress(
        id: DownloadID,
        bytes: Int64,
        segmentIndex: Int,
        segmentCount: Int,
        segmentBytes: Int64
    ) async {
        guard var record = records[id], record.status == .downloading else {
            return
        }
        record.downloadedBytes = bytes
        let segmentStart = max(0, bytes - segmentBytes)
        if !record.parts.contains(where: { $0.id == segmentIndex }) {
            record.parts.append(DownloadPart(
                id: segmentIndex,
                from: segmentStart,
                to: max(segmentStart, bytes - 1),
                downloaded: segmentBytes,
                completed: true
            ))
        } else if let index = record.parts.firstIndex(where: { $0.id == segmentIndex }) {
            record.parts[index].from = segmentStart
            record.parts[index].to = max(segmentStart, bytes - 1)
            record.parts[index].downloaded = segmentBytes
            record.parts[index].completed = true
        }
        record.parts.sort { $0.id < $1.id }
        record.updatedAt = Date()
        record.revision += 1
        records[id] = record
        do {
            try await store.save(record)
        } catch {
            reportPersistenceFailure("HLS progress", id: id, error: error)
        }
        emit(.updated(record))
    }

    private func hostSettings(for link: String) -> PerHostSettingsItem? {
        guard let host = URL(string: link)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return perHostSettings
            .sorted { lhs, rhs in
                let lhsWildcards = lhs.host.filter { $0 == "*" }.count
                let rhsWildcards = rhs.host.filter { $0 == "*" }.count
                if lhsWildcards != rhsWildcards { return lhsWildcards < rhsWildcards }
                return lhs.host.count > rhs.host.count
            }
            .first { $0.matches(host: host) }
    }

    private func effectiveThreadCount(_ record: DownloadRecord) -> Int {
        guard schedulerConfiguration.dynamicPartCreation || !record.parts.isEmpty else { return 1 }
        let hostCount = hostSettings(for: record.source.link)?.threadCount
        let configured = record.taskSettings?.threadCount
            ?? hostCount
            ?? schedulerConfiguration.maxConnectionsPerDownload
        return min(max(1, configured), 64)
    }

    private func effectiveSpeedLimit(_ record: DownloadRecord) -> Int64 {
        let hostLimit = hostSettings(for: record.source.link)?.speedLimit
        return max(0, record.taskSettings?.speedLimit ?? hostLimit ?? schedulerConfiguration.speedLimit)
    }

    private func effectiveSource(_ source: DownloadSource) -> DownloadSource {
        var source = source
        var headers = source.headers ?? [:]

        func hasHeader(_ name: String) -> Bool {
            headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        let hostSettings = hostSettings(for: source.link)
        let hostUserAgent = hostSettings?.userAgent?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userAgent = hostUserAgent.isEmpty ? schedulerConfiguration.userAgent : hostUserAgent
        if let userAgent, !hasHeader("User-Agent") {
            headers["User-Agent"] = userAgent
        }
        if let downloadPage = source.downloadPage,
           !downloadPage.isEmpty,
           !hasHeader("Referer") {
            headers["Referer"] = downloadPage
        }
        if let username = hostSettings?.username,
           !username.isEmpty,
           !hasHeader("Authorization"),
           let password = hostSettings?.password {
            let credentials = "\(username):\(password)"
            headers["Authorization"] = "Basic \(Data(credentials.utf8).base64EncodedString())"
        }
        if !headers.isEmpty {
            source.headers = headers
        }
        return source
    }

    private func emit(_ event: DownloadEvent) {
        subscribers.values.forEach { $0.yield(event) }
    }

    private func emitQueueEvent(_ event: DownloadQueueEvent) {
        queueEventSubscribers.values.forEach { $0.yield(event) }
    }

    private func reportPersistenceFailure(_ context: String, id: DownloadID, error: Error) {
        // A caller may remove a temporary data root while an already-cancelled
        // task is unwinding. There is no durable target to report in that
        // case; retain diagnostics for real storage failures only.
        guard FileManager.default.fileExists(atPath: store.rootURL.path) else { return }
        fputs("CoolDownloadCore: failed to persist \(context) for \(id): \(error)\n", stderr)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func removeQueueEventSubscriber(_ id: UUID) {
        queueEventSubscribers[id] = nil
    }

    private func canReplaceAutomaticFileName(_ record: DownloadRecord) -> Bool {
        guard record.source.suggestedName?.nilIfBlank == nil else { return false }
        let fallbackName = DownloadFileNameResolver.pathOrHost(fromURL: record.source.link)
        let queryName = DownloadFileNameResolver.fromURLQuery(record.source.link)
        return record.name == fallbackName
            || record.name == queryName
            || record.name == "download-\(record.id)"
    }

    private func resolvedCompletionName(
        for record: DownloadRecord,
        serverFileName: String?
    ) -> String {
        guard canReplaceAutomaticFileName(record),
              let serverFileName,
              let candidate = try? validatedName(serverFileName),
              candidate != record.name else {
            return record.name
        }

        let destination = URL(fileURLWithPath: record.folder, isDirectory: true)
            .appendingPathComponent(candidate)
            .standardizedFileURL
        guard !records.values.contains(where: {
            $0.id != record.id && $0.destinationURL.standardizedFileURL == destination
        }), !FileManager.default.fileExists(atPath: destination.path) else {
            return record.name
        }
        return candidate
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw DownloadCoreError.invalidName(name)
        }
        return trimmed
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
