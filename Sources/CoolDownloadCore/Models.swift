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

    public init(maxConcurrentDownloads: Int = 3, maxConnectionsPerDownload: Int = 1) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maxConnectionsPerDownload = max(1, maxConnectionsPerDownload)
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
        self.revision = revision
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name)
    }

    public var incompleteURL: URL {
        URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(".dl-\(id).abdm.part")
    }
}

public struct AddDownloadRequest: Codable, Sendable, Equatable {
    public var source: DownloadSource
    public var folder: String?
    public var name: String?
    public var queueID: DownloadID?
    public var categoryID: DownloadID?
    public var start: Bool

    public init(
        source: DownloadSource,
        folder: String? = nil,
        name: String? = nil,
        queueID: DownloadID? = nil,
        categoryID: DownloadID? = nil,
        start: Bool = false
    ) {
        self.source = source
        self.folder = folder
        self.name = name
        self.queueID = queueID
        self.categoryID = categoryID
        self.start = start
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
