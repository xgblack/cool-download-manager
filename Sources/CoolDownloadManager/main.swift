import SwiftUI
import AppKit
import Carbon
import Darwin
import CoolDownloadCore
import CoolDownloadIntegration

enum AppLaunchContext {
    static func shouldPresentMainWindow(arguments: [String], isLoginItem: Bool = false,
                                        isDefaultLaunch: Bool = true) -> Bool {
        !arguments.contains(AppPaths.browserIntegrationLaunchArgument) && !isLoginItem && isDefaultLaunch
    }

    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let properties = event?.paramDescriptor(forKeyword: keyAEPropData) else { return false }
        return properties.forKeyword(keyAELaunchedAsLogInItem)?.booleanValue == true
            || properties.forKeyword(keyAELaunchedAsServiceItem)?.booleanValue == true
    }
}

@main
enum CoolDownloadManagerApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        do {
            // Publish the control listener before database/configuration boot.
            let instance = try AppInstanceController(socketURL: AppPaths.nativeMessagingSocketURL())
            let delegate = CoolDownloadManagerAppDelegate(instance: instance)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch AppInstanceError.alreadyRunning {
            forwardToExistingInstance()
        } catch PrivateSocketServer.PrivateSocketServerError.alreadyRunning {
            // A pre-fix installed version may still own the existing socket.
            forwardToExistingInstance()
        } catch {
            let alert = NSAlert()
            alert.messageText = "下载管理器无法启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @MainActor
    private static func forwardToExistingInstance() {
        guard !CommandLine.arguments.contains(AppPaths.browserIntegrationLaunchArgument) else { return }
        do {
            try AppInstanceClient(socketURL: AppPaths.nativeMessagingSocketURL()).showMainWindow()
        } catch {
            // Opening through Launch Services also wakes an older installed
            // instance that does not implement show-main yet.
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppPaths.bundleIdentifier)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let url = other?.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            } else {
                fputs("CoolDownloadManager: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}

@MainActor
final class CoolDownloadManagerAppDelegate: NSObject, NSApplicationDelegate {
    private let instance: AppInstanceController
    private var store: AppStore?
    private var coordinator: AppCoordinator?
    private var scenes: NSHostingSceneRepresentation<CoolDownloadManagerScenes>?
    private var terminationInProgress = false
    private var pendingReopen = false

    init(instance: AppInstanceController) { self.instance = instance }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let store = AppStore()
        let coordinator = AppCoordinator(store: store)
        self.store = store
        self.coordinator = coordinator
        let scenes = NSHostingSceneRepresentation {
            CoolDownloadManagerScenes(store: store, coordinator: coordinator)
        }
        self.scenes = scenes
        NSApplication.shared.addSceneRepresentation(scenes)
        coordinator.configureMainWindowOpener { [weak scenes] in scenes?.environment.openWindow(id: "main") }
        coordinator.configureSettingsWindowOpener { [weak scenes] in scenes?.environment.openWindow(id: "settings") }
        coordinator.configureAboutWindowOpener { [weak scenes] in scenes?.environment.openWindow(id: "about") }
        coordinator.attachMenuBar()
        instance.configureShowMain { [weak coordinator] in
            await coordinator?.showMainWindow()
        }
        store.onStartupFinished = { [weak store, weak instance] failure in
            guard let instance else { return }
            if let failure { instance.setFailed(failure) }
            else {
                instance.setReady { [weak store] request in
                    guard let store else { throw AppInstanceError.stopping }
                    try await store.addFromBrowser(request)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator?.startUpdaterIfConfigured()
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if pendingReopen || AppLaunchContext.shouldPresentMainWindow(
            arguments: CommandLine.arguments,
            isLoginItem: AppLaunchContext.isLoginItem(NSAppleEventManager.shared().currentAppleEvent),
            isDefaultLaunch: isDefault
        ) {
            coordinator?.showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let coordinator { coordinator.showMainWindow() }
        else { pendingReopen = true }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let store, let coordinator else { return .terminateNow }
        terminationInProgress = true
        instance.beginStopping()
        Task { @MainActor [self] in
            await coordinator.fileActions.prepareForTermination()
            await store.shutdown()
            instance.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct CoolDownloadManagerScenes: Scene {
    @ObservedObject var store: AppStore
    @ObservedObject var coordinator: AppCoordinator

    var body: some Scene {
        WindowGroup("酷的下载管理器", id: "main") {
            MainView(store: store, coordinator: coordinator, viewState: coordinator.mainViewState)
                .background {
                    WindowAccessor { window in
                        coordinator.registerMainWindow(window)
                    }
                }
        }
        .defaultSize(width: 1_280, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于酷的下载管理器") {
                    coordinator.showAboutWindow()
                }
            }
            AppUpdateCommands(controller: coordinator.updates, showMain: coordinator.showMainWindow)
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { coordinator.presentSettings() }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("新建下载") {
                    coordinator.presentAddDownload()
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("从剪贴板新建") {
                    coordinator.presentAddDownload(fromClipboard: true)
                }
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
            }
            CommandGroup(after: .help) {
                Button("支持") {
                    openExternal("https://github.com/xgblack/cool-download-manager/issues")
                }
                Button("捐赠") {
                    openExternal("https://github.com/xgblack/cool-download-manager")
                }
                Button("关于") {
                    coordinator.showAboutWindow()
                }
            }
        }
        WindowGroup("关于酷的下载管理器", id: "about") {
            AboutView(updates: coordinator.updates)
                .appTheme(store.settings.theme)
                .background {
                    WindowAccessor { window in
                        coordinator.registerAboutWindow(window)
                    }
                }
                .onChange(of: store.settings.theme) { _, theme in
                    coordinator.applyThemeToAboutWindow(theme)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        WindowGroup("下载管理器", id: "settings") {
            SettingsView(store: store, coordinator: coordinator)
                .background {
                    WindowAccessor { window in
                        coordinator.registerSettingsWindow(window)
                    }
                }
        }
        .defaultSize(width: 1_160, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }

    private func openExternal(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
