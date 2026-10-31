import Foundation
import CoolDownloadCore
import CoolDownloadIntegration
import CoolFileActions
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())

// A private one-shot installation command. This branch never contacts the
// download socket or reads the administrator account's download configuration.
if arguments.first == "--install-application" {
    do {
        guard geteuid() == 0, arguments.count == 2,
              let data = Data(base64Encoded: arguments[1]) else {
            throw FileActionFailure("此安装命令需要系统管理员授权。")
        }
        let request = try JSONDecoder().decode(AuthorizedApplicationInstall.self, from: data)
        try request.validate()
        let ownBundle = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard request.destination.resolvingSymlinksInPath().path != ownBundle.path else {
            throw FileActionFailure("不能通过此命令替换正在使用的下载管理器。")
        }
        let result = try FileInstallation.perform(
            source: request.source, destination: request.destination,
            expectedIdentity: request.expectedIdentity,
            validate: { _ = try ApplicationBundleInfo.read($0) },
            beforeCommit: { try ApplicationBundleInfo.ensureNotRunning(request.destination) }
        )
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        exit(0)
    } catch {
        fputs("安装失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let socketURL = AppPaths.nativeMessagingSocketURL()
let client = PrivateSocketClient(socketURL: socketURL)

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
