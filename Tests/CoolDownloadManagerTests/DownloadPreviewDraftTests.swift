import Foundation
import Testing
import CoolDownloadCore
import CoolDownloadIntegration
@testable import CoolDownloadManager

@MainActor
@Suite("添加下载预览会话与来源草稿")
struct DownloadPreviewDraftTests {
    @Test("多链接预览最多并发两条，完成后继续下一条且结果索引对应来源")
    func previewsBoundConcurrencyAndKeepSourceOrder() async throws {
        let state = DownloadSubmissionState()
        let gate = DraftPreviewGate()
        defer { state.cancelPreviews(); Task { await gate.close() } }
        let sources = (0..<5).map { source("file\($0).bin") }
        state.loadPreviews(sources: sources, debounce: .zero, timeout: .seconds(5)) {
            await gate.perform($0)
        }
        try await waitUntil { await gate.started.count >= 2 }
        #expect(await gate.started.count == 2)
        #expect(await gate.maximumActive == 2)
        #expect(state.isLoadingPreview)

        for index in sources.indices {
            if index >= 2 {
                try await waitUntil { await gate.started.contains(sources[index].link) }
            }
            await gate.release(sources[index].link)
        }
        try await waitUntil { !state.isLoadingPreview }
        #expect(await gate.maximumActive == 2)
        #expect(await gate.started.count == sources.count)
        #expect(state.previewErrors.isEmpty)
        #expect(sources.indices.map { state.previews[$0]?.source } == sources.map(Optional.some))
        #expect(sources.indices.map { state.previews[$0]?.fileName } == sources.map { URL(string: $0.link)?.lastPathComponent })
    }

    @Test("旧会话即使忽略取消后才返回也不能覆盖新地址的结果")
    func staleResultsCannotReplaceCurrentDraft() async throws {
        let state = DownloadSubmissionState()
        let gate = DraftPreviewGate()
        defer { state.cancelPreviews(); Task { await gate.close() } }
        let old = source("old.bin")
        let current = source("new.bin")
        state.loadPreviews(sources: [old], debounce: .zero, timeout: .seconds(5)) {
            await gate.perform($0)
        }
        try await waitUntil { await gate.started.contains(old.link) }
        state.loadPreviews(sources: [current], debounce: .zero, timeout: .seconds(5)) {
            await gate.perform($0)
        }
        try await waitUntil { await gate.started.contains(current.link) }
        await gate.release(current.link)
        try await waitUntil { !state.isLoadingPreview && state.previews[0]?.source == current }
        await gate.release(old.link)
        try await waitUntil { await gate.finished.count == 2 }
        await settleMainActor()

        #expect(await gate.cancelled.contains(old.link))
        #expect(state.previewSources == [current])
        #expect(state.previews[0]?.source == current)
        #expect(state.previews[0]?.fileName == "new.bin")
        #expect(state.matchingPreview(for: old) == nil)
        #expect(state.matchingPreview(for: current)?.fileName == "new.bin")
        #expect(state.previewErrors.isEmpty)
        #expect(!state.isLoadingPreview)
    }

    @Test("会话超时取消探测，所有未完成项显示原因并退出加载状态")
    func timeoutEndsLoadingAndCancelsInFlightOperations() async throws {
        let state = DownloadSubmissionState()
        let gate = DraftPreviewGate()
        defer { state.cancelPreviews(); Task { await gate.close() } }
        let sources = [source("first.bin"), source("second.bin"), source("queued.bin")]
        state.loadPreviews(sources: sources, debounce: .zero, timeout: .milliseconds(100)) {
            await gate.perform($0)
        }
        try await waitUntil { await gate.started.count >= 2 }
        try await waitUntil { !state.isLoadingPreview }
        #expect(await gate.started.count == 2)
        #expect(state.previewValidationError == nil)
        #expect(state.previewErrors.count == 3)
        #expect(state.previewErrors.values.allSatisfy { $0.contains("超时") && $0.contains("直接添加") })

        await gate.close()
        try await waitUntil { await gate.finished.count == 2 }
        await settleMainActor()
        #expect(await gate.cancelled.count == 2)
        #expect(state.previews.isEmpty)
        #expect(state.previewErrors.count == 3)
        #expect(!state.isLoadingPreview)
    }

    @Test("关闭取消不接收迟到结果，无效草稿同时清除旧预览并保留校验错误")
    func cancellationAndInvalidationDoNotWriteLateResults() async throws {
        let state = DownloadSubmissionState()
        let gate = DraftPreviewGate()
        defer { state.cancelPreviews(); Task { await gate.close() } }
        let first = source("cancel.bin")
        state.loadPreviews(sources: [first], debounce: .zero, timeout: .seconds(5)) {
            await gate.perform($0)
        }
        try await waitUntil { await gate.started.contains(first.link) }
        state.cancelPreviews()
        #expect(!state.isLoadingPreview)
        await gate.release(first.link)
        try await waitUntil { await gate.finished.contains(first.link) }
        await settleMainActor()
        #expect(state.previews.isEmpty)
        #expect(state.previewErrors.isEmpty)

        let second = source("invalidate.bin")
        state.loadPreviews(sources: [second], debounce: .zero, timeout: .seconds(5)) {
            await gate.perform($0)
        }
        try await waitUntil { await gate.started.contains(second.link) }
        state.invalidatePreviews("下载地址无效")
        await gate.release(second.link)
        try await waitUntil { await gate.finished.contains(second.link) }
        await settleMainActor()
        #expect(state.previewSources.isEmpty)
        #expect(state.previews.isEmpty)
        #expect(state.previewErrors.isEmpty)
        #expect(state.previewValidationError == "下载地址无效")
        #expect(!state.isLoadingPreview)
    }

    @Test("防抖期间的新输入取消旧探测，空来源保持非加载状态")
    func cancellingDebounceAvoidsUnnecessaryProbe() async throws {
        let state = DownloadSubmissionState()
        let gate = DraftPreviewGate()
        defer { state.cancelPreviews(); Task { await gate.close() } }
        state.loadPreviews(sources: [source("superseded.bin")], debounce: .milliseconds(40), timeout: .seconds(5)) {
            await gate.perform($0)
        }
        state.loadPreviews(sources: [], debounce: .zero) { await gate.perform($0) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await gate.started.isEmpty)
        #expect(state.previewSources.isEmpty)
        #expect(state.previews.isEmpty)
        #expect(!state.isLoadingPreview)
    }

    @Test("同源编辑保留浏览器请求信息，手动名称优先于浏览器提示")
    func sameOriginPreservesCredentialsAndExplicitNameWins() throws {
        let original = IntegrationDownloadCredential(
            link: "https://example.test/original.bin",
            headers: ["Authorization": "Bearer fixture", "Cookie": "session=fixture"],
            downloadPage: "https://example.test/downloads", suggestedName: "browser.bin"
        )
        let edited = try DownloadSourceDraft.source(
            link: "https://EXAMPLE.test:443/updated.bin", name: nil, original: original
        )
        #expect(edited.headers == original.headers)
        #expect(edited.downloadPage == original.downloadPage)
        #expect(edited.suggestedName == "browser.bin")
        let named = try DownloadSourceDraft.source(
            link: edited.link, name: "  手动名称.bin \n", original: original
        )
        #expect(named.suggestedName == "手动名称.bin")
        #expect(named.headers == original.headers)
        let blankName = try DownloadSourceDraft.source(link: edited.link, name: " \n", original: original)
        #expect(blankName.suggestedName == "browser.bin")
    }

    @Test("跨主机、协议或端口编辑清除原请求头、下载页及浏览器名称提示")
    func crossOriginEditClearsBrowserCredentialsAndHints() throws {
        let original = IntegrationDownloadCredential(
            link: "https://example.test/original.bin",
            headers: ["Authorization": "Bearer fixture", "Cookie": "session=fixture"],
            downloadPage: "https://example.test/downloads", suggestedName: "browser.bin"
        )
        for link in [
            "https://other.test/video.m3u8", "http://example.test/video.m3u8",
            "https://example.test:444/video.m3u8"
        ] {
            let edited = try DownloadSourceDraft.source(link: link, name: nil, original: original)
            #expect(edited.kind == .hls)
            #expect(edited.link == link)
            #expect(edited.headers == nil)
            #expect(edited.downloadPage == nil)
            #expect(edited.suggestedName == nil)
        }
        let named = try DownloadSourceDraft.source(
            link: "https://other.test/new.bin", name: "explicit.bin", original: original
        )
        #expect(named.suggestedName == "explicit.bin")
        #expect(named.headers == nil)
    }

    @Test("非法请求头在建立预览来源前被拒绝，不调用探测操作")
    func invalidHeadersDoNotReachProbe() async {
        let state = DownloadSubmissionState()
        let gate = DraftPreviewGate()
        defer { state.cancelPreviews(); Task { await gate.close() } }
        for headers in [
            ["Authorization": "Bearer fixture\r\nInjected: value"],
            ["Invalid Name": "value"],
            ["Authorization": "one", "authorization": "two"]
        ] {
            let original = IntegrationDownloadCredential(link: "https://example.test/file.bin", headers: headers)
            #expect(throws: DownloadCoreError.self) {
                let sources = try DownloadSourceDraft.sources(link: original.link, name: nil, originals: [original])
                state.loadPreviews(sources: sources, debounce: .zero) { await gate.perform($0) }
            }
        }
        await settleMainActor()
        #expect(await gate.started.isEmpty)
        #expect(!state.isLoadingPreview)
        #expect(state.previewSources.isEmpty)
    }

    private func source(_ name: String) -> DownloadSource {
        DownloadSource(kind: .http, link: "https://example.test/\(name)")
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw DraftPreviewTestTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func settleMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

/// Ignores cancellation until explicitly released so the session, rather than
/// a cooperative transport, must reject obsolete results.
private actor DraftPreviewGate {
    private struct Pending {
        let source: DownloadSource
        let continuation: CheckedContinuation<DownloadPreview, Never>
    }

    private var pending: [String: Pending] = [:]
    private var isClosed = false
    private var active = 0
    private(set) var started: [String] = []
    private(set) var finished: Set<String> = []
    private(set) var cancelled: Set<String> = []
    private(set) var maximumActive = 0

    func perform(_ source: DownloadSource) async -> DownloadPreview {
        started.append(source.link)
        active += 1
        maximumActive = max(maximumActive, active)
        let result: DownloadPreview
        if isClosed {
            result = preview(for: source)
        } else {
            result = await withCheckedContinuation { continuation in
                pending[source.link] = Pending(source: source, continuation: continuation)
            }
        }
        active -= 1
        finished.insert(source.link)
        if Task.isCancelled { cancelled.insert(source.link) }
        return result
    }

    func release(_ link: String) {
        guard let item = pending.removeValue(forKey: link) else { return }
        item.continuation.resume(returning: preview(for: item.source))
    }

    func close() {
        isClosed = true
        let items = pending.values
        pending.removeAll()
        for item in items { item.continuation.resume(returning: preview(for: item.source)) }
    }

    private func preview(for source: DownloadSource) -> DownloadPreview {
        DownloadPreview(source: source, fileName: URL(string: source.link)?.lastPathComponent,
                        totalBytes: 2048, supportsResume: true)
    }
}

private struct DraftPreviewTestTimeout: Error {}
