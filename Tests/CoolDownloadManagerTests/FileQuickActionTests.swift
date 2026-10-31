import AppKit
import Foundation
import Testing
import Darwin
import CoolDownloadCore
import CoolFileActions
@testable import CoolDownloadManager

private struct QuickActionFixture {
    let root: URL
    let source: URL
    let system: URL
    let user: URL

    init(name: String = "示例 'App'; $(ignore).app") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-file-actions-\(UUID().uuidString)", isDirectory: true)
        system = root.appendingPathComponent("Applications", isDirectory: true)
        user = root.appendingPathComponent("UserApplications", isDirectory: true)
        source = root.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Self.application(source, contents: "new")
    }

    static func application(_ url: URL, contents: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Example",
            "CFBundleIdentifier": "test.cooldm.example", "CFBundleShortVersionString": "1.0"
        ], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        let executable = url.appendingPathComponent("Contents/MacOS/Example")
        try Data("#!/bin/sh\n# \(contents)\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func record(id: DownloadID = 1) -> DownloadRecord {
        .init(id: id, source: .init(kind: .http, link: "https://fixture.invalid/example.dmg"),
            folder: source.deletingLastPathComponent().path, name: source.lastPathComponent, status: .completed)
    }

    func recycle() { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
}

@Suite("File installation")
struct FileInstallationTests {
    @Test("App installation preserves bundle links, metadata and the download")
    func preservesBundle() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let contents = fixture.source.appendingPathComponent("Contents")
        try FileManager.default.createSymbolicLink(at: contents.appendingPathComponent("ExecutableLink"), withDestinationURL: URL(fileURLWithPath: "MacOS/Example", relativeTo: contents))
        let attr = "0083;00000000;CoolDownloadManager;test"
        let resultCode = attr.withCString { setxattr(fixture.source.path, "com.apple.quarantine", $0, attr.utf8.count, 0, 0) }
        #expect(resultCode == 0)
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        let result = try FileInstallation.perform(source: fixture.source, destination: destination, expectedIdentity: nil,
            validate: { _ = try ApplicationBundleInfo.read($0) })
        #expect(result.destination == destination)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try ApplicationBundleInfo.read(destination).identifier == "test.cooldm.example")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Contents/ExecutableLink").path).hasSuffix("MacOS/Example"))
        #expect(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        let oldIdentity = try FileItemIdentity.read(destination)
        let sourceExecutable = fixture.source.appendingPathComponent("Contents/MacOS/Example")
        try Data("#!/bin/sh\n# replaced\nexit 0\n".utf8).write(to: sourceExecutable)
        _ = try FileInstallation.perform(source: fixture.source, destination: destination, expectedIdentity: oldIdentity,
            validate: { _ = try ApplicationBundleInfo.read($0) })
        #expect(try FileItemIdentity.read(destination) != oldIdentity)
        #expect(try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/Example")) == Data(contentsOf: sourceExecutable))
    }

    @Test("Activation failure restores the previous file, and a failed first install leaves no destination", arguments: [false, true])
    func activationFailureRollsBack(existing: Bool) throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        if existing { try QuickActionFixture.application(destination, contents: "old") }
        let oldBytes = existing ? try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/Example")) : nil
        let identity = try FileItemIdentity.read(destination)
        #expect(throws: FileActionFailure.self) {
            try FileInstallation.perform(source: fixture.source, destination: destination, expectedIdentity: identity,
                validate: { _ = try ApplicationBundleInfo.read($0) },
                activate: { _ in throw FileActionFailure("controlled registration failure") })
        }
        #expect(try FileItemIdentity.read(destination) == identity)
        if let oldBytes { #expect(try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/Example")) == oldBytes) }
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test("Cancellation and staged validation failure never replace the existing app", arguments: [false, true])
    func preCommitFailure(cancel: Bool) throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        try QuickActionFixture.application(destination, contents: "old")
        let identity = try FileItemIdentity.read(destination)
        do {
            _ = try FileInstallation.perform(source: fixture.source, destination: destination, expectedIdentity: identity,
                validate: { url in
                    if !cancel, url.path.contains(".cooldm-install-") { throw FileActionFailure("staged bundle invalid") }
                    _ = try ApplicationBundleInfo.read(url)
                }, cancelled: { cancel })
            Issue.record("Installation should have stopped before commit")
        } catch { #expect((error is CancellationError) == cancel) }
        #expect(try FileItemIdentity.read(destination) == identity)
    }

    @Test("Destination changes and symlinks are rejected before replacement")
    func refusesChangedTarget() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        try QuickActionFixture.application(destination, contents: "old")
        let identity = try FileItemIdentity.read(destination)
        try FileManager.default.moveItem(at: destination, to: fixture.root.appendingPathComponent("backup.app"))
        try QuickActionFixture.application(destination, contents: "unrelated")
        #expect(throws: FileActionFailure.self) {
            try FileInstallation.perform(source: fixture.source, destination: destination, expectedIdentity: identity,
                validate: { _ = try ApplicationBundleInfo.read($0) })
        }
        let link = fixture.system.appendingPathComponent("linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        #expect(throws: FileActionFailure.self) { try FileItemIdentity.read(link) }
    }

    @Test("Privileged requests reject arbitrary destinations, non-apps and symlinked apps")
    func restrictsPrivilegedRequest() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        #expect(throws: FileActionFailure.self) {
            try AuthorizedApplicationInstall(source: fixture.source, destination: fixture.system.appendingPathComponent(fixture.source.lastPathComponent), expectedIdentity: nil).validate()
        }
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(fixture.source.lastPathComponent)
        try AuthorizedApplicationInstall(source: fixture.source, destination: target, expectedIdentity: nil).validate()
        let link = fixture.root.appendingPathComponent(fixture.source.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        #expect(throws: FileActionFailure.self) {
            try AuthorizedApplicationInstall(source: link, destination: target, expectedIdentity: nil).validate()
        }
    }

    @Test("Read permission errors never request write authorization")
    func rejectsReadPermissionEscalation() {
        let read = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(!FileInstallation.isPermissionError(read))
        #expect(FileInstallation.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
    }

    @Test("Font extension alone cannot pass font validation")
    func rejectsFakeFont() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let font = fixture.root.appendingPathComponent("Example.TTF")
        try Data("not a font".utf8).write(to: font)
        #expect(FileQuickActionKind.detect(font) == .font)
        #expect(throws: FileActionFailure.self) { try FontInstallation.validate(font) }
    }
}

@Suite("File quick actions")
@MainActor
struct FileQuickActionTests {
    @Test("Recognition excludes unfinished downloads and fake app files")
    func recognizesCompletedFiles() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        #expect(FileQuickActionKind.detect(fixture.record()) == .application)
        var pending = fixture.record()
        pending.status = .downloading
        #expect(FileQuickActionKind.detect(pending) == nil)
        let fakeApp = fixture.root.appendingPathComponent("fake.app")
        try Data("not a bundle".utf8).write(to: fakeApp)
        #expect(FileQuickActionKind.detect(fakeApp) == nil)
        let zip = fixture.root.appendingPathComponent("Example.TAR.GZ")
        try Data().write(to: zip)
        #expect(FileQuickActionKind.detect(zip) == .archive)
        let dmg = fixture.root.appendingPathComponent("Example.DMG")
        try Data().write(to: dmg)
        #expect(FileQuickActionKind.detect(dmg) == .diskImage)
    }

    @Test("Cancelling the permission choice or system authorization never falls back to user installation", arguments: [false, true])
    func authorizationCancellation(startsAuthorization: Bool) async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let actions = FileQuickActionController(applicationsDirectory: fixture.system, userApplicationsDirectory: fixture.user,
            installApplication: { _, _, _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) },
            authorizeApplication: { _ in throw CancellationError() })
        actions.onPrompt = { session in
            guard case .permission = session.prompt else { Issue.record("Expected permission choice"); session.answer(.cancel); return }
            session.answer(startsAuthorization ? .authorize : .cancel)
        }
        let session = try #require(actions.start(fixture.record()))
        await session.task?.value
        #expect(session.wasCancelled)
        #expect(session.error == nil)
        #expect(session.result == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.user.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.system.appendingPathComponent(fixture.source.lastPathComponent).path))
    }

    @Test("Explicit user installation copies to the user target and preserves the download")
    func explicitUserInstallation() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let actions = FileQuickActionController(applicationsDirectory: fixture.system, userApplicationsDirectory: fixture.user,
            installApplication: { source, destination, identity, progress in
                if destination.deletingLastPathComponent() == fixture.system { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                return try await FileQuickActionController.copyApplication(source, destination, identity, progress)
            }, authorizeApplication: { _ in throw FileActionFailure("Unexpected authorization") })
        actions.onPrompt = { $0.answer(.currentUser) }
        let session = try #require(actions.start(fixture.record()))
        await session.task?.value
        #expect(session.error == nil)
        #expect(session.result?.destination.path == fixture.user.appendingPathComponent(fixture.source.lastPathComponent).path)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test("Disk-full failures do not trigger administrator or user fallback")
    func nonPermissionFailure() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let actions = FileQuickActionController(applicationsDirectory: fixture.system, userApplicationsDirectory: fixture.user,
            installApplication: { _, _, _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
        actions.onPrompt = { $0.answer(.cancel); Issue.record("Disk full must not ask for authorization") }
        let session = try #require(actions.start(fixture.record()))
        await session.task?.value
        #expect(session.error != nil)
        #expect(!session.wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: fixture.user.path))
    }

    @Test("Duplicate source entries share a task, cancelling replacement preserves the existing app")
    func deduplicatesSourceAndCancelsReplacement() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        try QuickActionFixture.application(destination, contents: "old")
        let identity = try FileItemIdentity.read(destination)
        let actions = FileQuickActionController(applicationsDirectory: fixture.system)
        actions.onPrompt = { session in
            let duplicate = actions.start(fixture.record(id: 2))
            #expect(duplicate === session)
            session.cancel()
        }
        let session = try #require(actions.start(fixture.record()))
        await session.task?.value
        #expect(session.wasCancelled)
        #expect(try FileItemIdentity.read(destination) == identity)
        #expect(actions.session(for: fixture.record()) === session)
    }

    @Test("Administrator installation uses the exact replacement the user approved")
    func authorizesApprovedIdentity() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        try QuickActionFixture.application(destination, contents: "old")
        let approvedIdentity = try FileItemIdentity.read(destination)
        let actions = FileQuickActionController(applicationsDirectory: fixture.system,
            installApplication: { _, _, _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) },
            authorizeApplication: { request in
                #expect(request.expectedIdentity == approvedIdentity)
                throw CancellationError()
            })
        actions.onPrompt = { session in
            if case .replace = session.prompt { session.answer(.replace) }
            else if case .permission = session.prompt { session.answer(.authorize) }
            else { session.answer(.cancel) }
        }
        let session = try #require(actions.start(fixture.record()))
        await session.task?.value
        #expect(session.wasCancelled)
    }

    @Test("Two sources cannot replace the same target concurrently")
    func serializesTarget() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let destination = fixture.system.appendingPathComponent(fixture.source.lastPathComponent)
        try QuickActionFixture.application(destination, contents: "old")
        let oldIdentity = try FileItemIdentity.read(destination)
        let otherSource = fixture.root.appendingPathComponent("OtherDownloads").appendingPathComponent(fixture.source.lastPathComponent)
        try QuickActionFixture.application(otherSource, contents: "another")
        let other = DownloadRecord(id: 2, source: .init(kind: .http, link: "https://fixture.invalid/other.dmg"),
            folder: otherSource.deletingLastPathComponent().path, name: otherSource.lastPathComponent, status: .completed)
        let actions = FileQuickActionController(applicationsDirectory: fixture.system)
        actions.onPrompt = { first in
            Task { @MainActor in
                guard let second = actions.start(other) else {
                    Issue.record("The second download did not create an installation session")
                    first.answer(.cancel)
                    return
                }
                await second.task?.value
                #expect(second.error != nil)
                #expect(second.result == nil)
                first.answer(.cancel)
            }
        }
        let first = try #require(actions.start(fixture.record()))
        await first.task?.value
        #expect(first.wasCancelled)
        #expect(try FileItemIdentity.read(destination) == oldIdentity)
    }

    @Test("DMG discovery is shallow and does not follow links or inspect app internals")
    func diskImageDiscovery() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.recycle() }
        let volume = fixture.root.appendingPathComponent("Volume")
        let first = volume.appendingPathComponent("First.app")
        let second = volume.appendingPathComponent("Folder/Second.app")
        try QuickActionFixture.application(first, contents: "first")
        try QuickActionFixture.application(second, contents: "second")
        try QuickActionFixture.application(first.appendingPathComponent("Contents/Helper.app"), contents: "helper")
        try QuickActionFixture.application(volume.appendingPathComponent("Folder/Deep/Hidden.app"), contents: "deep")
        try FileManager.default.createSymbolicLink(at: volume.appendingPathComponent("Linked.app"), withDestinationURL: fixture.source)
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("Broken.app"), withIntermediateDirectories: true)
        let discovered = try await DiskImageInstaller.applications(in: [volume])
        #expect(try discovered.map { try FileItemIdentity.read($0) } == [first, second].map { try FileItemIdentity.read($0) })
    }

    @Test("Mount information records the actual device and all reported volumes")
    func mountPlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["system-entities": [
            ["dev-entry": "/dev/disk999"],
            ["dev-entry": "/dev/disk999s1", "mount-point": "/tmp/mount/Volume"]
        ]], format: .xml, options: 0)
        let parsed = try DiskImageInstaller.volumes(from: data)
        #expect(parsed.device == "/dev/disk999")
        #expect(parsed.volumes.map(\.path) == ["/tmp/mount/Volume"])
        #expect(throws: FileActionFailure.self) { try DiskImageInstaller.volumes(from: Data()) }
    }

    @Test("Actual AppleScript cancellation codes are treated as cancellation, not installation failure", arguments: [-128, -60006])
    func appleScriptCancellation(code: Int) async throws {
        let result = try await FileActionProcess.run("/usr/bin/osascript", ["-e", "error number \(code)"])
        #expect(result.status != 0)
        #expect(throws: CancellationError.self) { try FileQuickActionController.authorizedResult(result) }
    }

    @Test("Authorization command quotes tool paths and passes request data separately")
    func authorizationArguments() async throws {
        // Run the same generated command without escalation. The normal CLI
        // root guard must reject it; a shell syntax error would indicate broken
        // quoting before the CLI can even run.
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/CoolDownloadManagerCLI")
        let script = FileQuickActionController.authorizationScript.replacingOccurrences(of: " with administrator privileges", with: "")
        let reply = try await FileActionProcess.run("/usr/bin/osascript", ["-", executable.path, "invalid-data"], input: Data(script.utf8))
        #expect(reply.status != 0)
        #expect(reply.error.contains("系统管理员授权"))
    }

    @Test("Process runner drains stderr while collecting stdout")
    func processPipes() async throws {
        let result = try await FileActionProcess.run("/bin/sh", ["-c", "i=0; while [ $i -lt 5000 ]; do printf 'a long enough diagnostic line from the fixture\n' >&2; i=$((i+1)); done; printf 'complete'"])
        #expect(result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "complete")
        #expect(result.error.utf8.count > 200_000)
    }
}
