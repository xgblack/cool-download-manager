import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadIntegration

@Suite("Legacy AB browser handoff")
struct LegacyBrowserRedirectTests {
    @Test("entry and final URL create one completed file in either order", arguments: [false, true])
    func redirects(finalFirst: Bool) async throws {
        let fixture = try await Fixture()
        let handler = CoreDownloadIntegrationHandler(service: fixture.service)
        let router = IntegrationRouter(handler: handler, apiKey: "test-key")
        let entry = fixture.request("entry")
        let final = fixture.request("file.zip?version=1")
        let first = finalFirst ? final : entry
        let second = finalFirst ? entry : final
        let response = await router.handle(try fixture.http(first))
        #expect(response.statusCode == 200)
        try await handler.addFromBrowser(second)
        try await fixture.wait {
            let isDrained = try await fixture.service.pendingBrowserDownloads().isEmpty
            let isCompleted = await fixture.service.snapshot().downloads.first?.status == .completed
            return isDrained && isCompleted
        }
        let records = await fixture.service.snapshot().downloads
        try #require(records.count == 1)
        #expect(records[0].source.link == fixture.link("file.zip?version=1"))
        #expect(records[0].source.browserEntryLink == fixture.link("entry"))
        #expect(try Data(contentsOf: records[0].destinationURL) == FixtureTransport.contents)
        await handler.stopBrowserDownloads()
        await fixture.service.shutdown()
    }

    @Test("slow accepted /add remains recoverable before any visible task exists")
    func recovery() async throws {
        let fixture = try await Fixture(delay: .seconds(1))
        let handler = CoreDownloadIntegrationHandler(service: fixture.service)
        let router = IntegrationRouter(handler: handler, apiKey: "test-key")
        let clock = ContinuousClock()
        let now = clock.now
        #expect(await router.handle(try fixture.http(fixture.request("entry"))).statusCode == 200)
        #expect(now.duration(to: clock.now) < .milliseconds(500))
        #expect(await fixture.service.snapshot().downloads.isEmpty)
        let staged = try #require(try await fixture.service.pendingBrowserDownloads().first)
        await handler.stopBrowserDownloads()
        await fixture.service.shutdown()

        let reopened = DownloadService(store: try DownloadStore(rootURL: fixture.root),
                                      downloader: HTTPDownloader(transport: FixtureTransport()),
                                      defaultFolder: fixture.root)
        try await reopened.boot()
        #expect(await reopened.snapshot().downloads.isEmpty)
        let recovering = CoreDownloadIntegrationHandler(service: reopened)
        try await recovering.restoreBrowserDownloads()
        try await fixture.wait {
            await reopened.snapshot().downloads.first?.status == .completed
        }
        #expect(await reopened.snapshot().downloads.map(\.id) == [staged.id])
        #expect(try await reopened.pendingBrowserDownloads().isEmpty)
        await recovering.stopBrowserDownloads()
        await reopened.shutdown()
    }

    @Test("queries and conflicting final credentials do not merge; an HTML page does not create a download")
    func boundaries() async throws {
        let fixture = try await Fixture()
        let errors = Requests<String>()
        let handler = CoreDownloadIntegrationHandler(service: fixture.service, browserErrorHandler: { await errors.record($0) })
        for request in [fixture.request("entry"), fixture.request("file.zip?version=2"),
                        fixture.request("file.zip?version=1", headers: ["Cookie": "account=two"]),
                        fixture.request("login"), fixture.request("report.html")] {
            try await handler.addFromBrowser(request)
        }
        try await fixture.wait {
            await fixture.service.snapshot().downloads.filter { $0.status == .completed }.count == 4
        }
        let records = await fixture.service.snapshot().downloads
        #expect(records.count == 4)
        #expect(Set(records.map(\.source.link)) == Set(["file.zip?version=1", "file.zip?version=2", "report.html"].map(fixture.link)))
        #expect(await errors.values == ["浏览器下载地址返回的是网页，不是文件。请在浏览器中完成登录或确认后重试。"])
        await handler.stopBrowserDownloads()
        await fixture.service.shutdown()
    }

    @Test("both browser URLs in one confirmation request produce only one file row")
    func confirmation() async throws {
        let fixture = try await Fixture()
        let dialogs = Requests<AddDownloadsRequest>()
        let handler = CoreDownloadIntegrationHandler(service: fixture.service,
            interactiveAddHandler: { await dialogs.record($0) })
        let entries = [fixture.request("entry"), fixture.request("file.zip?version=1")].flatMap(\.items)
        try await handler.addFromBrowser(.init(items: entries))
        try await fixture.wait { await dialogs.values.count == 1 }
        #expect(await dialogs.values.first?.items.map(\.link) == [fixture.link("file.zip?version=1")])
        #expect(await fixture.service.snapshot().downloads.isEmpty)
        await handler.stopBrowserDownloads()
        await fixture.service.shutdown()
    }

    private actor Requests<T: Sendable> {
        var values: [T] = []
        func record(_ value: T) { values.append(value) }
    }

    private struct Fixture {
        let root: URL
        let service: DownloadService

        init(delay: Duration = .zero) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-browser-\(UUID())")
            service = DownloadService(store: try DownloadStore(rootURL: root),
                                      downloader: HTTPDownloader(transport: FixtureTransport(delay: delay)),
                                      defaultFolder: root)
            try await service.boot()
        }

        func link(_ path: String) -> String {
            "https://\(path == "entry" ? "entry" : "cdn").fixture.invalid/\(path)"
        }

        func request(_ path: String, headers: [String: String]? = nil) -> AddDownloadsRequest {
            .init(items: [.init(link: link(path), headers: headers)],
                  options: .init(silentAdd: true, silentStart: true))
        }

        func http(_ request: AddDownloadsRequest) throws -> HTTPRequest {
            .init(method: "POST", path: "/add", headers: ["X-Api-Key": "test-key"],
                  body: try JSONEncoder().encode(request))
        }

        func wait(_ ready: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if try await ready() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw URLError(.timedOut)
        }
    }

    private struct FixtureTransport: HTTPTransport {
        static let contents = Data("fixture payload".utf8)
        var delay: Duration = .zero

        func response(for request: URLRequest) async throws -> HTTPTransportResponse {
            if delay != .zero { try await Task.sleep(for: delay) }
            var final = request
            if request.url?.path == "/entry" {
                final.url = URL(string: "https://cdn.fixture.invalid/file.zip?version=1")
            }
            let path = final.url?.path
            let html = path == "/login" || path == "/report.html"
            var headers = ["Content-Length": "\(Self.contents.count)",
                           "Content-Type": html ? "text/html" : "application/zip",
                           "ETag": "\"fixture\""]
            if path != "/login" {
                headers["Content-Disposition"] = "attachment; filename=\"\(html ? "report.html" : "same.zip")\""
            }
            return HTTPTransportResponse(statusCode: 200, headers: headers, body: AsyncThrowingStream { stream in
                stream.yield(Self.contents)
                stream.finish()
            }, effectiveRequest: final)
        }
    }
}
