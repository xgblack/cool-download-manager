import Foundation
import Darwin

@_silgen_name("flock")
private func c_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

private final class SingleWriterLock: @unchecked Sendable {
    private let fileDescriptor: Int32

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DownloadCoreError.permissionDenied(url.path)
        }

        if c_flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            _ = Darwin.close(descriptor)
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw DownloadCoreError.storageLocked(url)
            }
            throw DownloadCoreError.permissionDenied(url.path)
        }

        self.fileDescriptor = descriptor
    }

    deinit {
        _ = c_flock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }
}

public actor DownloadStore {
    public let rootURL: URL
    private let recordsURL: URL
    private let partsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock: SingleWriterLock
    private var records: [DownloadID: DownloadRecord] = [:]
    private var legacyObjects: [DownloadID: JSONValue] = [:]
    /// Sidecars are only required for legacy records or records that already
    /// had one. Modern Codable records persist their parts inline, so creating
    /// a second synchronized file on every progress checkpoint is redundant.
    private var sidecarRequiredIDs: Set<DownloadID> = []
    private var metrics: any DownloadMetricsSink = NoopDownloadMetricsSink()
    private var metricsEnabled = false

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.recordsURL = self.rootURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("download_db", isDirectory: true)
            .appendingPathComponent("downloadlist", isDirectory: true)
        self.partsURL = self.rootURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("download_db", isDirectory: true)
            .appendingPathComponent("parts", isDirectory: true)
        self.lock = try SingleWriterLock(
            url: self.rootURL
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("download.lock")
        )

        try FileManager.default.createDirectory(
            at: self.recordsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: self.partsURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    @discardableResult
    public func load() throws -> [DownloadRecord] {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var loaded: [DownloadID: DownloadRecord] = [:]
        var loadedSidecarIDs: Set<DownloadID> = []

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                if var record = try? decoder.decode(DownloadRecord.self, from: data) {
                    try loadSidecarParts(into: &record)
                    loaded[record.id] = record
                    legacyObjects[record.id] = nil
                } else {
                    let decoded = try LegacyJSONCodec.decodeRecord(data: data)
                    var record = decoded.record
                    try loadSidecarParts(into: &record)
                    loaded[record.id] = record
                    legacyObjects[decoded.record.id] = decoded.rawObject
                }
            } catch {
                throw DownloadCoreError.corruptRecord(file, error.localizedDescription)
            }
        }

        records = loaded
        loadedSidecarIDs = Set(loaded.keys.filter { id in
            FileManager.default.fileExists(
                atPath: partsURL.appendingPathComponent("\(id).json").path
            )
        })
        sidecarRequiredIDs = loadedSidecarIDs
        return loaded.values.sorted { $0.id < $1.id }
    }

    public func all() -> [DownloadRecord] {
        records.values.sorted { $0.id < $1.id }
    }

    public func record(id: DownloadID) -> DownloadRecord? {
        records[id]
    }

    public func nextID() -> DownloadID {
        max(records.keys.max() ?? 0, 0) + 1
    }

    public func updateMetrics(_ metrics: any DownloadMetricsSink) {
        self.metrics = metrics
        metricsEnabled = metrics.isEnabled
    }

    public func save(_ record: DownloadRecord) throws {
        // DownloadService can be re-entered while a previous save is awaiting
        // filesystem I/O. Never let an older progress event overwrite a newer
        // pause, retry, or completion state.
        if let current = records[record.id], current.revision > record.revision {
            return
        }
        let target = recordsURL.appendingPathComponent("\(record.id).json")
        let temporary = recordsURL.appendingPathComponent(
            ".\(record.id).json.\(UUID().uuidString).tmp"
        )
        let shouldRecordMetrics = metricsEnabled
        let checkpointStartedAt = shouldRecordMetrics ? downloadMetricsNow() : 0
        let checkpointStartResources = shouldRecordMetrics
            ? DownloadResourceSnapshot.capture()
            : nil
        var encodedBytes: Int64 = 0
        var logicalWriteBytes: Int64 = 0
        var synchronizeCount = 0

        do {
            try FileManager.default.createDirectory(
                at: recordsURL,
                withIntermediateDirectories: true
            )
            let recordEncodeStartedAt = shouldRecordMetrics ? downloadMetricsNow() : 0
            let data: Data
            if let legacyObject = legacyObjects[record.id] {
                data = try LegacyJSONCodec.encodeRecord(record, preserving: legacyObject)
            } else {
                data = try encoder.encode(record)
            }
            let recordBytes = Int64(data.count)
            recordCheckpointPhase(
                id: record.id,
                phase: .recordEncode,
                startedAt: recordEncodeStartedAt,
                bytes: recordBytes,
                enabled: shouldRecordMetrics
            )
            encodedBytes += recordBytes
            logicalWriteBytes += recordBytes

            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw DownloadCoreError.permissionDenied(temporary.path)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            let recordWriteStartedAt = shouldRecordMetrics ? downloadMetricsNow() : 0
            try handle.write(contentsOf: data)
            recordCheckpointPhase(
                id: record.id,
                phase: .recordWrite,
                startedAt: recordWriteStartedAt,
                bytes: recordBytes,
                enabled: shouldRecordMetrics
            )
            let recordSynchronizeStartedAt = shouldRecordMetrics ? downloadMetricsNow() : 0
            try handle.synchronize()
            recordCheckpointPhase(
                id: record.id,
                phase: .recordSynchronize,
                startedAt: recordSynchronizeStartedAt,
                enabled: shouldRecordMetrics
            )
            synchronizeCount += 1
            try handle.close()

            let recordReplaceStartedAt = shouldRecordMetrics ? downloadMetricsNow() : 0
            try atomicallyReplace(temporary, at: target)
            recordCheckpointPhase(
                id: record.id,
                phase: .recordReplace,
                startedAt: recordReplaceStartedAt,
                enabled: shouldRecordMetrics
            )
            records[record.id] = record
            let sidecar = try saveSidecarParts(
                record,
                metricsEnabled: shouldRecordMetrics,
                required: shouldPersistSidecar(for: record)
            )
            encodedBytes += sidecar.encodedBytes
            logicalWriteBytes += sidecar.encodedBytes
            synchronizeCount += sidecar.synchronizeCount
            recordCheckpointMetric(
                id: record.id,
                startedAt: checkpointStartedAt,
                startResources: checkpointStartResources,
                encodedBytes: encodedBytes,
                logicalWriteBytes: logicalWriteBytes,
                synchronizeCount: synchronizeCount,
                succeeded: true,
                enabled: shouldRecordMetrics
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            recordCheckpointMetric(
                id: record.id,
                startedAt: checkpointStartedAt,
                startResources: checkpointStartResources,
                encodedBytes: encodedBytes,
                logicalWriteBytes: logicalWriteBytes,
                synchronizeCount: synchronizeCount,
                succeeded: false,
                enabled: shouldRecordMetrics
            )
            if let error = error as? DownloadCoreError {
                throw error
            }
            throw DownloadCoreError.permissionDenied(target.path)
        }
    }

    public func remove(id: DownloadID) throws {
        guard records[id] != nil else {
            throw DownloadCoreError.notFound(id)
        }
        let target = recordsURL.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        let partsFile = partsURL.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: partsFile.path) {
            try FileManager.default.removeItem(at: partsFile)
        }
        records.removeValue(forKey: id)
        legacyObjects.removeValue(forKey: id)
        sidecarRequiredIDs.remove(id)
    }

    private func loadSidecarParts(into record: inout DownloadRecord) throws {
        guard record.parts.isEmpty else { return }
        let file = partsURL.appendingPathComponent("\(record.id).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        record.parts = try LegacyJSONCodec.decodeParts(data: Data(contentsOf: file))
    }

    private func saveSidecarParts(
        _ record: DownloadRecord,
        metricsEnabled: Bool,
        required: Bool
    ) throws -> (encodedBytes: Int64, synchronizeCount: Int) {
        let target = partsURL.appendingPathComponent("\(record.id).json")
        guard !record.parts.isEmpty else {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            sidecarRequiredIDs.remove(record.id)
            return (0, 0)
        }
        guard required else { return (0, 0) }
        let temporary = partsURL.appendingPathComponent(".\(record.id).json.\(UUID().uuidString).tmp")
        let sidecarEncodeStartedAt = metricsEnabled ? downloadMetricsNow() : 0
        let data = try LegacyJSONCodec.encodeParts(record.parts, kind: record.source.kind)
        let sidecarBytes = Int64(data.count)
        recordCheckpointPhase(
            id: record.id,
            phase: .sidecarEncode,
            startedAt: sidecarEncodeStartedAt,
            bytes: sidecarBytes,
            enabled: metricsEnabled
        )
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw DownloadCoreError.permissionDenied(temporary.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            let sidecarWriteStartedAt = metricsEnabled ? downloadMetricsNow() : 0
            try handle.write(contentsOf: data)
            recordCheckpointPhase(
                id: record.id,
                phase: .sidecarWrite,
                startedAt: sidecarWriteStartedAt,
                bytes: sidecarBytes,
                enabled: metricsEnabled
            )
            let sidecarSynchronizeStartedAt = metricsEnabled ? downloadMetricsNow() : 0
            try handle.synchronize()
            recordCheckpointPhase(
                id: record.id,
                phase: .sidecarSynchronize,
                startedAt: sidecarSynchronizeStartedAt,
                enabled: metricsEnabled
            )
            try handle.close()
            let sidecarReplaceStartedAt = metricsEnabled ? downloadMetricsNow() : 0
            try atomicallyReplace(temporary, at: target)
            sidecarRequiredIDs.insert(record.id)
            recordCheckpointPhase(
                id: record.id,
                phase: .sidecarReplace,
                startedAt: sidecarReplaceStartedAt,
                enabled: metricsEnabled
            )
            return (sidecarBytes, 1)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadCoreError.permissionDenied(target.path)
        }
    }

    private func shouldPersistSidecar(for record: DownloadRecord) -> Bool {
        if legacyObjects[record.id] != nil || sidecarRequiredIDs.contains(record.id) {
            return true
        }
        // A sidecar may have been created by an older process between loads.
        // Preserve it rather than silently changing its compatibility mode.
        return FileManager.default.fileExists(
            atPath: partsURL.appendingPathComponent("\(record.id).json").path
        )
    }

    private func recordCheckpointMetric(
        id: DownloadID,
        startedAt: UInt64,
        startResources: DownloadResourceSnapshot?,
        encodedBytes: Int64,
        logicalWriteBytes: Int64,
        synchronizeCount: Int,
        succeeded: Bool,
        enabled: Bool
    ) {
        guard enabled, let startResources else { return }
        let endResources = DownloadResourceSnapshot.capture()
        metrics.record(.checkpoint(
            id: id,
            elapsedNanoseconds: downloadMetricsElapsed(since: startedAt),
            encodedBytes: encodedBytes,
            logicalWriteBytes: logicalWriteBytes,
            kernelAccountedWriteBytes: endResources.diskWriteDelta(from: startResources),
            synchronizeCount: synchronizeCount,
            succeeded: succeeded
        ))
    }

    /// Both temporary files are created beside their target, so POSIX rename
    /// provides an atomic same-volume replacement without Foundation's extra
    /// metadata and backup handling.
    private func atomicallyReplace(_ temporary: URL, at target: URL) throws {
        let result = temporary.path.withCString { temporaryPath in
            target.path.withCString { targetPath in
                Darwin.rename(temporaryPath, targetPath)
            }
        }
        guard result == 0 else {
            throw DownloadCoreError.permissionDenied(target.path)
        }
    }

    private func recordCheckpointPhase(
        id: DownloadID,
        phase: DownloadCheckpointPhase,
        startedAt: UInt64,
        bytes: Int64 = 0,
        enabled: Bool
    ) {
        guard enabled else { return }
        metrics.record(.checkpointPhase(
            id: id,
            phase: phase,
            elapsedNanoseconds: downloadMetricsElapsed(since: startedAt),
            bytes: bytes
        ))
    }
}
