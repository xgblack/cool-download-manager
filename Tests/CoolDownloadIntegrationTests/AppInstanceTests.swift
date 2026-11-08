import Foundation
import Darwin
import Testing
@testable import CoolDownloadIntegration

@Suite("应用启动与单实例")
struct AppInstanceTests {
    @Test("浏览器探活无需主应用，也不会尝试拉起")
    func pingDoesNotLaunch() throws {
        let root = SocketTestRoot()
        let calls = StartupCalls()
        let reply = try NativeMessagingRelay(socketURL: root.socket).handle(.init(
            id: "probe", content: .init(action: "ping", payload: "{}")
        )) { calls.launched() }
        #expect(reply.id == "probe")
        #expect(reply.content.payload == "true")
        #expect(!reply.content.isError)
        #expect(calls.launches == 0)
        #expect(!FileManager.default.fileExists(atPath: root.socket.path))
    }

    @Test("取得锁后立即提供控制服务，第二实例被拒绝，退出后可重启")
    func exclusiveApplicationLifetime() async throws {
        let root = SocketTestRoot()
        var instance: AppInstanceController? = try AppInstanceController(socketURL: root.socket)
        defer { instance?.stop() }
        #expect(throws: AppInstanceError.self) { _ = try AppInstanceController(socketURL: root.socket) }
        instance?.stop()
        // Stopping the listener must not release ownership before shutdown ends.
        #expect(throws: AppInstanceError.self) { _ = try AppInstanceController(socketURL: root.socket) }
        instance = nil
        let replacement = try AppInstanceController(socketURL: root.socket)
        defer { replacement.stop() }
        let reply = try await socketWorker {
            try PrivateSocketClient(socketURL: root.socket).send(.init(requestId: "status", action: "status"))
        }
        let status = try JSONDecoder().decode(AppInstanceStatus.self, from: Data(reply.payload.utf8))
        #expect(status.state == .starting)
    }

    @Test("已经启动但未就绪时有界等待，不重复拉起；失败状态立即返回")
    func waitsForExistingStartup() async throws {
        let root = SocketTestRoot()
        let instance = try AppInstanceController(socketURL: root.socket)
        defer { instance.stop() }
        let calls = StartupCalls()
        do {
            try await socketWorker {
                try AppInstanceClient(socketURL: root.socket).waitUntilReady(timeout: 0.15) { calls.launched() }
            }
            Issue.record("尚未就绪不应报告成功")
        } catch AppInstanceError.timedOut {}
        #expect(calls.launches == 0)
        instance.setFailed("测试启动失败")
        do {
            try await socketWorker { try AppInstanceClient(socketURL: root.socket).waitUntilReady() }
            Issue.record("启动失败不应报告就绪")
        } catch AppInstanceError.startupFailed(let message) { #expect(message == "测试启动失败") }
    }

    @Test("冷启动添加只拉起一次，随后只发送一次下载请求")
    func coldLaunchAndForwardOnce() async throws {
        let root = SocketTestRoot()
        let calls = StartupCalls()
        let reply = try await socketWorker {
            try NativeMessagingRelay(socketURL: root.socket).handle(Self.request("cold")) {
                calls.launched()
                let instance = try AppInstanceController(socketURL: root.socket)
                calls.keep(instance)
                instance.setReady { _ in calls.added() }
            }
        }
        defer { calls.stop() }
        #expect(!reply.content.isError)
        #expect(reply.content.payload == "true")
        #expect(calls.launches == 1)
        #expect(calls.adds == 1)
    }

    @Test("并发浏览器请求复用已运行实例，停止后拒绝新增下载")
    func concurrentForwarding() async throws {
        let root = SocketTestRoot()
        let instance = try AppInstanceController(socketURL: root.socket)
        defer { instance.stop() }
        let calls = StartupCalls()
        instance.setReady { _ in calls.added() }
        try await withThrowingTaskGroup(of: NativeMessagingMessage.self) { group in
            for index in 0..<6 {
                group.addTask {
                    try await socketWorker {
                        try NativeMessagingRelay(socketURL: root.socket).handle(Self.request("parallel-\(index)")) {
                            calls.launched()
                        }
                    }
                }
            }
            for try await reply in group { #expect(!reply.content.isError) }
        }
        #expect(calls.launches == 0)
        #expect(calls.adds == 6)
        instance.beginStopping()
        let stopped = try await socketWorker {
            try NativeMessagingRelay(socketURL: root.socket).handle(Self.request("stopped")) { calls.launched() }
        }
        #expect(stopped.content.isError)
        #expect(calls.adds == 6)
        #expect(calls.launches == 0)
    }

    @Test("窗口入口未注册前的唤起会在注册后执行")
    func reopenBeforeWindowRegistration() async throws {
        let root = SocketTestRoot()
        let instance = try AppInstanceController(socketURL: root.socket)
        defer { instance.stop() }
        try await socketWorker { try AppInstanceClient(socketURL: root.socket).showMainWindow() }
        let (events, continuation) = AsyncStream<Void>.makeStream()
        instance.configureShowMain { continuation.yield(); continuation.finish() }
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in events { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(received)
    }

    @Test("下载处理失败不会重发请求或再次启动应用")
    func failedAddIsNotReplayed() async throws {
        let root = SocketTestRoot()
        let instance = try AppInstanceController(socketURL: root.socket)
        defer { instance.stop() }
        let calls = StartupCalls()
        instance.setReady { _ in calls.added(); throw AppInstanceError.unavailable("测试失败") }
        let reply = try await socketWorker {
            try NativeMessagingRelay(socketURL: root.socket).handle(Self.request("failed")) { calls.launched() }
        }
        #expect(reply.content.isError)
        #expect(calls.adds == 1)
        #expect(calls.launches == 0)
    }

    @Test("下载已接收但响应连接中断时也不重发写请求")
    func lostAddResponseIsNotReplayed() async throws {
        let root = SocketTestRoot()
        let instance = try AppInstanceController(socketURL: root.socket)
        defer { instance.stop() }
        let calls = StartupCalls()
        instance.setReady { [weak instance] _ in
            calls.added()
            instance?.stop()
        }
        let reply = try await socketWorker {
            try NativeMessagingRelay(socketURL: root.socket).handle(Self.request("lost-reply")) { calls.launched() }
        }
        #expect(reply.content.isError)
        #expect(calls.adds == 1)
        #expect(calls.launches == 0)
    }

    private static func request(_ id: String) -> NativeMessagingMessage {
        .init(id: id, content: .init(action: "add", payload: "{\"items\":[],\"options\":{\"silentAdd\":true}}"))
    }
}

private final class StartupCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var launchCount = 0
    private var addCount = 0
    private var instance: AppInstanceController?
    var launches: Int { lock.withLock { launchCount } }
    var adds: Int { lock.withLock { addCount } }
    func launched() { lock.withLock { launchCount += 1 } }
    func added() { lock.withLock { addCount += 1 } }
    func keep(_ instance: AppInstanceController) { lock.withLock { self.instance = instance } }
    func stop() { lock.withLock { instance?.stop(); instance = nil } }
}

private final class SocketTestRoot: @unchecked Sendable {
    private let root = URL(fileURLWithPath: "/tmp/cdm-start-\(UUID().uuidString)")
    var socket: URL { root.appendingPathComponent("s.sock") }
    deinit {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        catch { fputs("测试临时目录保留：\(root.path)；\(error.localizedDescription)\n", stderr) }
    }
}

private func socketWorker<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result(catching: action)) }
    }
}
