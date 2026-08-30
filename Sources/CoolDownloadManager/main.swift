import SwiftUI
import AppKit

@MainActor
final class CoolDownloadManagerAppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?
    weak var coordinator: AppCoordinator?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the normal macOS application identity: Dock icon, Cmd+Tab, and
        // a regular application menu remain available while the window is
        // closed and downloads continue in the background.
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "com.cooldownloadmanager.settings-window" else {
            return
        }
        window.title = "下载管理器"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // During very early launch SwiftUI may not have attached the scene
        // content yet. Let its default behavior create the first window in
        // that narrow interval; once the coordinator is wired, it owns all
        // reopen/focus behavior to prevent a second WindowGroup instance.
        guard let coordinator, coordinator.handleApplicationReopen() else {
            return true
        }
        // The coordinator owns reopening. Returning true would also ask
        // SwiftUI/AppKit to create a window and can produce a duplicate.
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let terminationHandler else { return .terminateNow }
        terminationInProgress = true
        Task { @MainActor [weak self] in
            await terminationHandler()
            self?.terminationHandler = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CoolDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(CoolDownloadManagerAppDelegate.self)
    private var appDelegate
    @Environment(\.openWindow)
    private var openWindow
    @StateObject private var store: AppStore
    @StateObject private var coordinator: AppCoordinator

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: AppCoordinator(store: store))
    }

    var body: some Scene {
        WindowGroup("酷的下载管理器", id: "main") {
            MainView(store: store, coordinator: coordinator, viewState: coordinator.mainViewState)
                .background {
                    WindowAccessor { window in
                        coordinator.registerMainWindow(window)
                    }
                }
                .onAppear {
                    appDelegate.coordinator = coordinator
                    coordinator.configureMainWindowOpener {
                        openWindow(id: "main")
                    }
                    coordinator.configureSettingsWindowOpener {
                        openWindow(id: "settings")
                    }
                    let currentStore = store
                    appDelegate.terminationHandler = { [currentStore] in
                        await currentStore.shutdown()
                    }
                }
        }
        .defaultSize(width: 1_280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建下载") {
                    coordinator.presentAddDownload()
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("从剪贴板新建") {
                    coordinator.presentAddDownload(fromClipboard: true)
                }
                .keyboardShortcut("v", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("批量下载") {
                    coordinator.presentBatchDownload()
                }
                Button("队列") {
                    coordinator.presentQueues()
                }
                Button("分类") {
                    coordinator.presentCategories()
                }
            }
            CommandMenu("任务") {
                Button("继续") {
                    store.downloadList.startSelected()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!store.downloadList.canStartSelection)
                Button("暂停") {
                    store.downloadList.pauseSelected()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(!store.downloadList.canPauseSelection)
                Button("重新下载") {
                    store.downloadList.redownloadSelected()
                }
                .disabled(!store.downloadList.selectedDownloads.contains { $0.status == .completed })
                Button("删除") {
                    store.downloadList.removeSelected()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!store.downloadList.hasSelection)
                Button("删除已完成") {
                    store.downloadList.removeCompleted()
                }
                Button("删除未完成") {
                    store.downloadList.removeIncomplete()
                }
                Button("删除全部") {
                    store.downloadList.removeAll()
                }
                Divider()
                Button("启动队列") {
                    if case .queue(let id) = store.downloadList.filter {
                        store.startQueue(id)
                    } else {
                        coordinator.showNotice("请先在侧栏选择一个队列。")
                    }
                }
                Button("停止队列") {
                    if case .queue(let id) = store.downloadList.filter {
                        store.stopQueue(id)
                    } else {
                        coordinator.showNotice("请先在侧栏选择一个队列。")
                    }
                }
                Button("停止全部") {
                    store.downloadList.stopAll()
                }
            }
            CommandMenu("工具") {
                Button("每主机设置") {
                    coordinator.presentPerHostSettings()
                }
                Button("设置") {
                    coordinator.presentSettings()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(after: .help) {
                Button("支持") {
                    openExternal("https://github.com/xgblack/cool-download-manager/issues")
                }
                Button("第三方库") {
                    coordinator.showMainWindow()
                    coordinator.mainPath = [.appInfo(.thirdParty)]
                }
                Button("翻译者") {
                    coordinator.showMainWindow()
                    coordinator.mainPath = [.appInfo(.translators)]
                }
                Button("捐赠") {
                    openExternal("https://github.com/xgblack/cool-download-manager")
                }
                Button("检查更新") {
                    coordinator.checkForUpdates()
                }
                Button("关于") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
        Window("下载管理器", id: "settings") {
            SettingsView(store: store, coordinator: coordinator)
                .background {
                    WindowAccessor { window in
                        coordinator.registerSettingsWindow(window)
                        coordinator.configureSettingsWindowOpener {
                            openWindow(id: "settings")
                        }
                    }
                }
        }
        .defaultSize(width: 1_160, height: 760)
    }

    private func openExternal(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
