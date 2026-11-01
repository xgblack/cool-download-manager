import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadIntegration

@Suite("上游 1.11.2 HTTP 鉴权")
struct Upstream112AuthenticationTests {
    @Test("显式匿名模式只放行普通确认操作，所有静默操作仍要求有效密钥")
    func anonymousModeProtectsQuietCommands() async throws {
        let handler = Upstream112RecordingHandler()
        let router = IntegrationRouter(
            handler: handler, apiKey: "secret", allowAnonymous: true, requireAuthentication: false
        )
        #expect(router.canStartHTTP)
        #expect(await router.handle(HTTPRequest(method: "POST", path: "/ping")).statusCode == 200)
        #expect(await router.handle(HTTPRequest(method: "GET", path: "/queues")).statusCode == 200)
        let interactive = AddDownloadsRequest(items: [.init(link: "https://example.test/file.bin")])
        #expect(await router.handle(HTTPRequest(
            method: "POST", path: "/add", body: try JSONEncoder().encode(interactive)
        )).statusCode == 200)

        let commands = try quietCommands()
        for command in commands {
            for headers in [[:], ["X-Api-Key": ""], ["X-Api-Key": "wrong"]] {
                var command = command
                command.headers = headers
                #expect(await router.handle(command).statusCode == 401)
            }
        }
        #expect(await handler.additions == [interactive])
        #expect(await handler.headlessCount == 0)
        #expect(await handler.patchCount == 0)

        for command in commands {
            var command = command
            command.headers = ["x-api-key": "secret"]
            #expect(await router.handle(command).statusCode == 200)
        }
        #expect(await handler.additions.count == 4)
        #expect(await handler.headlessCount == 1)
        #expect(await handler.patchCount == 1)
    }

    @Test("匿名且没有可用密钥时普通操作可用，静默操作不可用", arguments: [nil, "", " \n "] as [String?])
    func anonymousWithoutKey(key: String?) async throws {
        let handler = Upstream112RecordingHandler()
        let router = IntegrationRouter(
            handler: handler, apiKey: key, allowAnonymous: true, requireAuthentication: false
        )
        #expect(router.canStartHTTP)
        #expect(await router.handle(HTTPRequest(method: "POST", path: "/ping")).statusCode == 200)
        for command in try quietCommands() {
            var command = command
            command.headers = ["X-Api-Key": key ?? "secret"]
            #expect(await router.handle(command).statusCode == 401)
        }
        #expect(await handler.additions.isEmpty)
        #expect(await handler.headlessCount == 0)
        #expect(await handler.patchCount == 0)
    }

    @Test("普通认证开启时不能被匿名开关绕过，空密钥阻止启动")
    func requiredAuthenticationOverridesAnonymousFlag() async throws {
        let router = IntegrationRouter(
            handler: Upstream112RecordingHandler(), apiKey: "secret", allowAnonymous: true,
            requireAuthentication: true
        )
        #expect(await router.handle(HTTPRequest(method: "GET", path: "/queues")).statusCode == 401)
        #expect(await router.handle(HTTPRequest(
            method: "GET", path: "/queues", headers: ["X-Api-Key": "secret"]
        )).statusCode == 200)
        let unconfigured = IntegrationRouter(
            handler: Upstream112RecordingHandler(), apiKey: " ", allowAnonymous: true,
            requireAuthentication: true
        )
        #expect(!unconfigured.canStartHTTP)
        #expect(throws: (any Error).self) { _ = try LoopbackHTTPServer(router: unconfigured) }
    }

    @Test("匿名静默请求在读取受保护请求体前被拒绝，合法密钥仍受来源限制")
    func authenticationPrecedesProtectedPayloadAndKeepsOriginChecks() async {
        let handler = Upstream112RecordingHandler()
        let router = IntegrationRouter(
            handler: handler, apiKey: "secret", allowAnonymous: true, requireAuthentication: false
        )
        for (method, path) in [("POST", "/start-headless-download"), ("PATCH", "/downloads/1/source")] {
            #expect(await router.handle(HTTPRequest(
                method: method, path: path, body: Data("invalid-json".utf8)
            )).statusCode == 401)
            #expect(await router.handle(HTTPRequest(
                method: method, path: path,
                headers: ["X-Api-Key": "secret", "Origin": "https://attacker.test"],
                body: Data("invalid-json".utf8)
            )).statusCode == 403)
        }
        #expect(await handler.headlessCount == 0)
        #expect(await handler.patchCount == 0)
    }

    private func quietCommands() throws -> [HTTPRequest] {
        let source = IntegrationDownloadCredential(link: "https://example.test/file.bin")
        var commands = try [
            AddDownloadOptions(silentAdd: true),
            AddDownloadOptions(silentStart: true),
            AddDownloadOptions(silentAdd: true, silentStart: true)
        ].map { options in
            HTTPRequest(
                method: "POST", path: "/add",
                body: try JSONEncoder().encode(AddDownloadsRequest(items: [source], options: options))
            )
        }
        commands.append(HTTPRequest(
            method: "POST", path: "/start-headless-download",
            body: try JSONEncoder().encode(HeadlessDownloadRequest(downloadSource: source))
        ))
        commands.append(HTTPRequest(
            method: "PATCH", path: "/downloads/1/source",
            body: try JSONEncoder().encode(DownloadSourcePatch(link: source.link))
        ))
        return commands
    }
}

@Suite("二维码下载来源格式")
struct DownloadSourceShareCodecTests {
    @Test("中文及任务请求凭据在 HTTP/HLS 单个对象与数组中完整往返")
    func completeSourcesRoundTrip() throws {
        let http = DownloadSource(
            kind: .http, link: "https://example.test/软件.zip?signature=fixture",
            headers: ["Authorization": "Bearer fixture", "Cookie": "session=测试", "User-Agent": "测试客户端"],
            downloadPage: "https://example.test/下载", suggestedName: "软件 测试.zip"
        )
        let hls = DownloadSource(
            kind: .hls, link: "https://example.test/播放.m3u8", headers: ["Referer": "https://example.test/视频"]
        )
        let single = try DownloadSourceShareCodec.encode([http])
        #expect(single.first == "{")
        #expect(try DownloadSourceShareCodec.decode(single) == [try DownloadSourceSecurity.validatedForPersistence(http)])
        let multiple = try DownloadSourceShareCodec.encode([http, hls])
        #expect(multiple.first == "[")
        #expect(try DownloadSourceShareCodec.decode(multiple) == [try DownloadSourceSecurity.validatedForPersistence(http), hls])
        let object = try #require(JSONSerialization.jsonObject(with: Data(single.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "http")
        #expect(object["credentialReference"] == nil)
        #expect(object["username"] == nil)
        #expect(object["password"] == nil)
    }

    @Test("上游独立 userAgent 和账号字段可导入，显式请求头优先")
    func upstreamCredentialsImport() throws {
        let sources = try DownloadSourceShareCodec.decode(#"[{"type":"hls","link":"https://example.test/playlist","userAgent":"手机客户端","username":"用户","password":"密码","downloadPage":"https://example.test/watch"},{"type":"http","link":"https://example.test/file","headers":{"user-agent":"Explicit","authorization":"Bearer explicit"},"userAgent":"Ignored","username":"ignored","password":"ignored"}]"#)
        #expect(sources.count == 2)
        #expect(sources[0].kind == .hls)
        #expect(sources[0].headers?["User-Agent"] == "手机客户端")
        #expect(sources[0].headers?["Authorization"] == "Basic \(Data("用户:密码".utf8).base64EncodedString())")
        #expect(sources[1].headers == ["user-agent": "Explicit", "authorization": "Bearer explicit"])
        let withoutPassword = try DownloadSourceShareCodec.decode(#"{"link":"https://example.test/file","username":"reader"}"#)
        #expect(withoutPassword[0].headers?["Authorization"] == "Basic \(Data("reader:".utf8).base64EncodedString())")
    }

    @Test("多行普通链接忽略空行并从路径推断 HLS，兼容未指定类型的上游对象")
    func plainLinksAndMissingType() throws {
        let sources = try DownloadSourceShareCodec.decode("\nhttps://example.test/a.zip\n  \n https://example.test/PLAY.M3U8?key=fixture \n")
        #expect(sources.map(\.kind) == [.http, .hls])
        #expect(sources.map(\.link) == ["https://example.test/a.zip", "https://example.test/PLAY.M3U8?key=fixture"])
        let object = try DownloadSourceShareCodec.decode(#"{"link":"https://example.test/play.m3u8","description":"ignored"}"#)
        #expect(object[0].kind == .hls)
    }

    @Test("无效来源整体拒绝且错误文案不包含输入凭据")
    func invalidSourcesAreRejectedWithoutSecrets() throws {
        let invalid = [
            #"{"link":"file:///private/credential-secret"}"#,
            #"[{"link":"https://example.test/ok"},{"link":"javascript:credential-secret"}]"#,
            #"{"link":"https://example.test/file","headers":{"Authorization":"credential-secret\r\nInjected: value"}}"#,
            #"{"link":"https://example.test/file","downloadPage":"file:///credential-secret"}"#,
            #"{"link":"https://example.test/file","headers":{"Authorization":"one","authorization":"credential-secret"}}"#
        ]
        for text in invalid {
            do {
                _ = try DownloadSourceShareCodec.decode(text)
                Issue.record("无效来源被接受")
            } catch {
                #expect(error as? DownloadSourceShareError == .invalidSource)
                #expect(!error.localizedDescription.contains("credential-secret"))
            }
        }
        #expect(throws: DownloadSourceShareError.unsupportedType) {
            _ = try DownloadSourceShareCodec.decode(#"{"type":"ftp","link":"https://example.test/file"}"#)
        }
        #expect(throws: DownloadSourceShareError.invalidFormat) {
            _ = try DownloadSourceShareCodec.decode(#"{"link":"credential-secret""#)
        }
        #expect(throws: DownloadSourceShareError.empty) { _ = try DownloadSourceShareCodec.decode("[]") }
        #expect(throws: DownloadSourceShareError.empty) { _ = try DownloadSourceShareCodec.encode([]) }
    }

    @Test("过大内容与未迁移的旧凭据标记明确拒绝")
    func oversizedAndUnavailableCredentials() throws {
        #expect(throws: DownloadSourceShareError.tooLarge) {
            _ = try DownloadSourceShareCodec.decode(String(repeating: "x", count: LoopbackHTTPServer.maximumRequestBytes + 1))
        }
        #expect(throws: DownloadSourceShareError.tooLarge) {
            _ = try DownloadSourceShareCodec.encode([DownloadSource(
                kind: .http, link: "https://example.test/file",
                suggestedName: String(repeating: "x", count: LoopbackHTTPServer.maximumRequestBytes)
            )])
        }
        #expect(throws: DownloadSourceShareError.credentialsUnavailable) {
            _ = try DownloadSourceShareCodec.encode([DownloadSource(
                kind: .http, link: "https://example.test/file", credentialReference: "legacy-fixture"
            )])
        }
    }
}

private actor Upstream112RecordingHandler: DownloadIntegrationHandler {
    var additions: [AddDownloadsRequest] = []
    var headlessCount = 0
    var patchCount = 0

    func addFromBrowser(_ request: AddDownloadsRequest) { additions.append(request) }
    func listQueues() -> [IntegrationQueue] { [.init(id: 1, name: "默认队列")] }
    func addHeadless(_ request: HeadlessDownloadRequest) -> DownloadID {
        headlessCount += 1
        return 1
    }
    func patchSource(id: DownloadID, patch: DownloadSourcePatch) -> DownloadSourcePatchResult {
        patchCount += 1
        return .init(id: id, status: .paused, continued: false)
    }
}
