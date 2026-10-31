import Foundation
import CoolFileActions

struct FileActionProcessResult: Sendable {
    let status: Int32
    let output: Data
    let error: String
}

/// Both pipes are drained concurrently; image tools may emit more than a pipe
/// buffer while the other stream is idle. Nothing is executed through a shell.
enum FileActionProcess {
    @concurrent
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil) async throws -> FileActionProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let inputPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()
        async let stdout = read(output.fileHandleForReading)
        async let stderr = read(errors.fileHandleForReading)
        var inputFailure: Error?
        if let input {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                inputFailure = error
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        var status: Int32 = -1
        for await value in exits { status = value }
        process.terminationHandler = nil
        let captured = try await FileActionProcessResult(status: status, output: stdout, error: String(decoding: stderr, as: UTF8.self))
        if let inputFailure { throw inputFailure }
        return captured
    }

    private static func read(_ handle: FileHandle) async throws -> Data {
        // FileHandle.readToEnd blocks. Use a dispatch worker rather than
        // exhausting Swift's cooperative executor with concurrent installs.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try handle.readToEnd() ?? Data()
                    try handle.close()
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct DiskImageMount: Sendable {
    let work: URL
    let device: String
    let volumes: [URL]
}

enum DiskImageInstaller {
    static func volumes(from data: Data) throws -> (device: String, volumes: [URL]) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let device = entities.compactMap({ $0["dev-entry"] as? String }).first,
              device.hasPrefix("/dev/disk") else {
            throw FileActionFailure("系统未返回可用的磁盘映像挂载信息。")
        }
        return (device, entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } })
    }

    static func mount(_ image: URL) async throws -> DiskImageMount {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-image-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let inventory = try await FileActionProcess.run("/usr/bin/hdiutil", ["info", "-plist"])
            guard inventory.status == 0,
                  let info = try PropertyListSerialization.propertyList(from: inventory.output, format: nil) as? [String: Any],
                  let images = info["images"] as? [[String: Any]] else {
                throw FileActionFailure("无法确认现有镜像挂载，请使用“打开镜像”。")
            }
            let existingDevices = Set(images.flatMap { ($0["system-entities"] as? [[String: Any]]) ?? [] }.compactMap { $0["dev-entry"] as? String })
            // Every invocation owns a fresh mount (-mountroot), including when
            // Finder already has the image open. Never detach Finder's mount.
            let result = try await FileActionProcess.run("/usr/bin/hdiutil", [
                "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen",
                "-mountroot", work.path, image.path
            ])
            guard result.status == 0 else {
                throw FileActionFailure("无法直接挂载此镜像。加密镜像或需要许可确认的镜像请使用“打开镜像”。\n\(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let parsed = try volumes(from: result.output)
            guard !existingDevices.contains(parsed.device) else {
                throw FileActionFailure("此镜像已由其他应用挂载，请使用“打开镜像”。现有挂载会保留。")
            }
            guard !parsed.volumes.isEmpty,
                  parsed.volumes.allSatisfy({ FileActionPath.canonical($0).path.hasPrefix(FileActionPath.canonical(work).path + "/") }) else {
                let detached = try await FileActionProcess.run("/usr/bin/hdiutil", ["detach", parsed.device])
                guard detached.status == 0 else { throw FileActionFailure("镜像未能推出，请在访达中推出：\(parsed.device)") }
                throw FileActionFailure("此镜像没有可直接安装的挂载卷，请使用“打开镜像”。")
            }
            return .init(work: work, device: parsed.device, volumes: parsed.volumes)
        } catch {
            // Do not trash a mount root with attached or partially attached
            // volumes. It is retained for explicit recovery if not empty.
            let remaining = try FileManager.default.contentsOfDirectory(atPath: work.path)
            if remaining.isEmpty {
                if let warning = FileInstallation.recycleWork(work) {
                    throw FileActionFailure("\(error.localizedDescription)\n\(warning)")
                }
            } else { throw FileActionFailure("\(error.localizedDescription)\n挂载目录已保留，请在访达中检查：\(work.path)") }
            throw error
        }
    }

    @concurrent
    static func applications(in roots: [URL]) async throws -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for root in roots {
            let rootPath = FileActionPath.canonical(root).path + "/"
            var pending: [(URL, Int)] = [(root, 0)]
            var visited = 0
            while let (directory, depth) = pending.popLast() {
                for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles]) {
                    try Task.checkCancellation()
                    visited += 1
                    guard visited <= 2_000 else { throw FileActionFailure("镜像内容较多，请使用“打开镜像”选择要安装的应用。") }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                    guard values.isSymbolicLink != true,
                          FileActionPath.canonical(url).path.hasPrefix(rootPath) else { continue }
                    if url.pathExtension.lowercased() == "app" {
                        if (try? ApplicationBundleInfo.read(url, verifySignature: false)) != nil { found.append(url) }
                    } else if values.isDirectory == true, values.isPackage != true, depth < 1 {
                        pending.append((url, depth + 1))
                    }
                }
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func unmount(_ mount: DiskImageMount) async -> String? {
        do {
            let result = try await FileActionProcess.run("/usr/bin/hdiutil", ["detach", mount.device])
            guard result.status == 0 else { return "镜像未能推出，请在访达中推出：\(mount.volumes.first?.path ?? mount.work.path)" }
            return FileInstallation.recycleWork(mount.work)
        } catch { return "镜像未能推出：\(error.localizedDescription)" }
    }
}
