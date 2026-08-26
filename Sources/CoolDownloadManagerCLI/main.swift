import Foundation
import CoolDownloadIntegration

let socketURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cooldm/config/native-messaging.sock")
let client = PrivateSocketClient(socketURL: socketURL)
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let response: PrivateSocketMessage
    switch arguments.first {
    case "ping":
        response = try client.send(PrivateSocketMessage(requestId: UUID().uuidString, action: "ping"))
    case "add" where arguments.count >= 2:
        let credential = IntegrationDownloadCredential(link: arguments[1])
        let payload = String(data: try JSONEncoder().encode(AddDownloadsRequest(items: [credential])), encoding: .utf8)!
        response = try client.send(PrivateSocketMessage(requestId: UUID().uuidString, action: "add", payload: payload))
    default:
        fputs("用法：CoolDownloadManagerCLI ping | add <url>\n", stderr)
        exit(64)
    }
    print(response.payload)
    if response.isError { exit(1) }
} catch {
    fputs("CoolDownloadManagerCLI: \(error.localizedDescription)\n", stderr)
    exit(1)
}
