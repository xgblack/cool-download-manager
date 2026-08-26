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
            throw DownloadCoreError.responseMismatch("不能截断为负数长度")
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
            throw DownloadCoreError.responseMismatch("不能写入负数偏移位置")
        }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    public func synchronize() throws {
        try handle.synchronize()
    }

    /// Ensures a range download has a complete backing file before workers
    /// write at independent offsets. Sparse mode only changes the logical
    /// length; dense mode writes zero-filled chunks so the filesystem can
    /// account for the requested space up front.
    public func prepare(length: Int64, sparse: Bool) throws {
        guard length >= 0 else {
            throw DownloadCoreError.responseMismatch("不能准备负数文件长度")
        }
        let currentLength = try self.length()
        if currentLength > length {
            try handle.truncate(atOffset: UInt64(length))
        }
        if sparse {
            if currentLength < length {
                try handle.truncate(atOffset: UInt64(length))
            }
            try handle.seek(toOffset: 0)
            return
        }

        // Dense allocation must not erase bytes already downloaded during a
        // resume. Extend only the missing tail with zeroes.
        let zeroes = Data(repeating: 0, count: 1024 * 1024)
        var remaining = max(0, length - min(currentLength, length))
        try handle.seek(toOffset: UInt64(min(currentLength, length)))
        while remaining > 0 {
            let chunk = min(remaining, Int64(zeroes.count))
            try handle.write(contentsOf: zeroes.prefix(Int(chunk)))
            remaining -= chunk
        }
        try handle.seek(toOffset: 0)
    }

    public func finish(destinationURL overrideDestinationURL: URL? = nil) throws {
        try handle.synchronize()
        try handle.close()

        let destinationURL = overrideDestinationURL ?? self.destinationURL
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
