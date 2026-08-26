import AppKit
import SwiftUI
import CoolDownloadCore

enum MainDestination: Hashable {
    case downloadDetail(DownloadID)
    case queues
    case categories
    case appInfo(MainInfoPage)
}

enum MainInfoPage: String, Hashable {
    case thirdParty
    case translators
}

enum MainSheet: Identifiable, Equatable {
    case addDownload
    case batchDownload
    case checksum([DownloadID])

    var id: String {
        switch self {
        case .addDownload: return "add-download"
        case .batchDownload: return "batch-download"
        case .checksum(let ids): return "checksum-\(ids.map(String.init).joined(separator: ","))"
        }
    }
}

enum SettingsDestination: Equatable {
    case section(SettingsSection)
    case perHost
}

enum SettingsRoute: Hashable {
    case perHost
}

@MainActor
final class AppCoordinator: NSObject, ObservableObject {
    @Published var mainPath: [MainDestination] = []
    @Published var mainSheet: MainSheet?
    @Published var settingsDestination: SettingsDestination = .section(.general)
    @Published var pendingURLText = ""
    @Published var noticeMessage: String?

    let store: AppStore
    let mainViewState = MainViewState()
    private var menuBarController: MenuBarController?
    private let utilityPanels = UtilityPanelController()
    private weak var mainWindow: NSWindow?
    private var openMainWindowAction: (() -> Void)?
    private var focusMainWindowWhenRegistered = false

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
        attachMenuBar()
    }

    func applyWindowSettings() {
        guard let window = mainWindow else { return }
        if store.settings.mergeTopBarWithTitleBar {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
        } else {
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .automatic
        }
    }

    func configureMainWindowOpener(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("com.cooldownloadmanager.main-window")
        window.title = "酷的下载管理器"
        window.minSize = NSSize(width: 900, height: 560)
        applyWindowSettings()
        if focusMainWindowWhenRegistered {
            focusMainWindowWhenRegistered = false
            focusMainWindow(window)
        }
    }

    func showMainWindow() {
        guard let window = resolvedMainWindow() else {
            // WindowGroup can release its NSWindow after the user closes it.
            // Ask SwiftUI to create a new one, then focus it after attachment.
            focusMainWindowWhenRegistered = true
            openMainWindowAction?()
            DispatchQueue.main.async { [weak self] in
                self?.focusMainWindow()
            }
            return
        }
        focusMainWindow(window)
    }

    private func resolvedMainWindow() -> NSWindow? {
        if let mainWindow, mainWindow.windowNumber != 0 {
            return mainWindow
        }
        mainWindow = nil
        return NSApp.windows.first { window in
            window.identifier?.rawValue == "com.cooldownloadmanager.main-window"
        }
    }

    private func focusMainWindow(_ window: NSWindow? = nil) {
        guard let window = window ?? resolvedMainWindow() else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func presentAddDownload(fromClipboard: Bool = false) {
        showMainWindow()
        if fromClipboard {
            pendingURLText = NSPasteboard.general.string(forType: .string) ?? ""
        }
        mainSheet = .addDownload
    }

    func presentSettings() {
        // SwiftUI's Settings scene installs the standard macOS action.
        settingsDestination = .section(.general)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func presentQueues() {
        showMainWindow()
        mainPath = [.queues]
    }

    func presentBatchDownload() {
        showMainWindow()
        mainSheet = .batchDownload
    }

    func presentPerHostSettings() {
        settingsDestination = .perHost
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func presentCategories() {
        showMainWindow()
        mainPath = [.categories]
    }

    func openDetail(for id: DownloadID) {
        showMainWindow()
        mainPath = [.downloadDetail(id)]
    }

    func closeDetail() {
        if case .downloadDetail = mainPath.last {
            mainPath.removeLast()
        }
    }

    func presentChecksum(for ids: [DownloadID]) {
        guard !ids.isEmpty else { return }
        showMainWindow()
        mainSheet = .checksum(ids)
    }

    func closeChecksum() {
        if case .checksum = mainSheet {
            mainSheet = nil
        }
    }

    func closeMainSheet() {
        mainSheet = nil
    }

    func showProgressPanel(for record: DownloadRecord, focus: Bool) {
        utilityPanels.showProgress(record: record, store: store.downloadList, coordinator: self, focus: focus)
    }

    func showCompletionPanel(for record: DownloadRecord, focus: Bool) {
        utilityPanels.showCompletion(record: record, store: store.downloadList, coordinator: self, focus: focus)
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

@MainActor
private final class UtilityPanelController: NSObject, NSWindowDelegate {
    private var progressPanel: NSPanel?
    private var completionPanel: NSPanel?
    private var completionClose: (() -> Void)?

    func showProgress(record: DownloadRecord, store: DownloadListStore, coordinator: AppCoordinator, focus: Bool) {
        let content = DownloadProgressView(
            record: record,
            store: store,
            coordinator: coordinator,
            onClose: { [weak self] in self?.progressPanel?.orderOut(nil) }
        )
        let panel = panel(
            existing: progressPanel,
            title: "下载进度",
            size: NSSize(width: 720, height: 520),
            content: content
        )
        progressPanel = panel
        present(panel, focus: focus)
    }

    func showCompletion(record: DownloadRecord, store: DownloadListStore, coordinator: AppCoordinator, focus: Bool) {
        let content = CompletionView(
            record: record,
            store: store,
            coordinator: coordinator,
            onClose: { [weak self, weak store] in
                store?.acknowledgeCompletion()
                self?.completionPanel?.orderOut(nil)
            }
        )
        completionClose = { [weak self, weak store] in
            store?.acknowledgeCompletion()
            self?.completionPanel?.orderOut(nil)
        }
        let panel = panel(
            existing: completionPanel,
            title: "下载完成",
            size: NSSize(width: 580, height: 330),
            content: content
        )
        completionPanel = panel
        present(panel, focus: focus)
    }

    private func panel<Content: View>(
        existing: NSPanel?,
        title: String,
        size: NSSize,
        content: Content
    ) -> NSPanel {
        let panel = existing ?? NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = size
        panel.setContentSize(size)
        panel.contentViewController = NSHostingController(rootView: AnyView(content))
        return panel
    }

    private func present(_ panel: NSPanel, focus: Bool) {
        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.center()
            panel.orderFrontRegardless()
        }
        guard focus else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === completionPanel {
            completionClose?()
            completionClose = nil
        }
        sender.orderOut(nil)
        return false
    }
}
