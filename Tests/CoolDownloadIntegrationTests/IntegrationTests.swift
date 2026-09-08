import Foundation
import Darwin
import Network
import Testing
import CoolDownloadCore
@testable import CoolDownloadIntegration

@Suite("CoolDownloadIntegration")
struct IntegrationTests {
    @Test("HTTP authentication fails closed unless anonymous mode is explicit")
    func authenticationPolicy() async {
        for key in [nil, "", "   "] as [String?] {
            let router = IntegrationRouter(handler: RecordingHandler(), apiKey: key)
            for path in ["/ping", "/queues", "/add", "/start-headless-download", "/downloads/7/source"] {
                let response = await router.handle(HTTPRequest(method: "POST", path: path))
                #expect(response.statusCode == 401)
            }
        }
        let anonymous = IntegrationRouter(handler: RecordingHandler(), allowAnonymous: true)
        #expect(await anonymous.handle(HTTPRequest(method: "POST", path: "/ping")).statusCode == 200)
        let authenticated = IntegrationRouter(handler: RecordingHandler(), apiKey: "secret")
        for value in ["", "wrong"] {
            #expect(await authenticated.handle(HTTPRequest(method: "POST", path: "/ping", headers: ["X-Api-Key": value])).statusCode == 401)
        }
    }

    @Test("HTTP rejects untrusted browser origins and rebinding hosts even with a token")
    func browserBoundary() async {
        let router = IntegrationRouter(handler: RecordingHandler(), apiKey: "secret")
        for headers in [
            ["Host": "attacker.test:15151"],
            ["Host": "localhost:80"],
            ["Origin": "https://attacker.test"],
            ["Origin": "null"],
            ["Origin": "http://localhost:15151.attacker.test"]
        ] {
            let request = HTTPRequest(method: "POST", path: "/ping", headers: headers.merging(["X-Api-Key": "secret"]) { _, new in new })
            #expect(await router.handle(request).statusCode == 403)
        }
        for host in ["localhost:15151", "127.0.0.1:15151", "[::1]:15151"] {
            #expect(await router.handle(HTTPRequest(method: "POST", path: "/ping", headers: ["Host": host, "X-Api-Key": "secret"])).statusCode == 200)
        }
    }

    @Test("HTTP parser distinguishes incomplete bodies from invalid and overflowing lengths")
    func boundedHTTPParser() throws {
        for value in ["-1", "+1", "abc", "9223372036854775807", "9999999999999999999999999"] {
            let bytes = Data("POST /add HTTP/1.1\r\nHost: localhost:15151\r\nContent-Length: \(value)\r\n\r\n".utf8)
            #expect(throws: (any Error).self) { _ = try LoopbackHTTPServer.parseRequest(bytes) }
        }
        for extra in ["Content-Length: 0\r\ncontent-length: 0", "Transfer-Encoding: chunked", "Bad Header: x"] {
            #expect(throws: (any Error).self) {
                _ = try LoopbackHTTPServer.parseRequest(Data("POST /ping HTTP/1.1\r\nHost: localhost:15151\r\n\(extra)\r\n\r\n".utf8))
            }
        }
        let prefix = Data("POST /add HTTP/1.1\r\nHost: localhost:15151\r\nContent-Length: 2\r\n\r\n".utf8)
        #expect(try LoopbackHTTPServer.parseRequest(prefix + Data("x".utf8)) == nil)
        #expect(try LoopbackHTTPServer.parseRequest(prefix + Data("xy".utf8))?.body == Data("xy".utf8))
        #expect(try LoopbackHTTPServer.parseRequest(Data("POST /ping HTTP/1.1\r\nHost: localhost:15151\r\n\r\n".utf8))?.body.isEmpty == true)
        #expect(throws: (any Error).self) { _ = try LoopbackHTTPServer.parseRequest(Data(repeating: 65, count: 16 * 1024 + 1)) }
    }

    @Test("stopping a stale socket server cannot unlink its replacement")
    func staleSocketStop() throws {
        let root = URL(fileURLWithPath: "/tmp/cdm-lifecycle-\(UUID().uuidString)")
        let url = root.appendingPathComponent("s.sock")
        let first = PrivateSocketServer(socketURL: url) { $0 }
        let second = PrivateSocketServer(socketURL: url) { $0 }
        try first.start()
        first.stop()
        try second.start()
        defer { second.stop() }
        first.stop()
        let request = PrivateSocketMessage(requestId: "replacement", action: "ping")
        #expect(try PrivateSocketClient(socketURL: url).send(request) == request)
    }

    @Test("HTTP cannot start with an absent or blank key")
    func httpStartupAuthentication() throws {
        for key in [nil, "", "  "] as [String?] {
            let router = IntegrationRouter(handler: RecordingHandler(), apiKey: key)
            #expect(throws: IntegrationServerError.authenticationRequired) {
                _ = try LoopbackHTTPServer(router: router)
            }
        }
    }

    @Test("HTTP closes excess, expired and stopped connections")
    func httpConnectionLifecycle() async throws {
        let port = UInt16.random(in: 27000..<28000)
        let server = try LoopbackHTTPServer(
            port: port, router: IntegrationRouter(handler: RecordingHandler(), apiKey: "secret"),
            maximumConnections: 1, connectionTimeout: 0.5
        )
        server.start()
        defer { server.stop() }
        try await waitForHTTP(port)
        try await performWithoutBlockingExecutor {
            // The first client occupies the sole slot with an incomplete request.
            let first = try openTestTCP(port)
            defer { _ = Darwin.close(first) }
            let partial = Data("POST /ping HTTP/1.1\r\nHost: ".utf8)
            try sendTestBytes(partial, to: first)
            usleep(50_000)
            let excess = try openTestTCP(port)
            defer { _ = Darwin.close(excess) }
            #expect(testPeerClosed(excess))
            // A total deadline expires even though the peer has not completed its headers.
            #expect(testPeerClosed(first))
            let stopped = try openTestTCP(port)
            defer { _ = Darwin.close(stopped) }
            try sendTestBytes(partial, to: stopped)
            usleep(50_000)
            server.stop()
            server.stop()
            #expect(testPeerClosed(stopped))
        }
    }

    @Test("HTTP listener conflict reports failure without stopping private socket")
    func listenerConflict() async throws {
        let port = UInt16.random(in: 28000..<29000)
        let router = IntegrationRouter(handler: RecordingHandler(), apiKey: "secret")
        let first = try LoopbackHTTPServer(port: port, router: router)
        first.start()
        defer { first.stop() }
        try await waitForHTTP(port)
        let failures = ListenerFailures()
        let root = URL(fileURLWithPath: "/tmp/cdm-conflict-\(UUID().uuidString)")
        let socket = PrivateSocketServer(socketURL: root.appendingPathComponent("s.sock")) { $0 }
        try socket.start()
        defer { socket.stop() }
        do {
            let second = try LoopbackHTTPServer(port: port, router: router) { failures.record($0) }
            second.start()
            defer { second.stop() }
            let deadline = ContinuousClock.now + .seconds(2)
            while failures.count == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(failures.count == 1)
        } catch {
            // Network.framework may reject a conflicting bind synchronously.
            #expect(error is NWError)
        }
        let message = PrivateSocketMessage(requestId: "independent", action: "ping")
        #expect(try await sendWithoutBlockingExecutor(message, using: PrivateSocketClient(socketURL: socket.socketURL)) == message)
    }

    private func waitForHTTP(_ port: UInt16) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ping")!)
        request.httpMethod = "POST"
        request.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        request.timeoutInterval = 0.5
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                return
            } catch {
                guard ContinuousClock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

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

        let patchPayload = Data(#"{"link":"https://example.test/a.bin?signature=secret","headers":{"Authorization":"Bearer secret"}}"#.utf8)
        let patched = await router.handle(HTTPRequest(
            method: "PATCH",
            path: "/downloads/7/source",
            headers: ["X-Api-Key": "secret"],
            body: patchPayload
        ))
        #expect(patched.statusCode == 200)
        #expect(await handler.sourcePatches.count == 1)
        #expect(!patched.body.contains(Data("signature".utf8)))
        #expect(!patched.body.contains(Data("Authorization".utf8)))

        let malformedPath = await router.handle(HTTPRequest(
            method: "PATCH",
            path: "/downloads/7/source/extra",
            headers: ["X-Api-Key": "secret"],
            body: patchPayload
        ))
        #expect(malformedPath.statusCode == 404)

        let malformedBody = await router.handle(HTTPRequest(
            method: "PATCH",
            path: "/downloads/7/source",
            headers: ["X-Api-Key": "secret"],
            body: Data("{}".utf8)
        ))
        #expect(malformedBody.statusCode == 400)
    }

    @Test("source patch route enforces authentication, exact paths and bounded input")
    func sourcePatchRouteValidation() async throws {
        let payload = Data(#"{"link":"https://example.test/file?token=private","headers":{"Authorization":"Bearer private"}}"#.utf8)
        let handler = RecordingHandler()
        let router = IntegrationRouter(handler: handler, apiKey: "secret")

        let missingKey = await router.handle(HTTPRequest(
            method: "PATCH",
            path: "/downloads/7/source",
            body: payload
        ))
        #expect(missingKey.statusCode == 401)
        let wrongKey = await router.handle(HTTPRequest(
            method: "PATCH",
            path: "/downloads/7/source",
            headers: ["X-Api-Key": "wrong"],
            body: payload
        ))
        #expect(wrongKey.statusCode == 401)

        let invalidPaths = [
            "/downloads/7/source/",
            "/downloads//source",
            "//downloads/7/source",
            "/downloads/0/source",
            "/downloads/not-an-id/source",
            "/downloads/7/source?extra=true",
            "/downloads/7/source/extra"
        ]
        for path in invalidPaths {
            let response = await router.handle(HTTPRequest(
                method: "PATCH",
                path: path,
                headers: ["X-Api-Key": "secret"],
                body: payload
            ))
            #expect(response.statusCode == 404, "unexpected path accepted: \(path)")
        }

        let invalidBodies = [
            Data("{".utf8),
            Data(#"{"headers":{}}"#.utf8),
            Data(#"{"link":"ftp://example.test/file"}"#.utf8),
            Data(#"{"link":"https://example.test/file","extra":true}"#.utf8),
            Data(#"{"link":"https://example.test/file","headers":{"Cookie":"a","cookie":"b"}}"#.utf8),
            Data(#"{"link":"https://example.test/file","headers":{"X-Test":"line\r\nbreak"}}"#.utf8)
        ]
        for body in invalidBodies {
            let response = await router.handle(HTTPRequest(
                method: "PATCH",
                path: "/downloads/7/source",
                headers: ["X-Api-Key": "secret"],
                body: body
            ))
            #expect(response.statusCode == 400)
            #expect(String(data: response.body, encoding: .utf8) == "Invalid request")
        }
        #expect(await handler.sourcePatches.isEmpty)
    }

    @Test("source patch route maps failures without exposing source material")
    func sourcePatchErrorMapping() async throws {
        let payload = Data(#"{"link":"https://example.test/file?signature=private"}"#.utf8)
        let coreFailures: [(DownloadCoreError, Int)] = [
            (.invalidURL("https://example.test/?signature=private"), 400),
            (.invalidSourcePatch("Authorization: private"), 400),
            (.notFound(7), 404),
            (.invalidState(7, .completed), 409),
            (.resourceChanged, 409),
            (.resumeNotSupported, 409),
            (.sourceRefreshRequired(.credentialsUnavailable), 409)
        ]

        for (error, expectedStatus) in coreFailures {
            let router = IntegrationRouter(
                handler: RecordingHandler(patchFailure: .core(error)),
                apiKey: "secret"
            )
            let response = await router.handle(HTTPRequest(
                method: "PATCH",
                path: "/downloads/7/source",
                headers: ["X-Api-Key": "secret"],
                body: payload
            ))
            #expect(response.statusCode == expectedStatus)
            #expect(!response.body.contains(Data("private".utf8)))
            #expect(!response.body.contains(Data("signature".utf8)))
            #expect(!response.body.contains(Data("Authorization".utf8)))
        }

        let storageRouter = IntegrationRouter(
            handler: RecordingHandler(patchFailure: .storage),
            apiKey: "secret"
        )
        let storageFailure = await storageRouter.handle(HTTPRequest(
            method: "PATCH",
            path: "/downloads/7/source",
            headers: ["X-Api-Key": "secret"],
            body: payload
        ))
        #expect(storageFailure.statusCode == 500)
        #expect(String(data: storageFailure.body, encoding: .utf8) == "Request failed")
        #expect(!storageFailure.body.contains(Data("private".utf8)))
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
        let response = try await sendWithoutBlockingExecutor(
            PrivateSocketMessage(requestId: "B_1", action: "ping"),
            using: client
        )
        #expect(response.requestId == "B_1")
        #expect(response.payload == "true")
        var socketStat = stat()
        #expect(lstat(socketURL.path, &socketStat) == 0)
        #expect((socketStat.st_mode & S_IFMT) == S_IFSOCK)
        #expect((socketStat.st_mode & 0o777) == 0o600)
        var directoryStat = stat()
        #expect(lstat(root.path, &directoryStat) == 0)
        #expect((directoryStat.st_mode & 0o777) == 0o700)

        let competingServer = PrivateSocketServer(socketURL: socketURL) { request in
            PrivateSocketMessage(requestId: request.requestId, action: request.action, payload: "false")
        }
        await #expect(throws: PrivateSocketServer.PrivateSocketServerError.alreadyRunning(socketURL)) {
            try await performWithoutBlockingExecutor {
                try competingServer.start()
            }
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
                    return try await sendWithoutBlockingExecutor(request, using: client)
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

    private func sendWithoutBlockingExecutor(
        _ message: PrivateSocketMessage,
        using client: PrivateSocketClient
    ) async throws -> PrivateSocketMessage {
        try await performWithoutBlockingExecutor {
            try client.send(message)
        }
    }

    private func performWithoutBlockingExecutor<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    @Test("loopback HTTP server binds locally and serves ping")
    func loopbackHTTP() async throws {
        let router = IntegrationRouter(handler: RecordingHandler(), apiKey: "secret")
        let port = UInt16(25000 + Int.random(in: 0..<500))
        let server = try LoopbackHTTPServer(port: port, router: router)
        server.start()
        defer { server.stop() }
        try await waitForHTTP(port)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ping")!)
        request.httpMethod = "POST"
        request.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "pong")

        var ipv6Request = URLRequest(url: URL(string: "http://[::1]:\(port)/ping")!)
        ipv6Request.httpMethod = "POST"
        ipv6Request.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        let (ipv6Data, ipv6Response) = try await URLSession.shared.data(for: ipv6Request)
        #expect((ipv6Response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: ipv6Data, encoding: .utf8) == "pong")
    }

    @Test("loopback source patch resumes an expired download and completes it")
    func loopbackSourcePatchResumesDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdm-source-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = SourceRefreshIntegrationTransport()
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root,
            retryPolicy: DownloadRetryPolicy(maxAttempts: 1, delay: .milliseconds(1))
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(
                kind: .http,
                link: "https://fixture.invalid/expired.bin",
                suggestedName: "refreshed.bin"
            ),
            start: true
        ))

        let waitingDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < waitingDeadline,
              await service.snapshot().downloads.first?.status != .waitingForSourceRefresh {
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = try #require(await service.snapshot().downloads.first)
        #expect(waiting.status == .waitingForSourceRefresh)
        #expect(waiting.sourceRefreshReason == .authenticationRequired)

        let router = IntegrationRouter(
            handler: CoreDownloadIntegrationHandler(service: service),
            apiKey: "secret"
        )
        let port = UInt16(25500 + Int.random(in: 0..<400))
        let server = try LoopbackHTTPServer(port: port, router: router)
        server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(50))

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/downloads/\(id)/source")!
        )
        request.httpMethod = "PATCH"
        request.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            #"{"link":"https://fixture.invalid/refreshed.bin?token=fresh","headers":{"Authorization":"Bearer fresh"}}"#.utf8
        )
        let (responseBody, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!responseBody.contains(Data("fresh".utf8)))
        let patchResult = try JSONDecoder().decode(DownloadSourcePatchResult.self, from: responseBody)
        #expect(patchResult.id == id)
        #expect(patchResult.continued)

        let completionDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < completionDeadline,
              await service.snapshot().downloads.first?.status != .completed {
            try await Task.sleep(for: .milliseconds(5))
        }
        let completed = try #require(await service.snapshot().downloads.first)
        #expect(completed.status == .completed)
        #expect(completed.sourceRefreshReason == nil)
        #expect(completed.source.link == "https://fixture.invalid/refreshed.bin?token=fresh")
        #expect(completed.source.headers?["Authorization"] == "Bearer fresh")
        #expect(completed.source.credentialReference == nil)
        #expect(try Data(contentsOf: completed.destinationURL) == Data("new!".utf8))
        #expect(await transport.refreshedRequestCount >= 2)
        #expect(await transport.receivedAuthorization == "Bearer fresh")
        await service.shutdown()
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
        let interactiveRequests = InteractiveRequestRecorder()
        let handler = CoreDownloadIntegrationHandler(
            service: service,
            interactiveAddHandler: { request in
                await interactiveRequests.record(request)
            }
        )

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
        #expect(records.first(where: { $0.name == "gui.bin" }) == nil)
        #expect(await interactiveRequests.requests.map(\.items.first?.suggestedName) == ["gui.bin"])
        #expect(records.first(where: { $0.name == "silent.bin" })?.status == .added)
        #expect(records.first(where: { $0.name == "start.bin" })?.status == .completed)
    }

    @Test("interactive browser adds fail instead of creating a zero-byte task when confirmation is unavailable")
    func interactiveAddRequiresConfirmationHandler() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdm-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: IntegrationTransport()),
            defaultFolder: root
        )
        try await service.boot()
        let handler = CoreDownloadIntegrationHandler(service: service)
        let request = AddDownloadsRequest(
            items: [IntegrationDownloadCredential(link: "https://fixture.invalid/confirm.bin")],
            options: AddDownloadOptions(silentAdd: false, silentStart: false)
        )

        await #expect(throws: DownloadIntegrationError.confirmationUnavailable) {
            try await handler.addFromBrowser(request)
        }
        #expect(await service.snapshot().downloads.isEmpty)
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
                case .activeConnectionCountChanged:
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
    var sourcePatches: [(DownloadID, DownloadSourcePatch)] = []
    let patchFailure: RecordedPatchFailure?

    init(
        queues: [IntegrationQueue] = [],
        patchFailure: RecordedPatchFailure? = nil
    ) {
        self.queues = queues
        self.patchFailure = patchFailure
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

    func patchSource(
        id: DownloadID,
        patch: DownloadSourcePatch
    ) async throws -> DownloadSourcePatchResult {
        if let patchFailure {
            switch patchFailure {
            case .core(let error):
                throw error
            case .storage:
                throw MetadataDatabaseError.saveFailed(
                    URL(fileURLWithPath: "/private/signature-secret"),
                    "Authorization: private"
                )
            }
        }
        sourcePatches.append((id, patch))
        return DownloadSourcePatchResult(id: id, status: .paused, continued: false)
    }
}

private enum RecordedPatchFailure: Sendable {
    case core(DownloadCoreError)
    case storage
}

private actor InteractiveRequestRecorder {
    var requests: [AddDownloadsRequest] = []

    func record(_ request: AddDownloadsRequest) {
        requests.append(request)
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

private actor SourceRefreshIntegrationTransport: HTTPTransport {
    private(set) var refreshedRequestCount = 0
    private(set) var receivedAuthorization: String?

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let path = request.url?.path
        let status: Int
        let body: Data
        let headers: [String: String]
        switch path {
        case "/expired.bin":
            status = 403
            body = Data()
            headers = [:]
        case "/refreshed.bin":
            refreshedRequestCount += 1
            receivedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            status = 200
            body = Data("new!".utf8)
            headers = ["Content-Length": String(body.count)]
        default:
            status = 404
            body = Data()
            headers = [:]
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(body)
            continuation.finish()
        }
        return HTTPTransportResponse(statusCode: status, headers: headers, body: stream)
    }
}

private final class ListenerFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var count: Int { lock.withLock { messages.count } }
    func record(_ message: String) { lock.withLock { messages.append(message) } }
}

private func openTestTCP(_ port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw PrivateSocketClientError.system(errno) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    var noSignal: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        let error = errno
        _ = Darwin.close(descriptor)
        throw PrivateSocketClientError.system(error)
    }
    return descriptor
}

private func sendTestBytes(_ bytes: Data, to descriptor: Int32) throws {
    let sent = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    guard sent == bytes.count else { throw PrivateSocketClientError.system(errno) }
}

private func testPeerClosed(_ descriptor: Int32) -> Bool {
    var byte: UInt8 = 0
    let count = Darwin.recv(descriptor, &byte, 1, 0)
    return count == 0 || (count < 0 && errno == ECONNRESET)
}
