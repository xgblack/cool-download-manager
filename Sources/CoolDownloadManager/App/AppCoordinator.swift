import AppKit
import SwiftUI
import CoolDownloadCore
import CoolDownloadIntegration

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
    @Published private(set) var activeBrowserRequest: AddDownloadsRequest?

    let store: AppStore
    let mainViewState = MainViewState()
    private var menuBarController: MenuBarController?
    private let utilityPanels = UtilityPanelController()
    private weak var mainWindow: NSWindow?
    private weak var settingsWindow: NSWindow?
    private var openMainWindowAction: (() -> Void)?
    private var openSettingsWindowAction: (() -> Void)?
    private var mainWindowCreationInFlight = false
    private var focusMainWindowWhenRegistered = false
    private var focusSettingsWindowWhenRegistered = false
    private var queuedBrowserRequests: [AddDownloadsRequest] = []

    init(store: AppStore) {
        self.store = store
        super.init()
        store.onBrowserDownloadRequest = { [weak self] request in
            self?.presentBrowserDownload(request)
        }
        store.downloadList.onDownloadCompleted = { [weak self] record in
            self?.handleDownloadCompleted(record)
        }
    }

    private func handleDownloadCompleted(_ record: DownloadRecord) {
        closeProgressPanel(for: record.id)
        let shouldShow = record.taskSettings?.showCompletionDialog
            ?? store.settings.showDownloadCompletionDialog
        guard shouldShow else {
            store.downloadList.acknowledgeCompletion()
            return
        }
        showCompletionPanel(
            for: record,
            focus: store.settings.focusDownloadCompletionDialogOnFinish
        )
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
        window.titlebarSeparatorStyle = .automatic
        if store.settings.mergeTopBarWithTitleBar {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .unified
        }
    }

    func applyTheme(_ rawValue: String, to window: NSWindow?) {
        window?.appearance = AppTheme(rawValue).windowAppearance
    }

    func applyThemeToMainWindow(_ rawValue: String) {
        applyTheme(rawValue, to: resolvedMainWindow())
    }

    func applyThemeToSettingsWindow(_ rawValue: String) {
        applyTheme(rawValue, to: resolvedSettingsWindow())
    }

    func configureMainWindowOpener(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func configureSettingsWindowOpener(_ action: @escaping () -> Void) {
        openSettingsWindowAction = action
    }

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindowCreationInFlight = false
        let mainWindowIdentifier = "com.cooldownloadmanager.main-window"
        NSApp.windows
            .filter {
                $0 !== window
                    && $0.windowNumber != 0
                    && $0.identifier?.rawValue == mainWindowIdentifier
            }
            .forEach { $0.close() }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier(mainWindowIdentifier)
        window.title = "酷的下载管理器"
        window.minSize = NSSize(width: 1_200, height: 640)
        applyWindowSettings()
        applyTheme(store.settings.theme, to: window)
        if focusMainWindowWhenRegistered {
            focusMainWindowWhenRegistered = false
            focusMainWindow(window)
        }
    }

    func showMainWindow() {
        _ = handleApplicationReopen()
    }

    /// Handles a Dock/application reopen event when the SwiftUI scene is
    /// already wired. Returning false lets the application delegate fall back
    /// to SwiftUI's default scene creation during the initial launch race.
    func handleApplicationReopen() -> Bool {
        if let window = resolvedMainWindow() {
            focusMainWindow(window)
            return true
        }

        guard let openMainWindowAction else { return false }
        guard !mainWindowCreationInFlight else { return true }
        // WindowGroup can release its NSWindow after the user closes it.
        // Ask SwiftUI to create a new one, then focus it after attachment.
        mainWindowCreationInFlight = true
        focusMainWindowWhenRegistered = true
        openMainWindowAction()
        DispatchQueue.main.async { [weak self] in
            self?.focusMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.resolvedMainWindow() == nil else { return }
            self.mainWindowCreationInFlight = false
        }
        return true
    }

    func registerSettingsWindow(_ window: NSWindow?) {
        guard let window else { return }
        settingsWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("com.cooldownloadmanager.settings-window")
        window.title = "下载管理器"
        // Keep the settings editor below the native title bar. Its custom
        // section header contains navigation controls and must not overlap the
        // traffic-light region when the window is resized.
        window.styleMask.remove(.fullSizeContentView)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 920, height: 640)
        applyTheme(store.settings.theme, to: window)
        if focusSettingsWindowWhenRegistered {
            focusSettingsWindowWhenRegistered = false
            focusSettingsWindow(window)
        }
    }

    private func resolvedSettingsWindow() -> NSWindow? {
        if let settingsWindow, settingsWindow.windowNumber != 0 {
            return settingsWindow
        }
        settingsWindow = nil
        return NSApp.windows.first { window in
            window.windowNumber != 0
                && window.identifier?.rawValue == "com.cooldownloadmanager.settings-window"
        }
    }

    private func focusSettingsWindow(_ window: NSWindow? = nil) {
        guard let window = window ?? resolvedSettingsWindow() else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func showSettingsWindow() {
        guard let window = resolvedSettingsWindow() else {
            focusSettingsWindowWhenRegistered = true
            openSettingsWindowAction?()
            DispatchQueue.main.async { [weak self] in
                self?.focusSettingsWindow()
            }
            return
        }
        focusSettingsWindow(window)
    }

    private func resolvedMainWindow() -> NSWindow? {
        if let mainWindow, mainWindow.windowNumber != 0 {
            return mainWindow
        }
        mainWindow = nil
        return NSApp.windows.first { window in
            window.windowNumber != 0
                && window.identifier?.rawValue == "com.cooldownloadmanager.main-window"
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
        activeBrowserRequest = nil
        if fromClipboard {
            pendingURLText = NSPasteboard.general.string(forType: .string) ?? ""
        }
        mainSheet = .addDownload
    }

    private func presentBrowserDownload(_ request: AddDownloadsRequest) {
        guard !request.items.isEmpty else { return }
        guard mainSheet == nil, activeBrowserRequest == nil else {
            queuedBrowserRequests.append(request)
            return
        }

        activeBrowserRequest = request
        pendingURLText = ""
        mainViewState.urlText = request.items.map(\.link).joined(separator: "\n")
        mainViewState.nameText = request.items.count == 1
            ? request.items[0].suggestedName ?? ""
            : ""
        mainViewState.folderURL = URL(
            fileURLWithPath: store.settings.defaultDownloadFolder,
            isDirectory: true
        )
        mainViewState.queueID = nil
        mainViewState.categoryID = nil
        mainViewState.startImmediately = true
        showMainWindow()
        mainSheet = .addDownload
    }

    func presentSettings() {
        settingsDestination = .section(.general)
        showSettingsWindow()
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
        showSettingsWindow()
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
        activeBrowserRequest = nil
        guard !queuedBrowserRequests.isEmpty else { return }
        let next = queuedBrowserRequests.removeFirst()
        DispatchQueue.main.async { [weak self] in
            self?.presentBrowserDownload(next)
        }
    }

    func showProgressPanel(for record: DownloadRecord, focus: Bool) {
        utilityPanels.showProgress(record: record, store: store.downloadList, coordinator: self, focus: focus)
    }

    func closeProgressPanel(for id: DownloadID) {
        utilityPanels.closeProgress(for: id)
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
    private var progressRecordID: DownloadID?
    private var completionPanel: NSPanel?
    private var completionClose: (() -> Void)?

    func showProgress(record: DownloadRecord, store: DownloadListStore, coordinator: AppCoordinator, focus: Bool) {
        let content = DownloadProgressView(
            record: record,
            store: store,
            coordinator: coordinator,
            onClose: { [weak self] in self?.hideProgressPanel() }
        )
        let panel = panel(
            existing: progressPanel,
            title: "下载进度",
            size: NSSize(width: 820, height: 540),
            floatsAboveNormalWindows: false,
            content: content
        )
        progressPanel = panel
        progressRecordID = record.id
        present(panel, focus: focus)
    }

    func closeProgress(for id: DownloadID) {
        guard progressRecordID == id else { return }
        hideProgressPanel()
    }

    func showCompletion(record: DownloadRecord, store: DownloadListStore, coordinator: AppCoordinator, focus: Bool) {
        let close: () -> Void = { [weak self, weak store] in
            self?.hideCompletionPanel(store: store)
        }
        let content = CompletionView(
            record: record,
            store: store,
            coordinator: coordinator,
            onClose: close
        )
        completionClose = close
        let panel = panel(
            existing: completionPanel,
            title: "下载完成",
            size: NSSize(width: 640, height: 360),
            floatsAboveNormalWindows: false,
            content: content
        )
        completionPanel = panel
        // Put the completion panel in front once without keeping it at the
        // floating window level. Later user activity can cover it normally.
        present(panel, focus: focus, orderFrontRegardless: true)
    }

    private func panel<Content: View>(
        existing: NSPanel?,
        title: String,
        size: NSSize,
        floatsAboveNormalWindows: Bool,
        content: Content
    ) -> NSPanel {
        let panel = existing ?? NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = floatsAboveNormalWindows
        panel.level = floatsAboveNormalWindows ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.minSize = size
        panel.setContentSize(size)
        panel.contentViewController = LiquidGlassPanelViewController(rootView: content)
        return panel
    }

    private func present(_ panel: NSPanel, focus: Bool, orderFrontRegardless: Bool = false) {
        if !panel.isVisible {
            panel.center()
        }
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else if orderFrontRegardless {
            panel.orderFrontRegardless()
        } else {
            panel.orderFront(nil)
        }
    }

    private func hideProgressPanel() {
        progressPanel?.orderOut(nil)
        progressRecordID = nil
    }

    private func hideCompletionPanel(store: DownloadListStore?) {
        store?.acknowledgeCompletion()
        completionPanel?.orderOut(nil)
        completionClose = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === progressPanel {
            progressRecordID = nil
        }
        if sender === completionPanel {
            completionClose?()
            completionClose = nil
        }
        sender.orderOut(nil)
        return false
    }
}
