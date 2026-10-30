import AppKit
import Combine
import Foundation
import Network
import Sparkle

enum UpdatePresentationState: Equatable {
    case unavailable
    case checking
    case available(version: String)
    case downloading(version: String)
    case preparing(version: String)
    case ready(version: String)
    case restarting
    case retrying
    case failed

    var title: String? {
        switch self {
        case .unavailable, .checking: nil
        case .available: "发现新版本"
        case .downloading: "正在下载更新"
        case .preparing: "正在准备更新"
        case .ready: "重启以更新"
        case .restarting: "正在重启更新"
        case .retrying: "正在切换线路"
        case .failed: "更新失败，点击重试"
        }
    }

    var systemImage: String {
        switch self {
        case .ready, .restarting: "arrow.clockwise.circle.fill"
        case .failed: "exclamationmark.arrow.circlepath"
        case .available: "arrow.down.circle.fill"
        default: "arrow.down.circle"
        }
    }

    var isWorking: Bool {
        switch self {
        case .checking, .downloading, .preparing, .retrying, .restarting: true
        default: false
        }
    }
}

struct UpdateRouteAttempt {
    enum Failure { case feed, archive }
    let selection: UpdateRouteSelection
    private(set) var feedIndex = 0
    private(set) var archiveIndex = 0

    var feedRoute: GitHubUpdateRoute { selection.feedRoutes[feedIndex] }
    var archiveRoute: GitHubUpdateRoute { selection.downloadRoutes[archiveIndex] }

    mutating func advance(after failure: Failure) -> Bool {
        switch failure {
        case .feed:
            guard feedIndex + 1 < selection.feedRoutes.count else { return false }
            feedIndex += 1
        case .archive:
            guard archiveIndex + 1 < selection.downloadRoutes.count else { return false }
            archiveIndex += 1
        }
        return true
    }
}

struct UpdateRelease: Equatable, Sendable {
    let build: String
    let version: String

    init(build: String, version: String) { self.build = build; self.version = version }
    init(_ item: SUAppcastItem) { self.init(build: item.versionString, version: item.displayVersionString) }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var settings = AppUpdateSettings.defaults
    @Published private(set) var state: UpdatePresentationState = .unavailable
    @Published private(set) var progress: Double?
    @Published private(set) var errorMessage: String?
    var onNotice: ((String) -> Void)?
    var prepareForRelaunch: ((String) async throws -> Void)?
    var discardRelaunchRecovery: (() -> Void)?

    private let bundle: Bundle
    private let router: GitHubUpdateRouter
    private var updater: SPUUpdater?
    private var userDriver: SidebarUpdateDriver?
    private var settingsObservations: [NSKeyValueObservation] = []
    private var engineStarted = false
    private var refreshTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var downloadRoutingTask: Task<Void, Never>?
    private var routeSelection = UpdateRouteSelection()
    private var attempt: UpdateRouteAttempt?
    private var lastRouteRefresh: Date?
    private var manualCheck = false
    private var downloadRequested = false
    private var backgroundDownloadAtCheckStart = false
    private var manualCheckPending = false
    private var retryPending = false
    private var deferredRefresh = false
    private var userCancelled = false
    private var currentRelease: UpdateRelease?
    private var staleFeed = false
    private var phase: UpdateRouteAttempt.Failure = .feed
    private var installHandler: (() -> Void)?
    private var cancellation: (() -> Void)?
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var receivedBytes: UInt64 = 0
    private var expectedBytes: UInt64 = 0
    private var pathMonitor: NWPathMonitor?
    private var networkWasSatisfied: Bool?

    private static let errorDomain = "CoolDownloadManager.Update"
    private static let refreshRequired = 1
    private static let staleFeedError = 2
    private static let automaticWorkDisabled = 3

    init(bundle: Bundle = .main, router: GitHubUpdateRouter = GitHubUpdateRouter()) {
        self.bundle = bundle
        self.router = router
        super.init()
        if isConfigured { configureUpdater() }
    }

    var isConfigured: Bool {
        feedURL != nil && (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            .flatMap { Data(base64Encoded: $0) }?.count == 32
    }

    private func configureUpdater() {
        let driver = SidebarUpdateDriver(hostBundle: bundle)
        driver.controller = self
        userDriver = driver
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        self.updater = updater
        settingsObservations = [
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.readSettings() }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.readSettings() }
            },
            updater.observe(\.updateCheckInterval) { [weak self] _, _ in
                Task { @MainActor in self?.readSettings() }
            }
        ]
        readSettings()
    }

    private func readSettings() {
        guard let updater else { return }
        settings = AppUpdateSettings(
            automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
            checkInterval: updater.updateCheckInterval.isFinite && updater.updateCheckInterval >= 3_600
                ? updater.updateCheckInterval : AppUpdateSettings.defaults.checkInterval,
            automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates
        )
    }

    func applySettings(_ settings: AppUpdateSettings) {
        guard let updater else { return }
        let previous = self.settings
        let interval = settings.checkInterval.isFinite && settings.checkInterval >= 3_600
            ? settings.checkInterval : AppUpdateSettings.defaults.checkInterval
        if updater.updateCheckInterval != interval { updater.updateCheckInterval = interval }
        if updater.automaticallyDownloadsUpdates != settings.automaticallyDownloadsUpdates {
            updater.automaticallyDownloadsUpdates = settings.automaticallyDownloadsUpdates
        }
        if updater.automaticallyChecksForUpdates != settings.automaticallyChecksForUpdates {
            updater.automaticallyChecksForUpdates = settings.automaticallyChecksForUpdates
        }
        readSettings()
        // A setting change must also stop work that is waiting on route probes.
        // Keep explicitly requested downloads and already prepared updates intact.
        if refreshTask != nil && (!self.settings.automaticallyChecksForUpdates
            || (previous.allowsAutomaticDownload && !self.settings.allowsAutomaticDownload)) {
            let manual = manualCheck || manualCheckPending
            refreshTask?.cancel()
            refreshTask = nil
            manualCheckPending = false
            if manual || self.settings.automaticallyChecksForUpdates {
                refreshAndStart(userInitiated: manual)
            } else if state == .checking || state == .retrying {
                state = .unavailable
            }
        }
        if !self.settings.automaticallyChecksForUpdates && !manualCheck && !manualCheckPending {
            deferredRefresh = false
        }
    }

    private var feedURL: URL? {
        guard let value = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: value), GitHubUpdateRoute.supports(url) else { return nil }
        return url
    }

    private var currentBuild: Int {
        Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    var menuTitle: String {
        if case .checking = state { return "正在检查更新…" }
        return state.title ?? "检查更新"
    }
    var canCancel: Bool { cancellation != nil }
    var helpText: String {
        if let errorMessage { return errorMessage }
        if let release = currentRelease {
            return "酷的下载管理器 \(release.version)（构建 \(release.build)）"
        }
        return "检查应用更新"
    }

    func startIfConfigured() {
        guard !engineStarted, let updater else { return }
        routeSelection = router.cachedSelection()
        // Sparkle uses its persisted last-check date and interval, including on
        // launch. Refresh routes only when it actually asks to perform a check.
        startEngine(updater)
        if engineStarted { observeNetwork() }
    }

    func checkForUpdates() {
        startIfConfigured()
        guard let updater else {
            onNotice?("当前开发构建未配置 Sparkle 更新源。")
            return
        }
        if refreshTask != nil {
            manualCheckPending = true
            return
        }
        guard !updater.sessionInProgress else {
            if case .available = state { beginDownload() }
            else if case .ready = state { restartToUpdate() }
            else if case .checking = state { manualCheck = true }
            return
        }
        downloadRequested = false
        refreshAndStart(userInitiated: true)
    }

    func performAction() {
        switch state {
        case .ready: restartToUpdate()
        case .available:
            if foundReply != nil { beginDownload() } else { checkForUpdates() }
        case .failed, .unavailable: checkForUpdates()
        default: break
        }
    }

    func cancel() {
        guard let cancellation else { return }
        userCancelled = true
        self.cancellation = nil
        cancellation()
    }

    private func refreshAndStart(userInitiated: Bool) {
        guard refreshTask == nil, let feedURL, let updater,
              let keyText = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let key = Data(base64Encoded: keyText) else { return }
        guard userInitiated || settings.automaticallyChecksForUpdates else { return }
        manualCheck = userInitiated
        errorMessage = nil
        state = .checking
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.routeSelection = try await self.router.refresh(
                    feedURL: feedURL, publicKey: key, currentBuild: self.currentBuild,
                    probeArchives: self.settings.allowsAutomaticDownload
                )
                self.lastRouteRefresh = Date()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "更新线路检测失败，将尝试已知线路。"
            }
            guard !Task.isCancelled else { return }
            self.refreshTask = nil
            if !self.engineStarted {
                self.startEngine(updater)
                guard self.engineStarted else { return }
            }
            let userInitiated = self.manualCheck || self.manualCheckPending
            self.manualCheckPending = false
            guard userInitiated || updater.automaticallyChecksForUpdates else {
                self.state = .unavailable
                return
            }
            self.beginCheck(userInitiated: userInitiated, retry: false)
        }
    }

    private func startEngine(_ updater: SPUUpdater) {
        do {
            try updater.start()
            engineStarted = true
        }
        catch {
            errorMessage = "更新服务启动失败，请检查应用安装位置后重试。"
            state = .failed
        }
    }

    private func beginCheck(userInitiated: Bool, retry: Bool) {
        guard let updater, !updater.sessionInProgress else { return }
        guard userInitiated || settings.automaticallyChecksForUpdates else {
            if state == .checking || state == .retrying { state = .unavailable }
            return
        }
        manualCheck = userInitiated
        if !retry { attempt = UpdateRouteAttempt(selection: routeSelection) }
        retryPending = retry
        phase = .feed
        staleFeed = false
        userCancelled = false
        progress = nil
        currentRelease = nil
        errorMessage = nil
        if !retry { state = .checking }
        if userInitiated { updater.checkForUpdates() }
        else { updater.checkForUpdatesInBackground() }
    }

    private func beginDownload() {
        guard let reply = foundReply else { return }
        foundReply = nil
        downloadRequested = true
        guard let feedURL,
              let keyText = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let key = Data(base64Encoded: keyText) else { reply(.install); return }
        if let release = currentRelease { state = .downloading(version: release.version) }
        // Manual-only users do not fetch ZIP samples until they choose Download.
        downloadRoutingTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.routeSelection = try await self.router.refresh(
                    feedURL: feedURL, publicKey: key, currentBuild: self.currentBuild
                )
                self.attempt = UpdateRouteAttempt(selection: self.routeSelection)
                self.lastRouteRefresh = Date()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "更新线路检测失败，将尝试已知线路。"
            }
            guard !Task.isCancelled else { return }
            self.downloadRoutingTask = nil
            self.cancellation = nil
            reply(.install)
        }
        cancellation = { [weak self] in
            self?.downloadRoutingTask?.cancel()
            self?.downloadRoutingTask = nil
            reply(.dismiss)
        }
    }

    private func restartToUpdate() {
        guard let handler = installHandler, let release = currentRelease else { return }
        installHandler = nil
        errorMessage = nil
        state = .restarting
        restartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareForRelaunch?(release.build)
                try Task.checkCancellation()
                handler()
            } catch {
                guard !Task.isCancelled else { return }
                self.restartTask = nil
                self.installHandler = handler
                self.errorMessage = "无法保存下载任务的恢复信息，请稍后重试更新。"
                self.state = .ready(version: release.version)
            }
        }
    }

    @discardableResult
    func abandonRelaunch() -> Task<Void, Never>? {
        guard let task = restartTask else { return nil }
        task.cancel()
        restartTask = nil
        discardRelaunchRecovery?()
        return task
    }

    private func observeNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasSatisfied = self.networkWasSatisfied
                self.networkWasSatisfied = satisfied
                guard wasSatisfied == false, satisfied, self.refreshTask == nil,
                      let updater = self.updater, self.settings.automaticallyChecksForUpdates,
                      !updater.sessionInProgress, self.state == .unavailable || self.state == .failed,
                      self.state == .failed || self.settings.isCheckDue(lastCheck: updater.lastUpdateCheckDate),
                      self.lastRouteRefresh.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
                self.refreshAndStart(userInitiated: false)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.cooldownloadmanager.update-network"))
        pathMonitor = monitor
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let feedURL else { return nil }
        return (attempt?.feedRoute ?? routeSelection.feedRoutes[0]).rewriting(feedURL)?.absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground {
            if !retryPending { manualCheck = false }
            guard settings.automaticallyChecksForUpdates else {
                throw NSError(domain: Self.errorDomain, code: Self.automaticWorkDisabled)
            }
            backgroundDownloadAtCheckStart = settings.allowsAutomaticDownload
        }
        if refreshTask != nil || (lastRouteRefresh.map { Date().timeIntervalSince($0) > 6 * 3_600 } ?? true) {
            deferredRefresh = true
            throw NSError(domain: Self.errorDomain, code: Self.refreshRequired)
        }
        let isRetry = retryPending
        if !isRetry {
            downloadRequested = false
            attempt = UpdateRouteAttempt(selection: routeSelection)
            userCancelled = false
            currentRelease = nil
            progress = nil
            state = .checking
        }
        retryPending = false
        phase = .feed
        staleFeed = false
        if updateCheck == .updatesInBackground && !isRetry { manualCheck = false }
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let build = appcast.items.filter { ($0.channel ?? "").isEmpty }.compactMap { Int($0.versionString) }.max() ?? 0
        staleFeed = build < routeSelection.latestBuild
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard !staleFeed, (Int(updateItem.versionString) ?? 0) >= routeSelection.latestBuild else {
            staleFeed = true
            throw NSError(domain: Self.errorDomain, code: Self.staleFeedError)
        }
        if updateCheck == .updatesInBackground {
            guard settings.automaticallyChecksForUpdates else {
                throw NSError(domain: Self.errorDomain, code: Self.automaticWorkDisabled)
            }
            if backgroundDownloadAtCheckStart && !settings.allowsAutomaticDownload {
                updateAvailable(UpdateRelease(updateItem))
                throw NSError(domain: Self.errorDomain, code: Self.automaticWorkDisabled)
            }
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable(UpdateRelease(item))
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        currentRelease = UpdateRelease(item)
        phase = .archive
        let route = attempt?.archiveRoute ?? routeSelection.downloadRoutes[0]
        if let url = request.url, let routed = route.rewriting(url) { request.url = routed }
        request.timeoutInterval = 15
        receivedBytes = 0
        expectedBytes = item.contentLength
        progress = nil
        state = .downloading(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        archiveDownloaded(UpdateRelease(item))
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        state = .preparing(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        readyToInstall(UpdateRelease(item), handler: immediateInstallationBlock)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        downloadRoutingTask?.cancel()
        downloadRoutingTask = nil
        cancellation = nil
        foundReply = nil
        if error != nil { abandonRelaunch() }
        if deferredRefresh {
            deferredRefresh = false
            refreshAndStart(userInitiated: manualCheck || manualCheckPending)
            return
        }
        if let error = error as NSError?, error.domain == Self.errorDomain,
           [Self.automaticWorkDisabled, Self.refreshRequired].contains(error.code) {
            if state == .checking || state == .retrying { state = .unavailable }
            return
        }
        if userCancelled || Self.isCancellation(error) {
            state = currentRelease.map { .available(version: $0.version) } ?? .unavailable
            return
        }
        if Self.isNoUpdate(error), !staleFeed {
            state = .unavailable
            if manualCheck { onNotice?("当前已经是最新版本，或暂无适合此系统的更新。") }
            return
        }
        guard let error = error ?? (staleFeed ? NSError(domain: Self.errorDomain, code: Self.staleFeedError) : nil) else {
            if case .checking = state { state = .unavailable }
            return
        }
        let failure = Self.retryableFailure(error, phase: phase, staleFeed: staleFeed)
        if let failure, (manualCheck || settings.automaticallyChecksForUpdates), attempt?.advance(after: failure) == true {
            state = .retrying
            let manual = manualCheck
            // The completion callback is the point at which Sparkle has released
            // its previous session. Never race it with a fixed-delay retry.
            Task { @MainActor [weak self] in self?.beginCheck(userInitiated: manual, retry: true) }
        } else {
            progress = nil
            errorMessage = phase == .feed ? "无法取得有效的更新信息，请稍后重试。" : "更新下载或准备失败，请稍后重试。"
            state = .failed
        }
    }

    static func isNoUpdate(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue
    }

    static func isCancellation(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == SUSparkleErrorDomain && [SUError.installationCanceledError, .installationAuthorizeLaterError].map { Int($0.rawValue) }.contains(error.code))
    }

    static func retryableFailure(_ error: Error, phase: UpdateRouteAttempt.Failure, staleFeed: Bool) -> UpdateRouteAttempt.Failure? {
        let value = error as NSError
        if staleFeed { return .feed }
        if isCancellation(error) || isNoUpdate(error) { return nil }
        if value.domain == NSURLErrorDomain { return .some(phase) }
        if value.domain == SUSparkleErrorDomain,
           [SUError.appcastParseError, .appcastError, .downloadError,
            .unarchivingError, .signatureError, .validationError].map({ Int($0.rawValue) }).contains(value.code) {
            return phase
        }
        return nil
    }

    func updateAvailable(_ release: UpdateRelease) {
        currentRelease = release
        state = .available(version: release.version)
    }

    func archiveDownloaded(_ release: UpdateRelease) {
        currentRelease = release
        cancellation = nil
        progress = nil
        state = .preparing(version: release.version)
    }

    func readyToInstall(_ release: UpdateRelease, handler: @escaping () -> Void) {
        currentRelease = release
        installHandler = handler
        progress = nil
        state = .ready(version: release.version)
    }

    // These callbacks come only from our user driver. Background automatic
    // downloads use Sparkle's installation-ready delegate above instead.
    func userDriverFound(_ item: SUAppcastItem, stage: SPUUserUpdateStage, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        currentRelease = UpdateRelease(item)
        if stage == .installing {
            readyToInstall(UpdateRelease(item), handler: { reply(.install) })
        } else if downloadRequested || settings.allowsAutomaticDownload {
            reply(.install)
        } else {
            foundReply = reply
            self.state = .available(version: item.displayVersionString)
        }
    }

    fileprivate func userDriverChecking(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    fileprivate func userDriverDownloading(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    fileprivate func userDriverReceived(_ bytes: UInt64) {
        receivedBytes += bytes
        if expectedBytes > 0 { progress = min(Double(receivedBytes) / Double(expectedBytes), 1) }
    }

    fileprivate func userDriverExpected(_ bytes: UInt64) { expectedBytes = bytes }

    fileprivate func userDriverPreparing() {
        cancellation = nil
        progress = nil
        if let release = currentRelease { archiveDownloaded(release) }
    }

    fileprivate func userDriverReady(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !userCancelled else { reply(.skip); return }
        guard let release = currentRelease else { return }
        readyToInstall(release, handler: { reply(.install) })
    }

    fileprivate func userDriverDismissed() {
        downloadRoutingTask?.cancel()
        downloadRoutingTask = nil
        cancellation = nil
        foundReply = nil
    }
}

/// Keeps standard permission/informational dialogs available while routing
/// normal update status and retryable errors through the application sidebar.
@MainActor
private final class SidebarUpdateDriver: NSObject, SPUUserDriver {
    weak var controller: AppUpdateController?
    private let standard: SPUStandardUserDriver

    init(hostBundle: Bundle) {
        standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller?.userDriverChecking(cancellation: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate || appcastItem.isMajorUpgrade {
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        } else {
            controller?.userDriverFound(appcastItem, stage: state.stage, reply: reply)
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller?.userDriverDownloading(cancellation: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { controller?.userDriverExpected(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { controller?.userDriverReceived(length) }
    func showDownloadDidStartExtractingUpdate() { controller?.userDriverPreparing() }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { controller?.userDriverReady(reply: reply) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation(); controller?.userDriverDismissed() }
    func showUpdateInFocus() {}
}
