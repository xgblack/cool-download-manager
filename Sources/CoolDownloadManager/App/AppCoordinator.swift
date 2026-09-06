import AppKit
import SwiftUI
import Sparkle
import UniformTypeIdentifiers
import CoolDownloadCore
import CoolDownloadIntegration

enum MainDestination: Hashable {
    case downloadDetail(DownloadID)
    case queues
    case categories
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

private final class BrowserConfirmationSession {
    let request: AddDownloadsRequest

    init(request: AddDownloadsRequest) {
        self.request = request
    }
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
    private var browserRequests = BrowserDownloadRequestQueue()
    private var browserConfirmationSession: BrowserConfirmationSession?
    private var updaterController: SPUStandardUpdaterController?
    private var updaterStarted = false

    init(store: AppStore) {
        self.store = store
        super.init()
        store.onBrowserDownloadRequest = { [weak self] request in
            self?.presentBrowserDownload(request)
        }
        store.downloadList.onDownloadStarted = { [weak self] record in
            self?.handleDownloadStarted(record)
        }
        store.downloadList.onDownloadCompleted = { [weak self] record in
            self?.handleDownloadCompleted(record)
        }
    }

    private func handleDownloadStarted(_ record: DownloadRecord) {
        store.downloadList.acknowledgeProgress()
        guard store.settings.showDownloadProgressDialog else { return }
        guard record.status == .preparing || record.status == .downloading || record.status == .retrying else {
            return
        }
        showProgressPanel(
            for: record,
            focus: store.settings.focusDownloadProgressDialogOnStart
        )
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
        window.title = "设置"
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
        if fromClipboard {
            pendingURLText = NSPasteboard.general.string(forType: .string) ?? ""
        }
        mainSheet = .addDownload
    }

    private func presentBrowserDownload(_ request: AddDownloadsRequest) {
        guard !request.items.isEmpty else { return }
        guard let next = browserRequests.enqueue(request) else { return }
        beginBrowserConfirmation(for: next)
    }

    private func beginBrowserConfirmation(for request: AddDownloadsRequest) {
        let session = BrowserConfirmationSession(request: request)
        browserConfirmationSession = session
        activeBrowserRequest = request
        showBrowserConfirmation(session)
    }

    private func showBrowserConfirmation(_ session: BrowserConfirmationSession) {
        let request = session.request
        utilityPanels.showBrowserConfirmation(
            request: request,
            defaultFolder: URL(
                fileURLWithPath: store.settings.defaultDownloadFolder,
                isDirectory: true
            ),
            queues: store.queues,
            categories: store.categories,
            onChooseFolder: { [weak self] in
                self?.utilityPanels.chooseBrowserFolder()
            },
            onCancel: { [weak self] in
                self?.finishBrowserConfirmation(session, outcome: .cancelled)
            },
            onAdd: { [weak self] state, queueID, categoryID, startImmediately in
                self?.addBrowserDownload(
                    session: session,
                    state: state,
                    queueID: queueID,
                    categoryID: categoryID,
                    startImmediately: startImmediately
                )
            }
        )
    }

    private func addBrowserDownload(
        session: BrowserConfirmationSession,
        state: BrowserDownloadConfirmationState,
        queueID: DownloadID?,
        categoryID: DownloadID?,
        startImmediately: Bool
    ) {
        guard browserConfirmationSession === session,
              browserRequests.active == session.request,
              state.request == session.request else { return }
        store.addDownload(
            link: state.urlText,
            name: state.nameText,
            folder: state.folderURL,
            queueID: queueID,
            categoryID: categoryID,
            startImmediately: startImmediately,
            integrationItems: session.request.items
        )
        finishBrowserConfirmation(session, outcome: .completed)
    }

    private enum BrowserConfirmationOutcome {
        case cancelled
        case completed
    }

    private func finishBrowserConfirmation(
        _ session: BrowserConfirmationSession,
        outcome: BrowserConfirmationOutcome
    ) {
        guard browserConfirmationSession === session,
              browserRequests.active == session.request else { return }
        let next: AddDownloadsRequest?
        switch outcome {
        case .cancelled:
            next = browserRequests.cancel(session.request)
        case .completed:
            next = browserRequests.complete(session.request)
        }
        // Invalidate callbacks from this view before tearing down the panel.
        // A late SwiftUI/AppKit event must never finish a newer session.
        browserConfirmationSession = nil
        utilityPanels.closeBrowserConfirmation()
        activeBrowserRequest = next
        guard let next else { return }
        // Let the current button/window-close event finish before presenting
        // the next request.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.browserConfirmationSession == nil,
                  self.browserRequests.active == next else { return }
            self.beginBrowserConfirmation(for: next)
        }
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

    /// Starts Sparkle only for a packaged application that declares a feed.
    /// SwiftPM/Xcode development launches do not have the release Info.plist,
    /// so they must remain usable without an updater configuration.
    func startUpdaterIfConfigured() {
        guard !updaterStarted else { return }
        guard let feedString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feedString),
              let scheme = feedURL.scheme?.lowercased(),
              scheme == "https" else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        updaterStarted = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        showMainWindow()
        startUpdaterIfConfigured()
        guard let updaterController else {
            showNotice("当前开发构建未配置 Sparkle 更新源。")
            return
        }
        updaterController.checkForUpdates(nil)
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

/// Owns browser requests independently from MainSheet. Cancellation leaves a
/// short-lived tombstone so HTTP/native fallback duplicates cannot reopen a
/// confirmation immediately after the user dismisses it.
struct BrowserDownloadRequestQueue: Equatable {
    static let cancellationSuppressionDuration: TimeInterval = 10

    /// The browser and native-messaging paths can describe one download with
    /// different presentation metadata. Compare only the source identity so a
    /// fallback request cannot become a second confirmation session.
    private struct BrowserDownloadRequestKey: Equatable {
        private struct HeaderKey: Equatable {
            let name: String
            let value: String
        }

        private struct ItemKey: Equatable {
            let type: String
            let link: String
            let headers: [HeaderKey]
            let downloadPage: String?
        }

        private let items: [ItemKey]

        init(_ request: AddDownloadsRequest) {
            items = request.items.map { item in
                ItemKey(
                    type: item.type.rawValue.lowercased(),
                    link: Self.normalizedURL(item.link),
                    headers: Self.normalizedHeaders(item.headers),
                    downloadPage: Self.normalizedOptionalURL(item.downloadPage)
                )
            }
        }

        /// HTTP and native-messaging integration can omit optional source
        /// metadata on one path. Treat those requests as the same intent,
        /// while retaining separate requests when both paths provide
        /// conflicting credentials or referrers.
        func isCompatible(with other: Self) -> Bool {
            guard items.count == other.items.count else { return false }
            return zip(items, other.items).allSatisfy { lhs, rhs in
                lhs.type == rhs.type
                    && lhs.link == rhs.link
                    && optionalHeadersAreCompatible(lhs.headers, rhs.headers)
                    && optionalValuesAreCompatible(lhs.downloadPage, rhs.downloadPage)
            }
        }

        private func optionalHeadersAreCompatible(
            _ lhs: [HeaderKey],
            _ rhs: [HeaderKey]
        ) -> Bool {
            lhs.isEmpty || rhs.isEmpty || lhs == rhs
        }

        private func optionalValuesAreCompatible(
            _ lhs: String?,
            _ rhs: String?
        ) -> Bool {
            lhs == nil || rhs == nil || lhs == rhs
        }

        private static func normalizedOptionalURL(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return normalizedURL(trimmed)
        }

        private static func normalizedURL(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  var components = URLComponents(string: trimmed) else {
                return trimmed
            }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            return components.string ?? trimmed
        }

        private static func normalizedHeaders(
            _ headers: [String: String]?
        ) -> [HeaderKey] {
            (headers ?? [:])
                .map { name, value in
                    HeaderKey(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        value: value
                    )
                }
                .sorted {
                    if $0.name != $1.name {
                        return $0.name < $1.name
                    }
                    return $0.value < $1.value
                }
        }
    }

    private struct CancellationTombstone: Equatable {
        let key: BrowserDownloadRequestKey
        let expiresAt: Date
    }

    private(set) var active: AddDownloadsRequest?
    private(set) var pending: [AddDownloadsRequest] = []
    private var cancellationTombstones: [CancellationTombstone] = []

    mutating func enqueue(
        _ request: AddDownloadsRequest,
        now: Date = Date()
    ) -> AddDownloadsRequest? {
        pruneTombstones(at: now)
        guard !request.items.isEmpty else { return nil }
        let key = BrowserDownloadRequestKey(request)
        guard !isCancellationSuppressed(key, at: now) else { return nil }
        guard active.map({ !BrowserDownloadRequestKey($0).isCompatible(with: key) }) ?? true,
              !pending.contains(where: {
                  BrowserDownloadRequestKey($0).isCompatible(with: key)
              }) else {
            return nil
        }
        guard active == nil else {
            pending.append(request)
            return nil
        }
        active = request
        return request
    }

    mutating func cancel(
        _ request: AddDownloadsRequest,
        now: Date = Date()
    ) -> AddDownloadsRequest? {
        finish(request, suppressLateDuplicate: true, now: now)
    }

    mutating func complete(
        _ request: AddDownloadsRequest,
        now: Date = Date()
    ) -> AddDownloadsRequest? {
        finish(request, suppressLateDuplicate: false, now: now)
    }

    mutating func finish(
        _ request: AddDownloadsRequest,
        suppressLateDuplicate: Bool = false,
        now: Date = Date()
    ) -> AddDownloadsRequest? {
        pruneTombstones(at: now)
        guard let activeRequest = active, activeRequest == request else {
            return nil
        }
        let activeKey = BrowserDownloadRequestKey(activeRequest)
        if suppressLateDuplicate {
            cancellationTombstones.removeAll {
                $0.key.isCompatible(with: activeKey)
            }
            cancellationTombstones.append(CancellationTombstone(
                key: activeKey,
                expiresAt: now.addingTimeInterval(Self.cancellationSuppressionDuration)
            ))
        }
        // A duplicate may already be queued from another integration path.
        // It must not be promoted after this session is dismissed or completed.
        pending.removeAll {
            BrowserDownloadRequestKey($0).isCompatible(with: activeKey)
        }
        active = pending.isEmpty ? nil : pending.removeFirst()
        return active
    }

    private mutating func pruneTombstones(at now: Date) {
        cancellationTombstones.removeAll { $0.expiresAt <= now }
    }

    private func isCancellationSuppressed(
        _ key: BrowserDownloadRequestKey,
        at now: Date
    ) -> Bool {
        cancellationTombstones.contains {
            $0.key.isCompatible(with: key) && $0.expiresAt > now
        }
    }
}

@MainActor
private final class UtilityPanelController: NSObject, NSWindowDelegate {
    private var progressPanel: NSPanel?
    private var progressRecordID: DownloadID?
    private var completionPanel: NSPanel?
    private var completionClose: (() -> Void)?
    private var browserConfirmationPanel: NSPanel?
    private var browserConfirmationState: BrowserDownloadConfirmationState?
    private var browserConfirmationClose: (() -> Void)?
    private var browserFolderPanel: NSOpenPanel?

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
        // Browser-triggered downloads may arrive while another app is active;
        // order the panel in front without forcing activation when focus is off.
        present(panel, focus: focus, orderFrontRegardless: true)
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

    func showBrowserConfirmation(
        request: AddDownloadsRequest,
        defaultFolder: URL,
        queues: [IntegrationQueue],
        categories: [DownloadCategory],
        onChooseFolder: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onAdd: @escaping (BrowserDownloadConfirmationState, DownloadID?, DownloadID?, Bool) -> Void
    ) {
        // Each confirmation owns its panel. Reusing an NSWindow lets a stale
        // close event from the previous request target the next request.
        dismissBrowserConfirmationPanel()
        let state = BrowserDownloadConfirmationState(
            request: request,
            defaultFolder: defaultFolder
        )
        browserConfirmationState = state
        browserConfirmationClose = onCancel
        let content = BrowserDownloadConfirmationView(
            state: state,
            queues: queues,
            categories: categories,
            onChooseFolder: onChooseFolder,
            onCancel: onCancel,
            onAdd: { queueID, categoryID, startImmediately in
                onAdd(state, queueID, categoryID, startImmediately)
            }
        )
        let panel = panel(
            existing: nil,
            title: "确认下载",
            size: NSSize(width: 700, height: 620),
            floatsAboveNormalWindows: false,
            content: content
        )
        panel.identifier = NSUserInterfaceItemIdentifier(
            "com.cooldownloadmanager.browser-confirmation"
        )
        browserConfirmationPanel = panel
        present(panel, focus: true, orderFrontRegardless: true)
    }

    func chooseBrowserFolder() {
        guard let panel = browserConfirmationPanel,
              let state = browserConfirmationState else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.folder]
        openPanel.directoryURL = state.folderURL
        browserFolderPanel = openPanel
        openPanel.beginSheetModal(for: panel) { [weak self] response in
            defer {
                if self?.browserFolderPanel === openPanel {
                    self?.browserFolderPanel = nil
                }
            }
            guard response == .OK, let url = openPanel.url else { return }
            guard self?.browserConfirmationState === state else { return }
            state.folderURL = url
        }
    }

    private func panel<Content: View>(
        existing: NSPanel?,
        title: String,
        size: NSSize,
        floatsAboveNormalWindows: Bool,
        content: Content
    ) -> NSPanel {
        let panel = existing ?? UtilityPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // Keep the transparent title bar inside the glass surface so the
            // traffic-light controls do not float above the panel boundary.
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
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
        panel.isMovableByWindowBackground = true
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

    func closeBrowserConfirmation() {
        dismissBrowserConfirmationPanel()
    }

    private func dismissBrowserConfirmationPanel() {
        let folderPanel = browserFolderPanel
        browserFolderPanel = nil
        browserConfirmationState = nil
        browserConfirmationClose = nil
        folderPanel?.cancel(nil)
        guard let panel = browserConfirmationPanel else { return }
        browserConfirmationPanel = nil
        panel.delegate = nil
        panel.contentViewController = nil
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.identifier?.rawValue == "com.cooldownloadmanager.browser-confirmation" {
            guard sender === browserConfirmationPanel else {
                // This is a retired panel. It must not invoke the callback
                // belonging to the currently visible confirmation.
                sender.orderOut(nil)
                return false
            }
            let close = browserConfirmationClose
            if let close {
                close()
            } else {
                dismissBrowserConfirmationPanel()
            }
            return false
        }
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

enum UtilityPanelMouseTarget: Equatable {
    case systemWindowButton
    case interactiveContent
    case emptyHeader
    case nonHeaderContent
}

enum UtilityPanelEventRouting {
    static func shouldBeginDrag(for target: UtilityPanelMouseTarget) -> Bool {
        target == .emptyHeader
    }
}

/// Captures only the empty header area before SwiftUI content receives the
/// mouse event and applies the pointer delta directly to the panel frame.
private final class UtilityPanel: NSPanel {
    private let fallbackHeaderHeight: CGFloat = 64
    private let minimumHeaderHeight: CGFloat = 44
    private let maximumHeaderHeight: CGFloat = 96

    private struct DragState {
        let startMouseLocation: NSPoint
        let startOrigin: NSPoint
    }

    private var dragState: DragState?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard UtilityPanelEventRouting.shouldBeginDrag(for: mouseTarget(for: event)) else {
                super.sendEvent(event)
                return
            }
            dragState = DragState(
                startMouseLocation: NSEvent.mouseLocation,
                startOrigin: frame.origin
            )
        case .leftMouseDragged:
            guard let dragState else {
                super.sendEvent(event)
                return
            }
            let current = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(
                x: dragState.startOrigin.x + current.x - dragState.startMouseLocation.x,
                y: dragState.startOrigin.y + current.y - dragState.startMouseLocation.y
            ))
        case .leftMouseUp:
            guard dragState != nil else {
                super.sendEvent(event)
                return
            }
            self.dragState = nil
        default:
            super.sendEvent(event)
        }
    }

    override func resignMain() {
        dragState = nil
        super.resignMain()
    }

    override func orderOut(_ sender: Any?) {
        dragState = nil
        super.orderOut(sender)
    }

    private func mouseTarget(for event: NSEvent) -> UtilityPanelMouseTarget {
        guard let contentView else { return .nonHeaderContent }
        let point = contentView.convert(event.locationInWindow, from: nil)

        if standardWindowButtonFrames.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(event.locationInWindow) }) {
            return .systemWindowButton
        }

        guard movableHeaderRect(for: contentView).contains(point) else {
            return .nonHeaderContent
        }

        guard let hitView = contentView.hitTest(point) else {
            return .emptyHeader
        }
        return containsInteractiveView(hitView, contentView: contentView)
            ? .interactiveContent
            : .emptyHeader
    }

    private var standardWindowButtonFrames: [NSRect] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = standardWindowButton(type) else { return nil }
            return button.convert(button.bounds, to: nil)
        }
    }

    private func movableHeaderRect(for contentView: NSView) -> NSRect {
        let bounds = contentView.bounds
        guard bounds.height > minimumHeaderHeight else { return .zero }

        // `contentLayoutRect` tracks the actual title-bar geometry across
        // full-size content layouts. Fall back only when AppKit has not laid
        // out the window yet (for example during the first event).
        let inferredHeight = frame.height - contentLayoutRect.height
        let resolvedHeaderHeight = (minimumHeaderHeight...maximumHeaderHeight).contains(inferredHeight)
            ? inferredHeight
            : fallbackHeaderHeight
        let headerHeight = min(
            bounds.height,
            max(
                minimumHeaderHeight,
                resolvedHeaderHeight
            )
        )
        return NSRect(
            x: bounds.minX,
            y: bounds.maxY - headerHeight,
            width: bounds.width,
            height: headerHeight
        )
    }

    private func containsInteractiveView(_ view: NSView, contentView: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current, candidate !== contentView {
            if !candidate.mouseDownCanMoveWindow
                || candidate is NSControl
                || candidate is NSTextView
                || candidate is NSScrollView
                || candidate is NSClipView {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
