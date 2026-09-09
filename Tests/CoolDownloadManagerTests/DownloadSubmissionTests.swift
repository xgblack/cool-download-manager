import Foundation
import Testing
import CoolDownloadCore
import CoolDownloadIntegration
@testable import CoolDownloadManager

@Suite("确认下载默认目录", .serialized)
@MainActor
struct DownloadSubmissionTests {
    private func makeStore() async throws -> (AppStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-folder-\(UUID().uuidString)")
        let preferences = try SettingsStore(dataRoot: root)
        var settings = AppSettingsModel.defaults()
        settings.apiEnabled = false
        settings.defaultDownloadFolder = root.appendingPathComponent("original").path
        _ = try await preferences.save(settings)
        let app = AppStore(dataRoot: root, cacheRoot: root.appendingPathComponent("cache"))
        for _ in 0..<500 {
            if app.isReady { return (app, root) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "DownloadSubmissionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用初始化超时"])
    }

    @Test("显式目录优先于分类且仅勾选后持久化")
    func remembersOnlyWhenSelected() async throws {
        let (app, root) = try await makeStore()
        let folder = root.appendingPathComponent("chosen")
        let original = app.settings.defaultDownloadFolder
        let first = DownloadSubmissionState()
        first.folderWasChosen = true
        #expect(await app.addDownload(link: "https://example.com/first.zip", name: nil, folder: folder, startImmediately: false, submission: first))
        #expect(app.settings.defaultDownloadFolder == original)
        let snapshot = await app.service!.snapshot()
        #expect(snapshot.downloads.first?.folder == folder.path)
        #expect(snapshot.downloads.first?.categoryID != nil)

        let second = DownloadSubmissionState()
        second.rememberFolder = true
        #expect(await app.addDownload(link: "https://example.com/second.zip", name: nil, folder: folder, startImmediately: false, submission: second))
        #expect(app.settings.defaultDownloadFolder == folder.path)
        let reopened = try await SettingsStore(dataRoot: root).load()
        #expect(reopened.defaultDownloadFolder == folder.path)
        #expect(!reopened.apiEnabled)
        let request = AddDownloadsRequest(items: [.init(link: "https://example.com/third.zip")])
        let next = BrowserDownloadConfirmationState(request: request, defaultFolder: URL(fileURLWithPath: app.settings.defaultDownloadFolder))
        #expect(next.folderURL.path == folder.path)
        #expect(!next.submission.rememberFolder)
        await app.shutdown()
    }

    @Test("失败后可改目录重试，部分成功不会重复创建")
    func failureAndPartialRetry() async throws {
        let (app, root) = try await makeStore()
        let original = app.settings.defaultDownloadFolder
        let blocked = root.appendingPathComponent("file-not-directory")
        try Data("occupied".utf8).write(to: blocked)
        let state = DownloadSubmissionState()
        state.folderWasChosen = true
        state.rememberFolder = true
        #expect(!(await app.addDownload(link: "https://example.com/a.bin", name: nil, folder: blocked, startImmediately: false, submission: state)))
        #expect(state.addedIDs.isEmpty)
        #expect(app.settings.defaultDownloadFolder == original)
        let folder = root.appendingPathComponent("valid")
        #expect(await app.addDownload(link: "https://example.com/a.bin", name: nil, folder: folder, startImmediately: false, submission: state))
        #expect(app.settings.defaultDownloadFolder == folder.path)

        let partial = DownloadSubmissionState()
        partial.rememberFolder = true
        let links = "https://example.com/b.bin\nfile:///forbidden"
        let newFolder = root.appendingPathComponent("partial")
        #expect(!(await app.addDownload(link: links, name: nil, folder: newFolder, startImmediately: false, submission: partial)))
        #expect(partial.addedIDs.count == 1)
        #expect(!(await app.addDownload(link: links, name: nil, folder: newFolder, startImmediately: false, submission: partial)))
        #expect(partial.addedIDs.count == 1)
        #expect(await app.service!.snapshot().downloads.count == 2)
        #expect(app.settings.defaultDownloadFolder == folder.path)
        await app.shutdown()
    }

    @Test("设置不可用时重试不重复添加任务")
    func preferenceFailureDoesNotDuplicateDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-folder-failure-\(UUID().uuidString)")
        let app = AppStore(dataRoot: root, cacheRoot: root.appendingPathComponent("cache"), settingsStoreFactory: { root in
            throw SettingsStoreError.writeFailed(root, "测试设置不可用")
        })
        for _ in 0..<500 {
            if app.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(app.isReady)
        let original = app.settings.defaultDownloadFolder
        let state = DownloadSubmissionState()
        state.rememberFolder = true
        let folder = root.appendingPathComponent("downloads")
        for _ in 0..<2 {
            #expect(!(await app.addDownload(link: "https://example.com/test.bin", name: nil, folder: folder, startImmediately: false, submission: state)))
            #expect(state.tasksAdded)
            #expect(state.errorMessage?.contains("默认目录未保存") == true)
            #expect(await app.service!.snapshot().downloads.count == 1)
            #expect(app.settings.defaultDownloadFolder == original)
        }
        await app.shutdown()
    }

    @Test("取消草稿不写设置，无效目录 URL 不修改已有设置")
    func cancelledDraftAndInvalidPreference() async throws {
        let (app, root) = try await makeStore()
        let original = app.settings.defaultDownloadFolder
        let request = AddDownloadsRequest(items: [.init(link: "https://example.com/test.bin")])
        var draft: BrowserDownloadConfirmationState? = BrowserDownloadConfirmationState(request: request, defaultFolder: URL(fileURLWithPath: original))
        draft?.folderURL = root.appendingPathComponent("cancelled")
        draft?.submission.rememberFolder = true
        draft = nil
        let preferences = try SettingsStore(dataRoot: root)
        #expect(try await preferences.load().defaultDownloadFolder == original)
        await #expect(throws: SettingsStoreError.self) {
            _ = try await preferences.saveDefaultDownloadFolder(URL(string: "https://example.com/not-a-directory")!)
        }
        #expect(try await preferences.load().defaultDownloadFolder == original)
        await app.shutdown()
    }

    @Test("草稿保持独立，规范化路径相同不能重复设置")
    func draftAndSettingsMerge() throws {
        let state = DownloadSubmissionState()
        let folder = URL(fileURLWithPath: "/tmp/downloads")
        #expect(!state.canRemember(folder: URL(fileURLWithPath: "/tmp/other/../downloads/"), defaultFolder: folder))
        #expect(state.canRemember(folder: URL(fileURLWithPath: "/tmp/elsewhere"), defaultFolder: folder))
        var settings = AppSettingsModel.defaults()
        settings.defaultDownloadFolder = "/tmp/original"
        let draft = SettingsViewState(model: settings, perHostItems: [])
        draft.model.theme = "dark"
        draft.mergeDefaultFolder("/tmp/new")
        #expect(draft.model.defaultDownloadFolder == "/tmp/new")
        #expect(draft.model.theme == "dark")
        #expect(draft.isDirty)
        draft.model.defaultDownloadFolder = "/tmp/explicit"
        draft.mergeDefaultFolder("/tmp/newer")
        #expect(draft.model.defaultDownloadFolder == "/tmp/explicit")
    }
}
