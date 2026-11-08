import Foundation

public struct NativeMessagingRelay: Sendable {
    public let socketURL: URL

    public init(socketURL: URL) { self.socketURL = socketURL }

    public func handle(_ request: NativeMessagingMessage,
                       startupTimeout: TimeInterval = 10,
                       launch: @escaping () throws -> Void) throws -> NativeMessagingMessage {
        do {
            if request.content.action == "ping" {
                return .init(id: request.id, content: try .boolean(true, action: "ping"))
            }
            guard request.content.action == "add" else {
                return .init(id: request.id, content: try .error(type: "unsupported_action", message: "不支持的操作"))
            }
            // Validate before waking the GUI. Preserve the original payload for
            // forwarding and keep credentials out of diagnostics.
            _ = try JSONDecoder().decode(AddDownloadsRequest.self, from: Data(request.content.payload.utf8))
            try AppInstanceClient(socketURL: socketURL).waitUntilReady(timeout: startupTimeout, launch: launch)
            let reply = try PrivateSocketClient(socketURL: socketURL).send(.init(
                requestId: request.id, action: "add", payload: request.content.payload
            ))
            return .init(id: request.id, content: .init(action: reply.action, isError: reply.isError, payload: reply.payload))
        } catch {
            return .init(id: request.id, content: try .error(type: String(describing: type(of: error)),
                                                          message: error.localizedDescription))
        }
    }
}
