import AppKit

@MainActor
final class MenuBarController {
    struct Actions {
        let showMain: () -> Void
        let newDownload: () -> Void
        let settings: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let target: MenuBarActionTarget

    init(actions: Actions) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        target = MenuBarActionTarget(actions: actions)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "酷的下载管理器"
            )
            button.image?.isTemplate = true
            button.toolTip = "酷的下载管理器"
            button.setAccessibilityLabel("酷的下载管理器")
        }

        let menu = NSMenu()
        menu.addItem(item("显示下载列表", action: #selector(MenuBarActionTarget.showMain(_:))))
        menu.addItem(item("从剪贴板新建下载", action: #selector(MenuBarActionTarget.newDownload(_:))))
        menu.addItem(.separator())
        menu.addItem(item("设置", action: #selector(MenuBarActionTarget.settings(_:))))
        menu.addItem(.separator())
        menu.addItem(item("退出", action: #selector(MenuBarActionTarget.quit(_:))))
        statusItem.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}

@MainActor
private final class MenuBarActionTarget: NSObject {
    private let actions: MenuBarController.Actions

    init(actions: MenuBarController.Actions) {
        self.actions = actions
    }

    @objc func showMain(_ sender: Any?) {
        actions.showMain()
    }

    @objc func newDownload(_ sender: Any?) {
        actions.newDownload()
    }

    @objc func settings(_ sender: Any?) {
        actions.settings()
    }

    @objc func quit(_ sender: Any?) {
        actions.quit()
    }
}
