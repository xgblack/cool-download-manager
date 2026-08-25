import AppKit
import SwiftUI
import CoolDownloadCore

@MainActor
final class AppCoordinator: NSObject, ObservableObject {
    @Published var isAddDownloadPresented = false
    @Published var isSettingsPresented = false
    @Published var isQueuePresented = false
    @Published var isBatchDownloadPresented = false
    @Published var isPerHostSettingsPresented = false
    @Published var isCategoryPresented = false
    @Published var detailID: DownloadID?
    @Published var checksumIDs: [DownloadID] = []
    @Published var pendingURLText = ""
    @Published var noticeMessage: String?

    let store: AppStore
    let mainViewState = MainViewState()
    private var menuBarController: MenuBarController?
    private weak var mainWindow: NSWindow?

    init(store: AppStore) {
        self.store = store
        super.init()
    }

    func attachMenuBar() {
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(
            actions: .init(
                showMain: { [weak self] in self?.showMainWindow() },
                newDownload: { [weak self] in self?.presentAddDownload() },
                settings: { [weak self] in self?.presentSettings() },
                quit: { NSApp.terminate(nil) }
            )
        )
    }

    func updateMenuBar() {
        if store.settings.useSystemTray {
            attachMenuBar()
        } else {
            menuBarController?.remove()
            menuBarController = nil
        }
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.title = "下载管理器"
        window.minSize = NSSize(width: 900, height: 560)
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = mainWindow ?? NSApp.windows.first { window in
            window.title == "下载管理器" || window.styleMask.contains(.titled)
        }
        mainWindow = window
        window?.makeKeyAndOrderFront(nil)
    }

    func presentAddDownload(fromClipboard: Bool = false) {
        showMainWindow()
        if fromClipboard {
            pendingURLText = NSPasteboard.general.string(forType: .string) ?? ""
        }
        isAddDownloadPresented = true
    }

    func presentSettings() {
        showMainWindow()
        isSettingsPresented = true
    }

    func presentQueues() {
        showMainWindow()
        isQueuePresented = true
    }

    func presentBatchDownload() {
        showMainWindow()
        isBatchDownloadPresented = true
    }

    func presentPerHostSettings() {
        showMainWindow()
        isPerHostSettingsPresented = true
    }

    func presentCategories() {
        showMainWindow()
        isCategoryPresented = true
    }

    func openDetail(for id: DownloadID) {
        detailID = id
    }

    func closeDetail() {
        detailID = nil
    }

    func presentChecksum(for ids: [DownloadID]) {
        guard !ids.isEmpty else { return }
        showMainWindow()
        checksumIDs = ids
    }

    func closeChecksum() {
        checksumIDs = []
    }

    func showNotice(_ message: String) {
        showMainWindow()
        noticeMessage = message
    }

    func checkForUpdates() {
        showMainWindow()
        noticeMessage = "正在检查更新…"
        let endpoint = URL(string: "https://api.github.com/repos/xgblack/cool-download-manager/releases/latest")!
        Task { @MainActor [weak self] in
            do {
                var request = URLRequest(url: endpoint)
                request.setValue("CoolDownloadManager/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                struct Release: Decodable { let tagName: String; let htmlURL: String? }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let release = try decoder.decode(Release.self, from: data)
                let link = release.htmlURL.map { "\n\($0)" } ?? ""
                self?.noticeMessage = "最新版本：\(release.tagName)\(link)"
            } catch {
                self?.noticeMessage = "更新检查失败：\(error.localizedDescription)"
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func openFile(_ record: DownloadRecord) {
        guard record.status == .completed else { return }
        NSWorkspace.shared.open(record.destinationURL)
    }

    func revealFile(_ record: DownloadRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.destinationURL])
    }
}
