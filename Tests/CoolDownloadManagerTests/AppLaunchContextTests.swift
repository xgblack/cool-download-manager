import Testing
import AppKit
import Carbon
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("App launch context")
struct AppLaunchContextTests {
    @Test("normal launches present the download list")
    func normalLaunchPresentsMainWindow() {
        #expect(AppLaunchContext.shouldPresentMainWindow(arguments: ["CoolDownloadManager"]))
    }

    @Test("登录自启和系统恢复不会强制弹出新的主窗口")
    func loginAndRestorationStayInBackground() {
        #expect(!AppLaunchContext.shouldPresentMainWindow(arguments: ["CoolDownloadManager"], isLoginItem: true))
        #expect(!AppLaunchContext.shouldPresentMainWindow(arguments: ["CoolDownloadManager"], isDefaultLaunch: false))
    }

    @Test("从系统登录 Apple Event 识别后台启动")
    @MainActor
    func detectsLoginAppleEvent() {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        #expect(!AppLaunchContext.isLoginItem(event))
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsLogInItem)
        event.setParam(properties, forKeyword: keyAEPropData)
        #expect(AppLaunchContext.isLoginItem(event))
    }

    @Test("browser integration launches suppress the download list")
    func browserLaunchSuppressesMainWindow() {
        #expect(!AppLaunchContext.shouldPresentMainWindow(arguments: [
            "CoolDownloadManager",
            AppPaths.browserIntegrationLaunchArgument
        ]))
    }
}
