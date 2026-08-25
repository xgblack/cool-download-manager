import Foundation

/// Persistent application settings compatible with the historical
/// `.abdm/config/appSettings.json` key names.
public struct AppSettingsModel: Codable, Equatable, Sendable {
    public var theme: String
    public var uiScale: Double?
    public var mergeTopBarWithTitleBar: Bool
    public var showIconLabels: Bool
    public var useRelativeDateTime: Bool
    public var threadCount: Int
    public var maxConcurrentDownloads: Int
    public var maxDownloadRetryCount: Int
    public var dynamicPartCreation: Bool
    public var useServerLastModifiedTime: Bool
    public var appendExtensionToIncompleteDownloads: Bool
    public var useSparseFileAllocation: Bool
    public var useAverageSpeed: Bool
    public var showDownloadProgressDialog: Bool
    public var showDownloadCompletionDialog: Bool
    public var focusDownloadProgressDialogOnStart: Bool
    public var focusDownloadCompletionDialogOnFinish: Bool
    public var speedLimit: Int64
    public var autoStartOnBoot: Bool
    public var notificationSound: Bool
    public var generalNotificationSound: String
    public var errorNotificationSound: String
    public var successNotificationSound: String
    public var defaultDownloadFolder: String
    public var apiEnabled: Bool
    public var apiPort: Int
    public var apiAuthEnabled: Bool
    public var apiAuthKey: String
    public var trackDeletedFilesOnDisk: Bool
    public var deletePartialFileOnDownloadCancellation: Bool
    public var sizeUnit: String
    public var speedUnit: String
    public var ignoreSSLCertificates: Bool
    public var useCategoryByDefault: Bool
    public var userAgent: String

    // Network settings introduced by the native implementation. They use
    // independent keys so older installations can ignore them safely.
    public var proxyMode: String
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String
    public var proxyPassword: String
    public var proxyPACURL: String

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(
            theme: "dark",
            uiScale: nil,
            mergeTopBarWithTitleBar: true,
            showIconLabels: true,
            useRelativeDateTime: true,
            threadCount: 8,
            maxConcurrentDownloads: 3,
            maxDownloadRetryCount: 3,
            dynamicPartCreation: true,
            useServerLastModifiedTime: false,
            appendExtensionToIncompleteDownloads: false,
            useSparseFileAllocation: true,
            useAverageSpeed: true,
            showDownloadProgressDialog: true,
            showDownloadCompletionDialog: true,
            focusDownloadProgressDialogOnStart: false,
            focusDownloadCompletionDialogOnFinish: false,
            speedLimit: 0,
            autoStartOnBoot: true,
            notificationSound: true,
            generalNotificationSound: "",
            errorNotificationSound: "",
            successNotificationSound: "",
            defaultDownloadFolder: home.appendingPathComponent("Downloads/ABDM", isDirectory: true).path,
            apiEnabled: true,
            apiPort: 15151,
            apiAuthEnabled: false,
            apiAuthKey: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            trackDeletedFilesOnDisk: false,
            deletePartialFileOnDownloadCancellation: false,
            sizeUnit: "BinaryBytes",
            speedUnit: "BinaryBytes",
            ignoreSSLCertificates: false,
            useCategoryByDefault: true,
            userAgent: "",
            proxyMode: "system",
            proxyHost: "",
            proxyPort: 8080,
            proxyUsername: "",
            proxyPassword: "",
            proxyPACURL: ""
        )
    }

    public init(
        theme: String,
        uiScale: Double?,
        mergeTopBarWithTitleBar: Bool,
        showIconLabels: Bool,
        useRelativeDateTime: Bool,
        threadCount: Int,
        maxConcurrentDownloads: Int,
        maxDownloadRetryCount: Int,
        dynamicPartCreation: Bool,
        useServerLastModifiedTime: Bool,
        appendExtensionToIncompleteDownloads: Bool,
        useSparseFileAllocation: Bool,
        useAverageSpeed: Bool,
        showDownloadProgressDialog: Bool,
        showDownloadCompletionDialog: Bool,
        focusDownloadProgressDialogOnStart: Bool,
        focusDownloadCompletionDialogOnFinish: Bool,
        speedLimit: Int64,
        autoStartOnBoot: Bool,
        notificationSound: Bool,
        generalNotificationSound: String,
        errorNotificationSound: String,
        successNotificationSound: String,
        defaultDownloadFolder: String,
        apiEnabled: Bool,
        apiPort: Int,
        apiAuthEnabled: Bool,
        apiAuthKey: String,
        trackDeletedFilesOnDisk: Bool,
        deletePartialFileOnDownloadCancellation: Bool,
        sizeUnit: String,
        speedUnit: String,
        ignoreSSLCertificates: Bool,
        useCategoryByDefault: Bool,
        userAgent: String,
        proxyMode: String,
        proxyHost: String,
        proxyPort: Int,
        proxyUsername: String,
        proxyPassword: String,
        proxyPACURL: String
    ) {
        self.theme = theme
        self.uiScale = uiScale
        self.mergeTopBarWithTitleBar = mergeTopBarWithTitleBar
        self.showIconLabels = showIconLabels
        self.useRelativeDateTime = useRelativeDateTime
        self.threadCount = threadCount
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxDownloadRetryCount = maxDownloadRetryCount
        self.dynamicPartCreation = dynamicPartCreation
        self.useServerLastModifiedTime = useServerLastModifiedTime
        self.appendExtensionToIncompleteDownloads = appendExtensionToIncompleteDownloads
        self.useSparseFileAllocation = useSparseFileAllocation
        self.useAverageSpeed = useAverageSpeed
        self.showDownloadProgressDialog = showDownloadProgressDialog
        self.showDownloadCompletionDialog = showDownloadCompletionDialog
        self.focusDownloadProgressDialogOnStart = focusDownloadProgressDialogOnStart
        self.focusDownloadCompletionDialogOnFinish = focusDownloadCompletionDialogOnFinish
        self.speedLimit = speedLimit
        self.autoStartOnBoot = autoStartOnBoot
        self.notificationSound = notificationSound
        self.generalNotificationSound = generalNotificationSound
        self.errorNotificationSound = errorNotificationSound
        self.successNotificationSound = successNotificationSound
        self.defaultDownloadFolder = defaultDownloadFolder
        self.apiEnabled = apiEnabled
        self.apiPort = apiPort
        self.apiAuthEnabled = apiAuthEnabled
        self.apiAuthKey = apiAuthKey
        self.trackDeletedFilesOnDisk = trackDeletedFilesOnDisk
        self.deletePartialFileOnDownloadCancellation = deletePartialFileOnDownloadCancellation
        self.sizeUnit = sizeUnit
        self.speedUnit = speedUnit
        self.ignoreSSLCertificates = ignoreSSLCertificates
        self.useCategoryByDefault = useCategoryByDefault
        self.userAgent = userAgent
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.proxyPACURL = proxyPACURL
    }

    private enum CodingKeys: String, CodingKey {
        case theme, uiScale, mergeTopBarWithTitleBar, showIconLabels, useRelativeDateTime
        case threadCount, maxConcurrentDownloads, maxDownloadRetryCount, dynamicPartCreation
        case useServerLastModifiedTime, appendExtensionToIncompleteDownloads, useSparseFileAllocation
        case useAverageSpeed, showDownloadProgressDialog, showDownloadCompletionDialog
        case focusDownloadProgressDialogOnStart, focusDownloadCompletionDialogOnFinish, speedLimit
        case autoStartOnBoot, notificationSound, generalNotificationSound, errorNotificationSound
        case successNotificationSound, defaultDownloadFolder, apiEnabled, apiPort, apiAuthEnabled, apiAuthKey
        case trackDeletedFilesOnDisk, deletePartialFileOnDownloadCancellation, sizeUnit, speedUnit
        case ignoreSSLCertificates, useCategoryByDefault, userAgent
        case proxyMode, proxyHost, proxyPort, proxyUsername, proxyPassword, proxyPACURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults()
        self.init(
            theme: try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme,
            uiScale: try c.decodeIfPresent(Double.self, forKey: .uiScale),
            mergeTopBarWithTitleBar: try c.decodeIfPresent(Bool.self, forKey: .mergeTopBarWithTitleBar) ?? d.mergeTopBarWithTitleBar,
            showIconLabels: try c.decodeIfPresent(Bool.self, forKey: .showIconLabels) ?? d.showIconLabels,
            useRelativeDateTime: try c.decodeIfPresent(Bool.self, forKey: .useRelativeDateTime) ?? d.useRelativeDateTime,
            threadCount: try c.decodeIfPresent(Int.self, forKey: .threadCount) ?? d.threadCount,
            maxConcurrentDownloads: try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? d.maxConcurrentDownloads,
            maxDownloadRetryCount: try c.decodeIfPresent(Int.self, forKey: .maxDownloadRetryCount) ?? d.maxDownloadRetryCount,
            dynamicPartCreation: try c.decodeIfPresent(Bool.self, forKey: .dynamicPartCreation) ?? d.dynamicPartCreation,
            useServerLastModifiedTime: try c.decodeIfPresent(Bool.self, forKey: .useServerLastModifiedTime) ?? d.useServerLastModifiedTime,
            appendExtensionToIncompleteDownloads: try c.decodeIfPresent(Bool.self, forKey: .appendExtensionToIncompleteDownloads) ?? d.appendExtensionToIncompleteDownloads,
            useSparseFileAllocation: try c.decodeIfPresent(Bool.self, forKey: .useSparseFileAllocation) ?? d.useSparseFileAllocation,
            useAverageSpeed: try c.decodeIfPresent(Bool.self, forKey: .useAverageSpeed) ?? d.useAverageSpeed,
            showDownloadProgressDialog: try c.decodeIfPresent(Bool.self, forKey: .showDownloadProgressDialog) ?? d.showDownloadProgressDialog,
            showDownloadCompletionDialog: try c.decodeIfPresent(Bool.self, forKey: .showDownloadCompletionDialog) ?? d.showDownloadCompletionDialog,
            focusDownloadProgressDialogOnStart: try c.decodeIfPresent(Bool.self, forKey: .focusDownloadProgressDialogOnStart) ?? d.focusDownloadProgressDialogOnStart,
            focusDownloadCompletionDialogOnFinish: try c.decodeIfPresent(Bool.self, forKey: .focusDownloadCompletionDialogOnFinish) ?? d.focusDownloadCompletionDialogOnFinish,
            speedLimit: try c.decodeIfPresent(Int64.self, forKey: .speedLimit) ?? d.speedLimit,
            autoStartOnBoot: try c.decodeIfPresent(Bool.self, forKey: .autoStartOnBoot) ?? d.autoStartOnBoot,
            notificationSound: try c.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? d.notificationSound,
            generalNotificationSound: try c.decodeIfPresent(String.self, forKey: .generalNotificationSound) ?? d.generalNotificationSound,
            errorNotificationSound: try c.decodeIfPresent(String.self, forKey: .errorNotificationSound) ?? d.errorNotificationSound,
            successNotificationSound: try c.decodeIfPresent(String.self, forKey: .successNotificationSound) ?? d.successNotificationSound,
            defaultDownloadFolder: try c.decodeIfPresent(String.self, forKey: .defaultDownloadFolder) ?? d.defaultDownloadFolder,
            apiEnabled: try c.decodeIfPresent(Bool.self, forKey: .apiEnabled) ?? d.apiEnabled,
            apiPort: try c.decodeIfPresent(Int.self, forKey: .apiPort) ?? d.apiPort,
            apiAuthEnabled: try c.decodeIfPresent(Bool.self, forKey: .apiAuthEnabled) ?? d.apiAuthEnabled,
            apiAuthKey: try c.decodeIfPresent(String.self, forKey: .apiAuthKey) ?? d.apiAuthKey,
            trackDeletedFilesOnDisk: try c.decodeIfPresent(Bool.self, forKey: .trackDeletedFilesOnDisk) ?? d.trackDeletedFilesOnDisk,
            deletePartialFileOnDownloadCancellation: try c.decodeIfPresent(Bool.self, forKey: .deletePartialFileOnDownloadCancellation) ?? d.deletePartialFileOnDownloadCancellation,
            sizeUnit: try c.decodeIfPresent(String.self, forKey: .sizeUnit) ?? d.sizeUnit,
            speedUnit: try c.decodeIfPresent(String.self, forKey: .speedUnit) ?? d.speedUnit,
            ignoreSSLCertificates: try c.decodeIfPresent(Bool.self, forKey: .ignoreSSLCertificates) ?? d.ignoreSSLCertificates,
            useCategoryByDefault: try c.decodeIfPresent(Bool.self, forKey: .useCategoryByDefault) ?? d.useCategoryByDefault,
            userAgent: try c.decodeIfPresent(String.self, forKey: .userAgent) ?? d.userAgent,
            proxyMode: try c.decodeIfPresent(String.self, forKey: .proxyMode) ?? d.proxyMode,
            proxyHost: try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? d.proxyHost,
            proxyPort: try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? d.proxyPort,
            proxyUsername: try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? d.proxyUsername,
            proxyPassword: try c.decodeIfPresent(String.self, forKey: .proxyPassword) ?? d.proxyPassword,
            proxyPACURL: try c.decodeIfPresent(String.self, forKey: .proxyPACURL) ?? d.proxyPACURL
        )
    }
}

public enum SettingsStoreError: Error, LocalizedError, Sendable, Equatable {
    case corrupt(URL, String)
    case invalid(String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, let reason): return "无法读取设置 \(url.path)：\(reason)"
        case .invalid(let reason): return reason
        case .writeFailed(let url, let reason): return "无法保存设置 \(url.path)：\(reason)"
        }
    }
}

public actor SettingsStore {
    public nonisolated let settingsURL: URL
    private var rawObject: [String: JSONValue] = [:]
    private var loaded = false

    public init(dataRoot: URL) throws {
        let config = dataRoot.standardizedFileURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        settingsURL = config.appendingPathComponent("appSettings.json")
    }

    public func load() throws -> AppSettingsModel {
        if loaded {
            return try decode(rawObject)
        }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            rawObject = [:]
            loaded = true
            return .defaults()
        }
        do {
            let raw = try JSONValue(data: Data(contentsOf: settingsURL))
            guard case .object(let object) = raw else {
                throw SettingsStoreError.corrupt(settingsURL, "根值不是 JSON 对象")
            }
            let decoded = try decode(object)
            rawObject = object
            loaded = true
            return decoded
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.corrupt(settingsURL, error.localizedDescription)
        }
    }

    @discardableResult
    public func save(_ settings: AppSettingsModel) throws -> AppSettingsModel {
        try validate(settings)
        if !loaded {
            _ = try load()
        }
        updateRaw(with: settings)
        do {
            let data = try JSONValue.object(rawObject).data()
            let directory = settingsURL.deletingLastPathComponent()
            let temporary = directory.appendingPathComponent(".appSettings.\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw SettingsStoreError.writeFailed(settingsURL, "无法创建临时文件")
            }
            do {
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                if FileManager.default.fileExists(atPath: settingsURL.path) {
                    _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: settingsURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw SettingsStoreError.writeFailed(settingsURL, error.localizedDescription)
            }
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.writeFailed(settingsURL, error.localizedDescription)
        }
        return settings
    }

    private func decode(_ object: [String: JSONValue]) throws -> AppSettingsModel {
        let data = try JSONValue.object(object).data()
        do {
            return try JSONDecoder().decode(AppSettingsModel.self, from: data)
        } catch {
            throw SettingsStoreError.corrupt(settingsURL, error.localizedDescription)
        }
    }

    private func validate(_ settings: AppSettingsModel) throws {
        guard (1...64).contains(settings.threadCount) else {
            throw SettingsStoreError.invalid("线程数必须在 1 到 64 之间")
        }
        guard (0...256).contains(settings.maxConcurrentDownloads) else {
            throw SettingsStoreError.invalid("最大并发数必须在 0 到 256 之间")
        }
        guard (0...100).contains(settings.maxDownloadRetryCount) else {
            throw SettingsStoreError.invalid("最大重试次数必须在 0 到 100 之间")
        }
        guard settings.speedLimit >= 0 else {
            throw SettingsStoreError.invalid("全局速度限制不能为负数")
        }
        guard (1...65535).contains(settings.apiPort) else {
            throw SettingsStoreError.invalid("API 端口必须在 1 到 65535 之间")
        }
        guard settings.proxyPort >= 1 && settings.proxyPort <= 65535 else {
            throw SettingsStoreError.invalid("代理端口必须在 1 到 65535 之间")
        }
        if settings.proxyMode == "manual" && settings.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SettingsStoreError.invalid("手动代理模式必须填写代理主机")
        }
        if settings.proxyMode == "pac" {
            guard let url = URL(string: settings.proxyPACURL),
                  url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https",
                  url.host != nil else {
                throw SettingsStoreError.invalid("PAC 模式必须填写有效的 HTTP(S) URL")
            }
        }
        guard !settings.defaultDownloadFolder.isEmpty else {
            throw SettingsStoreError.invalid("默认下载目录不能为空")
        }
    }

    private func updateRaw(with settings: AppSettingsModel) {
        func set(_ key: String, _ value: JSONValue) { rawObject[key] = value }
        [
            "defaultDarkTheme",
            "defaultLightTheme",
            "language",
            "font",
            "useNativeMenuBar",
            "useSystemTray",
            "dnsServers"
        ].forEach { rawObject.removeValue(forKey: $0) }
        set("theme", .string(settings.theme))
        if let scale = settings.uiScale { set("uiScale", .number(String(scale))) } else { rawObject.removeValue(forKey: "uiScale") }
        set("mergeTopBarWithTitleBar", .bool(settings.mergeTopBarWithTitleBar))
        set("showIconLabels", .bool(settings.showIconLabels))
        set("useRelativeDateTime", .bool(settings.useRelativeDateTime))
        set("threadCount", .number(String(settings.threadCount)))
        set("maxConcurrentDownloads", .number(String(settings.maxConcurrentDownloads)))
        set("maxDownloadRetryCount", .number(String(settings.maxDownloadRetryCount)))
        set("dynamicPartCreation", .bool(settings.dynamicPartCreation))
        set("useServerLastModifiedTime", .bool(settings.useServerLastModifiedTime))
        set("appendExtensionToIncompleteDownloads", .bool(settings.appendExtensionToIncompleteDownloads))
        set("useSparseFileAllocation", .bool(settings.useSparseFileAllocation))
        set("useAverageSpeed", .bool(settings.useAverageSpeed))
        set("showDownloadProgressDialog", .bool(settings.showDownloadProgressDialog))
        set("showDownloadCompletionDialog", .bool(settings.showDownloadCompletionDialog))
        set("focusDownloadProgressDialogOnStart", .bool(settings.focusDownloadProgressDialogOnStart))
        set("focusDownloadCompletionDialogOnFinish", .bool(settings.focusDownloadCompletionDialogOnFinish))
        set("speedLimit", .number(String(settings.speedLimit)))
        set("autoStartOnBoot", .bool(settings.autoStartOnBoot))
        set("notificationSound", .bool(settings.notificationSound))
        set("generalNotificationSound", .string(settings.generalNotificationSound))
        set("errorNotificationSound", .string(settings.errorNotificationSound))
        set("successNotificationSound", .string(settings.successNotificationSound))
        set("defaultDownloadFolder", .string(settings.defaultDownloadFolder))
        set("apiEnabled", .bool(settings.apiEnabled))
        set("apiPort", .number(String(settings.apiPort)))
        set("apiAuthEnabled", .bool(settings.apiAuthEnabled))
        set("apiAuthKey", .string(settings.apiAuthKey))
        set("trackDeletedFilesOnDisk", .bool(settings.trackDeletedFilesOnDisk))
        set("deletePartialFileOnDownloadCancellation", .bool(settings.deletePartialFileOnDownloadCancellation))
        set("sizeUnit", .string(settings.sizeUnit))
        set("speedUnit", .string(settings.speedUnit))
        set("ignoreSSLCertificates", .bool(settings.ignoreSSLCertificates))
        set("useCategoryByDefault", .bool(settings.useCategoryByDefault))
        set("userAgent", .string(settings.userAgent))
        set("proxyMode", .string(settings.proxyMode))
        set("proxyHost", .string(settings.proxyHost))
        set("proxyPort", .number(String(settings.proxyPort)))
        set("proxyUsername", .string(settings.proxyUsername))
        set("proxyPassword", .string(settings.proxyPassword))
        set("proxyPACURL", .string(settings.proxyPACURL))
    }
}
