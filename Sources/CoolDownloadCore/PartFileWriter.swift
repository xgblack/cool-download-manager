import Foundation

public actor PartFileWriter {
    public let partURL: URL
    private let destinationURL: URL
    private var handle: FileHandle

    public init(record: DownloadRecord) throws {
        self.partURL = record.incompleteURL
        self.destinationURL = record.destinationURL
        try FileManager.default.createDirectory(
            at: partURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: partURL.path) {
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                throw DownloadCoreError.permissionDenied(partURL.path)
            }
        }
        do {
            self.handle = try FileHandle(forUpdating: partURL)
        } catch {
            throw DownloadCoreError.permissionDenied(partURL.path)
        }
    }

    deinit {
        try? handle.close()
    }

    public func length() throws -> Int64 {
        Int64(try handle.seekToEnd())
    }

    public func truncate() throws {
        try truncate(to: 0)
    }

    public func truncate(to length: Int64) throws {
        guard length >= 0 else {
            throw DownloadCoreError.responseMismatch("cannot truncate to a negative length")
        }
        try handle.truncate(atOffset: UInt64(length))
        try handle.seek(toOffset: UInt64(length))
    }

    public func append(_ data: Data) throws {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func write(_ data: Data, at offset: Int64) throws {
        guard offset >= 0 else {
            throw DownloadCoreError.responseMismatch("cannot write at a negative offset")
        }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    public func synchronize() throws {
        try handle.synchronize()
    }

    public func finish() throws {
        try handle.synchronize()
        try handle.close()

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: partURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: partURL, to: destinationURL)
        }
    }
}
