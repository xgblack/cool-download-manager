import Foundation
import zlib

public enum DownloadQRCodeError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge
    case invalidFrame
    case differentTransfer
    case conflictingFrame

    public var errorDescription: String? {
        switch self {
        case .empty: return "没有可分享的下载来源。"
        case .tooLarge: return "二维码内容过多，请减少选中的任务，或复制完整来源文本。"
        case .invalidFrame: return "二维码帧格式无效，请重新扫描或导入完整图片。"
        case .differentTransfer: return "扫描到另一组二维码，已保留当前进度。请继续扫描当前组，或重置后扫描新内容。"
        case .conflictingFrame: return "二维码帧内容不一致，已保留当前进度。请确认来源，或重置后重新扫描。"
        }
    }
}

/// Wire-compatible with upstream v1.11.3. The short CRC identifier groups
/// frames; it does not authenticate their origin or grant download permission.
public enum DownloadQRCodeTransfer {
    public static let maximumFrames = 256
    public static let maximumPayloadBytes = LoopbackHTTPServer.maximumRequestBytes
    public static let maximumFrameBytes = 2331

    public static func frames(for content: String) throws -> [String] {
        guard !content.isEmpty else { throw DownloadQRCodeError.empty }
        guard content.utf8.count <= maximumPayloadBytes else { throw DownloadQRCodeError.tooLarge }
        if content.utf16.count <= 500 { return [content] }
        var chunks: [String] = []
        var chunk = ""
        var units = 0
        // Kotlin's chunk size is in UTF-16 units. Keep scalar boundaries so
        // supplementary characters survive independent QR encoding/decoding.
        for scalar in content.unicodeScalars {
            let width = scalar.utf16.count
            if units + width > 400 {
                chunks.append(chunk)
                chunk = ""
                units = 0
            }
            chunk.unicodeScalars.append(scalar)
            units += width
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        guard chunks.count <= maximumFrames else { throw DownloadQRCodeError.tooLarge }
        let id = identifier(for: content)
        return chunks.enumerated().map { "<qr_\(id)/\($0.offset)/\(chunks.count)>\($0.element)" }
    }

    private static func identifier(for text: String) -> String {
        let data = Data(text.utf8)
        let checksum = data.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        return String(String(checksum, radix: 36).suffix(4))
    }
}

public struct DownloadQRCodeCollector: Sendable {
    public private(set) var total = 0
    public var received: Int { chunks.count }
    public var receivedIndices: Set<Int> { Set(chunks.keys) }
    public var isComplete: Bool { total > 0 && received == total }
    private var id: String?
    private var chunks: [Int: String] = [:]
    private var byteCount = 0

    public init() {}

    public mutating func reset() { self = Self() }

    /// Returns complete original text once. Partial and duplicate frames return
    /// nil. Invalid, conflicting and unrelated input never mutates progress.
    public mutating func receive(_ text: String) throws -> String? {
        guard !text.isEmpty else { throw DownloadQRCodeError.empty }
        guard text.utf8.count <= DownloadQRCodeTransfer.maximumPayloadBytes else {
            throw DownloadQRCodeError.tooLarge
        }
        guard text.hasPrefix("<qr_") else {
            guard total == 0 else { throw DownloadQRCodeError.differentTransfer }
            return text
        }
        guard text.utf8.count <= DownloadQRCodeTransfer.maximumFrameBytes,
              let end = text.firstIndex(of: ">") else { throw DownloadQRCodeError.invalidFrame }
        let parts = text[text.index(text.startIndex, offsetBy: 4)..<end].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].count <= 32,
              parts[0].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              !parts[2].isEmpty, parts[2].utf8.allSatisfy({ (48...57).contains($0) }),
              let index = Int(parts[1]), let count = Int(parts[2]), count > 0,
              count <= DownloadQRCodeTransfer.maximumFrames, index < count else {
            throw DownloadQRCodeError.invalidFrame
        }
        let data = String(text[text.index(after: end)...])
        guard !data.isEmpty else { throw DownloadQRCodeError.invalidFrame }
        let newID = String(parts[0])
        if let id {
            guard newID == id else { throw DownloadQRCodeError.differentTransfer }
            guard count == total else { throw DownloadQRCodeError.conflictingFrame }
        }
        if let existing = chunks[index] {
            guard existing == data else { throw DownloadQRCodeError.conflictingFrame }
            return nil
        }
        let newSize = byteCount + data.utf8.count
        guard newSize <= DownloadQRCodeTransfer.maximumPayloadBytes else { throw DownloadQRCodeError.tooLarge }
        id = newID
        total = count
        chunks[index] = data
        byteCount = newSize
        guard isComplete else { return nil }
        return (0..<total).compactMap { chunks[$0] }.joined()
    }
}
