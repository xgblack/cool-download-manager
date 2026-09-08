import Foundation
import Darwin

public final class PrivateSocketServer: @unchecked Sendable {
    public let socketURL: URL

    private let handler: @Sendable (PrivateSocketMessage) async -> PrivateSocketMessage
    private let acceptQueue = DispatchQueue(label: "com.cooldownloadmanager.integration.socket.accept")
    private let workerQueue = DispatchQueue(label: "com.cooldownloadmanager.integration.socket.worker", attributes: .concurrent)
    private var listener: Int32 = -1
    private let stateLock = NSLock()
    private var stopped = false
    private var clients: [Int32: UUID] = [:]
    private var cancelledClients: Set<Int32> = []
    private var tasks: [Int32: Task<Void, Never>] = [:]
    private var deadlines: [Int32: DispatchWorkItem] = [:]
    private var socketIdentity: (dev_t, ino_t)?

    public init(
        socketURL: URL,
        handler: @escaping @Sendable (PrivateSocketMessage) async -> PrivateSocketMessage
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if listener >= 0 && !stopped {
            throw PrivateSocketServerError.alreadyRunning(socketURL)
        }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(socketURL.deletingLastPathComponent().path, 0o700) == 0 else {
            throw PrivateSocketClientError.system(errno)
        }
        if FileManager.default.fileExists(atPath: socketURL.path) {
            var socketStat = stat()
            guard lstat(socketURL.path, &socketStat) == 0 else {
                throw PrivateSocketClientError.system(errno)
            }
            let isSocket = (socketStat.st_mode & S_IFMT) == S_IFSOCK
            guard isSocket else {
                throw PrivateSocketServerError.pathOccupied(socketURL)
            }
            do {
                _ = try PrivateSocketClient(socketURL: socketURL).send(
                    PrivateSocketMessage(requestId: UUID().uuidString, action: "ping")
                )
                throw PrivateSocketServerError.alreadyRunning(socketURL)
            } catch let error as PrivateSocketServerError {
                throw error
            } catch let error as PrivateSocketClientError {
                switch error {
                case .system(ECONNREFUSED), .system(ENOENT):
                    // A refused connection is the only probe failure that
                    // proves a filesystem socket has no accepting listener.
                    _ = Darwin.unlink(socketURL.path)
                default:
                    throw PrivateSocketServerError.probeFailed(
                        socketURL,
                        error.localizedDescription
                    )
                }
            }
        }

        var address = try makeAddress()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PrivateSocketClientError.system(errno) }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + socketURL.path.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw PrivateSocketClientError.system(error)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(socketURL.path)
            throw PrivateSocketClientError.system(error)
        }
        var identity = stat()
        guard lstat(socketURL.path, &identity) == 0,
              Darwin.chmod(socketURL.path, 0o600) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw PrivateSocketClientError.system(error)
        }
        socketIdentity = (identity.st_dev, identity.st_ino)
        listener = descriptor
        stopped = false
        acceptQueue.async { [self] in acceptLoop(descriptor) }
    }

    public enum PrivateSocketServerError: Error, LocalizedError, Sendable, Equatable {
        case alreadyRunning(URL)
        case pathOccupied(URL)
        case probeFailed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning(let url): return "私有套接字已被占用：\(url.path)"
            case .pathOccupied(let url): return "私有套接字路径已被非套接字文件占用：\(url.path)"
            case .probeFailed(let url, let reason):
                return "无法验证私有套接字 \(url.path)：\(reason)"
            }
        }
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopped = true
        let descriptor = listener
        listener = -1
        // acceptLoop owns close; shutdown wakes accept without allowing FD reuse underneath it.
        if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        for client in clients.keys {
            cancelledClients.insert(client)
            _ = Darwin.shutdown(client, SHUT_RDWR)
        }
        for task in tasks.values { task.cancel() }
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        if let identity = socketIdentity {
            var current = stat()
            if lstat(socketURL.path, &current) == 0,
               current.st_dev == identity.0, current.st_ino == identity.1 {
                _ = Darwin.unlink(socketURL.path)
            }
            socketIdentity = nil
        }
    }

    private func acceptLoop(_ descriptor: Int32) {
        defer { _ = Darwin.close(descriptor) }
        while true {
            guard stateLock.withLock({ !stopped && listener == descriptor }) else { return }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            var noSignal: Int32 = 1
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(),
                  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                _ = Darwin.close(client)
                continue
            }
            configureTimeouts(for: client)
            stateLock.lock()
            guard !stopped, listener == descriptor, clients.count < 32 else {
                stateLock.unlock()
                _ = Darwin.close(client)
                continue
            }
            let identity = UUID()
            clients[client] = identity
            let deadline = DispatchWorkItem { [weak self] in
                self?.stateLock.withLock {
                    guard let self, self.clients[client] == identity else { return }
                    self.cancelledClients.insert(client)
                    self.tasks[client]?.cancel()
                    _ = Darwin.shutdown(client, SHUT_RDWR)
                }
            }
            deadlines[client] = deadline
            stateLock.unlock()
            workerQueue.asyncAfter(deadline: .now() + 10, execute: deadline)
            workerQueue.async { [self] in handleConnection(client) }
        }
    }

    private func finish(_ descriptor: Int32) {
        stateLock.withLock {
            guard clients.removeValue(forKey: descriptor) != nil else { return }
            cancelledClients.remove(descriptor)
            deadlines.removeValue(forKey: descriptor)?.cancel()
            tasks.removeValue(forKey: descriptor)
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        do {
            let frame = try readFrame(from: descriptor)
            let request = try PrivateSocketCodec.decodeFrame(frame).message
            // Hold the lock until task registration to prevent stop from missing a new task.
            stateLock.lock()
            guard !stopped, clients[descriptor] != nil, !cancelledClients.contains(descriptor) else {
                stateLock.unlock()
                finish(descriptor)
                return
            }
            tasks[descriptor] = Task { [self] in
                defer { finish(descriptor) }
                guard !Task.isCancelled else { return }
                let response = await handler(request)
                guard !Task.isCancelled else { return }
                do {
                    try writeAll(try PrivateSocketCodec.encode(response), to: descriptor)
                } catch {
                    fputs("CoolDownloadIntegration socket response failed\n", stderr)
                }
            }
            stateLock.unlock()
        } catch {
            fputs("CoolDownloadIntegration socket request failed\n", stderr)
            finish(descriptor)
        }
    }

    private func makeAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw PrivateSocketClientError.pathTooLong(socketURL.path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }

    private func readFrame(from descriptor: Int32) throws -> Data {
        let header = try readExactly(8, from: descriptor)
        let length = UInt32(bigEndian: header[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0, length <= PrivateSocketError.maximumMessageSize else {
            throw PrivateSocketClientError.invalidLength(length)
        }
        var frame = header
        frame.append(try readExactly(Int(length), from: descriptor))
        return frame
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data()
        while data.count < count {
            var bytes = [UInt8](repeating: 0, count: min(64 * 1024, count - data.count))
            let readCount = bytes.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw PrivateSocketClientError.system(errno)
            }
            guard readCount > 0 else { throw PrivateSocketClientError.closed }
            data.append(bytes, count: readCount)
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(descriptor, baseAddress.advanced(by: offset), data.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PrivateSocketClientError.system(errno)
                }
                guard written > 0 else { throw PrivateSocketClientError.closed }
                offset += written
            }
        }
    }

    private func configureTimeouts(for descriptor: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) { pointer in
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }
}
