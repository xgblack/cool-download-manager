import Foundation

public struct PrivateSocketMessage: Codable, Equatable, Sendable {
    public var requestId: String
    public var action: String
    public var payload: String
    public var isError: Bool

    public init(requestId: String, action: String, payload: String = "{}", isError: Bool = false) {
        self.requestId = requestId
        self.action = action
        self.payload = payload
        self.isError = isError
    }
}

public enum PrivateSocketError: Error, LocalizedError, Sendable, Equatable {
    case invalidMagic
    case truncatedFrame
    case invalidLength(UInt32)
    case messageTooLarge(Int)
    case malformedJSON(String)

    public static let maximumMessageSize = 4 * 1024 * 1024

    public var errorDescription: String? {
        switch self {
        case .invalidMagic: return "私有套接字帧标识无效"
        case .truncatedFrame: return "私有套接字帧不完整"
        case .invalidLength(let length): return "私有套接字帧长度无效：\(length)"
        case .messageTooLarge(let size): return "私有套接字消息过大：\(size)"
        case .malformedJSON(let reason): return "私有套接字 JSON 格式错误：\(reason)"
        }
    }
}

public enum PrivateSocketCodec {
    private static let magic = Data("CDM1".utf8)

    public static func encode(_ message: PrivateSocketMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= PrivateSocketError.maximumMessageSize else {
            throw PrivateSocketError.messageTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = magic
        frame.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        frame.append(payload)
        return frame
    }

    public static func decodeFrame(_ data: Data) throws -> (message: PrivateSocketMessage, consumed: Int) {
        let headerLength = magic.count + MemoryLayout<UInt32>.size
        guard data.count >= headerLength else {
            throw PrivateSocketError.truncatedFrame
        }
        guard data.prefix(magic.count) == magic else {
            throw PrivateSocketError.invalidMagic
        }
        let lengthData = data[magic.count..<headerLength]
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0 else { throw PrivateSocketError.invalidLength(length) }
        guard length <= PrivateSocketError.maximumMessageSize else {
            throw PrivateSocketError.messageTooLarge(Int(length))
        }
        let total = headerLength + Int(length)
        guard data.count >= total else {
            throw PrivateSocketError.truncatedFrame
        }
        let payload = data[headerLength..<total]
        do {
            return (try JSONDecoder().decode(PrivateSocketMessage.self, from: payload), total)
        } catch {
            throw PrivateSocketError.malformedJSON(error.localizedDescription)
        }
    }
}
