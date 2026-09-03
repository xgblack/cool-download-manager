import AppKit
import SwiftUI
import Testing
import CoolDownloadCore
import CoolDownloadIntegration
@testable import CoolDownloadManager

@Suite("主题")
struct ThemeTests {
    @Test("新安装和恢复默认使用跟随系统")
    func defaultsFollowSystem() {
        #expect(AppSettingsModel.defaults(home: URL(fileURLWithPath: "/tmp")).theme == "system")
    }

    @Test("主题解析在切换系统模式时清除固定外观")
    func resolvesThemeModes() {
        #expect(AppTheme("SYSTEM") == .system)
        #expect(AppTheme("unknown") == .system)
        #expect(AppTheme("dark").preferredColorScheme == .dark)
        #expect(AppTheme("light").preferredColorScheme == .light)
        #expect(AppTheme("system").preferredColorScheme == nil)
        #expect(AppTheme("system").windowAppearance == nil)
        #expect(AppTheme("dark").windowAppearance?.name == .darkAqua)
    }

    @Test("工具面板只允许空白标题区启动拖拽")
    func utilityPanelRoutesControlsToAppKit() {
        #expect(!UtilityPanelEventRouting.shouldBeginDrag(for: .systemWindowButton))
        #expect(!UtilityPanelEventRouting.shouldBeginDrag(for: .interactiveContent))
        #expect(!UtilityPanelEventRouting.shouldBeginDrag(for: .nonHeaderContent))
        #expect(UtilityPanelEventRouting.shouldBeginDrag(for: .emptyHeader))
    }

    @Test("浏览器确认请求去重且取消后的晚到请求会被抑制")
    func browserConfirmationQueueDeduplicatesAndSuppressesLateCancellation() {
        let request = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/file.bin")
        ])
        var queue = BrowserDownloadRequestQueue()
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(queue.enqueue(request, now: now) == request)
        #expect(queue.enqueue(request, now: now) == nil)
        #expect(queue.pending.isEmpty)

        #expect(queue.cancel(request, now: now) == nil)
        #expect(queue.active == nil)
        #expect(queue.enqueue(request, now: now.addingTimeInterval(1)) == nil)
        #expect(queue.enqueue(
            request,
            now: now.addingTimeInterval(BrowserDownloadRequestQueue.cancellationSuppressionDuration + 0.001)
        ) == request)
    }

    @Test("正常完成不会留下取消抑制")
    func browserConfirmationCompletionAllowsIntentionalRepeat() {
        let request = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/file.bin")
        ])
        var queue = BrowserDownloadRequestQueue()
        let now = Date(timeIntervalSince1970: 2_000)

        #expect(queue.enqueue(request, now: now) == request)
        #expect(queue.complete(request, now: now) == nil)
        #expect(queue.enqueue(request, now: now.addingTimeInterval(1)) == request)
    }

    @Test("浏览器确认队列保留不同请求的先后顺序")
    func browserConfirmationQueuePreservesDistinctRequests() {
        let first = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/one.bin")
        ])
        let second = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/two.bin")
        ])
        var queue = BrowserDownloadRequestQueue()

        #expect(queue.enqueue(first) == first)
        #expect(queue.enqueue(second) == nil)
        #expect(queue.enqueue(second) == nil)
        #expect(queue.pending == [second])
        #expect(queue.finish(second) == nil)
        #expect(queue.active == first)
        #expect(queue.finish(first) == second)
        #expect(queue.active == second)
        #expect(queue.finish(second) == nil)
        #expect(queue.active == nil)
    }

    @Test("同一下载意图的回退请求不会在取消后再次弹出")
    func browserConfirmationQueueSuppressesFallbackVariants() {
        let first = AddDownloadsRequest(
            items: [IntegrationDownloadCredential(
                link: "HTTPS://Example.test/file.bin",
                headers: ["Authorization": "Bearer token"],
                downloadPage: " https://Example.test/watch ",
                suggestedName: "from-http.bin"
            )],
            options: AddDownloadOptions(silentAdd: false, silentStart: true)
        )
        let fallback = AddDownloadsRequest(
            items: [IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                headers: ["authorization": "Bearer token"],
                downloadPage: "https://example.test/watch",
                suggestedName: "from-native.bin"
            )],
            options: AddDownloadOptions(silentAdd: false, silentStart: false)
        )
        var queue = BrowserDownloadRequestQueue()
        let now = Date(timeIntervalSince1970: 3_000)

        #expect(queue.enqueue(first, now: now) == first)
        #expect(queue.enqueue(fallback, now: now) == nil)
        #expect(queue.pending.isEmpty)
        #expect(queue.cancel(first, now: now) == nil)
        #expect(queue.enqueue(fallback, now: now.addingTimeInterval(1)) == nil)
    }

    @Test("缺少请求头或下载页的回退请求仍视为同一下载")
    func browserConfirmationQueueMatchesMissingFallbackMetadata() {
        let first = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                headers: ["Authorization": "Bearer token"],
                downloadPage: "https://example.test/watch"
            )
        ])
        let fallback = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/file.bin")
        ])
        var queue = BrowserDownloadRequestQueue()
        let now = Date(timeIntervalSince1970: 3_500)

        #expect(queue.enqueue(first, now: now) == first)
        #expect(queue.enqueue(fallback, now: now) == nil)
        #expect(queue.pending.isEmpty)
        #expect(queue.cancel(first, now: now) == nil)
        #expect(queue.enqueue(fallback, now: now.addingTimeInterval(1)) == nil)
    }

    @Test("兼容回退不会残留在其他请求之后")
    func browserConfirmationQueueDoesNotLeaveFallbackBehindUnrelatedRequest() {
        let first = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                downloadPage: "https://example.test/watch"
            )
        ])
        let fallback = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/file.bin")
        ])
        let other = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(link: "https://example.test/other.bin")
        ])
        var queue = BrowserDownloadRequestQueue()
        let now = Date(timeIntervalSince1970: 3_600)

        #expect(queue.enqueue(first, now: now) == first)
        #expect(queue.enqueue(other, now: now) == nil)
        // The fallback is deduplicated against the active request rather than
        // being left behind to reopen after the unrelated request completes.
        #expect(queue.enqueue(fallback, now: now) == nil)
        #expect(queue.pending == [other])
        #expect(queue.cancel(first, now: now) == other)
        #expect(queue.active == other)
        #expect(queue.complete(other, now: now) == nil)
        #expect(queue.active == nil)
    }

    @Test("请求头有意义的变化仍保留为独立下载")
    func browserConfirmationQueueKeepsCredentialVariantsDistinct() {
        let first = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                headers: ["Authorization": "Bearer one"]
            )
        ])
        let second = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                headers: ["Authorization": "Bearer two"]
            )
        ])
        var queue = BrowserDownloadRequestQueue()

        #expect(queue.enqueue(first) == first)
        #expect(queue.enqueue(second) == nil)
        #expect(queue.pending == [second])
    }

    @Test("下载类型不同的请求保持独立")
    func browserConfirmationQueueKeepsDownloadKindsDistinct() {
        let http = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                type: .http
            )
        ])
        let hls = AddDownloadsRequest(items: [
            IntegrationDownloadCredential(
                link: "https://example.test/file.bin",
                type: .hls
            )
        ])
        var queue = BrowserDownloadRequestQueue()

        #expect(queue.enqueue(http) == http)
        #expect(queue.enqueue(hls) == nil)
        #expect(queue.pending == [hls])
    }
}
