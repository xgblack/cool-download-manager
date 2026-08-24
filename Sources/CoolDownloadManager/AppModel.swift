import Foundation
import SwiftUI
import CoolDownloadCore
import CoolDownloadIntegration

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var downloads: [DownloadRecord] = []
    @Published var urlText = ""
    @Published var nameText = ""
    @Published var folderURL: URL
    @Published var errorMessage: String?
    @Published var isReady = false

    let service: DownloadService?
    private let store: DownloadStore?
    private let queueStore: LegacyQueueStore?
    private var eventTask: Task<Void, Never>?
    private var integrationServer: LoopbackHTTPServer?
    private var privateSocketServer: PrivateSocketServer?
    private var isShuttingDown = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataRoot = home.appendingPathComponent(".abdm", isDirectory: true)
        let defaultFolder = home.appendingPathComponent("Downloads", isDirectory: true)
        folderURL = defaultFolder

        do {
            let store = try DownloadStore(rootURL: dataRoot)
            self.store = store
            let environment = ProcessInfo.processInfo.environment
            let maxConcurrent = environment["CDM_MAX_CONCURRENT_DOWNLOADS"].flatMap(Int.init) ?? 3
            let rangeConnections = environment["CDM_RANGE_CONNECTIONS"].flatMap(Int.init) ?? 1
            self.service = DownloadService(
                store: store,
                defaultFolder: defaultFolder,
                schedulerConfiguration: DownloadSchedulerConfiguration(
                    maxConcurrentDownloads: maxConcurrent,
                    maxConnectionsPerDownload: rangeConnections
                )
            )
        } catch {
            self.store = nil
            self.service = nil
            self.errorMessage = error.localizedDescription
        }
        self.queueStore = try? LegacyQueueStore(dataRoot: dataRoot)

        Task { await boot() }
    }

    deinit {
        eventTask?.cancel()
        integrationServer?.stop()
        privateSocketServer?.stop()
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        eventTask?.cancel()
        eventTask = nil

        // Stop accepting browser requests before cancelling download tasks so
        // a quit cannot race a new add/start command with state persistence.
        integrationServer?.stop()
        integrationServer = nil
        privateSocketServer?.stop()
        privateSocketServer = nil
        if let service {
            await service.shutdown()
        }
    }

    func boot() async {
        guard !isShuttingDown else { return }
        do {
            guard let service else { return }
            try await service.boot()
            guard !isShuttingDown else {
                await service.shutdown()
                return
            }
            downloads = await service.snapshot().downloads
            let queueStore = self.queueStore
            let coreHandler = CoreDownloadIntegrationHandler(
                service: service,
                queuesProvider: {
                    try await queueStore?.load() ?? []
                }
            )
            let environment = ProcessInfo.processInfo.environment
            let configuredPort = environment["CDM_HTTP_PORT"].flatMap(UInt16.init)
                ?? IntegrationRouter.defaultPort
            let apiKey = environment["CDM_API_KEY"].flatMap { value in
                value.isEmpty ? nil : value
            }
            let router = IntegrationRouter(handler: coreHandler, apiKey: apiKey)
            let server = try LoopbackHTTPServer(port: configuredPort, router: router)
            server.start()
            guard !isShuttingDown else {
                server.stop()
                await service.shutdown()
                return
            }
            integrationServer = server
            let socketURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".abdm/config/native-messaging.sock")
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
                            payload: "{\"message\":\"unsupported action\"}",
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
                    )) ?? "{\"message\":\"request failed\"}"
                    return PrivateSocketMessage(
                        requestId: message.requestId,
                        action: message.action,
                        payload: payload,
                        isError: true
                    )
                }
            }
            try socketServer.start()
            guard !isShuttingDown else {
                socketServer.stop()
                server.stop()
                await service.shutdown()
                return
            }
            privateSocketServer = socketServer
            installNativeMessagingManifestIfAvailable()
            eventTask = Task { [weak self] in
                guard let self else { return }
                let events = await service.events()
                for await _ in events {
                    guard !Task.isCancelled else { break }
                    downloads = await service.snapshot().downloads
                }
            }
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func addAndStart() {
        guard let service else { return }
        let link = urlText
        let name = nameText.nilIfBlank
        let folder = folderURL.path
        Task {
            do {
                _ = try await service.add(AddDownloadRequest(
                    source: DownloadSource(kind: .http, link: link, suggestedName: name),
                    folder: folder,
                    name: name,
                    start: true
                ))
                urlText = ""
                nameText = ""
                downloads = await service.snapshot().downloads
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func start(_ record: DownloadRecord) {
        Task { await perform { guard let service = self.service else { return }; try await service.start(id: record.id) } }
    }

    func pause(_ record: DownloadRecord) {
        Task { await perform { guard let service = self.service else { return }; try await service.pause(ids: [record.id]) } }
    }

    func retry(_ record: DownloadRecord) {
        Task { await perform { guard let service = self.service else { return }; try await service.retry(ids: [record.id]) } }
    }

    func remove(_ record: DownloadRecord) {
        Task { await perform { guard let service = self.service else { return }; try await service.remove(ids: [record.id], removeFiles: false) } }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            if let service {
                downloads = await service.snapshot().downloads
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
