import Foundation

public enum BatchWildcardLength: Equatable, Sendable {
    case automatic
    case unspecified
    case custom(Int)
}

public enum BatchDownloadError: Error, LocalizedError, Sendable, Equatable {
    case emptyPattern
    case invalidRange
    case missingWildcard
    case tooManyItems(maximum: Int)
    case invalidURL(String)
    case invalidCustomLength

    public var errorDescription: String? {
        switch self {
        case .emptyPattern: return "批量下载地址不能为空"
        case .invalidRange: return "批量下载范围无效"
        case .missingWildcard: return "下载地址必须包含 * 占位符"
        case .tooManyItems(let maximum): return "批量下载最多支持 \(maximum) 个任务"
        case .invalidURL(let value): return "生成的下载地址无效：\(value)"
        case .invalidCustomLength: return "自定义补零位数必须在 1 到 10 之间"
        }
    }
}

public struct BatchDownloadExpander: Sendable {
    public static let maximumItems = 1000

    public init() {}

    public func expand(
        pattern: String,
        start: Int,
        end: Int,
        wildcardLength: BatchWildcardLength = .automatic,
        maximumItems: Int = BatchDownloadExpander.maximumItems
    ) throws -> [String] {
        let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BatchDownloadError.emptyPattern }
        guard value.contains("*") else { throw BatchDownloadError.missingWildcard }
        guard start >= 0, end >= start else { throw BatchDownloadError.invalidRange }
        guard maximumItems > 0 else { throw BatchDownloadError.tooManyItems(maximum: maximumItems) }
        let count = end - start + 1
        guard count <= maximumItems else { throw BatchDownloadError.tooManyItems(maximum: maximumItems) }

        let minimumWidth = max(String(start).count, String(end).count)
        let width: Int?
        switch wildcardLength {
        case .automatic:
            width = minimumWidth
        case .unspecified:
            width = nil
        case .custom(let length):
            guard (1...10).contains(length) else { throw BatchDownloadError.invalidCustomLength }
            width = max(length, minimumWidth)
        }

        var result: [String] = []
        result.reserveCapacity(count)
        for number in start...end {
            let raw = String(number)
            let replacement = width.map { width in
                String(repeating: "0", count: max(0, width - raw.count)) + raw
            } ?? raw
            let link = value.replacingOccurrences(of: "*", with: replacement)
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw BatchDownloadError.invalidURL(link)
            }
            result.append(link)
        }
        return result
    }
}
