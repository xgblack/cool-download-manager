import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    struct SpeedLimiterState {
        var enabled: Bool
        var summary: String
    }
    struct Actions {
        let showMain: () -> Void
        let newDownload: () -> Void
        let toggleSpeedLimiter: () -> Void
        let settings: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let target: MenuBarActionTarget

    private let speedLimiterState: () -> SpeedLimiterState
    private var limitItem: NSMenuItem?
    private var limitSummary: NSMenuItem?

    init(actions: Actions, speedLimiterState: @escaping () -> SpeedLimiterState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        target = MenuBarActionTarget(actions: actions)
        self.speedLimiterState = speedLimiterState
        super.init()

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
        menu.delegate = self
        menu.addItem(item("显示下载列表", action: #selector(MenuBarActionTarget.showMain(_:))))
        menu.addItem(item("从剪贴板新建下载", action: #selector(MenuBarActionTarget.newDownload(_:))))
        menu.addItem(.separator())
        let limit = item("启用全局限速", action: #selector(MenuBarActionTarget.toggleSpeedLimiter(_:)))
        menu.addItem(limit)
        limitItem = limit
        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        limitSummary = summary
        menu.addItem(.separator())
        menu.addItem(item("设置", action: #selector(MenuBarActionTarget.settings(_:))))
        menu.addItem(.separator())
        menu.addItem(item("退出", action: #selector(MenuBarActionTarget.quit(_:))))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let state = speedLimiterState()
        limitItem?.state = state.enabled ? .on : .off
        limitSummary?.title = state.summary
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

    @objc func toggleSpeedLimiter(_ sender: Any?) {
        actions.toggleSpeedLimiter()
    }

    @objc func settings(_ sender: Any?) {
        actions.settings()
    }

    @objc func quit(_ sender: Any?) {
        actions.quit()
    }
}
