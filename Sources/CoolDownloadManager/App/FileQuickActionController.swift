import AppKit
import Combine
import Foundation
import CoolDownloadCore
import CoolFileActions

enum FileQuickActionKind: Sendable {
    case archive, font, application, diskImage

    var title: String {
        switch self {
        case .archive: "快速解压"
        case .font: "安装字体"
        case .application: "安装应用"
        case .diskImage: "快速安装…"
        }
    }

    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .font: "textformat"
        case .application, .diskImage: "square.and.arrow.down"
        }
    }

    static func detect(_ record: DownloadRecord) -> Self? {
        guard record.status == .completed else { return nil }
        return detect(record.destinationURL)
    }

    static func detect(_ url: URL) -> Self? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "app", values.isDirectory == true,
           (try? ApplicationBundleInfo.read(url, verifySignature: false)) != nil { return .application }
        guard values.isRegularFile == true else { return nil }
        if FontInstallation.extensions.contains(ext) { return .font }
        if ext == "dmg" { return .diskImage }
        if ["zip", "zipx", "7z", "rar", "tar", "gz", "gzip", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "lz", "lzma", "lzh", "cab", "sit", "sitx"].contains(ext) { return .archive }
        return nil
    }
}

enum FileActionPrompt {
    case permission
    case replace(destination: URL, current: String, incoming: String)
    case applications([URL])
}

enum FileActionAnswer: Equatable {
    case cancel, authorize, currentUser, replace, application(URL)
}

@MainActor
final class FileQuickActionSession: ObservableObject, Identifiable {
    let id = UUID()
    let record: DownloadRecord
    let kind: FileQuickActionKind
    let sourceIdentity: FileItemIdentity?
    @Published var message = "正在准备…"
    @Published var isRunning = true
    @Published var canCancel = true
    @Published var isCancelling = false
    @Published var prompt: FileActionPrompt?
    @Published var result: FileInstallResult?
    @Published var error: String?
    @Published var wasCancelled = false
    var task: Task<Void, Never>?
    var onPrompt: ((FileQuickActionSession) -> Void)?
    private var answerContinuation: CheckedContinuation<FileActionAnswer, Never>?

    init(record: DownloadRecord, kind: FileQuickActionKind) {
        self.record = record
        self.kind = kind
        sourceIdentity = try? FileItemIdentity.read(record.destinationURL)
    }

    func ask(_ prompt: FileActionPrompt) async -> FileActionAnswer {
        if Task.isCancelled { return .cancel }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.answerContinuation = continuation
                self.prompt = prompt
                self.canCancel = true
                onPrompt?(self)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(.cancel) }
        }
    }

    func answer(_ value: FileActionAnswer) {
        let continuation = answerContinuation
        answerContinuation = nil
        prompt = nil
        continuation?.resume(returning: value)
    }

    func cancel() {
        guard isRunning, canCancel else { return }
        isCancelling = true
        message = "正在取消，等待当前操作安全结束…"
        canCancel = false
        task?.cancel()
        answer(.cancel)
    }
}

@MainActor
final class FileQuickActionController: ObservableObject {
    typealias InstallApplication = @Sendable (URL, URL, FileItemIdentity?, FileInstallation.Progress) async throws -> FileInstallResult
    typealias AuthorizeApplication = @Sendable (AuthorizedApplicationInstall) async throws -> FileInstallResult
    @Published private var sessions: [String: FileQuickActionSession] = [:]
    private var targetOwners: [String: UUID] = [:]
    var onPresent: ((FileQuickActionSession) -> Void)?
    var onPrompt: ((FileQuickActionSession) -> Void)?
    let applicationsDirectory: URL
    let userApplicationsDirectory: URL
    let fontsDirectory: URL
    private let installApplication: InstallApplication
    private let authorizeApplication: AuthorizeApplication

    init(
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        userApplicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        fontsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts", isDirectory: true),
        installApplication: @escaping InstallApplication = FileQuickActionController.copyApplication,
        authorizeApplication: @escaping AuthorizeApplication = FileQuickActionController.authorizedInstall
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.userApplicationsDirectory = userApplicationsDirectory
        self.fontsDirectory = fontsDirectory
        self.installApplication = installApplication
        self.authorizeApplication = authorizeApplication
    }

    func session(for record: DownloadRecord) -> FileQuickActionSession? {
        guard record.status == .completed,
              let session = sessions[FileActionPath.canonical(record.destinationURL).path] else { return nil }
        if session.isRunning { return session }
        guard session.sourceIdentity == (try? FileItemIdentity.read(record.destinationURL)) else { return nil }
        return session
    }

    @discardableResult
    func start(_ record: DownloadRecord) -> FileQuickActionSession? {
        let key = FileActionPath.canonical(record.destinationURL).path
        if let existing = sessions[key], existing.isRunning { onPresent?(existing); return existing }
        guard let kind = FileQuickActionKind.detect(record), kind != .archive else { return nil }
        let session = FileQuickActionSession(record: record, kind: kind)
        session.onPrompt = { [weak self] in self?.onPrompt?($0) }
        sessions[key] = session
        // Completed sessions do not need an unbounded application-lifetime cache.
        if sessions.count > 128 {
            sessions = sessions.filter { $0.key == key || $0.value.isRunning }
        }
        onPresent?(session)
        session.task = Task { [weak self] in await self?.execute(session) }
        return session
    }

    func present(_ session: FileQuickActionSession) { onPresent?(session) }

    func prepareForTermination() async {
        let active = sessions.values.filter(\.isRunning)
        for session in active where session.canCancel { session.cancel() }
        // An authorized operation or atomic commit must finish its rollback /
        // cleanup before the application exits. A UI window never owns it.
        for session in active { await session.task?.value }
    }

    private func execute(_ session: FileQuickActionSession) async {
        var mount: DiskImageMount?
        do {
            switch session.kind {
            case .archive: break
            case .font:
                try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
                let source = session.record.destinationURL
                try FontInstallation.validate(source)
                let destination = fontsDirectory.appendingPathComponent(source.lastPathComponent)
                let identity = try await prepareDestination(destination, source: source, session: session, font: true)
                defer { targetOwners[FileActionPath.canonical(destination).path] = nil }
                session.result = try await Self.copyFont(source, destination, identity, progress(for: session))
            case .application, .diskImage:
                var source = session.record.destinationURL
                if session.kind == .diskImage {
                    session.message = "正在只读挂载磁盘映像…"
                    mount = try await DiskImageInstaller.mount(source)
                    try Task.checkCancellation()
                    session.message = "正在查找可安装的应用…"
                    let candidates = try await DiskImageInstaller.applications(in: mount!.volumes)
                    guard !candidates.isEmpty else { throw FileActionFailure("镜像内没有可直接安装的应用，请使用“打开镜像”按开发者指引安装。") }
                    if candidates.count == 1 { source = candidates[0] }
                    else {
                        session.message = "请选择要安装的应用"
                        guard case .application(let selected) = await session.ask(.applications(candidates)), candidates.contains(selected) else { throw CancellationError() }
                        source = selected
                    }
                }
                session.result = try await install(source, session: session)
            }
            session.message = session.kind == .font ? "字体安装完成" : "应用安装完成"
        } catch is CancellationError {
            session.wasCancelled = true
            session.message = "已取消安装"
        } catch {
            session.error = error.localizedDescription
            session.message = "安装未完成"
        }
        if let mount {
            session.canCancel = false
            if let warning = await DiskImageInstaller.unmount(mount) {
                if session.result != nil { session.result?.warnings.append(warning) }
                else { session.error = [session.error, warning].compactMap { $0 }.joined(separator: "\n") }
            }
        }
        session.isRunning = false
        session.canCancel = false
        session.task = nil
    }

    private func install(_ source: URL, session: FileQuickActionSession) async throws -> FileInstallResult {
        session.message = "正在校验应用…"
        _ = try await Self.inspectApplication(source)
        let destination = applicationsDirectory.appendingPathComponent(source.lastPathComponent)
        let identity = try await prepareDestination(destination, source: source, session: session)
        defer { targetOwners[FileActionPath.canonical(destination).path] = nil }
        do {
            return try await installApplication(source, destination, identity, progress(for: session))
        } catch {
            guard FileInstallation.isPermissionError(error) else { throw error }
        }
        try Task.checkCancellation()
        session.message = "请选择安装方式"
        switch await session.ask(.permission) {
        case .authorize:
            try Task.checkCancellation()
            session.message = "正在请求管理员授权并安装…"
            session.canCancel = false // Cancel through the system authorization dialog.
            // Preserve the exact target identity shown in the replacement
            // prompt. Re-reading it here could replace a changed app silently.
            return try await authorizeApplication(.init(source: source, destination: destination, expectedIdentity: identity))
        case .currentUser:
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: userApplicationsDirectory, withIntermediateDirectories: true)
            let userDestination = userApplicationsDirectory.appendingPathComponent(source.lastPathComponent)
            return try await installAt(userDestination, source: source, session: session)
        default: throw CancellationError()
        }
    }

    private func installAt(_ destination: URL, source: URL, session: FileQuickActionSession) async throws -> FileInstallResult {
        let identity = try await prepareDestination(destination, source: source, session: session)
        defer { targetOwners[FileActionPath.canonical(destination).path] = nil }
        return try await installApplication(source, destination, identity, progress(for: session))
    }

    private func prepareDestination(_ destination: URL, source: URL, session: FileQuickActionSession, font: Bool = false) async throws -> FileItemIdentity? {
        guard targetOwners[FileActionPath.canonical(destination).path] == nil || targetOwners[FileActionPath.canonical(destination).path] == session.id else {
            throw FileActionFailure("另一个安装操作正在使用同一目标，请等待它完成后重试。")
        }
        targetOwners[FileActionPath.canonical(destination).path] = session.id
        do {
            let identity = try FileItemIdentity.read(destination)
            let resolved = FileActionPath.canonical(destination)
            guard resolved.path != FileActionPath.canonical(source).path else { throw FileActionFailure("此文件已经位于安装位置。") }
            if !font {
                guard resolved.path != FileActionPath.canonical(Bundle.main.bundleURL).path else {
                    throw FileActionFailure("请通过软件更新功能更新当前下载管理器。")
                }
                guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL.map { FileActionPath.canonical($0).path } == resolved.path }) else {
                    throw FileActionFailure("目标应用正在运行，请先退出该应用后重试。")
                }
            }
            if identity != nil {
                let current = font ? destination.lastPathComponent : applicationDescription(destination)
                let incoming = font ? source.lastPathComponent : applicationDescription(source)
                session.message = "请确认是否替换现有\(font ? "字体" : "应用")"
                guard await session.ask(.replace(destination: destination, current: current, incoming: incoming)) == .replace else { throw CancellationError() }
                try Task.checkCancellation()
                try FileInstallation.ensureIdentity(destination, expected: identity)
            }
            return identity
        } catch {
            targetOwners[FileActionPath.canonical(destination).path] = nil
            throw error
        }
    }

    private func applicationDescription(_ url: URL) -> String {
        guard let info = try? ApplicationBundleInfo.read(url, verifySignature: false) else { return url.lastPathComponent }
        return "\(info.name) · \(info.version)\n\(info.identifier)"
    }

    private func progress(for session: FileQuickActionSession) -> FileInstallation.Progress {
        { [weak session] message, canCancel in
            Task { @MainActor in
                guard let session, session.isRunning else { return }
                if !session.isCancelling { session.message = message; session.canCancel = canCancel }
            }
        }
    }

    @concurrent
    private static func inspectApplication(_ url: URL) async throws -> ApplicationBundleInfo { try ApplicationBundleInfo.read(url) }

    @concurrent
    static func copyApplication(_ source: URL, _ destination: URL, _ identity: FileItemIdentity?, _ progress: FileInstallation.Progress) async throws -> FileInstallResult {
        try FileInstallation.perform(source: source, destination: destination, expectedIdentity: identity,
            validate: { _ = try ApplicationBundleInfo.read($0) },
            beforeCommit: { try ApplicationBundleInfo.ensureNotRunning(destination) },
            cancelled: { Task.isCancelled }, progress: progress)
    }

    @concurrent
    private static func copyFont(_ source: URL, _ destination: URL, _ identity: FileItemIdentity?, _ progress: FileInstallation.Progress) async throws -> FileInstallResult {
        try FontInstallation.perform(source: source, destination: destination, expectedIdentity: identity,
            cancelled: { Task.isCancelled }, progress: progress)
    }

    nonisolated static let authorizationScript = """
    on run argv
        set toolPath to item 1 of argv
        set requestData to item 2 of argv
        do shell script (quoted form of toolPath & " --install-application " & quoted form of requestData) with administrator privileges
    end run
    """

    nonisolated static func authorizedInstall(_ request: AuthorizedApplicationInstall) async throws -> FileInstallResult {
        try request.validate()
        let tool = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("CoolDownloadManagerCLI")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw FileActionFailure("安装工具不可用，请使用完整应用安装包重试。") }
        let payload = try JSONEncoder().encode(request).base64EncodedString()
        let reply = try await FileActionProcess.run("/usr/bin/osascript", ["-", tool.path, payload], input: Data(authorizationScript.utf8))
        return try authorizedResult(reply)
    }

    nonisolated static func authorizedResult(_ reply: FileActionProcessResult) throws -> FileInstallResult {
        guard reply.status == 0 else {
            let diagnostic = reply.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if diagnostic.hasSuffix("(-128)") || diagnostic.hasSuffix("(-60006)") { throw CancellationError() }
            throw FileActionFailure("管理员安装未完成：\(diagnostic)")
        }
        return try JSONDecoder().decode(FileInstallResult.self, from: reply.output)
    }
}
