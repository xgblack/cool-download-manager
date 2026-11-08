import AppKit
import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("应用主菜单", .serialized)
@MainActor
struct AppMainMenuTests {
    @Test("没有创建窗口时也安装完整主菜单及系统菜单")
    func installsBeforeAnyWindow() async throws {
        let fixture = MenuFixture()
        defer { fixture.restoreMenus() }
        fixture.controller.install()
        let main = try #require(NSApp.mainMenu)
        let menus = main.items.compactMap(\.submenu)
        for title in ["酷的下载管理器", "文件", "编辑", "显示", "任务", "工具", "窗口", "帮助"] {
            #expect(menus.contains { $0.title == title && !$0.items.isEmpty })
        }
        #expect(NSApp.servicesMenu?.title == "服务")
        #expect(NSApp.windowsMenu?.title == "窗口")
        #expect(NSApp.helpMenu?.title == "帮助")
        let settings = try #require(fixture.find("设置…"))
        #expect(settings.keyEquivalent == ",")
        #expect(settings.keyEquivalentModifierMask == [.command])
        #expect(settings.target === fixture.controller)
        let quit = try #require(fixture.find("退出酷的下载管理器"))
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.target == nil)
        await fixture.store.shutdown()
    }

    @Test("主菜单动作复用协调器，关闭主窗口前也能打开设置和新建下载")
    func routesApplicationActions() async throws {
        let fixture = MenuFixture()
        defer { fixture.restoreMenus() }
        var mainOpened = 0
        var settingsOpened = 0
        var aboutOpened = 0
        fixture.coordinator.configureMainWindowOpener { mainOpened += 1 }
        fixture.coordinator.configureSettingsWindowOpener { settingsOpened += 1 }
        fixture.coordinator.configureAboutWindowOpener { aboutOpened += 1 }
        fixture.controller.install()
        try fixture.invoke("设置…")
        #expect(settingsOpened == 1)
        try fixture.invoke("关于酷的下载管理器")
        #expect(aboutOpened == 1)
        try fixture.invoke("新建下载")
        #expect(mainOpened == 1)
        #expect(fixture.coordinator.mainSheet == .addDownload)
        fixture.coordinator.mainSheet = nil
        try fixture.invoke("队列")
        #expect(fixture.coordinator.mainPath == [.queues])
        try fixture.invoke("分类")
        #expect(fixture.coordinator.mainPath == [.categories])
        await fixture.store.shutdown()
    }

    @Test("任务菜单跟随选中状态更新，文字编辑时禁止删除任务")
    func validatesActiveSelectionAndTextFocus() async throws {
        let fixture = MenuFixture()
        defer { fixture.restoreMenus() }
        fixture.controller.install()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("com.cooldownloadmanager.main-window")
        let content = NSView()
        window.contentView = content
        defer { window.close() }
        let delete = try #require(fixture.find("删除"))
        #expect(!fixture.controller.validateMenuItem(delete, in: window))
        let record = DownloadRecord(id: 99, source: .init(kind: .http, link: "https://example.test/menu.bin"),
                                    folder: fixture.root.path, name: "menu.bin", status: .paused)
        fixture.store.downloadList.apply([record], announceCompletion: false)
        fixture.store.downloadList.selectedIDs = [99]
        #expect(fixture.controller.validateMenuItem(delete, in: window))
        let start = try #require(fixture.find("继续"))
        #expect(fixture.controller.validateMenuItem(start, in: window))
        let field = NSTextView()
        content.addSubview(field)
        window.makeFirstResponder(field)
        #expect(!fixture.controller.validateMenuItem(delete, in: window))
        #expect(!fixture.controller.validateMenuItem(start, in: window))
        await fixture.store.shutdown()
    }

    @Test("编辑快捷键使用响应链，失去下载列表焦点时不执行任务删除")
    func preservesEditingAndRejectsInactiveTaskActions() async throws {
        let fixture = MenuFixture()
        defer { fixture.restoreMenus() }
        fixture.controller.install()
        for (title, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
            ("撤销", NSSelectorFromString("undo:"), "z")
        ] {
            let item = try #require(fixture.find(title))
            #expect(item.target == nil)
            #expect(item.action == selector)
            #expect(item.keyEquivalent == key)
        }
        let record = DownloadRecord(id: 99, source: .init(kind: .http, link: "https://example.test/menu.bin"),
                                    folder: fixture.root.path, name: "menu.bin", status: .completed)
        fixture.store.downloadList.apply([record], announceCompletion: false)
        fixture.store.downloadList.selectedIDs = [99]
        let delete = try #require(fixture.find("删除"))
        #expect(!fixture.controller.validateMenuItem(delete))
        try fixture.invoke("删除")
        #expect(fixture.store.downloadList.downloads.map(\.id) == [99])
        let pause = try #require(fixture.find("暂停"))
        #expect(!fixture.controller.validateMenuItem(pause))
        await fixture.store.shutdown()
    }
}

@MainActor
private final class MenuFixture {
    let root = URL(fileURLWithPath: "/tmp/cdm-menu-\(UUID().uuidString)")
    let store: AppStore
    let coordinator: AppCoordinator
    let controller: AppMainMenuController
    private let main: NSMenu?
    private let services: NSMenu?
    private let windows: NSMenu?
    private let help: NSMenu?

    init() {
        let application = NSApplication.shared
        main = application.mainMenu
        services = application.servicesMenu
        windows = application.windowsMenu
        help = application.helpMenu
        store = AppStore(dataRoot: root, cacheRoot: root.appendingPathComponent("cache"))
        coordinator = AppCoordinator(store: store)
        controller = AppMainMenuController(store: store, coordinator: coordinator)
    }

    func restoreMenus() {
        NSApp.mainMenu = main
        NSApp.servicesMenu = services
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
        do { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        catch { fputs("主菜单测试临时目录保留：\(error.localizedDescription)\n", stderr) }
    }

    func find(_ title: String) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title { return item }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    func invoke(_ title: String) throws {
        let item = try #require(find(title))
        let selector = try #require(item.action)
        #expect(NSApp.sendAction(selector, to: item.target, from: item))
    }
}
