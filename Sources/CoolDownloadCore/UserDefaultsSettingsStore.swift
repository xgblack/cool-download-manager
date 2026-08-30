import Foundation

public struct UserDefaultsKey<Value>: Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

/// Minimal typed façade around UserDefaults. Values are kept as individual
/// property-list entries so settings can be inspected and changed with the
/// normal macOS defaults tools without another JSON document.
public final class TypedUserDefaults: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func value<Value>(_ key: UserDefaultsKey<Value>, default defaultValue: Value) -> Value {
        defaults.object(forKey: key.name) as? Value ?? defaultValue
    }

    public func set<Value>(_ value: Value?, for key: UserDefaultsKey<Value>) {
        defaults.set(value, forKey: key.name)
    }
}

/// UserDefaults-backed application settings. The old `settingsURL` property
/// remains as a diagnostic compatibility value, but it is never read or
/// written by this store.
public actor SettingsStore {
    public nonisolated let settingsURL: URL
    public nonisolated let defaults: TypedUserDefaults

    private let typed: TypedUserDefaults
    private let keychain: KeychainStore
    private var loaded = false
    private var cached: AppSettingsModel?

    public init(dataRoot: URL) throws {
        let suiteName = Self.suiteName(for: dataRoot)
        let defaults: UserDefaults
        if suiteName == AppPaths.bundleIdentifier {
            // An app's own bundle identifier is its standard defaults domain;
            // passing it back as an additional suite is invalid in-app.
            defaults = .standard
        } else {
            guard let suiteDefaults = UserDefaults(suiteName: suiteName) else {
                throw SettingsStoreError.writeFailed(
                    dataRoot.appendingPathComponent("appSettings.json"),
                    "无法创建 UserDefaults 存储"
                )
            }
            defaults = suiteDefaults
        }
        settingsURL = dataRoot.standardizedFileURL.appendingPathComponent("appSettings.json")
        self.defaults = TypedUserDefaults(defaults: defaults)
        typed = TypedUserDefaults(defaults: defaults)
        keychain = KeychainStore(service: "\(AppPaths.bundleIdentifier).\(suiteName)")
    }

    public func load() throws -> AppSettingsModel {
        if let cached { return cached }
        let fallback = AppSettingsModel.defaults()
        let value: AppSettingsModel
        do {
            value = try read(fallback: fallback)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.readFailed(settingsURL, error.localizedDescription)
        }
        let storedAPIKey = defaults.defaults.object(forKey: Keys.apiAuthKey.name) as? String
        if typed.value(Keys.schemaVersion, default: 0) == 0 || storedAPIKey == nil {
            try write(value)
        }
        cached = value
        loaded = true
        return value
    }

    @discardableResult
    public func save(_ settings: AppSettingsModel) throws -> AppSettingsModel {
        try validate(settings)
        try write(settings)
        cached = settings
        loaded = true
        return settings
    }

    private func read(fallback d: AppSettingsModel) throws -> AppSettingsModel {
        AppSettingsModel(
            theme: typed.value(Keys.theme, default: d.theme),
            uiScale: defaults.defaults.object(forKey: Keys.uiScale.name) as? Double,
            mergeTopBarWithTitleBar: typed.value(Keys.mergeTopBarWithTitleBar, default: d.mergeTopBarWithTitleBar),
            showIconLabels: typed.value(Keys.showIconLabels, default: d.showIconLabels),
            useRelativeDateTime: typed.value(Keys.useRelativeDateTime, default: d.useRelativeDateTime),
            threadCount: typed.value(Keys.threadCount, default: d.threadCount),
            maxConcurrentDownloads: typed.value(Keys.maxConcurrentDownloads, default: d.maxConcurrentDownloads),
            maxDownloadRetryCount: typed.value(Keys.maxDownloadRetryCount, default: d.maxDownloadRetryCount),
            dynamicPartCreation: typed.value(Keys.dynamicPartCreation, default: d.dynamicPartCreation),
            useServerLastModifiedTime: typed.value(Keys.useServerLastModifiedTime, default: d.useServerLastModifiedTime),
            appendExtensionToIncompleteDownloads: typed.value(Keys.appendExtensionToIncompleteDownloads, default: d.appendExtensionToIncompleteDownloads),
            useSparseFileAllocation: typed.value(Keys.useSparseFileAllocation, default: d.useSparseFileAllocation),
            useAverageSpeed: typed.value(Keys.useAverageSpeed, default: d.useAverageSpeed),
            showDownloadProgressDialog: typed.value(Keys.showDownloadProgressDialog, default: d.showDownloadProgressDialog),
            showDownloadCompletionDialog: typed.value(Keys.showDownloadCompletionDialog, default: d.showDownloadCompletionDialog),
            focusDownloadProgressDialogOnStart: typed.value(Keys.focusDownloadProgressDialogOnStart, default: d.focusDownloadProgressDialogOnStart),
            focusDownloadCompletionDialogOnFinish: typed.value(Keys.focusDownloadCompletionDialogOnFinish, default: d.focusDownloadCompletionDialogOnFinish),
            speedLimit: typed.value(Keys.speedLimit, default: d.speedLimit),
            autoStartOnBoot: typed.value(Keys.autoStartOnBoot, default: d.autoStartOnBoot),
            notificationSound: typed.value(Keys.notificationSound, default: d.notificationSound),
            generalNotificationSound: typed.value(Keys.generalNotificationSound, default: d.generalNotificationSound),
            errorNotificationSound: typed.value(Keys.errorNotificationSound, default: d.errorNotificationSound),
            successNotificationSound: typed.value(Keys.successNotificationSound, default: d.successNotificationSound),
            defaultDownloadFolder: typed.value(Keys.defaultDownloadFolder, default: d.defaultDownloadFolder),
            apiEnabled: typed.value(Keys.apiEnabled, default: d.apiEnabled),
            apiPort: typed.value(Keys.apiPort, default: d.apiPort),
            apiAuthEnabled: typed.value(Keys.apiAuthEnabled, default: d.apiAuthEnabled),
            apiAuthKey: typed.value(Keys.apiAuthKey, default: d.apiAuthKey),
            trackDeletedFilesOnDisk: typed.value(Keys.trackDeletedFilesOnDisk, default: d.trackDeletedFilesOnDisk),
            deletePartialFileOnDownloadCancellation: typed.value(Keys.deletePartialFileOnDownloadCancellation, default: d.deletePartialFileOnDownloadCancellation),
            sizeUnit: typed.value(Keys.sizeUnit, default: d.sizeUnit),
            speedUnit: typed.value(Keys.speedUnit, default: d.speedUnit),
            ignoreSSLCertificates: typed.value(Keys.ignoreSSLCertificates, default: d.ignoreSSLCertificates),
            useCategoryByDefault: typed.value(Keys.useCategoryByDefault, default: d.useCategoryByDefault),
            userAgent: typed.value(Keys.userAgent, default: d.userAgent),
            proxyMode: typed.value(Keys.proxyMode, default: d.proxyMode),
            proxyHost: typed.value(Keys.proxyHost, default: d.proxyHost),
            proxyPort: typed.value(Keys.proxyPort, default: d.proxyPort),
            proxyUsername: try keychain.read(account: "proxy/username") ?? "",
            proxyPassword: try keychain.read(account: "proxy/password") ?? "",
            proxyPACURL: typed.value(Keys.proxyPACURL, default: d.proxyPACURL)
        )
    }

    private func write(_ settings: AppSettingsModel) throws {
        typed.set(settings.theme, for: Keys.theme)
        if let uiScale = settings.uiScale { typed.set(uiScale, for: Keys.uiScale) }
        else { defaults.defaults.removeObject(forKey: Keys.uiScale.name) }
        typed.set(settings.mergeTopBarWithTitleBar, for: Keys.mergeTopBarWithTitleBar)
        typed.set(settings.showIconLabels, for: Keys.showIconLabels)
        typed.set(settings.useRelativeDateTime, for: Keys.useRelativeDateTime)
        typed.set(settings.threadCount, for: Keys.threadCount)
        typed.set(settings.maxConcurrentDownloads, for: Keys.maxConcurrentDownloads)
        typed.set(settings.maxDownloadRetryCount, for: Keys.maxDownloadRetryCount)
        typed.set(settings.dynamicPartCreation, for: Keys.dynamicPartCreation)
        typed.set(settings.useServerLastModifiedTime, for: Keys.useServerLastModifiedTime)
        typed.set(settings.appendExtensionToIncompleteDownloads, for: Keys.appendExtensionToIncompleteDownloads)
        typed.set(settings.useSparseFileAllocation, for: Keys.useSparseFileAllocation)
        typed.set(settings.useAverageSpeed, for: Keys.useAverageSpeed)
        typed.set(settings.showDownloadProgressDialog, for: Keys.showDownloadProgressDialog)
        typed.set(settings.showDownloadCompletionDialog, for: Keys.showDownloadCompletionDialog)
        typed.set(settings.focusDownloadProgressDialogOnStart, for: Keys.focusDownloadProgressDialogOnStart)
        typed.set(settings.focusDownloadCompletionDialogOnFinish, for: Keys.focusDownloadCompletionDialogOnFinish)
        typed.set(settings.speedLimit, for: Keys.speedLimit)
        typed.set(settings.autoStartOnBoot, for: Keys.autoStartOnBoot)
        typed.set(settings.notificationSound, for: Keys.notificationSound)
        typed.set(settings.generalNotificationSound, for: Keys.generalNotificationSound)
        typed.set(settings.errorNotificationSound, for: Keys.errorNotificationSound)
        typed.set(settings.successNotificationSound, for: Keys.successNotificationSound)
        typed.set(settings.defaultDownloadFolder, for: Keys.defaultDownloadFolder)
        typed.set(settings.apiEnabled, for: Keys.apiEnabled)
        typed.set(settings.apiPort, for: Keys.apiPort)
        typed.set(settings.apiAuthEnabled, for: Keys.apiAuthEnabled)
        typed.set(settings.apiAuthKey, for: Keys.apiAuthKey)
        typed.set(settings.trackDeletedFilesOnDisk, for: Keys.trackDeletedFilesOnDisk)
        typed.set(settings.deletePartialFileOnDownloadCancellation, for: Keys.deletePartialFileOnDownloadCancellation)
        typed.set(settings.sizeUnit, for: Keys.sizeUnit)
        typed.set(settings.speedUnit, for: Keys.speedUnit)
        typed.set(settings.ignoreSSLCertificates, for: Keys.ignoreSSLCertificates)
        typed.set(settings.useCategoryByDefault, for: Keys.useCategoryByDefault)
        typed.set(settings.userAgent, for: Keys.userAgent)
        typed.set(settings.proxyMode, for: Keys.proxyMode)
        typed.set(settings.proxyHost, for: Keys.proxyHost)
        typed.set(settings.proxyPort, for: Keys.proxyPort)
        typed.set(settings.proxyPACURL, for: Keys.proxyPACURL)
        do {
            let username = settings.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = settings.proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            try keychain.write(username.isEmpty ? nil : username, account: "proxy/username")
            try keychain.write(password.isEmpty ? nil : password, account: "proxy/password")
        } catch {
            throw SettingsStoreError.writeFailed(settingsURL, "无法保存代理凭据")
        }
        typed.set(1, for: Keys.schemaVersion)
    }

    private func validate(_ settings: AppSettingsModel) throws {
        guard (1...64).contains(settings.threadCount) else {
            throw SettingsStoreError.invalid("单任务最大连接数必须在 1 到 64 之间")
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
                  (url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"),
                  url.host != nil else {
                throw SettingsStoreError.invalid("PAC 模式必须填写有效的 HTTP(S) URL")
            }
        }
        guard !settings.defaultDownloadFolder.isEmpty else {
            throw SettingsStoreError.invalid("默认下载目录不能为空")
        }
    }

    private static func suiteName(for root: URL) -> String {
        let path = root.standardizedFileURL.path
        if path == AppPaths.applicationSupportDirectory().path {
            return AppPaths.bundleIdentifier
        }
        var hash: UInt64 = 1469598103934665603
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(AppPaths.bundleIdentifier).test.\(String(hash, radix: 16))"
    }

    private enum Keys {
        static let schemaVersion = UserDefaultsKey<Int>("storage.schemaVersion")
        static let theme = UserDefaultsKey<String>("theme")
        static let uiScale = UserDefaultsKey<Double>("uiScale")
        static let mergeTopBarWithTitleBar = UserDefaultsKey<Bool>("mergeTopBarWithTitleBar")
        static let showIconLabels = UserDefaultsKey<Bool>("showIconLabels")
        static let useRelativeDateTime = UserDefaultsKey<Bool>("useRelativeDateTime")
        static let threadCount = UserDefaultsKey<Int>("threadCount")
        static let maxConcurrentDownloads = UserDefaultsKey<Int>("maxConcurrentDownloads")
        static let maxDownloadRetryCount = UserDefaultsKey<Int>("maxDownloadRetryCount")
        static let dynamicPartCreation = UserDefaultsKey<Bool>("dynamicPartCreation")
        static let useServerLastModifiedTime = UserDefaultsKey<Bool>("useServerLastModifiedTime")
        static let appendExtensionToIncompleteDownloads = UserDefaultsKey<Bool>("appendExtensionToIncompleteDownloads")
        static let useSparseFileAllocation = UserDefaultsKey<Bool>("useSparseFileAllocation")
        static let useAverageSpeed = UserDefaultsKey<Bool>("useAverageSpeed")
        static let showDownloadProgressDialog = UserDefaultsKey<Bool>("showDownloadProgressDialog")
        static let showDownloadCompletionDialog = UserDefaultsKey<Bool>("showDownloadCompletionDialog")
        static let focusDownloadProgressDialogOnStart = UserDefaultsKey<Bool>("focusDownloadProgressDialogOnStart")
        static let focusDownloadCompletionDialogOnFinish = UserDefaultsKey<Bool>("focusDownloadCompletionDialogOnFinish")
        static let speedLimit = UserDefaultsKey<Int64>("speedLimit")
        static let autoStartOnBoot = UserDefaultsKey<Bool>("autoStartOnBoot")
        static let notificationSound = UserDefaultsKey<Bool>("notificationSound")
        static let generalNotificationSound = UserDefaultsKey<String>("generalNotificationSound")
        static let errorNotificationSound = UserDefaultsKey<String>("errorNotificationSound")
        static let successNotificationSound = UserDefaultsKey<String>("successNotificationSound")
        static let defaultDownloadFolder = UserDefaultsKey<String>("defaultDownloadFolder")
        static let apiEnabled = UserDefaultsKey<Bool>("apiEnabled")
        static let apiPort = UserDefaultsKey<Int>("apiPort")
        static let apiAuthEnabled = UserDefaultsKey<Bool>("apiAuthEnabled")
        static let apiAuthKey = UserDefaultsKey<String>("apiAuthKey")
        static let trackDeletedFilesOnDisk = UserDefaultsKey<Bool>("trackDeletedFilesOnDisk")
        static let deletePartialFileOnDownloadCancellation = UserDefaultsKey<Bool>("deletePartialFileOnDownloadCancellation")
        static let sizeUnit = UserDefaultsKey<String>("sizeUnit")
        static let speedUnit = UserDefaultsKey<String>("speedUnit")
        static let ignoreSSLCertificates = UserDefaultsKey<Bool>("ignoreSSLCertificates")
        static let useCategoryByDefault = UserDefaultsKey<Bool>("useCategoryByDefault")
        static let userAgent = UserDefaultsKey<String>("userAgent")
        static let proxyMode = UserDefaultsKey<String>("proxyMode")
        static let proxyHost = UserDefaultsKey<String>("proxyHost")
        static let proxyPort = UserDefaultsKey<Int>("proxyPort")
        static let proxyPACURL = UserDefaultsKey<String>("proxyPACURL")
    }
}
