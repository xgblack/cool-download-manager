import Foundation

public typealias DownloadID = Int64

public enum DownloadKind: String, Codable, Sendable {
    case http
    case hls
}

public enum DownloadStatus: String, Codable, Sendable {
    case added
    case preparing
    case downloading
    case paused
    case retrying
    case completed
    case failed
    case cancelled
}

public struct DownloadSchedulerConfiguration: Sendable, Equatable {
    public let maxConcurrentDownloads: Int
    public let maxConnectionsPerDownload: Int
    public let dynamicPartCreation: Bool
    public let appendExtensionToIncompleteDownloads: Bool
    public let useSparseFileAllocation: Bool
    public let deletePartialFileOnDownloadCancellation: Bool
    /// A value of zero disables the global byte-rate limiter.
    public let speedLimit: Int64
    /// An empty value means the URLSession default User-Agent.
    public let userAgent: String?
    /// When enabled, a successfully completed file receives the server's
    /// HTTP `Last-Modified` timestamp when it can be parsed safely.
    public let useServerLastModifiedTime: Bool

    public init(
        maxConcurrentDownloads: Int = 3,
        maxConnectionsPerDownload: Int = 1,
        dynamicPartCreation: Bool = true,
        appendExtensionToIncompleteDownloads: Bool = false,
        useSparseFileAllocation: Bool = true,
        deletePartialFileOnDownloadCancellation: Bool = false,
        speedLimit: Int64 = 0,
        userAgent: String? = nil,
        useServerLastModifiedTime: Bool = false
    ) {
        // The historical setting uses 0 for unlimited concurrency.
        self.maxConcurrentDownloads = maxConcurrentDownloads <= 0 ? Int.max : max(1, maxConcurrentDownloads)
        self.maxConnectionsPerDownload = max(1, maxConnectionsPerDownload)
        self.dynamicPartCreation = dynamicPartCreation
        self.appendExtensionToIncompleteDownloads = appendExtensionToIncompleteDownloads
        self.useSparseFileAllocation = useSparseFileAllocation
        self.deletePartialFileOnDownloadCancellation = deletePartialFileOnDownloadCancellation
        self.speedLimit = max(0, speedLimit)
        let trimmedAgent = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userAgent = trimmedAgent?.isEmpty == false ? trimmedAgent : nil
        self.useServerLastModifiedTime = useServerLastModifiedTime
    }
}

public struct DownloadRetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let delay: Duration

    public init(maxAttempts: Int = 3, delay: Duration = .seconds(1)) {
        self.maxAttempts = max(1, maxAttempts)
        self.delay = delay
    }
}

public struct DownloadSource: Codable, Sendable, Equatable {
    public var kind: DownloadKind
    public var link: String
    public var headers: [String: String]?
    public var downloadPage: String?
    public var suggestedName: String?

    public init(
        kind: DownloadKind,
        link: String,
        headers: [String: String]? = nil,
        downloadPage: String? = nil,
        suggestedName: String? = nil
    ) {
        self.kind = kind
        self.link = link
        self.headers = headers
        self.downloadPage = downloadPage
        self.suggestedName = suggestedName
    }
}

public struct DownloadPart: Codable, Sendable, Equatable {
    public var id: Int
    public var from: Int64
    public var to: Int64?
    public var downloaded: Int64
    public var completed: Bool

    public init(
        id: Int,
        from: Int64,
        to: Int64? = nil,
        downloaded: Int64 = 0,
        completed: Bool = false
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.downloaded = downloaded
        self.completed = completed
    }
}

/// Settings that override the global downloader configuration for one task.
/// The entire value is optional on `DownloadRecord` so old records keep their
/// exact shape and continue to inherit current global settings.
public struct DownloadTaskSettings: Codable, Sendable, Equatable {
    /// `nil` inherits the global connection count; valid values are 1...64.
    public var threadCount: Int?
    /// `nil` inherits the global limit; zero means unlimited.
    public var speedLimit: Int64?
    /// `nil` inherits the global completion-dialog preference.
    public var showCompletionDialog: Bool?

    public init(
        threadCount: Int? = nil,
        speedLimit: Int64? = nil,
        showCompletionDialog: Bool? = nil
    ) {
        self.threadCount = threadCount
        self.speedLimit = speedLimit
        self.showCompletionDialog = showCompletionDialog
    }

    public func validated() throws -> Self {
        if let threadCount, !(1...64).contains(threadCount) {
            throw DownloadCoreError.invalidTaskSettings("任务线程数必须在 1 到 64 之间")
        }
        if let speedLimit, speedLimit < 0 {
            throw DownloadCoreError.invalidTaskSettings("任务速度限制不能为负数")
        }
        return self
    }
}

public struct DownloadRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: DownloadID
    public var source: DownloadSource
    public var folder: String
    public var name: String
    public var status: DownloadStatus
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var etag: String?
    public var lastModified: String?
    public var parts: [DownloadPart]
    public var queueID: DownloadID?
    public var categoryID: DownloadID?
    public var createdAt: Date
    public var updatedAt: Date
    public var error: String?
    /// Optional expected checksum in the historical `ALGORITHM:hex` format.
    public var fileChecksum: String?
    /// Per-task download and completion-dialog overrides.
    public var taskSettings: DownloadTaskSettings?
    /// The deterministic temporary filename used for this task. `nil` uses
    /// the default `.dl-{id}.cooldm.part` path.
    public var incompleteFileName: String?
    public var revision: Int64

    public init(
        id: DownloadID,
        source: DownloadSource,
        folder: String,
        name: String,
        status: DownloadStatus = .added,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        parts: [DownloadPart] = [],
        queueID: DownloadID? = nil,
        categoryID: DownloadID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        error: String? = nil,
        fileChecksum: String? = nil,
        taskSettings: DownloadTaskSettings? = nil,
        incompleteFileName: String? = nil,
        revision: Int64 = 1
    ) {
        self.id = id
        self.source = source
        self.folder = folder
        self.name = name
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.etag = etag
        self.lastModified = lastModified
        self.parts = parts
        self.queueID = queueID
        self.categoryID = categoryID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.error = error
        self.fileChecksum = fileChecksum
        self.taskSettings = taskSettings
        self.incompleteFileName = incompleteFileName
        self.revision = revision
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name)
    }

    public var incompleteURL: URL {
        URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(incompleteFileName ?? ".dl-\(id).cooldm.part")
    }

    public var lastModifiedDate: Date? {
        lastModified.flatMap(HTTPDateParser.date(from:))
    }
}

public struct AddDownloadRequest: Codable, Sendable, Equatable {
    public var source: DownloadSource
    public var folder: String?
    public var name: String?
    public var queueID: DownloadID?
    public var categoryID: DownloadID?
    public var start: Bool
    public var taskSettings: DownloadTaskSettings?

    public init(
        source: DownloadSource,
        folder: String? = nil,
        name: String? = nil,
        queueID: DownloadID? = nil,
        categoryID: DownloadID? = nil,
        start: Bool = false,
        taskSettings: DownloadTaskSettings? = nil
    ) {
        self.source = source
        self.folder = folder
        self.name = name
        self.queueID = queueID
        self.categoryID = categoryID
        self.start = start
        self.taskSettings = taskSettings
    }
}

public struct DownloadSnapshot: Codable, Sendable, Equatable {
    public var downloads: [DownloadRecord]

    public init(downloads: [DownloadRecord]) {
        self.downloads = downloads
    }
}

public enum DownloadEvent: Sendable, Equatable {
    case created(DownloadRecord)
    case updated(DownloadRecord)
    case removed(id: DownloadID)
}
