import Foundation
import CoreData
import Security
import Darwin

/// Canonical locations for the native client.  The old `~/.cooldm` path is
/// intentionally absent: a new installation starts from these system-owned
/// directories and never probes the legacy location.
public enum AppPaths {
    public static let bundleIdentifier = "com.cooldownloadmanager"

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static func cachesDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static func metadataStoreURL(
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("metadata.sqlite")
    }

    public static func nativeMessagingSocketURL(
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("native-messaging.sock")
    }

    public static func hostPerformanceURL(
        fileManager: FileManager = .default
    ) -> URL {
        cachesDirectory(fileManager: fileManager)
            .appendingPathComponent("host-performance.json")
    }
}

public enum MetadataDatabaseError: Error, LocalizedError, Sendable, Equatable {
    case loadFailed(URL, String)
    case saveFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let url, let reason):
            return "无法打开元数据数据库 \(url.path)：\(reason)"
        case .saveFailed(let url, let reason):
            return "无法保存元数据数据库 \(url.path)：\(reason)"
        }
    }
}

/// A single Core Data stack shared by the metadata façades.  The model is
/// built in code so SwiftPM does not need to copy a model bundle; the model
/// version is explicit and SQLite's lightweight migration remains enabled for
/// future additions.
public final class MetadataDatabase: @unchecked Sendable {
    public static let modelVersion = "1"

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        final class Box {
            weak var value: MetadataDatabase?
            init(_ value: MetadataDatabase? = nil) { self.value = value }
        }
        var values: [String: Box] = [:]
    }

    private static let registry = Registry()

    public let rootURL: URL
    public let storeURL: URL

    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let lock: MetadataWriterLock?

    /// Returns the process-wide stack for one metadata root. Every façade in
    /// the application uses this entry point so relationship updates share a
    /// context and never open competing SQLite connections.
    public static func shared(rootURL: URL) throws -> MetadataDatabase {
        let key = rootURL.standardizedFileURL.path
        registry.lock.lock()
        if let existing = registry.values[key]?.value {
            registry.lock.unlock()
            return existing
        }
        registry.lock.unlock()

        let created = try MetadataDatabase(rootURL: rootURL)
        registry.lock.lock()
        if let existing = registry.values[key]?.value {
            registry.lock.unlock()
            return existing
        }
        registry.values[key] = Registry.Box(created)
        registry.lock.unlock()
        return created
    }

    public init(rootURL: URL, readOnly: Bool = false) throws {
        self.rootURL = rootURL.standardizedFileURL
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        self.storeURL = self.rootURL.appendingPathComponent("metadata.sqlite")
        if readOnly {
            self.lock = nil
        } else {
            self.lock = try MetadataWriterLock(
                url: self.rootURL.appendingPathComponent("metadata.sqlite.lock")
            )
        }

        let model = Self.makeModel()
        let container = NSPersistentContainer(name: "CoolDownloadManagerMetadata", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        if readOnly {
            description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError {
            throw MetadataDatabaseError.loadFailed(storeURL, loadError.localizedDescription)
        }

        self.container = container
        let context = container.newBackgroundContext()
        context.name = "com.cooldownloadmanager.metadata"
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        context.undoManager = nil
        self.context = context
    }

    public func perform<T>(_ body: (NSManagedObjectContext) throws -> T) rethrows -> T {
        try context.performAndWait {
            try body(context)
        }
    }

    public func saveIfNeeded() throws {
        try context.performAndWait {
            guard context.hasChanges else { return }
            do {
                try context.save()
            } catch {
                throw MetadataDatabaseError.saveFailed(storeURL, error.localizedDescription)
            }
        }
    }

    public func reset() throws {
        try context.performAndWait {
            context.reset()
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        func attribute(
            _ name: String,
            _ type: NSAttributeType,
            optional: Bool = false,
            indexed: Bool = false
        ) -> NSAttributeDescription {
            let value = NSAttributeDescription()
            value.name = name
            value.attributeType = type
            value.isOptional = optional
            value.isIndexed = indexed
            return value
        }

        let task = NSEntityDescription()
        task.name = "DownloadTask"
        task.managedObjectClassName = "NSManagedObject"
        task.properties = [
            attribute("id", .integer64AttributeType, indexed: true),
            attribute("sourceKind", .stringAttributeType),
            attribute("link", .stringAttributeType),
            attribute("headersJSON", .stringAttributeType, optional: true),
            attribute("downloadPage", .stringAttributeType, optional: true),
            attribute("suggestedName", .stringAttributeType, optional: true),
            attribute("folder", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("status", .stringAttributeType),
            attribute("downloadedBytes", .integer64AttributeType),
            attribute("totalBytes", .integer64AttributeType, optional: true),
            attribute("etag", .stringAttributeType, optional: true),
            attribute("lastModified", .stringAttributeType, optional: true),
            attribute("supportsResume", .booleanAttributeType, optional: true),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("error", .stringAttributeType, optional: true),
            attribute("fileChecksum", .stringAttributeType, optional: true),
            attribute("taskSettingsJSON", .stringAttributeType, optional: true),
            attribute("incompleteFileName", .stringAttributeType, optional: true),
            attribute("revision", .integer64AttributeType),
            attribute("queueOrder", .integer64AttributeType, optional: true),
            attribute("categoryOrder", .integer64AttributeType, optional: true)
        ]

        let part = NSEntityDescription()
        part.name = "DownloadPart"
        part.managedObjectClassName = "NSManagedObject"
        part.properties = [
            attribute("partID", .integer64AttributeType),
            attribute("from", .integer64AttributeType),
            attribute("to", .integer64AttributeType, optional: true),
            attribute("downloaded", .integer64AttributeType),
            attribute("completed", .booleanAttributeType)
        ]

        let queue = NSEntityDescription()
        queue.name = "DownloadQueue"
        queue.managedObjectClassName = "NSManagedObject"
        queue.properties = [
            attribute("id", .integer64AttributeType, indexed: true),
            attribute("name", .stringAttributeType),
            attribute("maxConcurrent", .integer64AttributeType),
            attribute("scheduledTimesJSON", .stringAttributeType),
            attribute("stopQueueOnEmpty", .booleanAttributeType),
            attribute("completionAction", .stringAttributeType)
        ]

        let category = NSEntityDescription()
        category.name = "DownloadCategory"
        category.managedObjectClassName = "NSManagedObject"
        category.properties = [
            attribute("id", .integer64AttributeType, indexed: true),
            attribute("name", .stringAttributeType),
            attribute("icon", .stringAttributeType),
            attribute("path", .stringAttributeType),
            attribute("usePath", .booleanAttributeType),
            attribute("acceptedFileTypesJSON", .stringAttributeType),
            attribute("acceptedURLPatternsJSON", .stringAttributeType)
        ]

        let host = NSEntityDescription()
        host.name = "PerHostSettings"
        host.managedObjectClassName = "NSManagedObject"
        host.properties = [
            attribute("host", .stringAttributeType, indexed: true),
            attribute("userAgent", .stringAttributeType, optional: true),
            attribute("threadCount", .integer64AttributeType, optional: true),
            attribute("speedLimit", .integer64AttributeType, optional: true),
            attribute("usernameKey", .stringAttributeType, optional: true),
            attribute("passwordKey", .stringAttributeType, optional: true),
            attribute("sortOrder", .integer64AttributeType, optional: true)
        ]

        let taskParts = NSRelationshipDescription()
        taskParts.name = "parts"
        taskParts.destinationEntity = part
        taskParts.minCount = 0
        taskParts.maxCount = 0
        taskParts.deleteRule = .cascadeDeleteRule
        taskParts.isOrdered = false

        let partTask = NSRelationshipDescription()
        partTask.name = "task"
        partTask.destinationEntity = task
        partTask.minCount = 1
        partTask.maxCount = 1
        partTask.deleteRule = .nullifyDeleteRule
        taskParts.inverseRelationship = partTask
        partTask.inverseRelationship = taskParts

        let taskQueue = NSRelationshipDescription()
        taskQueue.name = "queue"
        taskQueue.destinationEntity = queue
        taskQueue.minCount = 0
        taskQueue.maxCount = 1
        taskQueue.deleteRule = .nullifyDeleteRule

        let queueTasks = NSRelationshipDescription()
        queueTasks.name = "items"
        queueTasks.destinationEntity = task
        queueTasks.minCount = 0
        queueTasks.maxCount = 0
        queueTasks.deleteRule = .nullifyDeleteRule
        taskQueue.inverseRelationship = queueTasks
        queueTasks.inverseRelationship = taskQueue

        let taskCategory = NSRelationshipDescription()
        taskCategory.name = "category"
        taskCategory.destinationEntity = category
        taskCategory.minCount = 0
        taskCategory.maxCount = 1
        taskCategory.deleteRule = .nullifyDeleteRule

        let categoryTasks = NSRelationshipDescription()
        categoryTasks.name = "items"
        categoryTasks.destinationEntity = task
        categoryTasks.minCount = 0
        categoryTasks.maxCount = 0
        categoryTasks.deleteRule = .nullifyDeleteRule
        taskCategory.inverseRelationship = categoryTasks
        categoryTasks.inverseRelationship = taskCategory

        task.properties += [taskParts, taskQueue, taskCategory]
        part.properties += [partTask]
        queue.properties += [queueTasks]
        category.properties += [categoryTasks]
        model.entities = [task, part, queue, category, host]
        model.versionIdentifiers = [modelVersion]
        return model
    }
}

private final class MetadataWriterLock: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DownloadCoreError.permissionDenied(url.path) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            _ = Darwin.close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw DownloadCoreError.storageLocked(url)
            }
            throw DownloadCoreError.permissionDenied(url.path)
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

/// Small Keychain façade used by settings repositories.  Values are keyed by
/// a stable service/account pair and never serialized into Core Data.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    public let service: String

    public init(service: String = AppPaths.bundleIdentifier) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.status(status)
        }
    }

    public func write(_ value: String?, account: String) throws {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let value {
            let data = Data(value.utf8)
            let status = SecItemCopyMatching(base as CFDictionary, nil)
            if status == errSecSuccess {
                let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
                guard updateStatus == errSecSuccess else { throw KeychainStoreError.status(updateStatus) }
            } else if status == errSecItemNotFound {
                var item = base
                item[kSecValueData] = data
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
            } else {
                throw KeychainStoreError.status(status)
            }
        } else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError.status(status)
            }
        }
    }
}

public enum KeychainStoreError: Error, LocalizedError, Sendable, Equatable {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            return "Keychain 操作失败（\(status)）"
        }
    }
}

public enum MetadataJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
}
