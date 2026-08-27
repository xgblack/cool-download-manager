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

    public func save(_ record: DownloadRecord) throws {
        // DownloadService can be re-entered while a previous save is awaiting
        // filesystem I/O. Never let an older progress event overwrite a newer
        // pause, retry, or completion state.
        if let current = records[record.id], current.revision > record.revision {
            return
        }
        try FileManager.default.createDirectory(
            at: recordsURL,
            withIntermediateDirectories: true
        )
        let data: Data
        if let legacyObject = legacyObjects[record.id] {
            data = try LegacyJSONCodec.encodeRecord(record, preserving: legacyObject)
        } else {
            data = try encoder.encode(record)
        }
        let target = recordsURL.appendingPathComponent("\(record.id).json")
        let temporary = recordsURL.appendingPathComponent(
            ".\(record.id).json.\(UUID().uuidString).tmp"
        )

        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw DownloadCoreError.permissionDenied(temporary.path)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(
                    target,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            records[record.id] = record
            try saveSidecarParts(record)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
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
    }

    private func loadSidecarParts(into record: inout DownloadRecord) throws {
        guard record.parts.isEmpty else { return }
        let file = partsURL.appendingPathComponent("\(record.id).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        record.parts = try LegacyJSONCodec.decodeParts(data: Data(contentsOf: file))
    }

    private func saveSidecarParts(_ record: DownloadRecord) throws {
        let target = partsURL.appendingPathComponent("\(record.id).json")
        guard !record.parts.isEmpty else {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            return
        }
        let temporary = partsURL.appendingPathComponent(".\(record.id).json.\(UUID().uuidString).tmp")
        let data = try LegacyJSONCodec.encodeParts(record.parts, kind: record.source.kind)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw DownloadCoreError.permissionDenied(temporary.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadCoreError.permissionDenied(target.path)
        }
    }
}
