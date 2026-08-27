import Foundation
import CryptoKit

public enum FileChecksumAlgorithm: String, Codable, CaseIterable, Sendable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"

    public static let `default`: Self = .sha256
}

public struct FileChecksum: Codable, Equatable, Sendable, CustomStringConvertible {
    public var algorithm: FileChecksumAlgorithm
    public var value: String

    public init(algorithm: FileChecksumAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value.lowercased()
    }

    public init?(string: String?) {
        guard let string, let separator = string.firstIndex(of: ":") else { return nil }
        let algorithmValue = String(string[..<separator])
        let value = String(string[string.index(after: separator)...])
        guard let algorithm = FileChecksumAlgorithm(rawValue: algorithmValue),
              !value.isEmpty,
              value.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.init(algorithm: algorithm, value: value)
    }

    public var description: String { "\(algorithm.rawValue):\(value)" }
}

public enum ChecksumError: Error, LocalizedError, Sendable, Equatable {
    case fileNotFound(URL)
    case notRegularFile(URL)
    case cancelled
    case invalidExpectedChecksum

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "文件不存在：\(url.path)"
        case .notRegularFile(let url): return "路径不是普通文件：\(url.path)"
        case .cancelled: return "完整性验证已取消"
        case .invalidExpectedChecksum: return "预期摘要格式无效"
        }
    }
}

/// Incremental file hashing keeps memory bounded for large downloads.
public struct FileChecksumCalculator: Sendable {
    public static let chunkSize = 1024 * 1024

    public init() {}

    public func calculate(
        fileURL: URL,
        algorithm: FileChecksumAlgorithm,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> FileChecksum {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw ChecksumError.fileNotFound(fileURL)
        }
        guard !isDirectory.boolValue else { throw ChecksumError.notRegularFile(fileURL) }
        let total = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        switch algorithm {
        case .md5:
            var hasher = Insecure.MD5()
            try update(&hasher, handle: handle, totalBytes: total, onProgress: onProgress)
            return FileChecksum(algorithm: algorithm, value: digestString(hasher.finalize()))
        case .sha1:
            var hasher = Insecure.SHA1()
            try update(&hasher, handle: handle, totalBytes: total, onProgress: onProgress)
            return FileChecksum(algorithm: algorithm, value: digestString(hasher.finalize()))
        case .sha256:
            var hasher = SHA256()
            try update(&hasher, handle: handle, totalBytes: total, onProgress: onProgress)
            return FileChecksum(algorithm: algorithm, value: digestString(hasher.finalize()))
        case .sha512:
            var hasher = SHA512()
            try update(&hasher, handle: handle, totalBytes: total, onProgress: onProgress)
            return FileChecksum(algorithm: algorithm, value: digestString(hasher.finalize()))
        }
    }

    private func update<H: HashFunction>(
        _ hasher: inout H,
        handle: FileHandle,
        totalBytes: Int64,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws {
        var processed: Int64 = 0
        while true {
            if Task.isCancelled { throw ChecksumError.cancelled }
            guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalBytes > 0 { onProgress?(min(1, Double(processed) / Double(totalBytes))) }
        }
        onProgress?(1)
    }

    private func digestString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
