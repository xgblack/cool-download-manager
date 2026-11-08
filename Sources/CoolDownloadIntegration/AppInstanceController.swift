import Foundation
import Darwin

public enum AppInstanceState: String, Codable, Sendable {
    case starting, ready, failed, stopping
}

public struct AppInstanceStatus: Codable, Sendable {
    public var state: AppInstanceState
    public var message: String?

    public init(state: AppInstanceState, message: String? = nil) {
        self.state = state
        self.message = message
    }
}

public enum AppInstanceError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case unavailable(String)
    case startupFailed(String)
    case stopping
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "下载管理器已经运行"
        case .unavailable(let message): "无法连接下载管理器：\(message)"
        case .startupFailed(let message): "下载管理器启动失败：\(message)"
        case .stopping: "下载管理器正在退出，请稍后重试"
        case .timedOut: "等待下载管理器启动超时，请打开应用查看状态后重试"
        }
    }
}

/// Owns the application lifetime, not a window or a settings revision. The
/// descriptor remains locked until this object is released after shutdown.
public final class AppInstanceController: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var status = AppInstanceStatus(state: .starting)
    private var server: PrivateSocketServer?
    private var showMain: (@Sendable () async -> Void)?
    private var pendingShowMain = false
    private var addDownload: (@Sendable (AddDownloadsRequest) async throws -> Void)?

    public init(socketURL: URL) throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("app-instance.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PrivateSocketClientError.system(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            _ = Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw AppInstanceError.alreadyRunning }
            throw PrivateSocketClientError.system(code)
        }
        descriptor = fd
        let server = PrivateSocketServer(socketURL: socketURL) { [weak self] message in
            guard let self else {
                return Self.failure(message, type: "stopping", description: AppInstanceError.stopping.localizedDescription)
            }
            return await self.handle(message)
        }
        self.server = server
        do { try server.start() }
        catch {
            self.server = nil
            // The initialized object's deinit releases the descriptor.
            throw error
        }
    }

    deinit {
        server?.stop()
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        // Leave the file in place: unlinking a lock permits another inode to
        // be locked while an existing opener still holds the previous inode.
    }

    public func configureShowMain(_ action: @escaping @Sendable () async -> Void) {
        let pending = lock.withLock {
            showMain = action
            let pending = pendingShowMain
            pendingShowMain = false
            return pending
        }
        if pending { Task { await action() } }
    }

    public func setReady(addDownload: @escaping @Sendable (AddDownloadsRequest) async throws -> Void) {
        lock.withLock {
            guard status.state == .starting else { return }
            self.addDownload = addDownload
            status = AppInstanceStatus(state: .ready)
        }
    }

    public func setFailed(_ message: String) {
        lock.withLock {
            guard status.state != .stopping else { return }
            addDownload = nil
            status = AppInstanceStatus(state: .failed, message: message)
        }
    }

    public func beginStopping() {
        lock.withLock {
            status = AppInstanceStatus(state: .stopping)
            addDownload = nil
        }
    }

    public func stop() {
        beginStopping()
        server?.stop()
    }

    private func handle(_ message: PrivateSocketMessage) async -> PrivateSocketMessage {
        if message.action == "status" {
            let current = lock.withLock { status }
            do {
                let data = try JSONEncoder().encode(current)
                return .init(requestId: message.requestId, action: message.action,
                             payload: String(decoding: data, as: UTF8.self))
            } catch {
                return Self.failure(message, type: "status_failed", description: error.localizedDescription)
            }
        }
        if message.action == "show-main" {
            let result = lock.withLock { () -> (Bool, (@Sendable () async -> Void)?) in
                guard status.state != .stopping else { return (false, nil) }
                if showMain == nil { pendingShowMain = true }
                return (true, showMain)
            }
            guard result.0 else {
                return Self.failure(message, type: "stopping", description: AppInstanceError.stopping.localizedDescription)
            }
            if let action = result.1 { await action() }
            return .init(requestId: message.requestId, action: message.action, payload: "true")
        }
        let (current, handler) = lock.withLock { (status, addDownload) }
        guard message.action == "add" || message.action == "ping" else {
            return Self.failure(message, type: "unsupported_action", description: "不支持的操作")
        }
        guard current.state == .ready else {
            return Self.failure(message, type: current.state.rawValue,
                                description: current.message ?? (current.state == .stopping ? "应用正在退出" : "应用尚未就绪"))
        }
        if message.action == "ping" {
            return .init(requestId: message.requestId, action: message.action, payload: "true")
        }
        do {
            guard let handler else { throw AppInstanceError.unavailable("下载处理器尚未就绪") }
            let request = try JSONDecoder().decode(AddDownloadsRequest.self, from: Data(message.payload.utf8))
            try await handler(request)
            return .init(requestId: message.requestId, action: message.action, payload: "true")
        } catch {
            return Self.failure(message, type: String(describing: type(of: error)), description: error.localizedDescription)
        }
    }

    private static func failure(_ request: PrivateSocketMessage, type: String, description: String) -> PrivateSocketMessage {
        // This synthesized payload contains only strings and cannot fail to encode.
        let data = try! JSONEncoder().encode(NativeMessagingErrorPayload(errorType: type, message: description))
        return .init(requestId: request.requestId, action: request.action,
                     payload: String(decoding: data, as: UTF8.self), isError: true)
    }
}
