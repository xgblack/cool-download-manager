import Foundation
import Darwin

public final class PrivateSocketClient: @unchecked Sendable {
    public let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public func send(_ message: PrivateSocketMessage) throws -> PrivateSocketMessage {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PrivateSocketClientError.system(errno)
        }
        defer { _ = Darwin.close(descriptor) }
        configureTimeouts(for: descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw PrivateSocketClientError.pathTooLong(socketURL.path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connected == 0 else {
            throw PrivateSocketClientError.system(errno)
        }

        try writeAll(try PrivateSocketCodec.encode(message), to: descriptor)
        let responseFrame = try readFrame(from: descriptor)
        return try PrivateSocketCodec.decodeFrame(responseFrame).message
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset,
                    0
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PrivateSocketClientError.system(errno)
                }
                guard written > 0 else { throw PrivateSocketClientError.closed }
                offset += written
            }
        }
    }

    private func readFrame(from descriptor: Int32) throws -> Data {
        let headerLength = 8
        var header = try readExactly(headerLength, from: descriptor)
        let length = UInt32(bigEndian: header[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0, length <= PrivateSocketError.maximumMessageSize else {
            throw PrivateSocketClientError.invalidLength(length)
        }
        header.append(try readExactly(Int(length), from: descriptor))
        return header
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, count - data.count))
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw PrivateSocketClientError.system(errno)
            }
            guard readCount > 0 else { throw PrivateSocketClientError.closed }
            data.append(buffer, count: readCount)
        }
        return data
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

public enum PrivateSocketClientError: Error, LocalizedError, Sendable, Equatable {
    case system(Int32)
    case pathTooLong(String)
    case invalidLength(UInt32)
    case closed

    public var errorDescription: String? {
        switch self {
        case .system(let code): return "Private socket error \(code): \(String(cString: strerror(code)))"
        case .pathTooLong(let path): return "Private socket path is too long: \(path)"
        case .invalidLength(let length): return "Invalid private socket length \(length)"
        case .closed: return "Private socket closed before a response"
        }
    }
}
