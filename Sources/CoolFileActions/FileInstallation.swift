import Foundation
import Darwin
import Security
import AppKit

public enum FileActionPath {
    /// Foundation intentionally preserves some /var aliases. POSIX realpath is
    /// needed for shared task ownership and mount containment comparisons.
    public static func canonical(_ url: URL) -> URL {
        if let path = realpath(url.path, nil) {
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path))
        }
        let parent = url.deletingLastPathComponent()
        if let path = realpath(parent.path, nil) {
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path)).appendingPathComponent(url.lastPathComponent)
        }
        return url.standardizedFileURL
    }
}

public struct FileActionFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FileItemIdentity: Codable, Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64

    public static func read(_ url: URL) throws -> Self? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT != S_IFLNK else {
            throw FileActionFailure("文件路径是符号链接，无法直接安装：\(url.lastPathComponent)")
        }
        return .init(device: info.st_dev, inode: info.st_ino)
    }
}

public struct FileInstallResult: Codable, Sendable {
    public let destination: URL
    public var warnings: [String]
    public init(destination: URL, warnings: [String] = []) {
        self.destination = destination
        self.warnings = warnings
    }
}

public struct ApplicationBundleInfo: Sendable {
    public let name: String
    public let identifier: String
    public let version: String

    public static func read(_ url: URL, verifySignature: Bool = true) throws -> Self {
        let fm = FileManager.default
        guard url.pathExtension.lowercased() == "app",
              try FileItemIdentity.read(url) != nil,
              (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw FileActionFailure("\(url.lastPathComponent) 不是有效的 macOS 应用程序包。")
        }
        let root = FileActionPath.canonical(url).path + "/"
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard FileActionPath.canonical(plist).path.hasPrefix(root),
              let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values["CFBundlePackageType"] as? String == "APPL",
              let executable = values["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\0") else {
            throw FileActionFailure("\(url.lastPathComponent) 的应用信息无效或缺少可执行文件。")
        }
        let binary = url.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileActionPath.canonical(binary).path.hasPrefix(root),
              (try? binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fm.isExecutableFile(atPath: binary.path) else {
            throw FileActionFailure("\(url.lastPathComponent) 缺少有效的可执行文件。")
        }
        if verifySignature {
            var code: SecStaticCode?
            let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
            if created != errSecCSUnsigned {
                guard created == errSecSuccess, let code else {
                    throw FileActionFailure("无法验证 \(url.lastPathComponent) 的应用签名。")
                }
                let checked = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil)
                guard checked == errSecSuccess || checked == errSecCSUnsigned else {
                    throw FileActionFailure("\(url.lastPathComponent) 的签名校验失败，应用可能不完整。")
                }
            }
        }
        return .init(
            name: values["CFBundleDisplayName"] as? String ?? values["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
            identifier: values["CFBundleIdentifier"] as? String ?? "未提供应用标识",
            version: values["CFBundleShortVersionString"] as? String ?? values["CFBundleVersion"] as? String ?? "未知版本"
        )
    }
    public static func ensureNotRunning(_ destination: URL) throws {
        guard let identifier = Bundle(url: destination)?.bundleIdentifier else { return }
        let target = FileActionPath.canonical(destination).path
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
            $0.bundleURL.map { FileActionPath.canonical($0).path } == target
        }) else {
            throw FileActionFailure("目标应用正在运行，请先退出该应用后重试。")
        }
    }

}

/// Shared by the GUI and the existing one-shot CLI. Staging and atomic exchanges
/// stay on the destination volume. No old version is permanently deleted.
public enum FileInstallation {
    public typealias Progress = @Sendable (_ message: String, _ canCancel: Bool) -> Void

    public static func perform(
        source: URL,
        destination: URL,
        expectedIdentity: FileItemIdentity?,
        validate: @Sendable (URL) throws -> Void,
        beforeCommit: @Sendable () throws -> Void = {},
        activate: @Sendable (URL) throws -> Void = { _ in },
        deactivate: @Sendable (URL) throws -> Void = { _ in },
        restore: @Sendable (URL) throws -> Void = { _ in },
        cancelled: @Sendable () -> Bool = { false },
        progress: Progress = { _, _ in }
    ) throws -> FileInstallResult {
        let fm = FileManager.default
        guard FileActionPath.canonical(source).path != FileActionPath.canonical(destination).path else {
            throw FileActionFailure("此文件已经位于安装位置。")
        }
        try validate(source)
        try ensureIdentity(destination, expected: expectedIdentity)
        let parent = destination.deletingLastPathComponent()
        // Never create arbitrary parent trees while running with elevated rights.
        guard try FileItemIdentity.read(parent) != nil else {
            throw FileActionFailure("安装目标目录不存在。")
        }
        let work = parent.appendingPathComponent(".cooldm-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = work.appendingPathComponent(destination.lastPathComponent)
        var preservesRecovery = false
        do {
            progress("正在复制 \(source.lastPathComponent)…", true)
            try fm.copyItem(at: source, to: staged)
            if cancelled() { throw CancellationError() }
            progress("正在校验安装文件…", true)
            try validate(staged)
            try ensureIdentity(destination, expected: expectedIdentity)
            if cancelled() { throw CancellationError() }
            progress("正在完成安装…", false)
            try beforeCommit()
            do {
                try rename(staged, to: destination, exchange: expectedIdentity != nil)
            } catch {
                if expectedIdentity != nil { try restore(destination) }
                throw error
            }
            do {
                try activate(destination)
            } catch {
                do {
                    try deactivate(destination)
                    if expectedIdentity != nil {
                        try rename(staged, to: destination, exchange: true)
                        try restore(destination)
                    } else {
                        try rename(destination, to: staged, exchange: false)
                    }
                } catch let rollback {
                    preservesRecovery = true
                    throw FileActionFailure("安装失败且无法完整恢复旧文件：\(rollback.localizedDescription)。备份或暂存文件保留在 \(work.path)")
                }
                throw error
            }
        } catch {
            if preservesRecovery { throw error }
            let warning = recycleWork(work)
            if let warning {
                throw NSError(domain: "CoolFileActions", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(error.localizedDescription)\n\(warning)",
                    NSUnderlyingErrorKey: error
                ])
            }
            throw error
        }
        let warnings = recycleWork(work).map { [$0] } ?? []
        return .init(destination: destination, warnings: warnings)
    }

    public static func ensureIdentity(_ url: URL, expected: FileItemIdentity?) throws {
        guard try FileItemIdentity.read(url) == expected else {
            throw FileActionFailure("安装目标已经发生变化，请重新发起安装并确认替换。")
        }
    }

    private static func rename(_ source: URL, to destination: URL, exchange: Bool) throws {
        let flags = UInt32(exchange ? RENAME_SWAP : RENAME_EXCL)
        guard renamex_np(source.path, destination.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    public static func recycleWork(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            // Empty directories carry no recoverable data; rmdir also refuses
            // races that introduce content after this explicit enumeration.
            if try fm.contentsOfDirectory(atPath: url.path).isEmpty {
                guard rmdir(url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            } else if geteuid() == 0 {
                return "旧版备份或暂存文件已保留，可由管理员恢复：\(url.path)"
            } else {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
            return nil
        } catch {
            return "无法移入废纸篓，文件已保留：\(url.path)（\(error.localizedDescription)）"
        }
    }

    public static func isPermissionError(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSFileReadNoPermissionError { return false }
            if value.code == NSFileWriteNoPermissionError { return true }
        }
        if value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code) { return true }
        return (value.userInfo[NSUnderlyingErrorKey] as? Error).map(isPermissionError) ?? false
    }
}

public struct AuthorizedApplicationInstall: Codable, Sendable {
    public let source: URL
    public let destination: URL
    public let expectedIdentity: FileItemIdentity?

    public init(source: URL, destination: URL, expectedIdentity: FileItemIdentity?) {
        self.source = source
        self.destination = destination
        self.expectedIdentity = expectedIdentity
    }

    public func validate() throws {
        let target = destination.standardizedFileURL
        guard source.isFileURL, destination.isFileURL, source.path.hasPrefix("/"),
              target == destination,
              target.deletingLastPathComponent().path == "/Applications",
              target.lastPathComponent == source.lastPathComponent,
              target.pathExtension.lowercased() == "app",
              !target.lastPathComponent.contains("\0"),
              try FileItemIdentity.read(target.deletingLastPathComponent()) != nil else {
            throw FileActionFailure("管理员安装只允许将有效应用安装到系统“应用程序”目录。")
        }
        _ = try ApplicationBundleInfo.read(source)
        try FileInstallation.ensureIdentity(target, expected: expectedIdentity)
    }
}
