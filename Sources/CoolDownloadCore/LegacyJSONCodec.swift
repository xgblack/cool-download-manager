import Foundation

/// A small JSON AST used to keep fields written by older Kotlin versions.
/// Numbers are retained as decimal strings instead of being forced through Double.
public enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        self = try Self.fromFoundation(object)
    }

    public func data(prettyPrinted: Bool = false) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: foundationValue,
            options: prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        )
    }

    private var foundationValue: Any {
        switch self {
        case .object(let values):
            return values.mapValues(\.foundationValue)
        case .array(let values):
            return values.map(\.foundationValue)
        case .string(let value):
            return value
        case .number(let value):
            return NSDecimalNumber(string: value)
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    private static func fromFoundation(_ value: Any) throws -> JSONValue {
        if value is NSNull {
            return .null
        }
        if let value = value as? NSNumber {
            if String(cString: value.objCType) == "c" {
                return .bool(value.boolValue)
            }
            return .number(value.stringValue)
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? [Any] {
            return .array(try value.map(Self.fromFoundation))
        }
        if let value = value as? [String: Any] {
            return .object(try value.mapValues(Self.fromFoundation))
        }
        throw CocoaError(.coderReadCorrupt, userInfo: [
            NSLocalizedDescriptionKey: "Unsupported JSON value (type(of: value))"
        ])
    }
}

public enum LegacyJSONCodec {
    public struct Decoded: Sendable {
        public let record: DownloadRecord
        public let rawObject: JSONValue

        public init(record: DownloadRecord, rawObject: JSONValue) {
            self.record = record
            self.rawObject = rawObject
        }
    }

    public static func decodeRecord(data: Data) throws -> Decoded {
        let rawObject = try JSONValue(data: data)
        guard case .object(let object) = rawObject else {
            throw DownloadCoreError.corruptRecord(
                URL(fileURLWithPath: "<memory>"),
                "legacy record is not a JSON object"
            )
        }

        let type = string(object, keys: ["type", "kind", "downloadType"]) ?? "http"
        let kind: DownloadKind = type.lowercased().contains("hls") ? .hls : .http
        let link = string(object, keys: ["link", "url"]) ?? ""
        let id = integer(object, keys: ["id"]) ?? 0
        let folder = string(object, keys: ["folder", "directory"]) ?? ""
        let name = string(object, keys: ["name", "fileName", "filename"])
            ?? URL(string: link)?.lastPathComponent
            ?? "download-\(id)"
        let headers = dictionary(object["headers"])
        let downloadPage = string(object, keys: ["downloadPage", "referer"])
        let status = status(object["status"])
        let totalBytes = integer(object, keys: ["contentLength", "totalBytes"])
            .flatMap { $0 >= 0 ? $0 : nil }
        let etag = string(object, keys: ["etag", "eTag", "ETag"])
        let lastModified = string(object, keys: ["lastModified", "last-modified", "Last-Modified"])
        let createdAt = date(object, keys: ["dateAdded", "createdAt"]) ?? Date()
        let updatedAt = date(object, keys: ["updatedAt", "completeTime", "startTime"]) ?? createdAt
        let parts = parseParts(object["parts"])
        let queueID = integer(object, keys: ["queueId", "queueID"])
        let categoryID = integer(object, keys: ["categoryId", "categoryID"])
        let fileChecksum = string(object, keys: ["fileChecksum", "checksum"])
        let legacyThreadCount = integer(object, keys: ["preferredConnectionCount", "threadCount"])
        let legacySpeedLimit = integer(object, keys: ["speedLimit"])
        let normalizedThreadCount = legacyThreadCount.flatMap { value in
            (1...64).contains(value) ? Int(value) : nil
        }
        let normalizedSpeedLimit = legacySpeedLimit.flatMap { $0 >= 0 ? $0 : nil }
        let taskSettings: DownloadTaskSettings? = (normalizedThreadCount != nil || normalizedSpeedLimit != nil)
            ? DownloadTaskSettings(
                threadCount: normalizedThreadCount,
                speedLimit: normalizedSpeedLimit
            )
            : nil
        let downloadedBytes = integer(object, keys: ["downloadedBytes", "current"])
            ?? parts.reduce(0) { $0 + $1.downloaded }

        let record = DownloadRecord(
            id: id,
            source: DownloadSource(
                kind: kind,
                link: link,
                headers: headers,
                downloadPage: downloadPage,
                suggestedName: name
            ),
            folder: folder,
            name: name,
            status: status,
            downloadedBytes: max(0, downloadedBytes),
            totalBytes: totalBytes,
            etag: etag,
            lastModified: lastModified,
            parts: parts,
            queueID: queueID,
            categoryID: categoryID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            error: string(object, keys: ["error", "errorMessage"]),
            fileChecksum: fileChecksum,
            taskSettings: taskSettings,
            revision: integer(object, keys: ["revision"]) ?? 1
        )
        return Decoded(record: record, rawObject: rawObject)
    }

    public static func decodeParts(data: Data) throws -> [DownloadPart] {
        let value = try JSONValue(data: data)
        guard case .object(let object) = value else { return [] }
        return parseParts(object["list"] ?? object["parts"] ?? value)
    }

    public static func encodeParts(_ parts: [DownloadPart], kind: DownloadKind) throws -> Data {
        let list = parts.map { part -> JSONValue in
            if kind == .hls {
                return .object([
                    "segmentIndex": .number(String(part.id)),
                    "from": .number("0"),
                    "current": .number(String(part.downloaded)),
                    "isCompleted": .bool(part.completed)
                ])
            }
            return .object([
                "from": .number(String(part.from)),
                "to": part.to.map { .number(String($0)) } ?? .null,
                "current": .number(String(part.from + part.downloaded))
            ])
        }
        return try JSONValue.object([
            "type": .string(kind == .hls ? "mediaSegments" : "ranges"),
            "list": .array(list)
        ]).data(prettyPrinted: true)
    }

    public static func encodeRecord(
        _ record: DownloadRecord,
        preserving rawObject: JSONValue
    ) throws -> Data {
        var object: [String: JSONValue]
        if case .object(let existing) = rawObject {
            object = existing
        } else {
            object = [:]
        }

        object["type"] = .string(record.source.kind.rawValue)
        object["link"] = .string(record.source.link)
        object["headers"] = record.source.headers.map { .object($0.mapValues { .string($0) }) } ?? .null
        object["downloadPage"] = record.source.downloadPage.map(JSONValue.string) ?? .null
        object["id"] = .number(String(record.id))
        object["folder"] = .string(record.folder)
        object["name"] = .string(record.name)
        object["contentLength"] = .number(String(record.totalBytes ?? -1))
        object["etag"] = record.etag.map(JSONValue.string) ?? .null
        object["lastModified"] = record.lastModified.map(JSONValue.string) ?? .null
        object["dateAdded"] = .number(String(Int64(record.createdAt.timeIntervalSince1970 * 1000)))
        object["updatedAt"] = .number(String(Int64(record.updatedAt.timeIntervalSince1970 * 1000)))
        object["status"] = .string(legacyStatus(record.status))
        object["downloadedBytes"] = .number(String(record.downloadedBytes))
        object["queueId"] = record.queueID.map { .number(String($0)) } ?? .null
        object["categoryId"] = record.categoryID.map { .number(String($0)) } ?? .null
        object["fileChecksum"] = record.fileChecksum.map(JSONValue.string) ?? .null
        if let taskSettings = record.taskSettings {
            object["preferredConnectionCount"] = taskSettings.threadCount.map { .number(String($0)) } ?? .null
            object["speedLimit"] = taskSettings.speedLimit.map { .number(String($0)) } ?? .null
        }
        object["revision"] = .number(String(record.revision))
        if let error = record.error {
            object["error"] = .string(error)
        } else {
            object["error"] = .null
        }
        return try JSONValue.object(object).data(prettyPrinted: true)
    }

    private static func string(_ object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value) = object[key] {
                return value
            }
        }
        return nil
    }

    private static func integer(_ object: [String: JSONValue], keys: [String]) -> Int64? {
        for key in keys {
            switch object[key] {
            case .number(let value):
                if let result = Int64(value) {
                    return result
                }
                if let result = Double(value) {
                    return Int64(result)
                }
            case .string(let value):
                if let result = Int64(value) {
                    return result
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func dictionary(_ value: JSONValue?) -> [String: String]? {
        guard case .object(let values) = value else {
            return nil
        }
        let strings = values.compactMapValues { value -> String? in
            guard case .string(let string) = value else { return nil }
            return string
        }
        return strings.isEmpty ? nil : strings
    }

    private static func date(_ object: [String: JSONValue], keys: [String]) -> Date? {
        guard let milliseconds = integer(object, keys: keys), milliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func status(_ value: JSONValue?) -> DownloadStatus {
        guard case .string(let raw) = value else { return .added }
        switch raw.lowercased() {
        case "completed": return .completed
        case "paused": return .paused
        case "downloading", "preparing": return .downloading
        case "error", "failed": return .failed
        case "cancelled", "canceled": return .cancelled
        default: return .added
        }
    }

    private static func legacyStatus(_ status: DownloadStatus) -> String {
        switch status {
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .downloading, .preparing: return "Downloading"
        case .failed: return "Error"
        case .cancelled: return "Error"
        case .retrying, .added: return "Added"
        }
    }

    private static func parseParts(_ value: JSONValue?) -> [DownloadPart] {
        let list: [JSONValue]
        switch value {
        case .array(let values):
            list = values
        case .object(let object):
            if case .array(let values) = object["list"] ?? object["parts"] {
                list = values
            } else {
                list = []
            }
        default:
            list = []
        }

        return list.enumerated().compactMap { index, value in
            guard case .object(let object) = value else { return nil }
            let segmentIndex = integer(object, keys: ["segmentIndex"])
            let from = segmentIndex == nil
                ? (integer(object, keys: ["from", "start"]) ?? Int64(index))
                : 0
            let to = integer(object, keys: ["to", "end"])
            let current = integer(object, keys: ["current", "downloaded", "length"]) ?? from
            let explicitCompleted: Bool? = {
                guard case .bool(let value) = object["isCompleted"] ?? object["completed"] else {
                    return nil
                }
                return value
            }()
            return DownloadPart(
                id: Int(segmentIndex ?? integer(object, keys: ["id"]) ?? Int64(index)),
                from: from,
                to: to,
                downloaded: max(0, current - from),
                completed: explicitCompleted ?? (to.map { current > $0 } ?? false)
            )
        }
    }
}
