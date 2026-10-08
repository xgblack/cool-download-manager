import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadIntegration

@Suite("浏览器重复提交防护")
struct BrowserDownloadProtectionTests {
    @Test("HTTP 与 Native Messaging 并发或晚到重试只创建一个任务")
    func concurrentBrowserTransportRetries() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        let router = IntegrationRouter(handler: handler, allowAnonymous: true)
        let request = silentRequest("https://fixture.invalid/file.bin")
        let httpRequest = HTTPRequest(method: "POST", path: "/add", body: try JSONEncoder().encode(request))

        async let httpResponse = router.handle(httpRequest)
        // The application's native socket decodes this payload and calls the
        // same handler instance used by the HTTP router.
        async let nativeResponse: Void = handler.addFromBrowser(request)
        #expect(await httpResponse.statusCode == 200)
        try await nativeResponse
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { try await handler.addFromBrowser(request) }
            }
            try await group.waitForAll()
        }
        #expect(await service.snapshot().downloads.count == 1)
        await service.shutdown()
    }

    @Test("GitHub 原地址与 CDN 地址在两种到达顺序下都只创建一个任务", arguments: [false, true])
    func githubRedirectDuplicates(cdnFirst: Bool) async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        let original = silentRequest(githubAsset, headers: ["Cookie": "fixture=value", "Sec-Fetch-Site": "same-origin"], page: githubPage)
        let cdn = silentRequest(cdnAsset, headers: ["Sec-Fetch-Site": "cross-site"], page: githubPage)
        try await handler.addFromBrowser(cdnFirst ? cdn : original)
        try await handler.addFromBrowser(cdnFirst ? original : cdn)
        #expect(await service.snapshot().downloads.count == 1)
        await service.shutdown()
    }

    @Test("部分批次失败后重试不复制成功项，也不吞掉失败项")
    func failedBrowserBatchCanRetry() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        let first = IntegrationDownloadCredential(link: "https://fixture.invalid/first.bin")
        let invalid = IntegrationDownloadCredential(link: "https://fixture.invalid/second.bin", suggestedName: "invalid/name.bin")
        let options = AddDownloadOptions(silentAdd: true)
        await #expect(throws: DownloadCoreError.invalidName("invalid/name.bin")) {
            try await handler.addFromBrowser(AddDownloadsRequest(items: [first, invalid], options: options))
        }
        #expect(await service.snapshot().downloads.count == 1)
        let corrected = IntegrationDownloadCredential(link: invalid.link, suggestedName: "second.bin")
        try await handler.addFromBrowser(AddDownloadsRequest(items: [first, corrected], options: options))
        #expect(await service.snapshot().downloads.count == 2)
        await service.shutdown()
    }

    @Test("已完成的静默开始请求重试仍返回成功且不再建任务")
    func completedBrowserStartCanRetry() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        var request = silentRequest("https://fixture.invalid/completed.bin")
        request.options.silentStart = true
        try await handler.addFromBrowser(request)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await service.snapshot().downloads.first?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.snapshot().downloads.first?.status == .completed)
        try await handler.addFromBrowser(request)
        #expect(await service.snapshot().downloads.count == 1)
        await service.shutdown()
    }

    @Test("开始失败后的回退重试复用已创建任务")
    func failedBrowserStartCanRetry() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        var request = silentRequest("https://fixture.invalid/start-retry.bin")
        try await handler.addFromBrowser(request)
        let id = try #require(await service.snapshot().downloads.first?.id)
        await service.shutdown()
        request.options.silentStart = true
        await #expect(throws: DownloadCoreError.cancelled) {
            try await handler.addFromBrowser(request)
        }
        try await service.boot()
        try await handler.addFromBrowser(request)
        #expect(await service.snapshot().downloads.map(\.id) == [id])
        await service.shutdown()
    }

    @Test("晚到重试不能重新开始用户已暂停的下载")
    func browserRetryPreservesUserPause() async throws {
        let (root, service) = try await makeService(transport: SlowBrowserProtectionTransport())
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        var request = silentRequest("https://fixture.invalid/paused.bin")
        request.options.silentStart = true
        try await handler.addFromBrowser(request)
        let id = try #require(await service.snapshot().downloads.first?.id)
        try await service.pause(ids: [id])
        try await handler.addFromBrowser(request)
        let downloads = await service.snapshot().downloads
        #expect(downloads.count == 1)
        #expect(downloads.first?.status == .paused)
        await service.shutdown()
    }

    @Test("删除刚创建的任务后立即再下可以创建新任务")
    func removedBrowserDownloadCanBeAddedAgain() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        let request = silentRequest("https://fixture.invalid/removed.bin")
        try await handler.addFromBrowser(request)
        let id = try #require(await service.snapshot().downloads.first?.id)
        try await service.remove(ids: [id], removeFiles: false)
        try await handler.addFromBrowser(request)
        let downloads = await service.snapshot().downloads
        #expect(downloads.count == 1)
        #expect(downloads.first?.id != id)
        await service.shutdown()
    }

    @Test("跨地址匹配需要发布页与文件名证据且保留认证冲突")
    func githubRedirectIdentityBoundaries() {
        let original = IntegrationDownloadCredential(link: githubAsset, downloadPage: githubPage)
        let identity = BrowserDownloadIdentity(original)
        let rejected = [
            IntegrationDownloadCredential(link: cdnAsset),
            IntegrationDownloadCredential(link: cdnAsset, downloadPage: "https://github.com/chen08209/FlClash/releases/tag/v0.8.98"),
            IntegrationDownloadCredential(link: cdnAsset.replacingOccurrences(of: "FlClash-0.8.99-android-arm64-v8a.apk", with: "different.apk"), downloadPage: githubPage),
            IntegrationDownloadCredential(link: "https://cdn.invalid/file.apk", downloadPage: githubPage),
            IntegrationDownloadCredential(link: cdnAsset, downloadPage: githubPage, type: .hls)
        ]
        for source in rejected {
            #expect(!identity.isCompatible(with: BrowserDownloadIdentity(source)))
        }
        let authenticatedOriginal = BrowserDownloadIdentity(IntegrationDownloadCredential(link: githubAsset, headers: ["Authorization": "Bearer one"], downloadPage: githubPage))
        let authenticatedCDN = BrowserDownloadIdentity(IntegrationDownloadCredential(link: cdnAsset, headers: ["authorization": "Bearer two"], downloadPage: githubPage))
        #expect(!authenticatedOriginal.isCompatible(with: authenticatedCDN))
    }

    @Test("短窗口到期后的重下及客户端手动添加仍可创建新任务")
    func intentionalRepeatRemainsAvailable() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        let request = silentRequest("https://fixture.invalid/repeat.bin")
        try await handler.addFromBrowser(request)
        _ = try await service.add(AddDownloadRequest(source: request.items[0].asCoreSource(), start: false))
        #expect(await service.snapshot().downloads.count == 2)
        try await handler.addFromBrowser(request)
        #expect(await service.snapshot().downloads.count == 2)
        try await Task.sleep(for: .milliseconds(4_100))
        try await handler.addFromBrowser(request)
        #expect(await service.snapshot().downloads.count == 3)
        await service.shutdown()
    }

    @Test("同名文件、不同查询参数或凭据不误合并")
    func distinctBrowserSourcesRemainSeparate() async throws {
        let (root, service) = try await makeService()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let handler = CoreDownloadIntegrationHandler(service: service)
        let requests = [
            silentRequest("https://one.invalid/file.bin"),
            silentRequest("https://two.invalid/file.bin"),
            silentRequest("https://one.invalid/file.bin?part=1"),
            silentRequest("https://one.invalid/file.bin?part=2"),
            silentRequest("https://auth.invalid/file.bin", headers: ["Authorization": "Bearer one"]),
            silentRequest("https://auth.invalid/file.bin", headers: ["Authorization": "Bearer two"]),
            silentRequest(githubAsset, page: githubPage),
            // Same filename alone cannot establish a redirect relationship.
            silentRequest(cdnAsset, page: "https://github.com/other/repo/releases/tag/v0.8.99"),
            silentRequest(cdnAsset.replacingOccurrences(of: "release-assets.githubusercontent.com", with: "cdn.invalid"), page: githubPage)
        ]
        for request in requests { try await handler.addFromBrowser(request) }
        #expect(await service.snapshot().downloads.count == requests.count)
        await service.shutdown()
    }

    private var githubPage: String { "https://github.com/chen08209/FlClash/releases/tag/v0.8.99" }
    private var githubAsset: String { "https://github.com/chen08209/FlClash/releases/download/v0.8.99/FlClash-0.8.99-android-arm64-v8a.apk" }
    private var cdnAsset: String { "https://release-assets.githubusercontent.com/github-production-release-asset/123/fixture?rscd=attachment%3B%20filename%3DFlClash-0.8.99-android-arm64-v8a.apk&sig=fixture" }

    private func silentRequest(_ link: String, headers: [String: String]? = nil, page: String? = nil) -> AddDownloadsRequest {
        AddDownloadsRequest(
            items: [IntegrationDownloadCredential(link: link, headers: headers, downloadPage: page)],
            options: AddDownloadOptions(silentAdd: true)
        )
    }

    private func makeService(transport: any HTTPTransport = BrowserProtectionTransport()) async throws -> (URL, DownloadService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdm-browser-protection-\(UUID().uuidString)", isDirectory: true)
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root
        )
        try await service.boot()
        return (root, service)
    }
}

private struct SlowBrowserProtectionTransport: HTTPTransport {
    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        try await Task.sleep(for: .seconds(30))
        return try await BrowserProtectionTransport().response(for: request)
    }
}

private struct BrowserProtectionTransport: HTTPTransport {
    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let body = Data("fixture".utf8)
        return HTTPTransportResponse(
            statusCode: 200,
            headers: ["Content-Length": String(body.count)],
            body: AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            }
        )
    }
}
