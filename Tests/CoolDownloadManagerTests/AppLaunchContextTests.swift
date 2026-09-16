import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("App launch context")
struct AppLaunchContextTests {
    @Test("normal launches present the download list")
    func normalLaunchPresentsMainWindow() {
        #expect(AppLaunchContext.shouldPresentMainWindow(arguments: ["CoolDownloadManager"]))
    }

    @Test("browser integration launches suppress the download list")
    func browserLaunchSuppressesMainWindow() {
        #expect(!AppLaunchContext.shouldPresentMainWindow(arguments: [
            "CoolDownloadManager",
            AppPaths.browserIntegrationLaunchArgument
        ]))
    }
}
