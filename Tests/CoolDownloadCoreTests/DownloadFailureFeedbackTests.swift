import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("下载失败反馈")
struct DownloadFailureFeedbackTests {
    @Test("永久网络错误只请求一次并保存安全诊断", arguments: [
        URLError.Code.appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted
    ])
    func permanentFailure(code: URLError.Code) async throws {
        let root = try temporaryRoot()
        defer { trash(root) }
        let transport = FeedbackTransport(failure: code, failuresRemaining: 10)
        let storage = try DownloadStore(rootURL: root)
        let service = DownloadService(store: storage, downloader: HTTPDownloader(transport: transport),
            defaultFolder: root, retryPolicy: .init(maxAttempts: 3, delay: .milliseconds(1)))
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "http://fixture.invalid/file.bin?token=secret"), start: true))
        let failed = try await wait(service, id: id, status: .failed)
        #expect(failed.totalBytes == nil)
        #expect(failed.error?.contains("NSURLErrorDomain / \(code.rawValue)") == true)
        #expect(failed.error?.contains("secret") == false)
        #expect(failed.error?.contains("Authorization") == false)
        #expect(await transport.count == 1)
        await service.shutdown()
        let persisted = try #require(try await storage.load().first { $0.id == id })
        #expect(persisted.error == failed.error)
        #expect(persisted.status == .failed)
    }

    @Test("瞬时错误自动恢复并清除错误；失败任务可手动重试")
    func retryRecovery() async throws {
        let root = try temporaryRoot()
        defer { trash(root) }
        let transport = FeedbackTransport(failure: .timedOut, failuresRemaining: 1)
        let service = DownloadService(store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport), defaultFolder: root,
            retryPolicy: .init(maxAttempts: 2, delay: .milliseconds(1)))
        try await service.boot()
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/file.bin")
        let first = try await service.add(AddDownloadRequest(source: source, name: "auto.bin", start: true))
        let completed = try await wait(service, id: first, status: .completed)
        #expect(completed.error == nil)
        #expect(try Data(contentsOf: completed.destinationURL) == Data([1, 2, 3, 4]))
        #expect(await transport.count == 2)
        await transport.failNext(3)
        let second = try await service.add(AddDownloadRequest(source: source, name: "manual.bin", start: true))
        _ = try await wait(service, id: second, status: .failed)
        await transport.failNext(0)
        try await service.retry(ids: [second])
        let retried = try await wait(service, id: second, status: .completed)
        #expect(retried.error == nil)
        #expect(try Data(contentsOf: retried.destinationURL) == Data([1, 2, 3, 4]))
        await service.shutdown()
    }

    @Test("失败任务更新来源保留字节，探测失败不改来源，成功后等待继续")
    func failedTaskSourceUpdate() async throws {
        let root = try temporaryRoot()
        defer { trash(root) }
        let storage = try DownloadStore(rootURL: root)
        let original = DownloadRecord(id: 77,
            source: DownloadSource(kind: .http, link: "http://fixture.invalid/old.bin"),
            folder: root.path, name: "file.bin", status: .failed,
            downloadedBytes: 2, totalBytes: 4, etag: "\"v1\"",
            parts: [DownloadPart(id: 0, from: 0, to: 3, downloaded: 2)], error: "Legacy network failure")
        try await storage.save(original)
        try Data([1, 2]).write(to: original.incompleteURL)
        let service = DownloadService(store: storage,
            downloader: HTTPDownloader(transport: FeedbackTransport()), defaultFolder: root)
        try await service.boot()
        await #expect(throws: DownloadCoreError.httpStatus(404)) {
            try await service.patchSource(id: original.id,
                patch: DownloadSourcePatch(link: "https://fixture.invalid/missing.bin"))
        }
        let retained = try #require(await service.snapshot().downloads.first)
        #expect(retained.source == original.source)
        #expect(retained.status == .failed && retained.error == original.error)
        #expect(try Data(contentsOf: original.incompleteURL) == Data([1, 2]))
        let result = try await service.patchSource(id: original.id,
            patch: DownloadSourcePatch(link: "https://fixture.invalid/new.bin"))
        #expect(result.status == .paused && !result.continued)
        let updated = try #require(await service.snapshot().downloads.first)
        #expect(updated.error == nil)
        #expect(updated.downloadedBytes == 2 && updated.parts == original.parts)
        try await service.start(id: original.id)
        let completed = try await wait(service, id: original.id, status: .completed)
        #expect(try Data(contentsOf: completed.destinationURL) == Data([1, 2, 3, 4]))
        await service.shutdown()
    }

    @Test("未知网络错误不复制包含签名和凭据的系统描述")
    func safeUnknownError() {
        let error = NSError(domain: NSURLErrorDomain, code: -99999,
            userInfo: [NSLocalizedDescriptionKey: "https://private.invalid/?token=secret Authorization: secret"])
        let message = DownloadFailureText.message(for: error)
        #expect(message.contains("-99999"))
        #expect(!message.contains("secret"))
        #expect(!message.contains("private.invalid"))
        #expect(DownloadFailureText.summary("Legacy failure\nraw details") == "Legacy failure")
    }

    private func wait(_ service: DownloadService, id: DownloadID, status: DownloadStatus) async throws -> DownloadRecord {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let record = await service.snapshot().downloads.first(where: { $0.id == id }), record.status == status {
                return record
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DownloadCoreError.responseMismatch("未到达预期任务状态：\(status)")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func trash(_ root: URL) {
        do { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        catch { Issue.record("无法回收测试目录：\(error.localizedDescription)") }
    }
}

private actor FeedbackTransport: HTTPTransport {
    private let failure: URLError.Code
    private var failuresRemaining: Int
    private(set) var count = 0

    init(failure: URLError.Code = .timedOut, failuresRemaining: Int = 0) {
        self.failure = failure
        self.failuresRemaining = failuresRemaining
    }

    func failNext(_ count: Int) { failuresRemaining = count }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        count += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(failure, userInfo: [NSLocalizedDescriptionKey: "Authorization secret"])
        }
        if request.url?.lastPathComponent == "missing.bin" {
            return reply(status: 404, headers: [:], body: Data())
        }
        let content = Data([1, 2, 3, 4])
        if let range = request.value(forHTTPHeaderField: "Range") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(bounds[0]) ?? 0
            let upper = bounds.count > 1 ? Int(bounds[1]) ?? 3 : 3
            let body = content.subdata(in: lower..<(upper + 1))
            return reply(status: 206, headers: ["ETag": "\"v1\"", "Content-Length": "\(body.count)",
                "Content-Range": "bytes \(lower)-\(upper)/4"], body: body)
        }
        return reply(status: 200, headers: ["Content-Length": "4", "ETag": "\"v1\""], body: content)
    }

    private func reply(status: Int, headers: [String: String], body: Data) -> HTTPTransportResponse {
        HTTPTransportResponse(statusCode: status, headers: headers, body: AsyncThrowingStream {
            $0.yield(body)
            $0.finish()
        })
    }
}
