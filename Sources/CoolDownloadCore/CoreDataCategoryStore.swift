import Foundation
import CoreData

/// Core Data façade for category metadata. Category membership is represented
/// by the inverse `DownloadTask.category` relationship.
public actor CategoryStore {
    public nonisolated let categoriesURL: URL
    public nonisolated let metadataURL: URL
    private let database: MetadataDatabase
    private var defaultFolder: URL
    private var models: [DownloadID: DownloadCategory] = [:]
    private var loaded = false

    public init(dataRoot: URL, defaultFolder: URL) throws {
        try self.init(
            dataRoot: dataRoot,
            defaultFolder: defaultFolder,
            database: MetadataDatabase.shared(rootURL: dataRoot)
        )
    }

    public init(dataRoot: URL, defaultFolder: URL, database: MetadataDatabase) throws {
        categoriesURL = dataRoot.standardizedFileURL
        self.database = database
        metadataURL = database.storeURL
        self.defaultFolder = defaultFolder.standardizedFileURL
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    public func load() throws -> [DownloadCategory] {
        if loaded { return sortedModels() }
        do {
            let values: [DownloadCategory] = try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory")
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                return try context.fetch(request).map(Self.decode)
            }
            models = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            if models.isEmpty {
                let defaults = Self.defaultCategories(folder: defaultFolder)
                try database.perform { context in
                    for value in defaults { try persist(value, in: context) }
                    try context.save()
                }
                models = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
            }
            loaded = true
            return sortedModels()
        } catch let error as CategoryStoreError {
            throw error
        } catch {
            throw CategoryStoreError.corrupt(metadataURL, error.localizedDescription)
        }
    }

    public func list() throws -> [DownloadCategory] { try load() }

    public func updateDefaultFolder(_ folder: URL) {
        defaultFolder = folder.standardizedFileURL
    }

    public func model(id: DownloadID) throws -> DownloadCategory {
        _ = try load()
        guard let model = models[id] else { throw CategoryStoreError.notFound(id) }
        return model
    }

    @discardableResult
    public func create(
        name: String,
        icon: String = "folder",
        path: String = "",
        usePath: Bool = true,
        acceptedFileTypes: [String] = [],
        acceptedURLPatterns: [String] = []
    ) throws -> DownloadCategory {
        _ = try load()
        let id = max(models.keys.max() ?? 100, 100) + 1
        let value = try DownloadCategory(
            id: id,
            name: name,
            icon: icon,
            path: path,
            usePath: usePath,
            acceptedFileTypes: acceptedFileTypes,
            acceptedURLPatterns: acceptedURLPatterns
        ).validated()
        do {
            try database.perform { context in
                try persist(value, in: context)
                try context.save()
            }
        } catch let error as CategoryStoreError {
            throw error
        } catch {
            throw CategoryStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
        models[id] = value
        return value
    }

    @discardableResult
    public func save(_ category: DownloadCategory) throws -> DownloadCategory {
        _ = try load()
        let value = try category.validated()
        guard models[value.id] != nil else { throw CategoryStoreError.notFound(value.id) }
        do {
            try database.perform { context in
                try persist(value, in: context)
                try replaceMembership(value.items, for: value.id, in: context)
                try context.save()
            }
            models[value.id] = value
        } catch let error as CategoryStoreError {
            throw error
        } catch {
            throw CategoryStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
        return value
    }

    public func remove(id: DownloadID) throws {
        _ = try load()
        guard models[id] != nil else { throw CategoryStoreError.notFound(id) }
        do {
            try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory")
                request.predicate = NSPredicate(format: "id == %lld", id)
                request.fetchLimit = 1
                guard let object = try context.fetch(request).first else {
                    throw CategoryStoreError.notFound(id)
                }
                context.delete(object)
                try context.save()
            }
            models[id] = nil
        } catch let error as CategoryStoreError {
            throw error
        } catch {
            throw CategoryStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
    }

    public func assignItems(_ ids: [DownloadID], to categoryID: DownloadID?) throws {
        _ = try load()
        var seen = Set<DownloadID>()
        let uniqueIDs = ids.filter { $0 > 0 && seen.insert($0).inserted }
        if let categoryID, models[categoryID] == nil {
            throw CategoryStoreError.notFound(categoryID)
        }
        do {
            try database.perform { context in
                let tasks = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
                let categories = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory"))
                let target = categories.first {
                    (($0.value(forKey: "id") as? NSNumber)?.int64Value) == categoryID
                }
                let selected = Set(uniqueIDs)
                let orderByID = Dictionary(uniqueKeysWithValues: uniqueIDs.enumerated().map {
                    ($0.element, Int64($0.offset))
                })
                var nextOrder: Int64 = 0
                if let target {
                    let orders = ((target.value(forKey: "items") as? NSSet)?.allObjects as? [NSManagedObject] ?? [])
                        .filter {
                            !selected.contains(($0.value(forKey: "id") as? NSNumber)?.int64Value ?? 0)
                        }
                        .compactMap { ($0.value(forKey: "categoryOrder") as? NSNumber)?.int64Value }
                    nextOrder = (orders.max() ?? -1) + 1
                }
                for task in tasks {
                    guard let taskID = (task.value(forKey: "id") as? NSNumber)?.int64Value,
                          selected.contains(taskID) else { continue }
                    if let target {
                        task.setValue(target, forKey: "category")
                        task.setValue(nextOrder + (orderByID[taskID] ?? 0), forKey: "categoryOrder")
                    } else {
                        task.setValue(nil, forKey: "category")
                        task.setValue(nil, forKey: "categoryOrder")
                    }
                }
                try context.save()
            }
            loaded = false
            _ = try load()
        } catch let error as CategoryStoreError {
            throw error
        } catch {
            throw CategoryStoreError.writeFailed(metadataURL, error.localizedDescription)
        }
    }

    public func matchingCategory(fileName: String, url: String) throws -> DownloadCategory? {
        _ = try load()
        return sortedModels()
            .filter { $0.hasFilters }
            .sorted {
                if $0.hasURLPatterns != $1.hasURLPatterns { return $0.hasURLPatterns }
                if $0.acceptedURLPatterns.count != $1.acceptedURLPatterns.count {
                    return $0.acceptedURLPatterns.count < $1.acceptedURLPatterns.count
                }
                return $0.acceptedFileTypes.count < $1.acceptedFileTypes.count
            }
            .first { $0.accepts(fileName: fileName, url: url) }
    }

    public static func defaultCategories(folder: URL) -> [DownloadCategory] {
        [
            ("压缩文件", "archivebox", ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg", "tgz"]),
            ("程序", "app.dashed", ["apk", "exe", "msi", "bat", "sh", "jar", "app", "deb", "rpm", "bin"]),
            ("视频", "film", ["mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v", "3gp", "mpeg", "ts"]),
            ("音乐", "music.note", ["mp3", "wav", "aac", "flac", "ogg", "aiff", "wma", "m4a"]),
            ("图片", "photo", ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "svg", "webp", "heic", "ico", "raw", "psd"]),
            ("文档", "doc.text", ["doc", "docx", "pdf", "txt", "rtf", "odt", "xls", "xlsx", "ppt", "pptx", "csv", "epub", "pages"])
        ].enumerated().map { index, definition in
            DownloadCategory(
                id: DownloadID(index),
                name: definition.0,
                icon: definition.1,
                path: folder.appendingPathComponent(definition.0, isDirectory: true).path,
                acceptedFileTypes: definition.2
            )
        }
    }

    private func sortedModels() -> [DownloadCategory] {
        models.values.sorted { lhs, rhs in
            if lhs.id <= 100 && rhs.id > 100 { return true }
            if lhs.id > 100 && rhs.id <= 100 { return false }
            return lhs.id < rhs.id
        }
    }

    private func persist(_ value: DownloadCategory, in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory")
        request.predicate = NSPredicate(format: "id == %lld", value.id)
        request.fetchLimit = 1
        let object = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(
            forEntityName: "DownloadCategory",
            into: context
        )
        object.setValue(value.id, forKey: "id")
        object.setValue(value.name, forKey: "name")
        object.setValue(value.icon, forKey: "icon")
        object.setValue(value.path, forKey: "path")
        object.setValue(value.usePath, forKey: "usePath")
        object.setValue(try MetadataJSON.encode(value.acceptedFileTypes), forKey: "acceptedFileTypesJSON")
        object.setValue(try MetadataJSON.encode(value.acceptedURLPatterns), forKey: "acceptedURLPatternsJSON")
    }

    private func replaceMembership(
        _ itemIDs: [DownloadID],
        for categoryID: DownloadID,
        in context: NSManagedObjectContext
    ) throws {
        let categories = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadCategory"))
        guard let target = categories.first(where: {
            (($0.value(forKey: "id") as? NSNumber)?.int64Value) == categoryID
        }) else { throw CategoryStoreError.notFound(categoryID) }
        let tasks = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadTask"))
        let desired = Set(itemIDs)
        let orderByID = Dictionary(uniqueKeysWithValues: itemIDs.enumerated().map {
            ($0.element, Int64($0.offset))
        })
        for task in tasks {
            guard let id = (task.value(forKey: "id") as? NSNumber)?.int64Value else { continue }
            let currentCategoryID = (task.value(forKey: "category") as? NSManagedObject)
                .flatMap { ($0.value(forKey: "id") as? NSNumber)?.int64Value }
            if desired.contains(id) {
                task.setValue(target, forKey: "category")
                task.setValue(orderByID[id], forKey: "categoryOrder")
            } else if currentCategoryID == categoryID {
                task.setValue(nil, forKey: "category")
                task.setValue(nil, forKey: "categoryOrder")
            }
        }
    }

    private static func decode(_ object: NSManagedObject) throws -> DownloadCategory {
        guard let id = (object.value(forKey: "id") as? NSNumber)?.int64Value,
              let name = object.value(forKey: "name") as? String,
              let icon = object.value(forKey: "icon") as? String,
              let path = object.value(forKey: "path") as? String,
              let fileTypesJSON = object.value(forKey: "acceptedFileTypesJSON") as? String,
              let urlPatternsJSON = object.value(forKey: "acceptedURLPatternsJSON") as? String else {
            throw CategoryStoreError.invalid("分类元数据字段无效")
        }
        let items = ((object.value(forKey: "items") as? NSSet)?.allObjects as? [NSManagedObject] ?? [])
            .sorted {
                let lhs = ($0.value(forKey: "categoryOrder") as? NSNumber)?.int64Value ?? Int64.max
                let rhs = ($1.value(forKey: "categoryOrder") as? NSNumber)?.int64Value ?? Int64.max
                return lhs == rhs
                    ? (($0.value(forKey: "id") as? NSNumber)?.int64Value ?? 0)
                        < (($1.value(forKey: "id") as? NSNumber)?.int64Value ?? 0)
                    : lhs < rhs
            }
            .compactMap { ($0.value(forKey: "id") as? NSNumber)?.int64Value }
        return try DownloadCategory(
            id: id,
            name: name,
            icon: icon,
            path: path,
            usePath: (object.value(forKey: "usePath") as? NSNumber)?.boolValue ?? true,
            acceptedFileTypes: try MetadataJSON.decode([String].self, from: fileTypesJSON),
            acceptedURLPatterns: try MetadataJSON.decode([String].self, from: urlPatternsJSON),
            items: items
        ).validated()
    }
}
