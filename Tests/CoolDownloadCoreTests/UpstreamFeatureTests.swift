import Foundation
import CoreData
import Testing
@testable import CoolDownloadCore

@Suite("上游功能原生核心")
struct UpstreamFeatureTests {
    @Test("ordinary filename parameters preserve naming precedence and sanitize input", arguments: [
        ("filename=report.zip", "report.zip"),
        ("FILENAME=%E4%B8%AD%E6%96%87+report.zip", "中文 report.zip"),
        ("filename=&filename=valid.zip&filename=other.zip", "valid.zip"),
        ("filename=..&filename=valid.zip", "valid.zip"),
        ("filename=..%2Fpath%5Cfile.zip", ".._path_file.zip"),
        ("filename=%00%0A", "download"),
        ("filename=plain.zip&rscd=attachment%3Bfilename%3Dsigned.zip", "signed.zip"),
        ("filename=plain.zip&response-content-disposition=attachment%3Bfilename%3Dpreferred.zip&rscd=attachment%3Bfilename%3Dother.zip", "preferred.zip")
    ])
    func filename(query: String, expected: String) {
        #expect(DownloadFileNameResolver.fromURL("https://fixture.invalid/download?" + query) == expected)
    }

    @Test("legacy speed settings retain behavior and new preferences round-trip", arguments: [Int64(0), Int64(8192)])
    func settingsMigration(oldLimit: Int64) async throws {
        let root = temporaryRoot()
        let store = try SettingsStore(dataRoot: root)
        store.defaults.defaults.set(oldLimit, forKey: "speedLimit")
        var model = try await store.load()
        #expect(model.speedLimiterEnabled == (oldLimit > 0))
        #expect(model.speedLimit == (oldLimit == 0 ? 256 * 1024 : oldLimit))
        #expect(model.minimumPartSize == 16 * 1024 * 1024)
        model.limitWhileUsingOtherApps = true
        model.minimumPartSize = 4 * 1024 * 1024
        model.theme = "dark"
        _ = try await store.save(model)
        _ = try await store.saveSpeedLimiterEnabled(!model.speedLimiterEnabled)
        let reopened = try await SettingsStore(dataRoot: root).load()
        #expect(reopened.speedLimit == model.speedLimit)
        #expect(reopened.speedLimiterEnabled != model.speedLimiterEnabled)
        #expect(reopened.limitWhileUsingOtherApps)
        #expect(reopened.minimumPartSize == model.minimumPartSize)
        #expect(reopened.theme == "dark")
    }

    @Test("settings reject invalid range sizes and enabled zero speed")
    func validation() async throws {
        let store = try SettingsStore(dataRoot: temporaryRoot())
        var settings = try await store.load()
        for size in [Int64(0), Int64(1023), Int64(2_147_483_649)] {
            settings.minimumPartSize = size
            await #expect(throws: SettingsStoreError.self) { _ = try await store.save(settings) }
        }
        for size in [Int64(1024), Int64(2_147_483_648)] {
            settings.minimumPartSize = size
            _ = try await store.save(settings)
        }
        settings.speedLimiterEnabled = true
        settings.speedLimit = 0
        await #expect(throws: SettingsStoreError.self) { _ = try await store.save(settings) }
    }

    @Test("rapid menu toggles serialize without losing a click or overwriting the cap")
    func rapidToggles() async throws {
        let store = try SettingsStore(dataRoot: temporaryRoot())
        let initial = try await store.load()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await store.toggleSpeedLimiter() } }
            try await group.waitForAll()
        }
        let final = try await store.load()
        #expect(final.speedLimiterEnabled == initial.speedLimiterEnabled)
        #expect(final.speedLimit == initial.speedLimit)
    }

    @Test("failed attempts have no completion date and manual retry retains the original start")
    func failedDates() async throws {
        let root = temporaryRoot()
        let service = DownloadService(store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: FeatureHTTPTransport(failFirstDataRequest: true)),
            defaultFolder: root, retryPolicy: DownloadRetryPolicy(maxAttempts: 1))
        try await service.boot()
        let id = try await service.add(request(name: "failed-then-retried.bin"))
        try await service.start(id: id)
        let failed = try await wait(service, id: id) { $0.status == .failed }
        #expect(failed.startedAt != nil && failed.completedAt == nil)
        try await service.retry(ids: [id])
        let completed = try await wait(service, id: id) { $0.status == .completed }
        #expect(completed.startedAt == failed.startedAt && completed.completedAt != nil)
        await service.shutdown()
    }

    @Test("Codable settings recover legacy switches without enabling new installations")
    func codableSettings() throws {
        let decoder = JSONDecoder()
        #expect(try !decoder.decode(AppSettingsModel.self, from: Data("{}".utf8)).speedLimiterEnabled)
        let zero = try decoder.decode(AppSettingsModel.self, from: Data(#"{"speedLimit":0}"#.utf8))
        #expect(!zero.speedLimiterEnabled && zero.speedLimit == 256 * 1024)
        let limited = try decoder.decode(AppSettingsModel.self, from: Data(#"{"speedLimit":4096}"#.utf8))
        #expect(limited.speedLimiterEnabled && limited.speedLimit == 4096)
        #expect(try decoder.decode(AppSettingsModel.self, from: JSONEncoder().encode(limited)) == limited)
    }

    @Test("lifecycle dates survive HTTP pause, resume, completion and fresh record reads")
    func httpDates() async throws {
        let fixture = FeatureHTTPTransport()
        let root = temporaryRoot()
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(store: store, downloader: HTTPDownloader(transport: fixture), defaultFolder: root)
        try await service.boot()
        let id = try await service.add(request(name: "dates.bin"))
        let queued = try #require(await service.snapshot().downloads.first)
        #expect(queued.startedAt == nil && queued.completedAt == nil)
        try await service.start(id: id)
        let started = try await wait(service, id: id) { $0.startedAt != nil }
        #expect(started.completedAt == nil)
        try await service.pause(ids: [id])
        let paused = try #require(await service.snapshot().downloads.first)
        #expect(paused.status == .paused && paused.startedAt == started.startedAt)
        try await service.start(id: id)
        let finished = try await wait(service, id: id) { $0.status == .completed }
        #expect(finished.startedAt == started.startedAt)
        #expect(try #require(finished.completedAt) >= #require(finished.startedAt))
        let reader = try MetadataDatabase(rootURL: root, readOnly: true)
        let freshStore = try DownloadStore(rootURL: root, database: reader)
        let persisted = try #require(try await freshStore.load().first)
        #expect(persisted.startedAt == finished.startedAt && persisted.completedAt == finished.completedAt)
        #expect(try Data(contentsOf: finished.destinationURL) == FeatureHTTPTransport.content)
        try await service.redownload(ids: [id])
        let restarted = try await wait(service, id: id) { $0.startedAt != nil && $0.startedAt != finished.startedAt }
        #expect(restarted.completedAt == nil)
        await service.shutdown()
    }

    @Test("HTTP transient retry retains a single start time and HLS uses the same completion semantics", arguments: [false, true])
    func protocolDates(hls: Bool) async throws {
        let transport = FeatureHTTPTransport(failFirstDataRequest: !hls)
        let root = temporaryRoot()
        let service = DownloadService(
            store: try DownloadStore(rootURL: root), downloader: HTTPDownloader(transport: transport),
            hlsDownloader: HLSDownloader(transport: transport), defaultFolder: root,
            retryPolicy: DownloadRetryPolicy(maxAttempts: 2, delay: .milliseconds(5))
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: hls ? .hls : .http, link: hls ? "https://fixture.invalid/video.m3u8" : "https://fixture.invalid/file"),
            name: hls ? "video.ts" : "retry.bin"
        ))
        try await service.start(id: id)
        let finished = try await wait(service, id: id) { $0.status == .completed || $0.status == .failed }
        #expect(finished.status == .completed)
        #expect(finished.startedAt != nil && finished.completedAt != nil)
        if !hls { #expect(await transport.failures == 1) }
        await service.shutdown()
    }

    @Test("changing the minimum part size preserves existing ranges and applies to subsequent tasks")
    func minimumRangeSize() async throws {
        let root = temporaryRoot()
        let service = DownloadService(
            store: try DownloadStore(rootURL: root), downloader: HTTPDownloader(transport: FeatureHTTPTransport()), defaultFolder: root,
            schedulerConfiguration: .init(maxConnectionsPerDownload: 2, minimumPartSize: 1024)
        )
        try await service.boot()
        let id = try await service.add(request(name: "parts.bin"))
        try await service.start(id: id)
        let segmented = try await wait(service, id: id) { !$0.parts.isEmpty }
        try await service.pause(ids: [id])
        await service.updateConfiguration(schedulerConfiguration: .init(maxConnectionsPerDownload: 2, minimumPartSize: 64 * 1024))
        try await service.start(id: id)
        let resumed = try await wait(service, id: id) { $0.status == .completed }
        #expect(resumed.parts.map(\.from) == segmented.parts.map(\.from))
        #expect(resumed.parts.map(\.to) == segmented.parts.map(\.to))
        let small = try await service.add(request(name: "single.bin"))
        try await service.start(id: small)
        let single = try await wait(service, id: small) { $0.status == .completed }
        #expect(single.parts.isEmpty)
        #expect(try Data(contentsOf: single.destinationURL) == FeatureHTTPTransport.content)
        await service.shutdown()
    }

    @Test("turning off the global limiter releases an active download without replacing its identity")
    func liveLimiter() async throws {
        let root = temporaryRoot()
        let service = DownloadService(
            store: try DownloadStore(rootURL: root), downloader: HTTPDownloader(transport: FeatureHTTPTransport()), defaultFolder: root,
            schedulerConfiguration: .init(speedLimit: 1)
        )
        try await service.boot()
        let id = try await service.add(request(name: "limited.bin"))
        try await service.start(id: id)
        let before = try await wait(service, id: id) { $0.startedAt != nil }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await service.snapshot().downloads.first?.status == .downloading)
        await service.updateGlobalSpeedLimit(bytesPerSecond: 0)
        let finished = try await wait(service, id: id) { $0.status == .completed }
        #expect(finished.id == before.id && finished.startedAt == before.startedAt)
        #expect(try Data(contentsOf: finished.destinationURL) == FeatureHTTPTransport.content)
        await service.shutdown()
    }

    @Test("legacy date round-trip and missing dates never infer lifecycle from update time")
    func legacyDates() throws {
        let raw = Data(#"{"id":1,"link":"https://fixture.invalid/file","folder":"/tmp","name":"file","dateAdded":1000,"updatedAt":9000,"startTime":2000,"completeTime":3000}"#.utf8)
        let decoded = try LegacyJSONCodec.decodeRecord(data: raw)
        #expect(decoded.record.startedAt == Date(timeIntervalSince1970: 2))
        #expect(decoded.record.completedAt == Date(timeIntervalSince1970: 3))
        let data = try LegacyJSONCodec.encodeRecord(decoded.record, preserving: decoded.rawObject)
        #expect(try LegacyJSONCodec.decodeRecord(data: data).record.startedAt == decoded.record.startedAt)
        let old = try LegacyJSONCodec.decodeRecord(data: Data(#"{"id":2,"link":"https://fixture.invalid/file","folder":"/tmp","name":"file","updatedAt":9000}"#.utf8))
        #expect(old.record.startedAt == nil && old.record.completedAt == nil)
    }

    @Test("unsupported metadata remains intact and reports an incompatible model")
    func oldDatabasePreserved() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = MetadataDatabase.makeModel()
        let entity = try #require(model.entitiesByName["DownloadTask"])
        let unknown = NSAttributeDescription()
        unknown.name = "futureAttribute"
        unknown.attributeType = .stringAttributeType
        unknown.isOptional = true
        entity.properties.append(unknown)
        model.versionIdentifiers = ["4"]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let url = root.appendingPathComponent("metadata.sqlite")
        let persistent = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let task = NSEntityDescription.insertNewObject(forEntityName: "DownloadTask", into: context)
            for (key, value) in ["sourceKind":"http", "link":"https://fixture.invalid/keep", "folder":root.path, "name":"keep.bin", "status":"paused"] { task.setValue(value, forKey: key) }
            task.setValue(1, forKey: "id")
            task.setValue(0, forKey: "downloadedBytes")
            task.setValue(1, forKey: "revision")
            task.setValue(Date(), forKey: "createdAt")
            task.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        do {
            _ = try MetadataDatabase(rootURL: root)
            Issue.record("An unsupported metadata model must not open or be recreated")
        } catch {
            #expect(error.localizedDescription.contains("旧数据已保留"))
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        try context.performAndWait {
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
            #expect(rows.count == 1 && rows.first?.value(forKey: "name") as? String == "keep.bin")
            context.reset()
        }
        try coordinator.remove(persistent)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-upstream-\(UUID().uuidString)", isDirectory: true)
    }
    private func request(name: String) -> AddDownloadRequest {
        AddDownloadRequest(source: DownloadSource(kind: .http, link: "https://fixture.invalid/file"), name: name)
    }
    private func wait(_ service: DownloadService, id: DownloadID, condition: (DownloadRecord) -> Bool) async throws -> DownloadRecord {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let record = await service.snapshot().downloads.first(where: { $0.id == id }), condition(record) { return record }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}

private actor FeatureHTTPTransport: HTTPTransport {
    static let content = Data((0..<32_768).map { UInt8($0 % 251) })
    var failFirstDataRequest: Bool
    private(set) var failures = 0
    init(failFirstDataRequest: Bool = false) { self.failFirstDataRequest = failFirstDataRequest }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        if request.url?.pathExtension == "m3u8" {
            return reply(status: 200, headers: [:], bytes: Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8), slow: false)
        }
        let content = Self.content
        let range = request.value(forHTTPHeaderField: "Range")
        if range == "bytes=0-0" {
            return reply(status: 206, headers: ["Content-Range": "bytes 0-0/\(content.count)", "ETag": "\"v1\""], bytes: content.prefix(1), slow: false)
        }
        if failFirstDataRequest { failFirstDataRequest = false; failures += 1; return reply(status: 503, headers: [:], bytes: Data(), slow: false) }
        if let range {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds[0]) ?? 0
            let end = bounds.count > 1 ? Int(bounds[1]) ?? content.count - 1 : content.count - 1
            return reply(status: 206, headers: ["Content-Range": "bytes \(start)-\(end)/\(content.count)", "ETag": "\"v1\""], bytes: content.subdata(in: start..<(end + 1)), slow: true)
        }
        return reply(status: 200, headers: ["ETag": "\"v1\""], bytes: content, slow: true)
    }

    private func reply(status: Int, headers: [String: String], bytes: Data, slow: Bool) -> HTTPTransportResponse {
        var headers = headers
        headers["Content-Length"] = String(bytes.count)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let producer = Task {
                do {
                    for offset in stride(from: 0, to: bytes.count, by: 2048) {
                        if slow { try await Task.sleep(for: .milliseconds(10)) }
                        try Task.checkCancellation()
                        continuation.yield(bytes.subdata(in: offset..<min(offset + 2048, bytes.count)))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        return HTTPTransportResponse(statusCode: status, headers: headers, body: body)
    }
}
