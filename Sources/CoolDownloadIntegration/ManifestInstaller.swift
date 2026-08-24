import Foundation

public enum NativeMessagingManifestInstaller {
    public static let hostName = "com.abdownloadmanager"
    public static let firefoxExtensionID = "firefox-integration@abdownloadmanager.com"
    public static let chromeExtensionOrigin = "chrome-extension://bbobopahenonfdgjgaleledndnnfhooj/"

    public static func install(hostExecutableURL: URL) throws -> [URL] {
        let hostPath = hostExecutableURL.standardizedFileURL.path
        guard hostExecutableURL.path.hasPrefix("/") else {
            throw ManifestInstallerError.nonAbsoluteHostPath(hostPath)
        }
        let fileManager = FileManager.default
        let directories = manifestDirectories
        let firefox = try JSONSerialization.data(withJSONObject: [
            "name": hostName,
            "description": "Cool download manager",
            "path": hostPath,
            "type": "stdio",
            "allowed_extensions": [firefoxExtensionID]
        ], options: [.sortedKeys, .prettyPrinted])
        let chrome = try JSONSerialization.data(withJSONObject: [
            "name": hostName,
            "description": "Cool download manager",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": [chromeExtensionOrigin]
        ], options: [.sortedKeys, .prettyPrinted])

        var written: [URL] = []
        for (directory, data) in zip(directories, [firefox, chrome, chrome]) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let target = directory.appendingPathComponent("\(hostName).json")
            let temporary = directory.appendingPathComponent(".\(hostName).\(UUID().uuidString).tmp")
            guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw ManifestInstallerError.writeFailed(target.path)
            }
            do {
                if fileManager.fileExists(atPath: target.path) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: target)
                }
                written.append(target)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw ManifestInstallerError.writeFailed(target.path)
            }
        }
        return written
    }

    public static func remove() {
        for directory in manifestDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(hostName).json"))
        }
    }

    public static var manifestDirectories: [URL] {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return [
            applicationSupport.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true),
            applicationSupport.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true),
            applicationSupport.appendingPathComponent("Chromium/NativeMessagingHosts", isDirectory: true)
        ]
    }
}

public enum ManifestInstallerError: Error, LocalizedError, Sendable, Equatable {
    case nonAbsoluteHostPath(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nonAbsoluteHostPath(let path): return "Native Messaging host path is not absolute: \(path)"
        case .writeFailed(let path): return "Cannot write Native Messaging manifest: \(path)"
        }
    }
}
