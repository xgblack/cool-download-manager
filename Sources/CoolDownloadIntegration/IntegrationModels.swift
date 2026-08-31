import Foundation
import CoolDownloadCore

public struct IntegrationDownloadCredential: Codable, Equatable, Sendable {
    public var link: String
    public var headers: [String: String]?
    public var downloadPage: String?
    public var suggestedName: String?
    public var type: DownloadKind

    public init(
        link: String,
        headers: [String: String]? = nil,
        downloadPage: String? = nil,
        suggestedName: String? = nil,
        type: DownloadKind = .http
    ) {
        self.link = link
        self.headers = headers
        self.downloadPage = downloadPage
        self.suggestedName = suggestedName
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case link, headers, downloadPage, suggestedName, type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        link = try container.decode(String.self, forKey: .link)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        downloadPage = try container.decodeIfPresent(String.self, forKey: .downloadPage)
        suggestedName = try container.decodeIfPresent(String.self, forKey: .suggestedName)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type)?.lowercased()
        type = rawType?.contains("hls") == true ? .hls : .http
    }

    public func asCoreSource() -> DownloadSource {
        DownloadSource(
            kind: type,
            link: link,
            headers: headers,
            downloadPage: downloadPage,
            suggestedName: suggestedName
        )
    }
}

public struct AddDownloadOptions: Codable, Equatable, Sendable {
    public var silentAdd: Bool
    public var silentStart: Bool

    public init(silentAdd: Bool = false, silentStart: Bool = false) {
        self.silentAdd = silentAdd
        self.silentStart = silentStart
    }

    private enum CodingKeys: String, CodingKey {
        case silentAdd, silentStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        silentAdd = try container.decodeIfPresent(Bool.self, forKey: .silentAdd) ?? false
        silentStart = try container.decodeIfPresent(Bool.self, forKey: .silentStart) ?? false
    }
}

public struct AddDownloadsRequest: Codable, Equatable, Sendable {
    public var items: [IntegrationDownloadCredential]
    public var options: AddDownloadOptions

    public init(items: [IntegrationDownloadCredential], options: AddDownloadOptions = .init()) {
        self.items = items
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case items, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([IntegrationDownloadCredential].self, forKey: .items)
        options = try container.decodeIfPresent(AddDownloadOptions.self, forKey: .options) ?? .init()
    }
}

public struct HeadlessDownloadRequest: Codable, Equatable, Sendable {
    public var downloadSource: IntegrationDownloadCredential
    public var folder: String?
    public var name: String?
    public var queueId: DownloadID?
    public var categoryId: DownloadID?
    public var startDownload: Bool
    public var startQueue: Bool

    public init(
        downloadSource: IntegrationDownloadCredential,
        folder: String? = nil,
        name: String? = nil,
        queueId: DownloadID? = nil,
        categoryId: DownloadID? = nil,
        startDownload: Bool = false,
        startQueue: Bool = false
    ) {
        self.downloadSource = downloadSource
        self.folder = folder
        self.name = name
        self.queueId = queueId
        self.categoryId = categoryId
        self.startDownload = startDownload
        self.startQueue = startQueue
    }

    private enum CodingKeys: String, CodingKey {
        case downloadSource, folder, name, queueId, categoryId, startDownload, startQueue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadSource = try container.decode(IntegrationDownloadCredential.self, forKey: .downloadSource)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        queueId = try container.decodeIfPresent(DownloadID.self, forKey: .queueId)
        categoryId = try container.decodeIfPresent(DownloadID.self, forKey: .categoryId)
        startDownload = try container.decodeIfPresent(Bool.self, forKey: .startDownload) ?? false
        startQueue = try container.decodeIfPresent(Bool.self, forKey: .startQueue) ?? false
    }
}

public struct IntegrationQueue: Codable, Equatable, Sendable {
    public var id: DownloadID
    public var name: String

    public init(id: DownloadID, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol DownloadIntegrationHandler: Sendable {
    func addFromBrowser(_ request: AddDownloadsRequest) async throws
    func listQueues() async throws -> [IntegrationQueue]
    func addHeadless(_ request: HeadlessDownloadRequest) async throws -> DownloadID
    func patchSource(id: DownloadID, patch: DownloadSourcePatch) async throws -> DownloadSourcePatchResult
}

public enum DownloadIntegrationError: Error, LocalizedError, Sendable, Equatable {
    case confirmationUnavailable
    case sourcePatchUnavailable

    public var errorDescription: String? {
        switch self {
        case .confirmationUnavailable:
            return "无法打开下载确认窗口"
        case .sourcePatchUnavailable:
            return "当前下载处理器不支持更新来源"
        }
    }
}

public extension DownloadIntegrationHandler {
    func patchSource(
        id: DownloadID,
        patch: DownloadSourcePatch
    ) async throws -> DownloadSourcePatchResult {
        _ = id
        _ = patch
        throw DownloadIntegrationError.sourcePatchUnavailable
    }
}

public struct CoreDownloadIntegrationHandler: DownloadIntegrationHandler {
    private let service: DownloadService
    private let queuesProvider: @Sendable () async throws -> [IntegrationQueue]
    private let queueItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)?
    private let categoryItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)?
    private let interactiveAddHandler: (@Sendable (AddDownloadsRequest) async throws -> Void)?

    public init(
        service: DownloadService,
        queuesProvider: @escaping @Sendable () async throws -> [IntegrationQueue] = { [] },
        queueItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)? = nil,
        categoryItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)? = nil,
        interactiveAddHandler: (@Sendable (AddDownloadsRequest) async throws -> Void)? = nil
    ) {
        self.service = service
        self.queuesProvider = queuesProvider
        self.queueItemAdder = queueItemAdder
        self.categoryItemAdder = categoryItemAdder
        self.interactiveAddHandler = interactiveAddHandler
    }

    public func addFromBrowser(_ request: AddDownloadsRequest) async throws {
        guard request.options.silentAdd else {
            guard let interactiveAddHandler else {
                throw DownloadIntegrationError.confirmationUnavailable
            }
            try await interactiveAddHandler(request)
            return
        }

        for item in request.items {
            let id = try await service.add(
                AddDownloadRequest(
                    source: item.asCoreSource(),
                    start: false
                )
            )
            if request.options.silentStart {
                try await service.start(id: id)
            }
        }
    }

    public func listQueues() async throws -> [IntegrationQueue] {
        try await queuesProvider()
    }

    public func addHeadless(_ request: HeadlessDownloadRequest) async throws -> DownloadID {
        let id = try await service.add(
            AddDownloadRequest(
                source: request.downloadSource.asCoreSource(),
                folder: request.folder,
                name: request.name,
                queueID: request.queueId,
                categoryID: request.categoryId,
                start: false
            )
        )
        if let queueID = request.queueId {
            try await queueItemAdder?(queueID, id)
        }
        if let categoryID = request.categoryId {
            try await categoryItemAdder?(categoryID, id)
        }
        if request.startQueue, let queueID = request.queueId {
            try await service.startQueue(id: queueID)
        } else if request.startDownload {
            try await service.start(id: id)
        }
        return id
    }

    public func patchSource(
        id: DownloadID,
        patch: DownloadSourcePatch
    ) async throws -> DownloadSourcePatchResult {
        try await service.patchSource(id: id, patch: patch)
    }
}
