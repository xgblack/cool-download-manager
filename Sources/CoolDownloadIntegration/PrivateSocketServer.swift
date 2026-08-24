import Foundation
import Darwin

public final class PrivateSocketServer: @unchecked Sendable {
    public let socketURL: URL

    private let handler: @Sendable (PrivateSocketMessage) async -> PrivateSocketMessage
    private let acceptQueue = DispatchQueue(label: "com.abdownloadmanager.integration.socket.accept")
    private let workerQueue = DispatchQueue(label: "com.abdownloadmanager.integration.socket.worker", attributes: .concurrent)
    private var listener: Int32 = -1
    private let stateLock = NSLock()
    private var stopped = false

    public init(
        socketURL: URL,
        handler: @escaping @Sendable (PrivateSocketMessage) async -> PrivateSocketMessage
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        stateLock.lock()
        let alreadyStarted = listener >= 0 && !stopped
        stateLock.unlock()
        if alreadyStarted {
            throw PrivateSocketServerError.alreadyRunning(socketURL)
        }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = Darwin.chmod(socketURL.deletingLastPathComponent().path, 0o700)
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

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PrivateSocketClientError.system(errno) }
        var address = try makeAddress()
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
        _ = Darwin.chmod(socketURL.path, 0o600)
        stateLock.lock()
        listener = descriptor
        stopped = false
        stateLock.unlock()
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public enum PrivateSocketServerError: Error, LocalizedError, Sendable, Equatable {
        case alreadyRunning(URL)
        case pathOccupied(URL)
        case probeFailed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning(let url): return "Private socket is already in use: \(url.path)"
            case .pathOccupied(let url): return "Private socket path is occupied by a non-socket file: \(url.path)"
            case .probeFailed(let url, let reason):
                return "Could not verify private socket \(url.path): \(reason)"
            }
        }
    }

    public func stop() {
        stateLock.lock()
        stopped = true
        let descriptor = listener
        listener = -1
        stateLock.unlock()
        if descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
        _ = Darwin.unlink(socketURL.path)
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let descriptor = listener
            let shouldStop = stopped
            stateLock.unlock()
            guard !shouldStop, descriptor >= 0 else { return }
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                stateLock.lock()
                let stopped = self.stopped
                stateLock.unlock()
                if stopped || errno == EBADF || errno == EINTR { return }
                continue
            }
            configureTimeouts(for: client)
            workerQueue.async { [weak self] in
                self?.handleConnection(client)
            }
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        do {
            let frame = try readFrame(from: descriptor)
            let request = try PrivateSocketCodec.decodeFrame(frame).message
            Task { [weak self] in
                guard let self else {
                    _ = Darwin.close(descriptor)
                    return
                }
                let response = await self.handler(request)
                do {
                    try self.writeAll(try PrivateSocketCodec.encode(response), to: descriptor)
                } catch {
                    fputs("CoolDownloadIntegration socket write failed: \(error)\n", stderr)
                }
                _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                _ = Darwin.close(descriptor)
            }
        } catch {
            fputs("CoolDownloadIntegration socket read failed: \(error)\n", stderr)
            _ = Darwin.close(descriptor)
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
