import Foundation
import Darwin
import CoolDownloadCore
import CoolDownloadIntegration

let relay = NativeMessagingRelay(socketURL: AppPaths.nativeMessagingSocketURL())
let input = FileHandle.standardInput
let output = FileHandle.standardOutput

while true {
    do {
        let request = try NativeMessagingCodec.read(from: input)
        let response = try relay.handle(request) {
            let hostURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let executable = hostURL.deletingLastPathComponent().appendingPathComponent("CoolDownloadManager")
            let process = Process()
            process.executableURL = executable
            process.arguments = [AppPaths.browserIntegrationLaunchArgument]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        try NativeMessagingCodec.write(response, to: output)
    } catch NativeMessagingError.eof {
        break
    } catch {
        // Frame payloads can contain credentials. Never log the input or send
        // diagnostics to the browser's binary stdout stream.
        fputs("CoolDownloadManagerNativeMessagingHost: 消息流无效或已断开\n", stderr)
        exit(1)
    }
}
