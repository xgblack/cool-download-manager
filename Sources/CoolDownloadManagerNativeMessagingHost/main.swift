import Foundation
import Darwin
import CoolDownloadIntegration

let socketURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cooldm/config/native-messaging.sock")
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let client = PrivateSocketClient(socketURL: socketURL)

while true {
    do {
        let request = try NativeMessagingCodec.read(from: input)
        let response = try handle(request, client: client)
        try NativeMessagingCodec.write(response, to: output)
    } catch NativeMessagingError.eof {
        break
    } catch {
        fputs("CoolDownloadManagerNativeMessagingHost: \(error.localizedDescription)\n", stderr)
        // A malformed or truncated browser frame has no trustworthy request
        // ID, so it cannot receive a valid error response. Close the host with
        // a non-zero status and keep stdout free of diagnostic text.
        exit(1)
    }
}

func handle(
    _ request: NativeMessagingMessage,
    client: PrivateSocketClient
) throws -> NativeMessagingMessage {
    do {
        guard request.content.action == "ping" || request.content.action == "add" else {
            return NativeMessagingMessage(
                id: request.id,
                content: try NativeMessagingContent.error(type: "unsupported_action", message: "不支持的操作")
            )
        }
        let forwarded = try sendToMainApp(PrivateSocketMessage(
            requestId: request.id,
            action: request.content.action ?? "add",
            payload: request.content.payload
        ), client: client)
        return NativeMessagingMessage(
            id: request.id,
            content: NativeMessagingContent(
                action: forwarded.action,
                isError: forwarded.isError,
                payload: forwarded.payload
            )
        )
    } catch {
        return NativeMessagingMessage(
            id: request.id,
            content: try NativeMessagingContent.error(
                type: String(describing: type(of: error)),
                message: error.localizedDescription
            )
        )
    }
}

func sendToMainApp(
    _ message: PrivateSocketMessage,
    client: PrivateSocketClient
) throws -> PrivateSocketMessage {
    do {
        return try client.send(message)
    } catch {
        let hostURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appURL = hostURL.deletingLastPathComponent()
            .appendingPathComponent("CoolDownloadManager")
        var lastError: Error = error

        // Give an app that is already booting a short window to publish its
        // socket before attempting a second process launch.
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.05)
            do {
                return try client.send(message)
            } catch {
                lastError = error
            }
        }

        if shouldWakeMainApp(after: error), FileManager.default.isExecutableFile(atPath: appURL.path) {
            do {
                let process = Process()
                process.executableURL = appURL
                try process.run()
            } catch {
                lastError = error
            }
        }

        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            do {
                return try client.send(message)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

func shouldWakeMainApp(after error: Error) -> Bool {
    guard let socketError = error as? PrivateSocketClientError else { return false }
    switch socketError {
    case .system(ENOENT), .system(ECONNREFUSED):
        return true
    default:
        return false
    }
}
