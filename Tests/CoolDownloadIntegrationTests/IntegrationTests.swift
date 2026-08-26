import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadIntegration

@Suite("CoolDownloadIntegration")
struct IntegrationTests {
    @Test("HTTP routes preserve add, queues, ping and API key behavior")
    func routes() async throws {
        let handler = RecordingHandler(queues: [IntegrationQueue(id: 9, name: "Nightly")])
        let router = IntegrationRouter(handler: handler, apiKey: "secret")

        let unauthorized = await router.handle(HTTPRequest(method: "POST", path: "/ping"))
        #expect(unauthorized.statusCode == 401)

        let ping = await router.handle(HTTPRequest(
            method: "POST", path: "/ping", headers: ["X-Api-Key": "secret"]
        ))
        #expect(ping.statusCode == 200)
        #expect(String(data: ping.body, encoding: .utf8) == "pong")

        let addPayload = Data(#"[{"link":"https://example.test/file.zip","suggestedName":"file.zip","type":"http","description":"ignored"}]"#.utf8)
        let add = await router.handle(HTTPRequest(
            method: "POST", path: "/add", headers: ["X-Api-Key": "secret"], body: addPayload
        ))
        #expect(add.statusCode == 200)
        #expect(await handler.addRequests.count == 1)
        #expect(await handler.addRequests.first?.items.first?.link == "https://example.test/file.zip")

        let queues = await router.handle(HTTPRequest(
            method: "GET", path: "/queues", headers: ["X-Api-Key": "secret"]
        ))
        #expect(queues.statusCode == 200)
        #expect(String(data: queues.body, encoding: .utf8)?.contains("Nightly") == true)

        let headlessPayload = Data(#"{"downloadSource":{"link":"https://example.test/a.bin","type":"hls"},"startDownload":true,"unknown":true}"#.utf8)
        let headless = await router.handle(HTTPRequest(
            method: "POST", path: "/start-headless-download", headers: ["X-Api-Key": "secret"], body: headlessPayload
        ))
        #expect(headless.statusCode == 200)
        #expect(await handler.headlessRequests.count == 1)
    }

    @Test("Native Messaging codec uses native-endian four-byte framing")
    func nativeCodec() throws {
        let message = NativeMessagingMessage(
            id: "B_test",
            content: NativeMessagingContent(action: "ping", payload: "{}")
        )
        let frame = try NativeMessagingCodec.encode(message)
        #expect(frame.count > 4)
        let decoded = try NativeMessagingCodec.decodeFrame(frame)
        #expect(decoded.message == message)
        #expect(decoded.consumed == frame.count)

        let pipe = Pipe()
        try NativeMessagingCodec.write(message, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let piped = try NativeMessagingCodec.decodeFrame(pipe.fileHandleForReading.readDataToEndOfFile())
        #expect(piped.message == message)

        #expect(throws: NativeMessagingError.truncatedFrame) {
            _ = try NativeMessagingCodec.decodeFrame(frame.dropLast())
        }
    }

    @Test("private socket codec rejects wrong magic and preserves request IDs")
    func privateCodec() throws {
        let message = PrivateSocketMessage(requestId: "B_1", action: "add", payload: "{\"ok\":true}")
        let frame = try PrivateSocketCodec.encode(message)
        let decoded = try PrivateSocketCodec.decodeFrame(frame)
        #expect(decoded.message == message)
        #expect(decoded.consumed == frame.count)

        var invalid = frame
        invalid[0] = 0
        #expect(throws: PrivateSocketError.invalidMagic) {
            _ = try PrivateSocketCodec.decodeFrame(invalid)
        }
    }

    @Test("private socket server forwards one request and cleans up")
    func privateServer() async throws {
        let root = URL(fileURLWithPath: "/tmp/cdm-\(UUID().uuidString)", isDirectory: true)
        let socketURL = root.appendingPathComponent("native-messaging.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PrivateSocketServer(socketURL: socketURL) { request in
            PrivateSocketMessage(
                requestId: request.requestId,
                action: request.action,
                payload: "true"
            )
        }
        try server.start()
        defer { server.stop() }

        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: socketURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let client = PrivateSocketClient(socketURL: socketURL)
        let response = try client.send(PrivateSocketMessage(requestId: "B_1", action: "ping"))
        #expect(response.requestId == "B_1")
        #expect(response.payload == "true")

        let competingServer = PrivateSocketServer(socketURL: socketURL) { request in
            PrivateSocketMessage(requestId: request.requestId, action: request.action, payload: "false")
        }
        #expect(throws: PrivateSocketServer.PrivateSocketServerError.alreadyRunning(socketURL)) {
            try competingServer.start()
        }
    }

    @Test("private socket server preserves a non-socket path")
    func privateServerPreservesOccupiedPath() async throws {
        let root = URL(fileURLWithPath: "/tmp/cdm-occupied-\(UUID().uuidString)", isDirectory: true)
        let socketURL = root.appendingPathComponent("native-messaging.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: socketURL)

        let server = PrivateSocketServer(socketURL: socketURL) { request in
            PrivateSocketMessage(requestId: request.requestId, action: request.action, payload: "true")
        }
        #expect(throws: PrivateSocketServer.PrivateSocketServerError.pathOccupied(socketURL)) {
            try server.start()
        }
        #expect(FileManager.default.fileExists(atPath: socketURL.path))
        #expect(String(data: try Data(contentsOf: socketURL), encoding: .utf8) == "sentinel")
    }

    @Test("private socket server handles concurrent clients without mixing request IDs")
    func privateServerConcurrent() async throws {
        let root = URL(fileURLWithPath: "/tmp/cdm-concurrent-\(UUID().uuidString)", isDirectory: true)
        let socketURL = root.appendingPathComponent("native-messaging.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PrivateSocketServer(socketURL: socketURL) { request in
            try? await Task.sleep(for: .milliseconds(5))
            return PrivateSocketMessage(
                requestId: request.requestId,
                action: request.action,
                payload: request.requestId
            )
        }
        try server.start()
        defer { server.stop() }

        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: socketURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let client = PrivateSocketClient(socketURL: socketURL)
        let responses = try await withThrowingTaskGroup(of: PrivateSocketMessage.self, returning: [PrivateSocketMessage].self) { group in
            for index in 0..<8 {
                group.addTask {
                    let request = PrivateSocketMessage(
                        requestId: "B_\(index)",
                        action: "ping"
                    )
                    return try client.send(request)
                }
            }
            var values: [PrivateSocketMessage] = []
            for try await response in group {
                values.append(response)
            }
            return values
        }
        #expect(Set(responses.map(\.requestId)) == Set((0..<8).map { "B_\($0)" }))
        #expect(responses.allSatisfy { $0.payload == $0.requestId })
    }

    @Test("loopback HTTP server binds locally and serves ping")
    func loopbackHTTP() async throws {
        let router = IntegrationRouter(handler: RecordingHandler())
        let port = UInt16(25000 + Int.random(in: 0..<500))
        let server = try LoopbackHTTPServer(port: port, router: router)
        server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(50))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ping")!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "pong")

        var ipv6Request = URLRequest(url: URL(string: "http://[::1]:\(port)/ping")!)
        ipv6Request.httpMethod = "POST"
        let (ipv6Data, ipv6Response) = try await URLSession.shared.data(for: ipv6Request)
        #expect((ipv6Response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: ipv6Data, encoding: .utf8) == "pong")
    }

    @Test("legacy queue files are exposed through the integration model")
    func legacyQueues() async throws {
        let root = URL(fileURLWithPath: "/tmp/cdm-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queueDirectory = root.appendingPathComponent("config/download_db/queues", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        try Data(#"{"id":12,"name":"Archive"}"#.utf8)
            .write(to: queueDirectory.appendingPathComponent("12.json"))
        let queues = try await LegacyQueueStore(dataRoot: root).load()
        #expect(queues == [IntegrationQueue(id: 12, name: "Archive")])
    }

    @Test("browser add options preserve silent import and silent start semantics")
    func addOptions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdm-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: IntegrationTransport()),
            defaultFolder: root
        )
        try await service.boot()
        let handler = CoreDownloadIntegrationHandler(service: service)

        try await handler.addFromBrowser(AddDownloadsRequest(
            items: [IntegrationDownloadCredential(
                link: "https://fixture.invalid/gui.bin",
                suggestedName: "gui.bin"
            )],
            options: AddDownloadOptions(silentAdd: false, silentStart: true)
        ))
        try await handler.addFromBrowser(AddDownloadsRequest(
            items: [IntegrationDownloadCredential(
                link: "https://fixture.invalid/silent.bin",
                suggestedName: "silent.bin"
            )],
            options: AddDownloadOptions(silentAdd: true, silentStart: false)
        ))
        try await handler.addFromBrowser(AddDownloadsRequest(
            items: [IntegrationDownloadCredential(
                link: "https://fixture.invalid/start.bin",
                suggestedName: "start.bin"
            )],
            options: AddDownloadOptions(silentAdd: true, silentStart: true)
        ))

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await service.snapshot().downloads.contains(where: {
                $0.name == "start.bin" && $0.status == .completed
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let records = await service.snapshot().downloads
        #expect(records.first(where: { $0.name == "gui.bin" })?.status == .added)
        #expect(records.first(where: { $0.name == "silent.bin" })?.status == .added)
        #expect(records.first(where: { $0.name == "start.bin" })?.status == .completed)
    }

    @Test("browser-started downloads publish the progress lifecycle")
    func browserStartedDownloadPublishesProgressLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdm-browser-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: IntegrationTransport()),
            defaultFolder: root
        )
        try await service.boot()
        let handler = CoreDownloadIntegrationHandler(service: service)
        let events = await service.events()

        let observer = Task { () -> [DownloadStatus] in
            var statuses: [DownloadStatus] = []
            for await event in events {
                let record: DownloadRecord?
                switch event {
                case .created(let value), .updated(let value):
                    record = value
                case .removed:
                    record = nil
                }
                if let record, record.name == "browser-progress.bin" {
                    statuses.append(record.status)
                    if record.status == .completed {
                        return statuses
                    }
                }
            }
            return statuses
        }

        try await handler.addFromBrowser(AddDownloadsRequest(
            items: [IntegrationDownloadCredential(
                link: "https://fixture.invalid/browser-progress.bin",
                suggestedName: "browser-progress.bin"
            )],
            options: AddDownloadOptions(silentAdd: true, silentStart: true)
        ))

        let observedStatuses = try await withThrowingTaskGroup(of: [DownloadStatus].self) { group in
            group.addTask { await observer.value }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw EventTimeout()
            }
            defer {
                observer.cancel()
                group.cancelAll()
            }
            return try await group.next()!
        }

        #expect(observedStatuses.contains(.preparing))
        #expect(observedStatuses.contains(.downloading))
        #expect(observedStatuses.contains(.completed))
    }

    @Test("headless downloads register queue and category items")
    func headlessItemRegistration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdm-headless-items-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let queueStore = try QueueStore(dataRoot: root)
        let queue = try await queueStore.create(name: "Browser")
        let categoryStore = try CategoryStore(
            dataRoot: root,
            defaultFolder: root.appendingPathComponent("Downloads", isDirectory: true)
        )
        _ = try await categoryStore.load()
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: IntegrationTransport()),
            defaultFolder: root
        )
        try await service.boot()
        let handler = CoreDownloadIntegrationHandler(
            service: service,
            queueItemAdder: { queueID, downloadID in
                try await queueStore.assignItems([downloadID], to: queueID)
            },
            categoryItemAdder: { categoryID, downloadID in
                try await categoryStore.assignItems([downloadID], to: categoryID)
            }
        )

        let id = try await handler.addHeadless(HeadlessDownloadRequest(
            downloadSource: IntegrationDownloadCredential(
                link: "https://fixture.invalid/browser.bin",
                suggestedName: "browser.bin"
            ),
            queueId: queue.id,
            categoryId: 0
        ))
        #expect(await service.snapshot().downloads.first(where: { $0.id == id })?.queueID == queue.id)
        #expect(await service.snapshot().downloads.first(where: { $0.id == id })?.categoryID == 0)
        #expect(try await queueStore.model(id: queue.id).queueItems == [id])
        #expect(try await categoryStore.model(id: 0).items == [id])
    }
}

private actor RecordingHandler: DownloadIntegrationHandler {
    var addRequests: [AddDownloadsRequest] = []
    var headlessRequests: [HeadlessDownloadRequest] = []
    var queues: [IntegrationQueue] = []

    init(queues: [IntegrationQueue] = []) {
        self.queues = queues
    }

    func addFromBrowser(_ request: AddDownloadsRequest) async throws {
        addRequests.append(request)
    }

    func listQueues() async throws -> [IntegrationQueue] {
        queues
    }

    func addHeadless(_ request: HeadlessDownloadRequest) async throws -> Int64 {
        headlessRequests.append(request)
        return 1
    }
}

private struct EventTimeout: Error {}

private struct IntegrationTransport: HTTPTransport, Sendable {
    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let body = Data("ok".utf8)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(body)
            continuation.finish()
        }
        return HTTPTransportResponse(
            statusCode: 200,
            headers: ["Content-Length": String(body.count)],
            body: stream
        )
    }
}
