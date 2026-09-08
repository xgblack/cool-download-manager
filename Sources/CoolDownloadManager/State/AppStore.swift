import Foundation
import SwiftUI
import ServiceManagement
import CoolDownloadCore
import CoolDownloadIntegration

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var isReady = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var queues: [IntegrationQueue] = []
    @Published private(set) var queueModels: [DownloadQueueModel] = []
    @Published private(set) var categories: [DownloadCategory] = []
    @Published private(set) var perHostSettings: [PerHostSettingsItem] = []
    @Published private(set) var settings: AppSettingsModel
    @Published private(set) var autoStartStatus = SMAppService.mainApp.status

    let service: DownloadService?
    var downloadList: DownloadListStore
    var onBrowserDownloadRequest: ((AddDownloadsRequest) -> Void)?
    private let store: DownloadStore?
    private let settingsStore: SettingsStore?
    private let settingsStoreInitializationError: SettingsStoreError?
    private let settingsURL: URL
    private let queueStore: QueueStore?
    private let categoryStore: CategoryStore?
    private let perHostSettingsStore: PerHostSettingsStore?
    private let hostPerformanceStore: HostPerformanceStore?
    private var integrationServer: LoopbackHTTPServer?
    private var integrationGeneration = UUID()
    private var privateSocketServer: PrivateSocketServer?
    private var queueScheduleTask: Task<Void, Never>?
    private var queueEventTask: Task<Void, Never>?
    private var downloadEventTask: Task<Void, Never>?
    private var missingFileTask: Task<Void, Never>?
    private var scheduledQueueStates: [DownloadID: Bool] = [:]
    private var notificationStatuses: [DownloadID: DownloadStatus] = [:]
    private var isShuttingDown = false

    init(
        dataRoot: URL = AppPaths.applicationSupportDirectory(),
        cacheRoot: URL = AppPaths.cachesDirectory(),
        settingsStoreFactory: (URL) throws -> SettingsStore = { try SettingsStore(dataRoot: $0) }
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let initialSettings = AppSettingsModel.defaults(home: home)
        let defaultFolder = URL(fileURLWithPath: initialSettings.defaultDownloadFolder, isDirectory: true)
        var loadedSettingsStore: SettingsStore?
        var loadedSettingsStoreError: SettingsStoreError?
        do {
            loadedSettingsStore = try settingsStoreFactory(dataRoot)
        } catch let error as SettingsStoreError {
            loadedSettingsStore = nil
            loadedSettingsStoreError = error
        } catch {
            loadedSettingsStore = nil
            loadedSettingsStoreError = .writeFailed(
                dataRoot.appendingPathComponent("appSettings.json"),
                error.localizedDescription
            )
        }
        self.settingsStore = loadedSettingsStore
        self.settingsStoreInitializationError = loadedSettingsStoreError
        self.settingsURL = dataRoot.standardizedFileURL.appendingPathComponent("appSettings.json")
        self.settings = initialSettings
        let metadataDatabase: MetadataDatabase?
        let metadataDatabaseError: Error?
        do {
            metadataDatabase = try MetadataDatabase.shared(rootURL: dataRoot)
            metadataDatabaseError = nil
        } catch {
            metadataDatabase = nil
            metadataDatabaseError = error
        }
        self.perHostSettingsStore = metadataDatabase.flatMap {
            try? PerHostSettingsStore(dataRoot: dataRoot, database: $0)
        }
        self.hostPerformanceStore = try? HostPerformanceStore(dataRoot: cacheRoot)

        do {
            guard let metadataDatabase else {
                if let metadataDatabaseError {
                    throw metadataDatabaseError
                }
                throw MetadataDatabaseError.loadFailed(
                    dataRoot.appendingPathComponent("metadata.sqlite"),
                    "无法创建共享元数据数据库"
                )
            }
            let store = try DownloadStore(rootURL: dataRoot, database: metadataDatabase)
            self.store = store
            let environment = ProcessInfo.processInfo.environment
            let maxConcurrent = environment["CDM_MAX_CONCURRENT_DOWNLOADS"].flatMap(Int.init) ?? 3
            let rangeConnections = environment["CDM_RANGE_CONNECTIONS"].flatMap(Int.init)
                ?? initialSettings.threadCount
            self.service = DownloadService(
                store: store,
                defaultFolder: defaultFolder,
                schedulerConfiguration: DownloadSchedulerConfiguration(
                    maxConcurrentDownloads: maxConcurrent,
                    maxConnectionsPerDownload: rangeConnections,
                    dynamicPartCreation: initialSettings.dynamicPartCreation,
                    appendExtensionToIncompleteDownloads: initialSettings.appendExtensionToIncompleteDownloads,
                    useSparseFileAllocation: initialSettings.useSparseFileAllocation,
                    deletePartialFileOnDownloadCancellation: initialSettings.deletePartialFileOnDownloadCancellation,
                    speedLimit: initialSettings.speedLimit,
                    userAgent: initialSettings.userAgent,
                    useServerLastModifiedTime: initialSettings.useServerLastModifiedTime
                ),
                hostPerformanceStore: hostPerformanceStore
            )
        } catch {
            self.store = nil
            self.service = nil
            self.errorMessage = error.localizedDescription
        }

        self.downloadList = DownloadListStore(service: service)
        self.queueStore = metadataDatabase.flatMap {
            try? QueueStore(dataRoot: dataRoot, database: $0)
        }
        self.categoryStore = metadataDatabase.flatMap {
            try? CategoryStore(dataRoot: dataRoot, defaultFolder: defaultFolder, database: $0)
        }
        self.downloadList.onRemovedIDs = { [weak self] ids in
            self?.removeMetadataReferences(for: ids)
        }

        Task { [weak self] in
            await self?.boot()
        }
    }

    deinit {
        queueScheduleTask?.cancel()
        queueEventTask?.cancel()
        downloadEventTask?.cancel()
        missingFileTask?.cancel()
        integrationServer?.stop()
        privateSocketServer?.stop()
    }

    func boot() async {
        guard !isShuttingDown else { return }
        guard let service else {
            if errorMessage == nil {
                errorMessage = "无法创建下载核心"
            }
            return
        }

        do {
            try await service.boot()
            guard !isShuttingDown else {
                await service.shutdown()
                return
            }

            await downloadList.reload()
            let initialSnapshot = await service.snapshot()
            notificationStatuses = Dictionary(
                uniqueKeysWithValues: initialSnapshot.downloads.map { ($0.id, $0.status) }
            )
            downloadList.beginObserving()
            await reloadPerHostSettings()
            await service.updatePerHostSettings(perHostSettings)
            do {
                if let settingsStore {
                    do {
                        let loadedSettings = try await settingsStore.load()
                        settings = loadedSettings
                        await service.updateConfiguration(
                            schedulerConfiguration: schedulerConfiguration(for: loadedSettings),
                            retryPolicy: DownloadRetryPolicy(
                                maxAttempts: max(1, loadedSettings.maxDownloadRetryCount),
                                delay: .seconds(1)
                            ),
                            defaultFolder: URL(fileURLWithPath: loadedSettings.defaultDownloadFolder, isDirectory: true),
                            networkConfiguration: networkConfiguration(for: loadedSettings)
                        )
                        do {
                            try applyAutoStartOnBoot(loadedSettings.autoStartOnBoot)
                        } catch {
                            refreshAutoStartStatus()
                            errorMessage = "无法更新开机启动：\(error.localizedDescription)"
                        }
                        if loadedSettings.trackDeletedFilesOnDisk {
                            await reconcileMissingFiles()
                            startMissingFileMonitor()
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                await categoryStore?.updateDefaultFolder(
                    URL(fileURLWithPath: settings.defaultDownloadFolder, isDirectory: true)
                )
                await reloadQueues()
                await reloadCategories()
                await pruneMetadataReferences()
                await reloadQueues()
                await reloadCategories()
                startQueueScheduleMonitor()
                startQueueEventMonitor()
                startDownloadEventMonitor()
                try startIntegration(service: service, settings: settings)
            } catch {
                errorMessage = error.localizedDescription
            }
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        queueScheduleTask?.cancel()
        queueScheduleTask = nil
        queueEventTask?.cancel()
        queueEventTask = nil
        downloadEventTask?.cancel()
        downloadEventTask = nil
        missingFileTask?.cancel()
        missingFileTask = nil

        // Stop accepting browser requests before cancelling downloads so quit
        // cannot race a new add/start command with state persistence.
        integrationServer?.stop()
        integrationServer = nil
        privateSocketServer?.stop()
        privateSocketServer = nil
        if let service {
            await service.shutdown()
        }
    }

    func addAndStart(link: String, name: String?, folder: URL) {
        addDownload(link: link, name: name, folder: folder)
    }

    /// Adds through the same path as the UI and applies the historical
    /// "use category by default" rule before the core creates the record.
    func addDownload(
        link: String,
        name: String?,
        folder: URL,
        queueID: DownloadID? = nil,
        categoryID: DownloadID? = nil,
        startImmediately: Bool = true,
        integrationItems: [IntegrationDownloadCredential]? = nil
    ) {
        guard let service else {
            errorMessage = "下载核心尚未准备好"
            return
        }
        let categoryStore = self.categoryStore
        let queueStore = self.queueStore
        let shouldUseCategories = settings.useCategoryByDefault && categoryID == nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            var resolvedCategoryID = categoryID
            var resolvedFolder = folder
            if shouldUseCategories, let categoryStore {
                let firstLink = link
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .first ?? link
                let candidateName: String
                if let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedName.isEmpty {
                    candidateName = trimmedName
                } else {
                    candidateName = URL(string: firstLink)?.lastPathComponent ?? ""
                }
                if let category = try? await categoryStore.matchingCategory(
                    fileName: candidateName,
                    url: firstLink
                ) {
                    resolvedCategoryID = category.id
                    if let path = category.downloadPath {
                        resolvedFolder = URL(fileURLWithPath: path, isDirectory: true)
                    }
                }
            }
            let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
            let links = trimmedLink
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !links.isEmpty else {
                self.errorMessage = "请输入下载地址"
                return
            }
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitName = trimmedName?.isEmpty == false ? trimmedName : nil
            do {
                var ids: [DownloadID] = []
                for (index, item) in links.enumerated() {
                    var source: DownloadSource
                    if let integrationItems, integrationItems.indices.contains(index) {
                        source = integrationItems[index].asCoreSource()
                        source.link = item
                        if links.count == 1, let explicitName {
                            source.suggestedName = explicitName
                        }
                    } else {
                        source = DownloadSource(
                            kind: item.lowercased().contains(".m3u8") ? .hls : .http,
                            link: item,
                            suggestedName: links.count == 1 ? explicitName : nil
                        )
                    }
                    let id = try await service.add(AddDownloadRequest(
                        source: source,
                        folder: resolvedFolder.path,
                        name: links.count == 1 ? explicitName : nil,
                        queueID: queueID,
                        categoryID: resolvedCategoryID,
                        start: startImmediately
                    ))
                    ids.append(id)
                }
                if let queueID, let queueStore {
                    try await queueStore.assignItems(ids, to: queueID)
                }
                if let resolvedCategoryID, let categoryStore {
                    try await categoryStore.assignItems(ids, to: resolvedCategoryID)
                }
                await self.downloadList.reload()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func saveSettings(_ updated: AppSettingsModel) async throws {
        guard let settingsStore else {
            throw settingsStoreInitializationError
                ?? SettingsStoreError.writeFailed(settingsURL, "设置存储尚未初始化")
        }

        let saved = try await settingsStore.save(updated)
        settings = saved

        // UserDefaults preferences remain durable even when Core Data could
        // not initialize. The next healthy launch applies them to the core.
        guard let service else { return }

        await service.updateConfiguration(
            schedulerConfiguration: schedulerConfiguration(for: saved),
            retryPolicy: DownloadRetryPolicy(
                maxAttempts: max(1, saved.maxDownloadRetryCount),
                delay: .seconds(1)
            ),
            defaultFolder: URL(fileURLWithPath: saved.defaultDownloadFolder, isDirectory: true),
            networkConfiguration: networkConfiguration(for: saved)
        )
        do {
            try applyAutoStartOnBoot(saved.autoStartOnBoot)
            if saved.trackDeletedFilesOnDisk {
                await reconcileMissingFiles()
                startMissingFileMonitor()
            } else {
                missingFileTask?.cancel()
                missingFileTask = nil
            }
            stopIntegration()
            try startIntegration(service: service, settings: saved)
        } catch {
            refreshAutoStartStatus()
            throw error
        }
    }

    func refreshAutoStartStatus() {
        autoStartStatus = SMAppService.mainApp.status
    }

    var autoStartStatusTitle: String {
        switch autoStartStatus {
        case .enabled:
            return "已启用"
        case .notRegistered:
            return "未注册"
        case .requiresApproval:
            return "需要系统批准"
        case .notFound:
            return "当前应用不支持"
        @unknown default:
            return "未知状态"
        }
    }

    func reloadQueues() async {
        guard let queueStore else {
            queues = []
            queueModels = []
            return
        }
        do {
            let models = try await queueStore.load()
            queueModels = models
            queues = models.map { IntegrationQueue(id: $0.id, name: $0.name) }
            if let service {
                await service.updateQueuePolicies(
                    Dictionary(uniqueKeysWithValues: models.map { model in
                        (
                            model.id,
                            DownloadQueuePolicy(
                                maxConcurrent: model.maxConcurrent,
                                stopQueueOnEmpty: model.stopQueueOnEmpty,
                                completionAction: model.completionAction
                            )
                        )
                    })
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadPerHostSettings() async {
        guard let perHostSettingsStore else {
            perHostSettings = []
            return
        }
        do {
            perHostSettings = try await perHostSettingsStore.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadCategories() async {
        guard let categoryStore else {
            categories = []
            return
        }
        do {
            categories = try await categoryStore.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Download records can be removed through the main list, a browser
    /// request, or a future core workflow. Keep secondary metadata indexes in
    /// sync from one event path instead of relying on each delete button.
    private func removeMetadataReferences(for ids: Set<DownloadID>) {
        guard !ids.isEmpty else { return }
        let queueStore = self.queueStore
        let categoryStore = self.categoryStore
        Task { @MainActor [weak self] in
            do {
                try await queueStore?.assignItems(Array(ids), to: nil)
                try await categoryStore?.assignItems(Array(ids), to: nil)
                await self?.reloadQueues()
                await self?.reloadCategories()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func pruneMetadataReferences() async {
        let validIDs = Set(downloadList.downloads.map(\.id))
        do {
            if let queueStore {
                let stale = try await queueStore.load()
                    .flatMap { $0.queueItems.filter { !validIDs.contains($0) } }
                if !stale.isEmpty {
                    try await queueStore.assignItems(stale, to: nil)
                }
            }
            if let categoryStore {
                let stale = try await categoryStore.load()
                    .flatMap { $0.items.filter { !validIDs.contains($0) } }
                if !stale.isEmpty {
                    try await categoryStore.assignItems(stale, to: nil)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func savePerHostSettings(_ items: [PerHostSettingsItem]) async -> Bool {
        guard let perHostSettingsStore else {
            errorMessage = "主机设置存储尚未准备好"
            return false
        }
        do {
            let saved = try await perHostSettingsStore.save(items)
            perHostSettings = saved
            await service?.updatePerHostSettings(saved)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createQueue(name: String) {
        guard let queueStore else {
            errorMessage = "队列存储尚未准备好"
            return
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await queueStore.create(name: name)
                await self?.reloadQueues()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func saveQueue(_ model: DownloadQueueModel) {
        guard let queueStore else {
            errorMessage = "队列存储尚未准备好"
            return
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await queueStore.save(model)
                await self?.reloadQueues()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func deleteQueue(id: DownloadID) {
        guard let queueStore else {
            errorMessage = "队列存储尚未准备好"
            return
        }
        let service = self.service
        Task { @MainActor [weak self] in
            do {
                if let model = try? await queueStore.model(id: id), let service {
                    try await service.assignQueue(ids: model.queueItems, queueID: nil)
                }
                try await queueStore.remove(id: id)
                await self?.reloadQueues()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func addSelectedToQueue(_ queueID: DownloadID, ids: Set<DownloadID>) {
        guard let queueStore, let service, !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.assignQueue(ids: Array(ids), queueID: queueID)
                try await queueStore.assignItems(Array(ids), to: queueID)
                await self?.reloadQueues()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func removeSelectedFromQueue(_ queueID: DownloadID, ids: Set<DownloadID>) {
        guard let queueStore, let service, !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.assignQueue(ids: Array(ids), queueID: nil)
                try await queueStore.assignItems(Array(ids), to: nil)
                await self?.reloadQueues()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func createCategory(
        name: String,
        icon: String = "folder",
        path: String = "",
        usePath: Bool = true,
        acceptedFileTypes: [String] = [],
        acceptedURLPatterns: [String] = []
    ) {
        guard let categoryStore else {
            errorMessage = "分类存储尚未准备好"
            return
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await categoryStore.create(
                    name: name,
                    icon: icon,
                    path: path,
                    usePath: usePath,
                    acceptedFileTypes: acceptedFileTypes,
                    acceptedURLPatterns: acceptedURLPatterns
                )
                await self?.reloadCategories()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func saveCategory(_ category: DownloadCategory) {
        guard let categoryStore else {
            errorMessage = "分类存储尚未准备好"
            return
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await categoryStore.save(category)
                await self?.reloadCategories()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func deleteCategory(id: DownloadID) {
        guard let categoryStore else {
            errorMessage = "分类存储尚未准备好"
            return
        }
        let service = self.service
        Task { @MainActor [weak self] in
            do {
                let model = try await categoryStore.model(id: id)
                if let service {
                    try await service.assignCategory(ids: model.items, categoryID: nil)
                }
                try await categoryStore.remove(id: id)
                await self?.reloadCategories()
                await self?.downloadList.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func assignSelectedToCategory(_ categoryID: DownloadID?, ids: Set<DownloadID>) {
        guard let categoryStore, let service, !ids.isEmpty else { return }
        let values = Array(ids)
        Task { @MainActor [weak self] in
            do {
                try await service.assignCategory(ids: values, categoryID: categoryID)
                try await categoryStore.assignItems(values, to: categoryID)
                await self?.reloadCategories()
                await self?.downloadList.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func startQueue(_ queueID: DownloadID) {
        downloadList.startQueue(
            queueID,
            orderedIDs: queueModels.first(where: { $0.id == queueID })?.queueItems
        )
    }

    func stopQueue(_ queueID: DownloadID) {
        downloadList.stopQueue(queueID)
    }

    private func startQueueScheduleMonitor() {
        guard queueScheduleTask == nil else { return }
        queueScheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.applyQueueSchedules()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func startQueueEventMonitor() {
        guard queueEventTask == nil, let service else { return }
        queueEventTask = Task { @MainActor [weak self] in
            let events = await service.queueEvents()
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.handleQueueEvent(event)
            }
        }
    }

    /// Keeps completion/failure notifications alive even when the main window
    /// has been closed. Completion-panel presentation is handled by the
    /// download-list lifecycle callback; notification delivery remains owned
    /// by the application lifecycle.
    private func startDownloadEventMonitor() {
        guard downloadEventTask == nil, let service else { return }
        downloadEventTask = Task { @MainActor [weak self] in
            let events = await service.events()
            for await event in events {
                guard !Task.isCancelled, let self else { break }
                self.handleDownloadEvent(event)
            }
        }
    }

    private func handleDownloadEvent(_ event: DownloadEvent) {
        switch event {
        case .created(let record):
            notificationStatuses[record.id] = record.status
        case .updated(let record):
            let previous = notificationStatuses[record.id]
            if record.status == .completed, previous != .completed {
                NotificationController.shared.notifyCompletion(
                    record: record,
                    soundEnabled: settings.notificationSound,
                    soundPath: settings.successNotificationSound.isEmpty
                        ? settings.generalNotificationSound
                        : settings.successNotificationSound
                )
            } else if record.status == .failed, previous != .failed {
                NotificationController.shared.notifyFailure(
                    record: record,
                    soundEnabled: settings.notificationSound,
                    soundPath: settings.errorNotificationSound.isEmpty
                        ? settings.generalNotificationSound
                        : settings.errorNotificationSound
                )
            }
            notificationStatuses[record.id] = record.status
        case .removed(let id):
            notificationStatuses[id] = nil
        case .activeConnectionCountChanged:
            break
        }
    }

    private func handleQueueEvent(_ event: DownloadQueueEvent) {
        guard case let .becameEmpty(queueID, completionAction) = event else { return }
        guard completionAction != .none else { return }
        let name = queueModels.first(where: { $0.id == queueID })?.name ?? "队列"
        let action: String
        switch completionAction {
        case .none: return
        case .shutdown: action = "关机"
        case .sleep: action = "睡眠"
        case .hibernate: action = "休眠"
        case .lock: action = "锁定屏幕"
        }
        // Power commands are intentionally not issued from the core. A
        // visible notice makes the configured action observable until the
        // macOS confirmation controller is available.
        noticeMessage = "\(name) 已完成，配置的完成动作是“\(action)”。请在 macOS 中确认后执行。"
    }

    private func applyQueueSchedules() async {
        let now = Date()
        let ids = Set(queueModels.map(\.id))
        scheduledQueueStates = scheduledQueueStates.filter { ids.contains($0.key) }
        for model in queueModels {
            guard model.scheduledTimes.isEnabled else {
                scheduledQueueStates[model.id] = nil
                continue
            }
            let active = model.scheduledTimes.isActive(at: now)
            let wasActive = scheduledQueueStates[model.id] ?? false
            if active && !wasActive {
                downloadList.startQueue(model.id, orderedIDs: model.queueItems)
            } else if !active && wasActive {
                downloadList.stopQueue(model.id)
            }
            scheduledQueueStates[model.id] = active
        }
    }

    private func startIntegration(service: DownloadService, settings: AppSettingsModel) throws {
        let queueStore = self.queueStore
        let categoryStore = self.categoryStore
        let coreHandler = CoreDownloadIntegrationHandler(
            service: service,
            queuesProvider: {
                guard let queueStore else { return [] }
                return try await queueStore.load().map {
                    IntegrationQueue(id: $0.id, name: $0.name)
                }
            },
            queueItemAdder: { [queueStore] queueID, downloadID in
                guard let queueStore else { return }
                try await queueStore.assignItems([downloadID], to: queueID)
            },
            categoryItemAdder: { [categoryStore] categoryID, downloadID in
                guard let categoryStore else { return }
                try await categoryStore.assignItems([downloadID], to: categoryID)
            },
            interactiveAddHandler: { [weak self] request in
                guard let self else {
                    throw DownloadIntegrationError.confirmationUnavailable
                }
                try await self.requestBrowserDownloadConfirmation(request)
            }
        )
        let generation = UUID()
        integrationGeneration = generation
        var server: LoopbackHTTPServer?
        if let configurationError = settings.httpIntegrationConfigurationError {
            errorMessage = configurationError
        } else if settings.apiEnabled {
            do {
                let router = IntegrationRouter(
                    handler: coreHandler,
                    apiKey: settings.apiAuthEnabled ? settings.apiAuthKey : nil,
                    allowAnonymous: !settings.apiAuthEnabled && settings.apiAnonymousAccessConfirmed
                )
                let loopback = try LoopbackHTTPServer(port: UInt16(settings.apiPort), router: router) { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.integrationGeneration == generation else { return }
                        self.integrationServer = nil
                        self.errorMessage = message
                    }
                }
                loopback.start()
                server = loopback
            } catch {
                errorMessage = "HTTP 连接无法启动：\(error.localizedDescription)"
            }
        }

        let socketURL = AppPaths.nativeMessagingSocketURL()
        let socketServer = PrivateSocketServer(socketURL: socketURL) { message in
            do {
                switch message.action {
                case "ping":
                    return PrivateSocketMessage(requestId: message.requestId, action: "ping", payload: "true")
                case "add":
                    let request = try JSONDecoder().decode(
                        AddDownloadsRequest.self,
                        from: Data(message.payload.utf8)
                    )
                    try await coreHandler.addFromBrowser(request)
                    return PrivateSocketMessage(requestId: message.requestId, action: "add", payload: "true")
                default:
                    return PrivateSocketMessage(
                        requestId: message.requestId,
                        action: message.action,
                        payload: "{\"message\":\"不支持的操作\"}",
                        isError: true
                    )
                }
            } catch {
                let payload = (try? String(
                    data: JSONEncoder().encode(NativeMessagingErrorPayload(
                        errorType: String(describing: type(of: error)),
                        message: error.localizedDescription
                    )),
                    encoding: .utf8
                )) ?? "{\"message\":\"请求失败\"}"
                return PrivateSocketMessage(
                    requestId: message.requestId,
                    action: message.action,
                    payload: payload,
                    isError: true
                )
            }
        }
        do {
            try socketServer.start()
        } catch {
            server?.stop()
            throw error
        }
        integrationServer = server
        privateSocketServer = socketServer
        installNativeMessagingManifestIfAvailable()
    }

    private func requestBrowserDownloadConfirmation(_ request: AddDownloadsRequest) throws {
        guard let onBrowserDownloadRequest else {
            throw DownloadIntegrationError.confirmationUnavailable
        }
        onBrowserDownloadRequest(request)
    }

    private func stopIntegration() {
        integrationGeneration = UUID()
        integrationServer?.stop()
        integrationServer = nil
        privateSocketServer?.stop()
        privateSocketServer = nil
    }

    private func installNativeMessagingManifestIfAvailable() {
        let environment = ProcessInfo.processInfo.environment["CDM_NATIVE_HOST_PATH"]
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/CoolDownloadManagerNativeMessagingHost")
        let hostURL = environment.map(URL.init(fileURLWithPath:)) ?? bundled
        guard FileManager.default.isExecutableFile(atPath: hostURL.path) else { return }
        do {
            _ = try NativeMessagingManifestInstaller.install(hostExecutableURL: hostURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func networkConfiguration(for settings: AppSettingsModel) -> HTTPNetworkConfiguration {
        HTTPNetworkConfiguration(
            proxyMode: HTTPProxyMode(rawValue: settings.proxyMode) ?? .system,
            proxyHost: settings.proxyHost,
            proxyPort: settings.proxyPort,
            proxyUsername: settings.proxyUsername,
            proxyPassword: settings.proxyPassword,
            proxyPACURL: settings.proxyPACURL,
            ignoreSSLCertificates: settings.ignoreSSLCertificates
        )
    }

    private func schedulerConfiguration(for settings: AppSettingsModel) -> DownloadSchedulerConfiguration {
        DownloadSchedulerConfiguration(
            maxConcurrentDownloads: settings.maxConcurrentDownloads,
            maxConnectionsPerDownload: settings.threadCount,
            dynamicPartCreation: settings.dynamicPartCreation,
            appendExtensionToIncompleteDownloads: settings.appendExtensionToIncompleteDownloads,
            useSparseFileAllocation: settings.useSparseFileAllocation,
            deletePartialFileOnDownloadCancellation: settings.deletePartialFileOnDownloadCancellation,
            speedLimit: settings.speedLimit,
            userAgent: settings.userAgent,
            useServerLastModifiedTime: settings.useServerLastModifiedTime
        )
    }

    private func applyAutoStartOnBoot(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        }
        refreshAutoStartStatus()
    }

    private func reconcileMissingFiles() async {
        do {
            _ = try await service?.removeCompletedDownloadsMissingFiles()
            await downloadList.reload()
        } catch {
            errorMessage = "无法同步已删除文件：\(error.localizedDescription)"
        }
    }

    private func startMissingFileMonitor() {
        missingFileTask?.cancel()
        missingFileTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.settings.trackDeletedFilesOnDisk else { break }
                await self.reconcileMissingFiles()
            }
        }
    }
}
