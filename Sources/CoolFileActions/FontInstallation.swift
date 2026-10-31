import Foundation
import CoreText

public enum FontInstallation {
    public static let extensions: Set<String> = ["otf", "ttf", "ttc"]

    public static func validate(_ url: URL) throws {
        guard extensions.contains(url.pathExtension.lowercased()),
              try FileItemIdentity.read(url) != nil,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            throw FileActionFailure("\(url.lastPathComponent) 不是有效的 OTF、TTF 或 TTC 字体。")
        }
    }

    public static func perform(
        source: URL, destination: URL, expectedIdentity: FileItemIdentity?,
        cancelled: @Sendable () -> Bool = { false }, progress: FileInstallation.Progress = { _, _ in }
    ) throws -> FileInstallResult {
        try validate(source)
        let previousScope = expectedIdentity == nil ? CTFontManagerScope.none : CTFontManagerGetScopeForURL(destination as CFURL)
        return try FileInstallation.perform(
            source: source, destination: destination, expectedIdentity: expectedIdentity,
            validate: validate,
            beforeCommit: {
                if expectedIdentity != nil { try unregister(destination) }
            },
            activate: register,
            deactivate: unregister,
            restore: { url in
                if previousScope != .none { try register(url, scope: previousScope) }
            },
            cancelled: cancelled, progress: progress
        )
    }

    public static func register(_ url: URL) throws { try register(url, scope: .persistent) }

    private static func register(_ url: URL, scope: CTFontManagerScope) throws {
        var error: Unmanaged<CFError>?
        let succeeded = CTFontManagerRegisterFontsForURL(url as CFURL, scope, &error)
        let failure = error?.takeRetainedValue()
        if succeeded { return }
        // The font directory watcher can register this exact installed URL
        // before this call. A same-name font elsewhere is still a failure.
        if let failure, CFErrorGetCode(failure) == CTFontManagerError.alreadyRegistered.rawValue,
           matchesInstalledURL(url) { return }
        throw FileActionFailure("字体注册失败：\(failure.map { CFErrorCopyDescription($0) as String } ?? "系统未能启用此字体")")
    }

    private static func unregister(_ url: URL) throws {
        let scope = CTFontManagerGetScopeForURL(url as CFURL)
        guard scope != .none else { return }
        var error: Unmanaged<CFError>?
        let succeeded = CTFontManagerUnregisterFontsForURL(url as CFURL, scope, &error)
        let failure = error?.takeRetainedValue()
        guard succeeded else {
            throw FileActionFailure("无法暂停旧字体以进行替换：\(failure.map { CFErrorCopyDescription($0) as String } ?? "系统拒绝了操作")")
        }
    }

    private static func matchesInstalledURL(_ url: URL) -> Bool {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else { return false }
        return descriptors.allSatisfy { descriptor in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute),
                  let matches = CTFontDescriptorCreateMatchingFontDescriptors(
                    CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary),
                    NSSet(object: kCTFontNameAttribute) as CFSet
                  ) as? [CTFontDescriptor] else { return false }
            return matches.contains {
                guard let actual = CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL else { return false }
                return FileActionPath.canonical(actual).path == FileActionPath.canonical(url).path
            }
        }
    }
}
