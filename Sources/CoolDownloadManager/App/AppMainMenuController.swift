import AppKit
import Combine
import CoolDownloadCore

/// AppKit owns the process lifecycle, so it must also own the application
/// menu. Commands attached to hosted SwiftUI scenes do not populate mainMenu.
@MainActor
final class AppMainMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private enum Action: Int {
        case about = 1, update, settings, newDownload, clipboardDownload, batch, queues, categories
        case startSelected, pauseSelected, redownloadSelected, removeSelected
        case removeCompleted, removeIncomplete, removeAll, startQueue, stopQueue, stopAll
        case perHost, showMain, support, donate
    }

    private let store: AppStore
    private let coordinator: AppCoordinator
    private var updateItem: NSMenuItem?
    private var toolbarItem: NSMenuItem?
    private var updateObservation: AnyCancellable?

    init(store: AppStore, coordinator: AppCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init()
        updateObservation = coordinator.updates.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUpdateItem() }
    }

    func install(on application: NSApplication = .shared) {
        let main = NSMenu()
        let app = submenu("酷的下载管理器", in: main)
        app.addItem(item("关于酷的下载管理器", .about))
        let update = item(coordinator.updates.menuTitle, .update)
        updateItem = update
        app.addItem(update)
        app.addItem(.separator())
        app.addItem(item("设置…", .settings, key: ","))
        app.addItem(.separator())
        let services = submenu("服务", in: app)
        application.servicesMenu = services
        app.addItem(.separator())
        app.addItem(standard("隐藏酷的下载管理器", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(standard("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        app.addItem(standard("显示全部", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(standard("退出酷的下载管理器", #selector(NSApplication.terminate(_:)), key: "q"))

        let file = submenu("文件", in: main)
        file.addItem(item("新建下载", .newDownload, key: "n"))
        file.addItem(item("从剪贴板新建", .clipboardDownload))
        file.addItem(.separator())
        file.addItem(item("批量下载", .batch))
        file.addItem(item("队列", .queues))
        file.addItem(item("分类", .categories))
        file.addItem(.separator())
        file.addItem(standard("关闭窗口", #selector(NSWindow.performClose(_:)), key: "w"))

        let edit = submenu("编辑", in: main)
        edit.addItem(standard("撤销", NSSelectorFromString("undo:"), key: "z"))
        edit.addItem(standard("重做", NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(standard("剪切", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(standard("复制", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(standard("粘贴", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(standard("全选", #selector(NSText.selectAll(_:)), key: "a"))

        let view = submenu("显示", in: main)
        view.addItem(standard("切换侧栏", #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control]))
        let toolbar = standard("隐藏工具栏", #selector(NSWindow.toggleToolbarShown(_:)))
        toolbarItem = toolbar
        view.addItem(toolbar)
        view.addItem(.separator())
        view.addItem(standard("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))

        let tasks = submenu("任务", in: main)
        tasks.addItem(item("继续", .startSelected, key: "r"))
        tasks.addItem(item("暂停", .pauseSelected, key: "p"))
        tasks.addItem(item("重新下载", .redownloadSelected))
        tasks.addItem(item("删除", .removeSelected, key: String(UnicodeScalar(NSDeleteCharacter)!), modifiers: []))
        tasks.addItem(.separator())
        tasks.addItem(item("删除已完成", .removeCompleted))
        tasks.addItem(item("删除未完成", .removeIncomplete))
        tasks.addItem(item("删除全部", .removeAll))
        tasks.addItem(.separator())
        tasks.addItem(item("启动队列", .startQueue))
        tasks.addItem(item("停止队列", .stopQueue))
        tasks.addItem(item("停止全部", .stopAll))

        let tools = submenu("工具", in: main)
        tools.addItem(item("每主机设置", .perHost))
        let windows = submenu("窗口", in: main)
        windows.addItem(item("显示下载列表", .showMain))
        windows.addItem(standard("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windows.addItem(standard("缩放", #selector(NSWindow.performZoom(_:))))
        windows.addItem(.separator())
        windows.addItem(standard("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        application.windowsMenu = windows

        let help = submenu("帮助", in: main)
        help.addItem(item("支持", .support))
        help.addItem(item("捐赠", .donate))
        application.helpMenu = help
        application.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshUpdateItem()
        toolbarItem?.title = NSApp.keyWindow?.toolbar?.isVisible == false ? "显示工具栏" : "隐藏工具栏"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateMenuItem(menuItem, in: NSApp.keyWindow)
    }

    // Use one snapshot of the focused window for every selection check; text
    // editors and secondary windows must never act on stale task selection.
    func validateMenuItem(_ menuItem: NSMenuItem, in window: NSWindow?) -> Bool {
        let selectionIsActive = canActOnSelection(in: window)
        guard let action = Action(rawValue: menuItem.tag) else { return true }
        let downloads = store.downloadList
        switch action {
        case .update: return !coordinator.updates.state.isWorking
        case .startSelected: return selectionIsActive && downloads.canStartSelection
        case .pauseSelected: return selectionIsActive && downloads.canPauseSelection
        case .redownloadSelected:
            return selectionIsActive && downloads.selectedDownloads.contains { $0.status == .completed }
        case .removeSelected: return selectionIsActive && downloads.hasSelection
        case .removeCompleted: return selectionIsActive && downloads.downloads.contains { $0.status == .completed }
        case .removeIncomplete: return selectionIsActive && downloads.downloads.contains { $0.status != .completed }
        case .removeAll: return selectionIsActive && !downloads.downloads.isEmpty
        case .stopAll: return downloads.downloads.contains { [.preparing, .downloading, .retrying].contains($0.status) }
        default: return true
        }
    }

    private func canActOnSelection(in window: NSWindow?) -> Bool {
        guard let window,
              window.identifier?.rawValue == "com.cooldownloadmanager.main-window" else { return false }
        // Field editors must keep Delete and editing shortcuts, including in
        // a sheet attached to the main window, without mutating selected tasks.
        return !(window.firstResponder is NSTextView) && window.attachedSheet == nil
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let action = Action(rawValue: sender.tag) else { return }
        switch action {
        case .about: coordinator.showAboutWindow()
        case .update: coordinator.showMainWindow(); coordinator.updates.performAction()
        case .settings: coordinator.presentSettings()
        case .newDownload: coordinator.presentAddDownload()
        case .clipboardDownload: coordinator.presentAddDownload(fromClipboard: true)
        case .batch: coordinator.presentBatchDownload()
        case .queues: coordinator.presentQueues()
        case .categories: coordinator.presentCategories()
        case .startSelected: store.downloadList.startSelected()
        case .pauseSelected: store.downloadList.pauseSelected()
        case .redownloadSelected: store.downloadList.redownloadSelected()
        case .removeSelected: store.downloadList.removeSelected()
        case .removeCompleted: store.downloadList.removeCompleted()
        case .removeIncomplete: store.downloadList.removeIncomplete()
        case .removeAll: store.downloadList.removeAll()
        case .startQueue:
            if case .queue(let id) = store.downloadList.filter { store.startQueue(id) }
            else { showQueueSelectionNotice() }
        case .stopQueue:
            if case .queue(let id) = store.downloadList.filter { store.stopQueue(id) }
            else { showQueueSelectionNotice() }
        case .stopAll: store.downloadList.stopAll()
        case .perHost: coordinator.presentPerHostSettings()
        case .showMain: coordinator.showMainWindow()
        case .support: openExternal("https://github.com/xgblack/cool-download-manager/issues")
        case .donate: openExternal("https://github.com/xgblack/cool-download-manager")
        }
    }

    private func showQueueSelectionNotice() {
        coordinator.showMainWindow()
        coordinator.showNotice("请先在侧栏选择一个队列。")
    }

    private func refreshUpdateItem() {
        updateItem?.title = coordinator.updates.menuTitle
        updateItem?.isEnabled = !coordinator.updates.state.isWorking
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        parent.addItem(entry)
        return menu
    }

    private func item(_ title: String, _ action: Action, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = action.rawValue
        item.target = self
        return item
    }

    private func standard(_ title: String, _ action: Selector, key: String = "",
                          modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // A nil target preserves AppKit's first-responder handling for text
        // editing, window actions and application termination.
        return item
    }

    private func openExternal(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
