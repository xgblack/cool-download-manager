import SwiftUI
import AppKit

final class CoolDownloadManagerAppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the normal macOS application identity: Dock icon, Cmd+Tab, and
        // a regular application menu remain available while the window is
        // closed and downloads continue in the background.
        NSApp.setActivationPolicy(.regular)
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
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("下载管理器") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    let currentModel = model
                    appDelegate.terminationHandler = { [weak currentModel] in
                        await currentModel?.shutdown()
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加下载") {
                    model.addAndStart()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
