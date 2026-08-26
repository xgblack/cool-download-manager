import Foundation

public struct NativeMessagingMessage: Codable, Equatable, Sendable {
    public var id: String
    public var content: NativeMessagingContent

    public init(id: String, content: NativeMessagingContent) {
        self.id = id
        self.content = content
    }
}

public struct NativeMessagingContent: Codable, Equatable, Sendable {
    public var action: String?
    public var isError: Bool
    public var payload: String

    public init(action: String? = nil, isError: Bool = false, payload: String) {
        self.action = action
        self.isError = isError
        self.payload = payload
    }

    public static func boolean(_ value: Bool, action: String? = nil) throws -> NativeMessagingContent {
        let data = try JSONEncoder().encode(value)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw NativeMessagingError.invalidUTF8
        }
        return NativeMessagingContent(action: action, payload: payload)
    }

    public static func error(type: String? = nil, message: String? = nil) throws -> NativeMessagingContent {
        let data = try JSONEncoder().encode(NativeMessagingErrorPayload(errorType: type, message: message))
        guard let payload = String(data: data, encoding: .utf8) else {
            throw NativeMessagingError.invalidUTF8
        }
        return NativeMessagingContent(isError: true, payload: payload)
    }
}

public struct NativeMessagingErrorPayload: Codable, Equatable, Sendable {
    public var errorType: String?
    public var message: String?

    public init(errorType: String? = nil, message: String? = nil) {
        self.errorType = errorType
        self.message = message
    }
}

public enum NativeMessagingError: Error, LocalizedError, Sendable, Equatable {
    case eof
    case truncatedFrame
    case invalidLength(UInt32)
    case messageTooLarge(Int)
    case invalidUTF8
    case malformedJSON(String)

    public static let maximumMessageSize = 4 * 1024 * 1024

    public var errorDescription: String? {
        switch self {
        case .eof: return "Native Messaging 流已到达 EOF"
        case .truncatedFrame: return "Native Messaging 帧不完整"
        case .invalidLength(let length): return "Native Messaging 长度无效：\(length)"
        case .messageTooLarge(let size): return "Native Messaging 消息过大：\(size)"
        case .invalidUTF8: return "Native Messaging 负载不是 UTF-8"
        case .malformedJSON(let reason): return "Native Messaging JSON 格式错误：\(reason)"
        }
    }
}

public enum NativeMessagingCodec {
    public static func encode(_ message: NativeMessagingMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= NativeMessagingError.maximumMessageSize else {
            throw NativeMessagingError.messageTooLarge(payload.count)
        }
        var length = UInt32(payload.count)
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    public static func decodeFrame(_ data: Data) throws -> (message: NativeMessagingMessage, consumed: Int) {
        guard data.count >= MemoryLayout<UInt32>.size else {
            throw NativeMessagingError.truncatedFrame
        }
        let length = data.withUnsafeBytes { rawBuffer -> UInt32 in
            rawBuffer.loadUnaligned(as: UInt32.self)
        }
        guard length > 0 else {
            throw NativeMessagingError.invalidLength(length)
        }
        guard length <= NativeMessagingError.maximumMessageSize else {
            throw NativeMessagingError.messageTooLarge(Int(length))
        }
        let total = MemoryLayout<UInt32>.size + Int(length)
        guard data.count >= total else {
            throw NativeMessagingError.truncatedFrame
        }
        let payload = data[MemoryLayout<UInt32>.size..<total]
        guard let text = String(data: payload, encoding: .utf8) else {
            throw NativeMessagingError.invalidUTF8
        }
        do {
            return (try JSONDecoder().decode(NativeMessagingMessage.self, from: payload), total)
        } catch {
            throw NativeMessagingError.malformedJSON(text)
        }
    }

    public static func read(from handle: FileHandle) throws -> NativeMessagingMessage {
        let lengthData = try readExactly(MemoryLayout<UInt32>.size, from: handle)
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0 else { throw NativeMessagingError.invalidLength(length) }
        guard length <= NativeMessagingError.maximumMessageSize else {
            throw NativeMessagingError.messageTooLarge(Int(length))
        }
        let payload = try readExactly(Int(length), from: handle)
        guard String(data: payload, encoding: .utf8) != nil else {
            throw NativeMessagingError.invalidUTF8
        }
        do {
            return try JSONDecoder().decode(NativeMessagingMessage.self, from: payload)
        } catch {
            throw NativeMessagingError.malformedJSON(error.localizedDescription)
        }
    }

    public static func write(_ message: NativeMessagingMessage, to handle: FileHandle) throws {
        try handle.write(contentsOf: encode(message))
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                if result.isEmpty { throw NativeMessagingError.eof }
                throw NativeMessagingError.truncatedFrame
            }
            result.append(chunk)
        }
        return result
    }
}
