import Foundation
import CoolDownloadCore

public struct IntegrationDownloadCredential: Codable, Equatable, Sendable {
    public var link: String
    public var headers: [String: String]?
    public var downloadPage: String?
    public var suggestedName: String?
    public var type: DownloadKind
    // Desktop-only metadata; not part of the browser request format.
    var browserEntryLink: String? = nil

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
            suggestedName: suggestedName,
            browserEntryLink: browserEntryLink
        )
    }
}

extension IntegrationDownloadCredential {
    init(source: DownloadSource) {
        self.init(link: source.link, headers: source.headers, downloadPage: source.downloadPage,
                  suggestedName: source.suggestedName, type: source.kind)
        browserEntryLink = source.browserEntryLink
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

public actor CoreDownloadIntegrationHandler: DownloadIntegrationHandler {
    private let service: DownloadService
    private let queuesProvider: @Sendable () async throws -> [IntegrationQueue]
    private let queueItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)?
    private let categoryItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)?
    private let interactiveAddHandler: (@Sendable (AddDownloadsRequest) async throws -> Void)?
    private let browserErrorHandler: @Sendable (String) async -> Void

    private static let browserSuppressionDuration: Duration = .seconds(4)
    private var browserWorker: Task<Void, Never>?
    private var browserJobs: [BrowserJob] = []
    private var resolvedBrowserItems: [ResolvedBrowserItem] = []
    private var stoppingBrowserWorker = false

    public init(
        service: DownloadService,
        queuesProvider: @escaping @Sendable () async throws -> [IntegrationQueue] = { [] },
        queueItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)? = nil,
        categoryItemAdder: (@Sendable (DownloadID, DownloadID) async throws -> Void)? = nil,
        interactiveAddHandler: (@Sendable (AddDownloadsRequest) async throws -> Void)? = nil,
        browserErrorHandler: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.service = service
        self.queuesProvider = queuesProvider
        self.queueItemAdder = queueItemAdder
        self.categoryItemAdder = categoryItemAdder
        self.interactiveAddHandler = interactiveAddHandler
        self.browserErrorHandler = browserErrorHandler
    }

    private enum BrowserJob {
        case silent(PendingBrowserDownload)
        case interactive(AddDownloadsRequest)
    }

    private struct ResolvedBrowserItem {
        var inputs: [IntegrationDownloadCredential]
        let preview: DownloadPreview?
        let taskID: DownloadID?
        var didStart = false
        let finishedAt: ContinuousClock.Instant
    }

    /// Accept locally before replying to the old extension; its HTTP timeout
    /// must not include a round trip to the download site.
    public func addFromBrowser(_ request: AddDownloadsRequest) async throws {
        guard !stoppingBrowserWorker else { throw DownloadCoreError.cancelled }
        if request.options.silentAdd {
            for item in request.items {
                let pending = try await service.stageBrowserDownload(item.asCoreSource(), start: request.options.silentStart)
                enqueueBrowserJob(.silent(pending))
            }
        } else {
            guard interactiveAddHandler != nil else { throw DownloadIntegrationError.confirmationUnavailable }
            for item in request.items { try DownloadSourceSecurity.validate(item.asCoreSource()) }
            enqueueBrowserJob(.interactive(request))
        }
    }

    public func restoreBrowserDownloads() async throws {
        for pending in try await service.pendingBrowserDownloads() {
            enqueueBrowserJob(.silent(pending))
        }
    }

    public func stopBrowserDownloads() async {
        stoppingBrowserWorker = true
        browserWorker?.cancel()
        await waitForBrowserDownloads()
    }

    func waitForBrowserDownloads() async {
        while let worker = browserWorker { await worker.value }
    }

    private func enqueueBrowserJob(_ job: BrowserJob) {
        guard !stoppingBrowserWorker else { return }
        browserJobs.append(job)
        if browserWorker == nil {
            browserWorker = Task { await self.drainBrowserJobs() }
        }
    }

    private func drainBrowserJobs() async {
        defer { browserWorker = nil }
        while !Task.isCancelled, !browserJobs.isEmpty {
            do {
                switch browserJobs.removeFirst() {
                case .silent(let pending): try await processBrowserDownload(pending)
                case .interactive(let request): try await processBrowserConfirmation(request)
                }
            } catch is CancellationError {
                if Task.isCancelled { break }
                await browserErrorHandler("浏览器下载处理被取消，可重新提交。")
            } catch {
                if Task.isCancelled { break }
                // Errors from URL loading can contain signed URLs or headers.
                await browserErrorHandler("浏览器下载未能处理，请检查下载地址或重新提交。")
            }
        }
    }

    private func resolveBrowserItem(_ item: IntegrationDownloadCredential) async throws -> BrowserDownloadResolution? {
        guard item.type == .http else { return nil }
        do {
            return try await service.resolveBrowserDownload(item.asCoreSource())
        } catch {
            try Task.checkCancellation()
            // Network failure is not evidence of duplication. Preserve the original
            // source for normal download retry or the existing confirmation UI.
            return nil
        }
    }

    private func recentBrowserItems(silent: Bool) -> [ResolvedBrowserItem] {
        resolvedBrowserItems.removeAll { $0.finishedAt.duration(to: .now) >= Self.browserSuppressionDuration }
        return resolvedBrowserItems.filter { ($0.taskID != nil) == silent }
    }

    private func exactMatch(_ item: IntegrationDownloadCredential, history: [ResolvedBrowserItem]) -> ResolvedBrowserItem? {
        let identity = BrowserDownloadIdentity(item)
        return history.first { candidate in
            candidate.inputs.contains { BrowserDownloadIdentity($0).isSameRequest(as: identity) }
        }
    }

    private func redirectMatch(_ item: IntegrationDownloadCredential, resolution: BrowserDownloadResolution?,
                               history: [ResolvedBrowserItem]) -> ResolvedBrowserItem? {
        guard let resolution, resolution.verified else { return nil }
        return history.first { candidate in
            guard let other = candidate.preview,
                  other.source.browserEntryLink != nil || resolution.preview.source.browserEntryLink != nil,
                  candidate.inputs.contains(where: { $0.downloadPage == nil || item.downloadPage == nil || $0.downloadPage == item.downloadPage })
            else { return false }
            return BrowserDownloadIdentity.sameResolvedFile(other.source, resolution.preview.source)
        }
    }

    private func processBrowserDownload(_ pending: PendingBrowserDownload) async throws {
        let item = IntegrationDownloadCredential(source: pending.source)
        let present = Set(await service.snapshot().downloads.map(\.id))
        let history = recentBrowserItems(silent: true).filter { $0.taskID.map(present.contains) == true }
        let exact = exactMatch(item, history: history)
        let resolution = exact == nil ? try await resolveBrowserItem(item) : nil
        try Task.checkCancellation()
        if resolution?.isPage == true {
            try await service.discardPendingBrowserDownload(id: pending.id)
            await browserErrorHandler("浏览器下载地址返回的是网页，不是文件。请在浏览器中完成登录或确认后重试。")
            return
        }
        // Preserve compatibility with older GitHub redirects that produce a
        // different signed URL when replayed outside the browser.
        let compatibilityMatch = history.first { candidate in
            candidate.inputs.contains { BrowserDownloadIdentity($0).isCompatible(with: BrowserDownloadIdentity(item)) }
        }
        if let candidate = exact ?? redirectMatch(item, resolution: resolution, history: history) ?? compatibilityMatch,
           let id = candidate.taskID,
           await service.snapshot().downloads.contains(where: { $0.id == id }) {
            if let source = resolution?.preview.source, let entry = source.browserEntryLink,
               let other = candidate.preview?.source, BrowserDownloadIdentity.sameResolvedFile(source, other) {
                try await service.rememberBrowserEntry(entry, for: id, finalLink: source.link)
            }
            if pending.start && !candidate.didStart { try await startBrowserItem(id: id) }
            try await service.discardPendingBrowserDownload(id: pending.id)
            if let index = resolvedBrowserItems.firstIndex(where: { $0.taskID == id }),
               !resolvedBrowserItems[index].inputs.contains(item) {
                resolvedBrowserItems[index].inputs.append(item)
            }
            return
        }
        let preview = resolution?.preview
        let id = try await service.promoteBrowserDownload(pending, preview: preview)
        resolvedBrowserItems.append(.init(inputs: [item], preview: resolution?.verified == true ? preview : nil,
                                          taskID: id, finishedAt: .now))
        if pending.start { try await startBrowserItem(id: id) }
    }

    private func processBrowserConfirmation(_ request: AddDownloadsRequest) async throws {
        guard let interactiveAddHandler else { throw DownloadIntegrationError.confirmationUnavailable }
        var items: [IntegrationDownloadCredential] = []
        var additions: [ResolvedBrowserItem] = []
        for item in request.items {
            let history = recentBrowserItems(silent: false) + additions
            if exactMatch(item, history: history) != nil { continue }
            let resolution = try await resolveBrowserItem(item)
            try Task.checkCancellation()
            if redirectMatch(item, resolution: resolution, history: history) != nil { continue }
            let preview = resolution?.verified == true ? resolution?.preview : nil
            items.append(preview.map { IntegrationDownloadCredential(source: $0.source) } ?? item)
            additions.append(.init(inputs: [item], preview: preview, taskID: nil, finishedAt: .now))
        }
        guard !items.isEmpty else { return }
        try await interactiveAddHandler(.init(items: items, options: request.options))
        resolvedBrowserItems.append(contentsOf: additions)
    }

    private func startBrowserItem(id: DownloadID) async throws {
        guard let record = await service.snapshot().downloads.first(where: { $0.id == id }) else {
            throw DownloadCoreError.notFound(id)
        }
        if record.status != .completed { try await service.start(id: id) }
        if let index = resolvedBrowserItems.firstIndex(where: { $0.taskID == id }) {
            resolvedBrowserItems[index].didStart = true
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
