import AppKit
import CoolDownloadCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    struct SpeedLimiterState {
        var enabled: Bool
        var summary: String
    }
    struct QueueState {
        var id: DownloadID
        var name: String
        var canStart: Bool
        var canStop: Bool
    }
    struct Actions {
        let showMain: () -> Void
        let newDownload: () -> Void
        let toggleSpeedLimiter: () -> Void
        let startQueue: (DownloadID) -> Void
        let stopQueue: (DownloadID) -> Void
        let stopAll: () -> Void
        let settings: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let target: MenuBarActionTarget

    private let speedLimiterState: () -> SpeedLimiterState
    private var limitItem: NSMenuItem?
    private var limitSummary: NSMenuItem?
    private let queueStates: () -> [QueueState]
    private let canStopAll: () -> Bool
    private var startQueuesMenu: NSMenu?
    private var stopQueuesMenu: NSMenu?
    private var stopAllItem: NSMenuItem?

    init(actions: Actions, speedLimiterState: @escaping () -> SpeedLimiterState,
         queueStates: @escaping () -> [QueueState], canStopAll: @escaping () -> Bool) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        target = MenuBarActionTarget(actions: actions)
        self.speedLimiterState = speedLimiterState
        self.queueStates = queueStates
        self.canStopAll = canStopAll
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
        menu.autoenablesItems = false
        menu.addItem(item("显示下载列表", action: #selector(MenuBarActionTarget.showMain(_:))))
        menu.addItem(item("从剪贴板新建下载", action: #selector(MenuBarActionTarget.newDownload(_:))))
        menu.addItem(.separator())
        let startQueues = NSMenuItem(title: "启动队列", action: nil, keyEquivalent: "")
        startQueues.submenu = NSMenu(title: "启动队列")
        startQueues.submenu?.autoenablesItems = false
        startQueuesMenu = startQueues.submenu
        menu.addItem(startQueues)
        let stopQueues = NSMenuItem(title: "停止队列", action: nil, keyEquivalent: "")
        stopQueues.submenu = NSMenu(title: "停止队列")
        stopQueues.submenu?.autoenablesItems = false
        stopQueuesMenu = stopQueues.submenu
        menu.addItem(stopQueues)
        let stopAll = item("全部停止", action: #selector(MenuBarActionTarget.stopAll(_:)))
        stopAllItem = stopAll
        menu.addItem(stopAll)
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
        let queues = queueStates()
        updateQueues(startQueuesMenu, queues: queues, start: true)
        updateQueues(stopQueuesMenu, queues: queues, start: false)
        stopAllItem?.isEnabled = canStopAll()
    }

    private func updateQueues(_ menu: NSMenu?, queues: [QueueState], start: Bool) {
        guard let menu else { return }
        menu.removeAllItems()
        if queues.isEmpty {
            let empty = NSMenuItem(title: "暂无队列", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for queue in queues {
            let row = item(queue.name, action: start ? #selector(MenuBarActionTarget.startQueue(_:)) : #selector(MenuBarActionTarget.stopQueue(_:)))
            row.representedObject = NSNumber(value: queue.id)
            row.isEnabled = start ? queue.canStart : queue.canStop
            menu.addItem(row)
        }
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

    @objc func startQueue(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSNumber else { return }
        actions.startQueue(id.int64Value)
    }

    @objc func stopQueue(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSNumber else { return }
        actions.stopQueue(id.int64Value)
    }

    @objc func stopAll(_ sender: Any?) { actions.stopAll() }

    @objc func settings(_ sender: Any?) {
        actions.settings()
    }

    @objc func quit(_ sender: Any?) {
        actions.quit()
    }
}
