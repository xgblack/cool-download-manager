import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("进度窗口停止并删除")
@MainActor
struct DownloadRemovalTests {
    @Test("下载中删除只影响当前任务，临时文件按显式选择处理", arguments: [false, true], [false, true])
    func removesActiveDownload(removePartialFiles: Bool, cancellationSetting: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let metadata = try DownloadStore(rootURL: root)
        let transport = PendingDownloadTransport()
        let service = DownloadService(
            store: metadata,
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root,
            schedulerConfiguration: DownloadSchedulerConfiguration(
                deletePartialFileOnDownloadCancellation: cancellationSetting
            )
        )
        try await service.boot()
        let otherID = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/other.bin"),
            start: false
        ))
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/active.bin"),
            start: true
        ))
        let record = try await waitForPartialFile(id: id, service: service)
        let partialContents = try Data(contentsOf: record.incompleteURL)
        #expect(partialContents.prefix(transport.partialData.count) == transport.partialData)
        // A file created outside the manager at the destination must survive
        // both progress-panel choices, even if the task finishes concurrently.
        let existingFile = Data("existing destination".utf8)
        try existingFile.write(to: record.destinationURL)
        let list = DownloadListStore(service: service)
        await list.reload()
        list.selectedIDs = [otherID]

        try await list.remove(id: id, removePartialFiles: removePartialFiles)

        #expect(transport.wasCancelled)
        #expect(list.record(id: id) == nil)
        #expect(await metadata.record(id: id) == nil)
        #expect(list.selectedIDs == [otherID])
        #expect(list.downloads.map(\.id) == [otherID])
        #expect(try Data(contentsOf: record.destinationURL) == existingFile)
        #expect(FileManager.default.fileExists(atPath: record.incompleteURL.path) == !removePartialFiles)
        if !removePartialFiles {
            #expect(try Data(contentsOf: record.incompleteURL) == partialContents)
        }
        #expect(await service.snapshot().downloads.map(\.id) == [otherID])
        await service.shutdown()
    }

    @Test("下载完成后删除仍保留成品文件", arguments: [false, true])
    func preservesCompletedDestination(removePartialFiles: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let metadata = try DownloadStore(rootURL: root)
        let record = DownloadRecord(
            id: 1,
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/completed.bin"),
            folder: root.path,
            name: "completed.bin",
            status: .completed
        )
        let contents = Data("completed file".utf8)
        try contents.write(to: record.destinationURL)
        try Data("leftover partial file".utf8).write(to: record.incompleteURL)
        try await metadata.save(record)
        let service = DownloadService(store: metadata, defaultFolder: root)
        try await service.boot()
        let list = DownloadListStore(service: service)
        await list.reload()

        try await list.remove(id: record.id, removePartialFiles: removePartialFiles)

        #expect(list.downloads.isEmpty)
        #expect(try Data(contentsOf: record.destinationURL) == contents)
        #expect(FileManager.default.fileExists(atPath: record.incompleteURL.path) == !removePartialFiles)
        await service.shutdown()
    }

    @Test("记录不存在时删除返回错误并保留其他任务")
    func missingRecordReportsFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let service = DownloadService(store: try DownloadStore(rootURL: root), defaultFolder: root)
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/retained.bin"),
            start: false
        ))
        let list = DownloadListStore(service: service)
        await list.reload()
        list.selectedIDs = [id]

        await #expect(throws: DownloadCoreError.notFound(id + 1)) {
            try await list.remove(id: id + 1, removePartialFiles: true)
        }

        #expect(list.downloads.map(\.id) == [id])
        #expect(list.selectedIDs == [id])
        #expect(await service.snapshot().downloads.map(\.id) == [id])
        await service.shutdown()
    }

    @Test("未指定临时文件选择的既有调用仍遵循全局设置", arguments: [false, true])
    func defaultRemovalHonorsSetting(cancellationSetting: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            defaultFolder: root,
            schedulerConfiguration: DownloadSchedulerConfiguration(
                deletePartialFileOnDownloadCancellation: cancellationSetting
            )
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/queued.bin"),
            start: false
        ))
        let record = try #require(await service.snapshot().downloads.first)
        try Data("partial file".utf8).write(to: record.incompleteURL)

        try await service.remove(ids: [id], removeFiles: false)

        #expect(await service.snapshot().downloads.isEmpty)
        #expect(FileManager.default.fileExists(atPath: record.incompleteURL.path) == !cancellationSetting)
        await service.shutdown()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooldm-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // Other suites can occupy MainActor longer than this wait's deadline.
    // Poll on the concurrent executor without weakening the timeout or assertions.
    @concurrent
    nonisolated private func waitForPartialFile(
        id: DownloadID,
        service: DownloadService
    ) async throws -> DownloadRecord {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let record = await service.snapshot().downloads.first(where: { $0.id == id }),
               record.status == .downloading, record.downloadedBytes == 65_536 {
                return record
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "DownloadRemovalTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "测试下载没有写入临时文件"
        ])
    }
}

private final class PendingDownloadTransport: HTTPTransport, @unchecked Sendable {
    let partialData = Data(repeating: 0x61, count: 65_536)
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        if request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
            pair.continuation.finish()
            return HTTPTransportResponse(statusCode: 200, headers: ["Content-Length": "131072"], body: pair.stream)
        }
        pair.continuation.yield(partialData)
        return HTTPTransportResponse(
            statusCode: 200,
            headers: ["Content-Length": "131072"],
            body: pair.stream,
            cancelBody: { [self] in
                lock.withLock { cancelled = true }
                pair.continuation.finish()
            }
        )
    }
}
