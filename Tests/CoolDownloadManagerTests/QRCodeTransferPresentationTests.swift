import Foundation
import Testing
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration
@testable import CoolDownloadManager

@MainActor
@Suite("批量二维码分享与收集")
struct QRCodeTransferPresentationTests {
    @Test("批量分享默认移除请求信息，完整模式保留来源，复制内容始终为原文")
    func batchSharing() throws {
        let records = fixtureRecords()
        let share = QRCodeShareState(records: records)
        defer { share.cancelRendering() }
        let links = try DownloadSourceShareCodec.decode(#require(share.payload))
        #expect(links.map(\.link) == records.map { $0.source.link })
        #expect(links.allSatisfy { $0.headers == nil && $0.downloadPage == nil })
        share.mode = .source
        share.refresh()
        #expect(try DownloadSourceShareCodec.decode(#require(share.payload)) == records.map(\.source))
        #expect(share.frames.count > 1)
        #expect(share.payload?.hasPrefix("[") == true)
        share.selectFrame(-1)
        #expect(share.currentIndex == share.frames.count - 1)
        #expect(!share.isPlaying)
        share.selectFrame(share.frames.count)
        #expect(share.currentIndex == 0)
        share.setAutomaticPlayback(true)
        #expect(share.isPlaying)
        share.setAutomaticPlayback(false)
        #expect(!share.isPlaying)
    }

    @Test("轮播换帧保留可扫描的前一帧，生成完成后图像与帧号同步")
    func frameTransitionKeepsImage() async throws {
        let share = QRCodeShareState(records: fixtureRecords())
        defer { share.cancelRendering() }
        share.mode = .source
        share.refresh()
        func waitForRender() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while share.isRendering && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!share.isRendering)
        }
        try await waitForRender()
        let previous = try #require(share.image?.pngData)
        share.selectFrame(1)
        #expect(share.image?.pngData == previous)
        #expect(share.displayedIndex == 0)
        try await waitForRender()
        #expect(share.displayedIndex == 1)
        let texts = try QRCodeReader.read(#require(share.image?.pngData))
        #expect(texts == [share.frames[1]])
    }

    @Test("完整来源通过真实 PNG 和 Vision 乱序重复识别，收齐后才提供可选任务")
    func pngRoundTrip() throws {
        let sources = fixtureRecords().map(\.source)
        let payload = try DownloadSourceShareCodec.encode(sources)
        let frames = try DownloadQRCodeTransfer.frames(for: payload)
        #expect(frames.count > 2)
        let state = QRCodeImportState()
        let last = try #require(frames.last)
        let lastTexts = try QRCodeReader.read(QRCodeRenderer.render(last).pngData)
        #expect(!state.receive(lastTexts))
        #expect(state.hasIncompleteTransfer && state.selectedSources.isEmpty)
        #expect(!state.receive(lastTexts))
        #expect(state.collection.received == 1)
        for frame in frames.dropLast().reversed() {
            let texts = try QRCodeReader.read(QRCodeRenderer.render(frame).pngData)
            _ = state.receive(texts)
        }
        #expect(state.collection.isComplete)
        #expect(!state.hasIncompleteTransfer)
        #expect(state.candidates.map(\.sources).flatMap { $0 } == sources)
        #expect(state.selectedSources == [sources[0]])
        state.selectedIDs = Set(state.candidates.map(\.id))
        #expect(state.selectedSources == sources)
    }

    @Test("分批导入 PNG 可补齐，失败图片有提示且保留有效图片进度")
    func incrementalImageImport() async throws {
        let payload = try DownloadSourceShareCodec.encode(fixtureRecords().map(\.source))
        let frames = try DownloadQRCodeTransfer.frames(for: payload)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-qr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let folder = try QRCodeShareState.exportImages(frames, in: root)
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not-an-image".utf8).write(to: invalid)
        let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(images.count == frames.count)
        let state = QRCodeImportState()
        state.importImages(at: [images[0], invalid])
        try await waitForImages(state)
        #expect(state.collection.received == 1 && state.hasIncompleteTransfer)
        #expect(state.errorMessage != nil)
        state.importImages(at: Array(images.dropFirst()).reversed())
        try await waitForImages(state)
        #expect(state.collection.isComplete)
        #expect(state.errorMessage == nil)
        #expect(state.candidates.count == 2)
        state.clear()
        #expect(state.collection.total == 0 && state.selectedSources.isEmpty)
    }

    @Test("冲突保留进度，重置取消未完成识别，旧图片不会回填")
    func resetAndConflicts() async throws {
        let state = QRCodeImportState()
        #expect(!state.receive(["<qr_test/0/2>{\"link\":"]))
        #expect(!state.receive(["<qr_other/1/2>secret"]))
        #expect(state.collection.receivedIndices == [0])
        #expect(state.errorMessage != nil)
        #expect(state.errorMessage?.contains("secret") == false)
        state.importImage(data: try QRCodeRenderer.render("<qr_test/1/2>\"https://example.test/file\"}").pngData)
        #expect(state.isReading)
        state.clear()
        for _ in 0..<5 { await Task.yield() }
        #expect(!state.isReading && state.collection.total == 0 && state.candidates.isEmpty)
        #expect(state.receive(["https://example.test/new"]))
        #expect(state.selectedSources.first?.link == "https://example.test/new")
    }

    @Test("重置会取消仍在加载的拖放文件，并释放识别状态")
    func pendingDropCancels() async throws {
        let provider = NSItemProvider()
        let loading = PendingImageLoad()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { _ in
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { loading.markCancelled() }
            loading.markStarted()
            return progress
        }
        var state: QRCodeImportState? = QRCodeImportState()
        weak let weakState = state
        #expect(state?.importDrop([provider]) == true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !loading.started && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loading.started)
        state?.clear()
        state = nil
        for _ in 0..<100 where weakState != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loading.cancelled)
        #expect(weakState == nil)
    }

    @Test("拼接后的非法来源不会停止扫描，合法单码仍可继续识别")
    func invalidAssemblyRecovers() {
        let state = QRCodeImportState()
        #expect(!state.receive(["<qr_bad/0/1>file:///private/secret"]))
        #expect(state.collection.total == 0 && state.candidates.isEmpty)
        #expect(state.errorMessage?.contains("secret") == false)
        #expect(state.receive(["https://example.test/valid"]))
    }

    private func waitForImages(_ state: QRCodeImportState) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while state.isReading && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!state.isReading)
    }

    private func fixtureRecords() -> [DownloadRecord] {
        (1...2).map { id in
            DownloadRecord(id: Int64(id), source: DownloadSource(kind: id == 1 ? .http : .hls,
                link: "https://example.test/下载\(id).\(id == 1 ? "zip" : "m3u8")?token=fixture",
                headers: ["Cookie": "fixture=" + String(repeating: "中文🙂", count: 100)],
                downloadPage: "https://example.test/page/\(id)"),
                folder: "/tmp/fixture", name: "测试下载\(id)", status: .added,
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        }
    }
}

private final class PendingImageLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func markStarted() { lock.withLock { didStart = true } }
    func markCancelled() { lock.withLock { didCancel = true } }
}
