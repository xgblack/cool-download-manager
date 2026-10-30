import AppKit
import CryptoKit
import Foundation
import Sparkle
import SwiftUI
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("更新线路与后台更新")
@MainActor
struct UpdateRoutingTests {
    private let archive = URL(string: "https://github.com/xgblack/cool-download-manager/releases/download/v1.0.20/CoolDownloadManager-macOS-arm64.zip")!
    private let feedURL = URL(string: "https://github.com/xgblack/cool-download-manager/releases/latest/download/appcast.xml")!

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cooldm-update-tests-\(UUID().uuidString)"))
    }

    private func signedFeed(build: Int, key: Curve25519.Signing.PrivateKey, extra: String = "") throws -> Data {
        let content = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>\(build)</sparkle:version><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
        <enclosure url="\(archive.absoluteString)" length="524288" sparkle:edSignature="\(Data(repeating: 7, count: 64).base64EncodedString())" />
        \(extra)
        </item></channel></rss>

        """.utf8)
        let signature = try key.signature(for: content).base64EncodedString()
        return content + Data("<!-- sparkle-signatures:\nlength: \(content.count)\nedSignature: \(signature)\n-->\n".utf8)
    }

    @Test("只给本项目合法 HTTPS Release 资源添加前缀并保留编码")
    func rewritesOnlySupportedReleaseURL() throws {
        let route = GitHubUpdateRoute.builtIns[1]
        let url = try #require(URL(string: "https://github.com/xgblack/cool-download-manager/releases/download/v1.0.20/app%20test.zip?download=1"))
        #expect(route.rewriting(url)?.absoluteString == "https://gh-proxy.com/" + url.absoluteString)
        #expect(GitHubUpdateRoute.official.rewriting(url) == url)
        for text in [
            "http://github.com/xgblack/cool-download-manager/releases/download/v1/a.zip",
            "https://github.com.evil.test/xgblack/cool-download-manager/releases/download/v1/a.zip",
            "https://github.com/example/project/releases/download/v1/a.zip",
            "https://user:secret@github.com/xgblack/cool-download-manager/releases/download/v1/a.zip",
            "https://github.com/xgblack/cool-download-manager/releases/download/v1/a.zip#fragment",
            "https://github.com/xgblack/cool-download-manager/issues",
            "https://gh-proxy.com/https://github.com/xgblack/cool-download-manager/releases/download/v1/a.zip"
        ] {
            #expect(route.rewriting(try #require(URL(string: text))) == nil)
        }
    }

    @Test("未知及重复缓存条目不生效且官方线路始终保留")
    func cachedRoutesAreConstrained() throws {
        let storage = try defaults()
        storage.set(["unknown", "ghfast", "ghfast"], forKey: "updateFeedRouteOrder")
        let router = GitHubUpdateRouter(defaults: storage)
        let selection = router.cachedSelection()
        #expect(selection.feedRoutes.first?.id == "ghfast")
        #expect(selection.feedRoutes.count == 4)
        #expect(Set(selection.feedRoutes.map(\.id)) == Set(GitHubUpdateRoute.builtIns.map(\.id)))
    }

    @Test("清单必须用公钥验签后才能参与版本比较")
    func validatesSignedFeed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try signedFeed(build: 1020, key: key)
        let decoded = try VerifiedUpdateFeed.decode(data, publicKey: key.publicKey.rawRepresentation)
        #expect(decoded.build == 1020)
        #expect(decoded.archiveURL == archive)
        #expect(decoded.archiveLength == 524_288)
        #expect(throws: (any Error).self) {
            try VerifiedUpdateFeed.decode(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        }
        let tampered = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: ">1020<", with: ">9999<").utf8)
        #expect(throws: (any Error).self) { try VerifiedUpdateFeed.decode(tampered, publicKey: key.publicKey.rawRepresentation) }
        #expect(throws: (any Error).self) { try VerifiedUpdateFeed.decode(Data("<rss/>".utf8), publicKey: key.publicKey.rawRepresentation) }
    }

    @Test("清单长度错误、外部实体与预发布不能参与线路选取")
    func rejectsInvalidAndNonStableFeeds() throws {
        let key = Curve25519.Signing.PrivateKey()
        let good = try signedFeed(build: 1020, key: key)
        let badLength = Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "length: ", with: "length: 999").utf8)
        #expect(throws: (any Error).self) { try VerifiedUpdateFeed.decode(badLength, publicKey: key.publicKey.rawRepresentation) }
        let beta = try signedFeed(build: 1021, key: key, extra: "<sparkle:channel>beta</sparkle:channel>")
        #expect(throws: (any Error).self) { try VerifiedUpdateFeed.decode(beta, publicKey: key.publicKey.rawRepresentation) }
        let entity = try signedFeed(build: 1021, key: key, extra: "<!ENTITY hidden SYSTEM 'file:///etc/passwd'>")
        #expect(throws: (any Error).self) { try VerifiedUpdateFeed.decode(entity, publicKey: key.publicKey.rawRepresentation) }
    }

    @Test("检查优先有效新版本且下载线路独立按吞吐排序")
    func ranksFeedAndArchiveSeparately() {
        let routes = GitHubUpdateRoute.builtIns
        let older = VerifiedUpdateFeed(build: 1019, archiveURL: archive, archiveLength: 524_288)
        let newer = VerifiedUpdateFeed(build: 1020, archiveURL: archive, archiveLength: 524_288)
        let feeds = GitHubUpdateRouter.rankFeeds([
            .init(route: routes[0], feed: older, milliseconds: 1),
            .init(route: routes[1], feed: newer, milliseconds: 100),
            .init(route: routes[2], feed: newer, milliseconds: 20)
        ], fallback: routes)
        #expect(feeds.map(\.id) == ["ghfast", "gh-proxy", "github", "ghproxy"])
        let downloads = GitHubUpdateRouter.rankArchives([
            .init(route: routes[0], bytesPerSecond: 5000),
            .init(route: routes[1], bytesPerSecond: 1000)
        ], fallback: routes)
        #expect(downloads.first == .official)
        #expect(downloads.count == 4)
    }

    @Test("下载探测拒绝忽略 Range、长度错误和网页响应")
    func validatesRangeSample() {
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0])
        #expect(GitHubUpdateRouter.validArchiveSample(.init(data: bytes, status: 206, contentRange: "bytes 0-7/100"), expectedLength: 100, requestedBytes: 8))
        #expect(!GitHubUpdateRouter.validArchiveSample(.init(data: bytes, status: 200, contentRange: nil), expectedLength: 100, requestedBytes: 8))
        #expect(!GitHubUpdateRouter.validArchiveSample(.init(data: bytes, status: 206, contentRange: "bytes 0-7/200"), expectedLength: 100, requestedBytes: 8))
        #expect(!GitHubUpdateRouter.validArchiveSample(.init(data: Data("<html/>".utf8), status: 206, contentRange: "bytes 0-7/100"), expectedLength: 100, requestedBytes: 8))
    }

    @Test("篡改高版本不污染缓存且只有确有更新才探测 ZIP")
    func refreshUsesVerifiedVersionsAndBoundsRequests() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let old = try signedFeed(build: 1019, key: key)
        let newest = try signedFeed(build: 1020, key: key)
        let forged = try signedFeed(build: 9999, key: Curve25519.Signing.PrivateKey())
        let recorder = ProbeRecorder(feeds: ["github.com": old, "gh-proxy.com": newest, "ghfast.top": forged])
        let storage = try defaults()
        let router = GitHubUpdateRouter(defaults: storage, transport: { request, limit in
            try await recorder.respond(request, limit: limit)
        })
        let selection = try await router.refresh(feedURL: feedURL, publicKey: key.publicKey.rawRepresentation, currentBuild: 1019)
        #expect(selection.latestBuild == 1020)
        #expect(selection.feedRoutes.first?.id == "gh-proxy")
        #expect(selection.feedRoutes.contains(.official))
        #expect(storage.integer(forKey: "highestVerifiedUpdateBuild") == 1020)
        let counts = await recorder.counts()
        #expect(counts.feed == 4)
        #expect(counts.archive == 4)
        #expect(counts.maximumConcurrent <= 2)
        #expect(counts.limits.allSatisfy { $0 <= 256 * 1024 })

        let noUpdateRecorder = ProbeRecorder(feeds: ["github.com": newest])
        let noUpdateRouter = GitHubUpdateRouter(defaults: try defaults(), transport: { request, limit in
            try await noUpdateRecorder.respond(request, limit: limit)
        })
        _ = try await noUpdateRouter.refresh(feedURL: feedURL, publicKey: key.publicKey.rawRepresentation, currentBuild: 1020)
        #expect(await noUpdateRecorder.counts().archive == 0)
    }

    @Test("仅检查更新时不探测安装包，之后显式下载仍会测量线路")
    func feedOnlyRefreshDefersArchiveProbes() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let recorder = ProbeRecorder(feeds: ["github.com": try signedFeed(build: 1020, key: key)])
        let router = GitHubUpdateRouter(defaults: try defaults(), transport: { request, limit in
            try await recorder.respond(request, limit: limit)
        })
        let checked = try await router.refresh(feedURL: feedURL, publicKey: key.publicKey.rawRepresentation,
                                               currentBuild: 1019, probeArchives: false)
        #expect(checked.latestBuild == 1020)
        #expect(await recorder.counts().archive == 0)
        _ = try await router.refresh(feedURL: feedURL, publicKey: key.publicKey.rawRepresentation, currentBuild: 1019)
        #expect(await recorder.counts().archive == 4)
    }

    @Test("探测全失败仍保留全部候选线路供实际检查重试")
    func allProbeFailuresPreserveFallbacks() async throws {
        let router = GitHubUpdateRouter(defaults: try defaults(), transport: { _, _ in throw URLError(.timedOut) })
        let selection = try await router.refresh(feedURL: feedURL, publicKey: Data(repeating: 0, count: 32), currentBuild: 1019)
        #expect(selection.feedRoutes.count == 4)
        #expect(selection.downloadRoutes.count == 4)
        #expect(selection.feedRoutes.contains(.official))
        #expect(selection.latestBuild == 0)
    }

    @Test("流式探测在未知正文长度时达到读取上限就取消请求")
    func boundsStreamingProbeResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedProbeURLProtocol.self]
        let id = UUID().uuidString
        let request = URLRequest(url: try #require(URL(string: "https://update-probe.example/\(id)")))
        do {
            _ = try await GitHubUpdateRouter.fetch(request, maximumBytes: 1024, configuration: configuration)
            Issue.record("超限正文不应读取成功")
        } catch UpdateRoutingError.responseTooLarge {
            #expect(BoundedProbeURLProtocol.metrics.bytes(for: id) < BoundedProbeURLProtocol.totalBytes)
        }
    }

    @Test("服务器忽略 Range 时不继续下载整包")
    func rejectsIgnoredRangeBeforeDownloadingBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedProbeURLProtocol.self]
        let id = UUID().uuidString
        var request = URLRequest(url: try #require(URL(string: "https://update-probe.example/\(id)")))
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        do {
            _ = try await GitHubUpdateRouter.fetch(request, maximumBytes: 1024, configuration: configuration)
            Issue.record("忽略 Range 的服务不应被用于测速")
        } catch UpdateRoutingError.invalidResponse {
            #expect(BoundedProbeURLProtocol.metrics.bytes(for: id) < BoundedProbeURLProtocol.totalBytes)
        }
    }

    @Test("源故障分别推进检查与下载线路，耗尽后停止")
    func retriesAreBoundedAndSeparate() {
        var attempt = UpdateRouteAttempt(selection: .init())
        let feedRoute = attempt.feedRoute
        let firstArchive = attempt.advance(after: .archive)
        #expect(firstArchive)
        #expect(attempt.feedRoute == feedRoute)
        #expect(attempt.archiveIndex == 1)
        let firstFeed = attempt.advance(after: .feed)
        #expect(firstFeed)
        #expect(attempt.archiveIndex == 1)
        let moreFeeds = [0, 1, 2].map { _ in attempt.advance(after: .feed) }
        #expect(moreFeeds == [true, true, false])
        let moreArchives = [0, 1, 2].map { _ in attempt.advance(after: .archive) }
        #expect(moreArchives == [true, true, false])
    }

    @Test("用户取消、无更新和安装权限错误不触发换源")
    func classifiesFailures() {
        let cancel = URLError(.cancelled)
        #expect(AppUpdateController.isCancellation(cancel))
        #expect(AppUpdateController.retryableFailure(cancel, phase: .archive, staleFeed: false) == nil)
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        #expect(AppUpdateController.isNoUpdate(noUpdate))
        let permission = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.authenticationFailure.rawValue))
        #expect(AppUpdateController.retryableFailure(permission, phase: .archive, staleFeed: false) == nil)
        let download = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue))
        #expect(AppUpdateController.retryableFailure(download, phase: .archive, staleFeed: false) == .archive)
        #expect(AppUpdateController.retryableFailure(download, phase: .feed, staleFeed: false) == .feed)
        #expect(AppUpdateController.retryableFailure(noUpdate, phase: .feed, staleFeed: true) == .feed)
    }

    @Test("下载完成后仍在准备阶段，不能提前触发重启")
    func archiveDownloadIsNotInstallReady() {
        let controller = AppUpdateController()
        let release = UpdateRelease(build: "1020", version: "1.0.20")
        controller.updateAvailable(release)
        #expect(controller.state == .available(version: "1.0.20"))
        controller.archiveDownloaded(release)
        controller.performAction()
        #expect(controller.state == .preparing(version: "1.0.20"))
        #expect(controller.state.title == "正在准备更新")
    }

    @Test("重启更新等待恢复信息保存且重复点击只安装一次")
    func restartWaitsForCheckpointHandoff() async {
        let controller = AppUpdateController()
        let release = UpdateRelease(build: "1020", version: "1.0.20")
        let preparing = AsyncStream<Void>.makeStream()
        let installed = AsyncStream<Void>.makeStream()
        var gate: CheckedContinuation<Void, Never>?
        var installCount = 0
        controller.prepareForRelaunch = { build in
            #expect(build == "1020")
            await withCheckedContinuation { continuation in
                gate = continuation
                preparing.continuation.yield(())
            }
        }
        controller.readyToInstall(release) { installCount += 1; installed.continuation.yield(()) }
        controller.performAction()
        controller.performAction()
        var started = preparing.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(installCount == 0)
        #expect(controller.state == .restarting)
        gate?.resume()
        var finished = installed.stream.makeAsyncIterator()
        _ = await finished.next()
        #expect(installCount == 1)
    }

    @Test("重启被取消后清除恢复记录且晚到的准备回调不能安装")
    func cancelledRestartDoesNotRunLateInstallHandler() async {
        let controller = AppUpdateController()
        let release = UpdateRelease(build: "1020", version: "1.0.20")
        let preparing = AsyncStream<Void>.makeStream()
        var gate: CheckedContinuation<Void, Never>?
        var installed = false
        var recoveryDiscarded = false
        controller.prepareForRelaunch = { _ in
            await withCheckedContinuation { continuation in
                gate = continuation
                preparing.continuation.yield(())
            }
        }
        controller.discardRelaunchRecovery = { recoveryDiscarded = true }
        controller.readyToInstall(release) { installed = true }
        controller.performAction()
        var iterator = preparing.stream.makeAsyncIterator()
        _ = await iterator.next()
        let task = controller.abandonRelaunch()
        gate?.resume()
        await task?.value
        #expect(recoveryDiscarded)
        #expect(!installed)
    }

    @Test("恢复信息保存失败时保留已准备的更新供再次重试")
    func restartHandoffFailureDoesNotInstall() async {
        let controller = AppUpdateController()
        let release = UpdateRelease(build: "1020", version: "1.0.20")
        let prepared = AsyncStream<Void>.makeStream()
        var installCount = 0
        controller.prepareForRelaunch = { _ in
            defer { prepared.continuation.yield(()) }
            throw URLError(.cannotWriteToFile)
        }
        controller.readyToInstall(release) { installCount += 1 }
        controller.performAction()
        var iterator = prepared.stream.makeAsyncIterator()
        _ = await iterator.next()
        await Task.yield()
        #expect(installCount == 0)
        #expect(controller.state == .ready(version: "1.0.20"))
        #expect(controller.errorMessage != nil)
    }

    @Test("更新恢复只消费升级前活动任务，过期或未升级记录不自动恢复")
    func updateRecoveryIsOneShotAndSelective() throws {
        let storage = try defaults()
        let recovery = UpdateRestartRecovery(defaults: storage)
        let now = Date(timeIntervalSince1970: 1_000_000)
        var active = record(id: 1); active.status = .downloading
        var paused = record(id: 2); paused.status = .paused
        var retrying = record(id: 3); retrying.status = .retrying
        var completed = record(id: 4); completed.status = .completed
        let records = [active, paused, retrying, completed]
        try recovery.save(targetBuild: "1020", downloads: records, now: now)
        #expect(try recovery.consume(currentBuild: 1020, now: now) == [1, 3])
        #expect(try recovery.consume(currentBuild: 1020, now: now).isEmpty)
        try recovery.save(targetBuild: "1020", downloads: records, now: now)
        #expect(try recovery.consume(currentBuild: 1019, now: now).isEmpty)
        try recovery.save(targetBuild: "1020", downloads: records, now: now)
        #expect(try recovery.consume(currentBuild: 1020, now: now.addingTimeInterval(25 * 3600)).isEmpty)
        storage.set(Data("broken".utf8), forKey: UpdateRestartRecovery.key)
        #expect(throws: (any Error).self) { try recovery.consume(currentBuild: 1020, now: now) }
        #expect(storage.data(forKey: UpdateRestartRecovery.key) == nil)
    }

    @Test("侧栏更新按钮浅深色渲染", .enabled(if: ProcessInfo.processInfo.environment["COOLDM_UPDATE_UI_SNAPSHOT"] == "1"))
    func sidebarSnapshots() throws {
        let controller = AppUpdateController()
        let release = UpdateRelease(build: "1020", version: "1.0.20")
        for scheme in [ColorScheme.light, .dark] {
            controller.readyToInstall(release, handler: {})
            let view = SidebarUpdateButton(controller: controller)
                .frame(width: 210, height: 64)
                .environment(\.colorScheme, scheme)
                .background(scheme == .light ? Color(white: 0.94) : Color(white: 0.16))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            let name = scheme == .light ? "light" : "dark"
            let path = URL(fileURLWithPath: "/tmp/cooldm-update-sidebar-\(name).png")
            try png.write(to: path)
            print("Update sidebar snapshot: \(path.path)")
        }
    }

    private func record(id: Int64) -> DownloadRecord {
        DownloadRecord(id: id, source: .init(kind: .http, link: "https://example.test/file"), folder: "/tmp", name: "test-\(id)")
    }

    @Test("真实 GitHub 清单能通过生产路由器的签名验证", .enabled(if: ProcessInfo.processInfo.environment["COOLDM_LIVE_UPDATE_PROBE"] == "1"))
    func publishedSignedFeed() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/macos/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let keyText = try #require(info["SUPublicEDKey"] as? String)
        let key = try #require(Data(base64Encoded: keyText))
        let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        let selection = try await GitHubUpdateRouter(defaults: defaults()).refresh(feedURL: feedURL, publicKey: key, currentBuild: build)
        #expect(selection.latestBuild > 0)
        #expect(selection.feedRoutes.count == 4)
        print("Verified published feed build: \(selection.latestBuild); feed route order: \(selection.feedRoutes.map(\.id).joined(separator: ", "))")
    }
}

private actor ProbeRecorder {
    let feeds: [String: Data]
    private var feedCount = 0
    private var archiveCount = 0
    private var active = 0
    private var maximumConcurrent = 0
    private var limits: [Int] = []

    init(feeds: [String: Data]) { self.feeds = feeds }

    func respond(_ request: URLRequest, limit: Int) async throws -> UpdateProbeResponse {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        limits.append(limit)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        if request.value(forHTTPHeaderField: "Range") != nil {
            archiveCount += 1
            var bytes = Data([0x50, 0x4B, 0x03, 0x04])
            bytes.append(Data(repeating: 0, count: limit - 4))
            return .init(data: bytes, status: 206, contentRange: "bytes 0-\(limit - 1)/524288")
        }
        feedCount += 1
        guard let data = feeds[request.url?.host ?? ""] else { throw URLError(.timedOut) }
        return .init(data: data, status: 200, contentRange: nil)
    }

    func counts() -> (feed: Int, archive: Int, maximumConcurrent: Int, limits: [Int]) {
        (feedCount, archiveCount, maximumConcurrent, limits)
    }
}

private final class ProbeByteMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ bytes: Int, for id: String) {
        lock.withLock { counts[id, default: 0] += bytes }
    }
    func bytes(for id: String) -> Int { lock.withLock { counts[id, default: 0] } }
}

private final class BoundedProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static let totalBytes = 3 * 1024 * 1024
    static let metrics = ProbeByteMetrics()
    private let lock = NSLock()
    private var stopped = false
    private var sent = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "update-probe.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        sendNextChunk()
    }
    override func stopLoading() { lock.withLock { stopped = true } }

    private func sendNextChunk() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            let size = 2048
            self.sent += size
            Self.metrics.add(size, for: self.request.url?.lastPathComponent ?? "")
            self.client?.urlProtocol(self, didLoad: Data(repeating: 42, count: size))
            if self.sent >= Self.totalBytes {
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.sendNextChunk()
            }
        }
    }
}
