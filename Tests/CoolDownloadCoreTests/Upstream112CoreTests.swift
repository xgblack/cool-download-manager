import CoreData
import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("v1.11.2 preview and queue controls")
struct Upstream112CoreTests {
    @Test("HTTP preview uses effective headers without reserving a task or destination")
    func httpPreview() async throws {
        let root = temporaryRoot()
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let store = try DownloadStore(rootURL: root)
        let transport = PreviewTransport()
        let service = DownloadService(store: store, downloader: HTTPDownloader(transport: transport), defaultFolder: destination,
                                      schedulerConfiguration: .init(maxOpenFileDescriptors: 2))
        try await service.boot()
        await service.updatePerHostSettings([
            PerHostSettingsItem(host: "fixture.invalid", username: "fixture-user", password: "fixture-password", userAgent: "Fixture-Agent")
        ])
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/download", headers: ["X-Fixture": "preview"], downloadPage: "  https://fixture.invalid/page  ")
        let preview = try await service.preview(source: source)
        #expect(preview.fileName == "preview.zip")
        #expect(preview.totalBytes == Int64(PreviewTransport.content.count))
        #expect(preview.supportsResume == true)
        #expect(preview.source.downloadPage == "https://fixture.invalid/page")
        #expect(preview.source.headers == source.headers)
        #expect(preview.hlsDuration == nil && preview.hlsSegmentCount == nil)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Fixture-Agent")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://fixture.invalid/page")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("fixture-user:fixture-password".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "X-Fixture") == "preview")
        #expect(await service.snapshot().downloads.isEmpty)
        #expect(try await store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let id = try await service.add(AddDownloadRequest(source: source), preview: preview)
        #expect(id == 1)
        #expect(await service.snapshot().downloads.first?.name == "preview.zip")
        await service.shutdown()
    }

    @Test("invalid and cancelled previews leave no task or output behind")
    func failedPreview() async throws {
        let root = temporaryRoot()
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let transport = PreviewTransport(holdRequests: true)
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(store: store, downloader: HTTPDownloader(transport: transport), defaultFolder: destination,
                                      schedulerConfiguration: .init(maxOpenFileDescriptors: 2))
        try await service.boot()
        await #expect(throws: DownloadCoreError.self) {
            _ = try await service.preview(source: DownloadSource(kind: .http, link: "file:///private/file"))
        }
        #expect(await transport.requests.isEmpty)
        // More attempts than the two-unit descriptor budget exposes leaked
        // reservations: a later preview would never reach the transport.
        for count in 1...3 {
            let previewTask = Task { try await service.preview(source: source()) }
            try await waitUntil { await transport.requests.count == count }
            previewTask.cancel()
            await #expect(throws: CancellationError.self) { _ = try await previewTask.value }
        }
        #expect(await transport.cancelledRequests == 3)
        #expect(await service.snapshot().downloads.isEmpty)
        #expect(try await store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await store.reserveNextID() == 1)
        await service.shutdown()
    }

    @Test("HLS preview resolves only manifests and reports duration without a byte-size guess")
    func hlsPreview() async throws {
        let root = temporaryRoot()
        let transport = PreviewTransport()
        let service = DownloadService(store: try DownloadStore(rootURL: root), hlsDownloader: HLSDownloader(transport: transport), defaultFolder: root)
        try await service.boot()
        let preview = try await service.preview(source: DownloadSource(kind: .hls, link: "https://fixture.invalid/master.m3u8"))
        #expect(preview.hlsSegmentCount == 2)
        #expect(preview.hlsDuration == 5.5)
        #expect(preview.totalBytes == nil && preview.supportsResume == nil)
        #expect(await transport.requests.compactMap { $0.url?.lastPathComponent } == ["master.m3u8", "media.m3u8"])
        #expect(await service.snapshot().downloads.isEmpty)
        await service.shutdown()
    }

    @Test("explicit names win, stale previews are ignored, and automatic preview names are revalidated")
    func previewNames() async throws {
        let root = temporaryRoot()
        let transport = PreviewTransport()
        let store = try DownloadStore(rootURL: root)
        try await store.save(DownloadRecord(id: 1, source: source(), folder: root.path, name: "legacy-custom.zip"))
        let service = DownloadService(store: store, downloader: HTTPDownloader(transport: transport), defaultFolder: root)
        try await service.boot()
        let preview = try await service.preview(source: source())
        let automatic = try await service.add(AddDownloadRequest(source: source()), preview: preview)
        let explicit = try await service.add(AddDownloadRequest(source: source(), name: "my-name.zip"), preview: preview)
        var browserSource = source()
        browserSource.suggestedName = "browser-name.zip"
        let browser = try await service.add(AddDownloadRequest(source: browserSource), preview: preview)
        let stale = try await service.add(AddDownloadRequest(source: source(link: "https://fixture.invalid/other.bin")), preview: preview)
        let before = await service.snapshot().downloads
        #expect(before.first { $0.id == automatic }?.name == "preview.zip")
        #expect(before.first { $0.id == automatic }?.source.suggestedName == nil)
        #expect(before.first { $0.id == explicit }?.name == "my-name.zip")
        #expect(before.first { $0.id == browser }?.name == "browser-name.zip")
        #expect(before.first { $0.id == stale }?.name == "other.bin")
        await transport.setFileName("actual.zip")
        for id in [1, automatic, explicit, browser] {
            try await service.start(id: id)
            _ = try await waitForRecord(service, id: id) { $0.status == .completed }
        }
        let after = await service.snapshot().downloads
        #expect(after.first { $0.id == automatic }?.name == "actual.zip")
        #expect(after.first { $0.id == 1 }?.name == "legacy-custom.zip")
        #expect(after.first { $0.id == explicit }?.name == "my-name.zip")
        #expect(after.first { $0.id == browser }?.name == "browser-name.zip")
        let completed = try #require(after.first { $0.id == automatic })
        #expect(try Data(contentsOf: completed.destinationURL) == PreviewTransport.content)
        await service.shutdown()
    }

    @Test("stop all withdraws queued work before releasing the active task and preserves its partial bytes")
    func stopAllQueuedWork() async throws {
        let root = temporaryRoot()
        let transport = PreviewTransport(holdBodies: true)
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(store: store, downloader: HTTPDownloader(transport: transport), defaultFolder: root,
                                      schedulerConfiguration: .init(maxConcurrentDownloads: 1))
        try await service.boot()
        await service.updateQueuePolicies([7: .init(maxConcurrent: 1, stopQueueOnEmpty: true, completionAction: .lock)])
        let stream = await service.queueEvents()
        let eventsTask = Task { var events: [DownloadQueueEvent] = []; for await event in stream { events.append(event) }; return events }
        var ids: [DownloadID] = []
        for index in 0..<3 {
            ids.append(try await service.add(AddDownloadRequest(source: source(link: "https://fixture.invalid/task-\(index).bin"), queueID: 7)))
        }
        try await service.startQueue(id: 7)
        let active = try await waitForRecord(service, id: ids[0]) { $0.downloadedBytes > 0 }
        try await service.stopAll()
        let records = await service.snapshot().downloads
        #expect(records.allSatisfy { $0.status == .paused })
        #expect(records.first?.downloadedBytes == active.downloadedBytes)
        #expect(try Data(contentsOf: active.incompleteURL) == PreviewTransport.content.prefix(PreviewTransport.heldPrefixBytes))
        #expect(await transport.requests.count == 1)
        #expect(try await store.load().allSatisfy { $0.status == .paused })
        await service.shutdown()
        #expect(await eventsTask.value.isEmpty)
    }

    @Test("stop interrupts a queue start suspended in its first metadata save", arguments: [false, true])
    func stopAllDuringQueueStart(allQueues: Bool) async throws {
        let root = temporaryRoot()
        let database = try MetadataDatabase(rootURL: root)
        let transport = PreviewTransport()
        let service = DownloadService(store: try DownloadStore(rootURL: root, database: database),
                                      downloader: HTTPDownloader(transport: transport), defaultFolder: root)
        try await service.boot()
        for index in 0..<3 {
            _ = try await service.add(AddDownloadRequest(source: source(link: "https://fixture.invalid/start-\(index).bin"), queueID: 9))
        }
        let gate = PreparingSaveGate()
        let observer = database.perform { context in
            NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: context, queue: nil) { notification in
                guard let context = notification.object as? NSManagedObjectContext,
                      context.updatedObjects.contains(where: { $0.entity.name == "DownloadTask" && $0.value(forKey: "status") as? String == "preparing" }) else { return }
                gate.blockFirstSave()
            }
        }
        defer { gate.release(); NotificationCenter.default.removeObserver(observer) }
        let startTask = Task { try await service.startQueue(id: 9) }
        try await waitUntil { gate.hasBlocked }
        let stopTask = Task {
            if allQueues { try await service.stopAll() }
            else { try await service.stopQueue(id: 9) }
        }
        try await waitUntil { await service.snapshot().downloads.first?.status == .paused }
        gate.release()
        try await stopTask.value
        try await startTask.value
        #expect(await service.snapshot().downloads.map(\.status) == [.paused, .added, .added])
        #expect(await transport.requests.isEmpty)
        await service.shutdown()
    }

    private func source(link: String = "https://fixture.invalid/download") -> DownloadSource {
        DownloadSource(kind: .http, link: link)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-upstream112-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }

    private func waitForRecord(_ service: DownloadService, id: DownloadID, condition: (DownloadRecord) -> Bool) async throws -> DownloadRecord {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let record = await service.snapshot().downloads.first(where: { $0.id == id }), condition(record) { return record }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}

private actor PreviewTransport: HTTPTransport {
    static let content = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
    // Supply a complete downloader write buffer before holding the body so
    // cancellation tests observe bytes already persisted to the part file.
    static let heldPrefixBytes = 64 * 1024
    private(set) var requests: [URLRequest] = []
    private(set) var cancelledRequests = 0
    private var fileName = "preview.zip"
    private let holdRequests: Bool
    private let holdBodies: Bool

    init(holdRequests: Bool = false, holdBodies: Bool = false) {
        self.holdRequests = holdRequests
        self.holdBodies = holdBodies
    }

    func setFileName(_ name: String) { fileName = name }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        if holdRequests {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelledRequests += 1; throw error }
        }
        if request.url?.lastPathComponent == "master.m3u8" {
            return reply(status: 200, headers: [:], bytes: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nmedia.m3u8\n".utf8))
        }
        if request.url?.lastPathComponent == "media.m3u8" {
            return reply(status: 200, headers: [:], bytes: Data("#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.5,\none.ts\n#EXTINF:3.0,\ntwo.ts\n#EXT-X-ENDLIST\n".utf8))
        }
        var headers = ["Content-Disposition": "attachment; filename=\"\(fileName)\"", "ETag": "\"fixture-v1\""]
        if request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
            headers["Content-Range"] = "bytes 0-0/\(Self.content.count)"
            return reply(status: 206, headers: headers, bytes: Self.content.prefix(1))
        }
        return reply(status: 200, headers: headers, bytes: Self.content, hold: holdBodies)
    }

    private func reply(status: Int, headers: [String: String], bytes: Data, hold: Bool = false) -> HTTPTransportResponse {
        var headers = headers
        headers["Content-Length"] = String(bytes.count)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let producer = Task {
                do {
                    if hold {
                        continuation.yield(bytes.prefix(Self.heldPrefixBytes))
                        try await Task.sleep(for: .seconds(30))
                        continuation.yield(bytes.dropFirst(Self.heldPrefixBytes))
                    } else { continuation.yield(bytes) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        return HTTPTransportResponse(statusCode: status, headers: headers, body: body)
    }
}

private final class PreparingSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var blocked = false
    var hasBlocked: Bool { lock.withLock { blocked } }
    func blockFirstSave() {
        let shouldBlock = lock.withLock {
            guard !blocked else { return false }
            blocked = true
            return true
        }
        if shouldBlock { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
}
