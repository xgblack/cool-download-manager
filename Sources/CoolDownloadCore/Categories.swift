import Foundation

/// A download category compatible with the historical Kotlin category JSON.
/// Category IDs 0...100 are reserved for built-in categories; custom IDs start
/// at 101 so old installations can keep their identity across migrations.
public struct DownloadCategory: Codable, Equatable, Sendable, Identifiable {
    public let id: DownloadID
    public var name: String
    public var icon: String
    public var path: String
    public var usePath: Bool
    public var acceptedFileTypes: [String]
    public var acceptedURLPatterns: [String]
    public var items: [DownloadID]

    public init(
        id: DownloadID,
        name: String,
        icon: String = "folder",
        path: String = "",
        usePath: Bool = true,
        acceptedFileTypes: [String] = [],
        acceptedURLPatterns: [String] = [],
        items: [DownloadID] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.path = path
        self.usePath = usePath
        self.acceptedFileTypes = acceptedFileTypes
        self.acceptedURLPatterns = acceptedURLPatterns
        self.items = items
    }

    public var hasFileTypes: Bool { !acceptedFileTypes.isEmpty }
    public var hasURLPatterns: Bool { !acceptedURLPatterns.isEmpty }
    public var hasFilters: Bool { hasFileTypes || hasURLPatterns }

    public func accepts(fileName: String, url: String) -> Bool {
        let fileAccepted = !hasFileTypes || acceptedFileTypes.contains { type in
            let normalized = type.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard !normalized.isEmpty else { return false }
            return fileName.lowercased().hasSuffix(".\(normalized)")
        }
        let urlAccepted = !hasURLPatterns || acceptedURLPatterns.contains { pattern in
            wildcardMatch(pattern, url) || URL(string: url).map {
                wildcardMatch(pattern, ($0.host ?? "") + $0.path)
            } == true
        }
        return fileAccepted && urlAccepted
    }

    public var downloadPath: String? {
        usePath && !path.isEmpty ? path : nil
    }

    public func validated() throws -> Self {
        guard id >= 0 else { throw CategoryStoreError.invalid("分类 ID 无效") }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            throw CategoryStoreError.invalid("分类名称不能为空且不能超过 64 个字符")
        }
        guard items.allSatisfy({ $0 > 0 }), Set(items).count == items.count else {
            throw CategoryStoreError.invalid("分类项目列表包含无效或重复任务")
        }
        var copy = self
        copy.name = trimmedName
        copy.acceptedFileTypes = copy.acceptedFileTypes
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
        copy.acceptedURLPatterns = copy.acceptedURLPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.items = Array(Set(copy.items)).sorted()
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, path, usePath, acceptedFileTypes, acceptedURLPatterns, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(DownloadID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            icon: try container.decodeIfPresent(String.self, forKey: .icon) ?? "folder",
            path: try container.decodeIfPresent(String.self, forKey: .path) ?? "",
            usePath: try container.decodeIfPresent(Bool.self, forKey: .usePath) ?? true,
            acceptedFileTypes: try container.decodeIfPresent([String].self, forKey: .acceptedFileTypes) ?? [],
            acceptedURLPatterns: try container.decodeIfPresent([String].self, forKey: .acceptedURLPatterns) ?? [],
            items: try container.decodeIfPresent([DownloadID].self, forKey: .items) ?? []
        )
    }
}

public enum CategoryStoreError: Error, LocalizedError, Sendable, Equatable {
    case corrupt(URL, String)
    case invalid(String)
    case notFound(DownloadID)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, let reason): return "无法读取分类 \(url.path)：\(reason)"
        case .invalid(let reason): return reason
        case .notFound(let id): return "找不到分类 \(id)"
        case .writeFailed(let url, let reason): return "无法保存分类 \(url.path)：\(reason)"
        }
    }
}

/// Actor-isolated category persistence. Unknown JSON keys on each category
/// are retained when a category is edited, matching the migration behavior of
/// settings, queues and download records.
public actor CategoryStore {
    public nonisolated let categoriesURL: URL
    private let defaultFolder: URL
    private var rawObjects: [DownloadID: JSONValue] = [:]
    private var models: [DownloadID: DownloadCategory] = [:]
    private var loaded = false

    public init(dataRoot: URL, defaultFolder: URL) throws {
        let directory = dataRoot.standardizedFileURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("download_db", isDirectory: true)
            .appendingPathComponent("categories", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        categoriesURL = directory.appendingPathComponent("categories.json")
        self.defaultFolder = defaultFolder.standardizedFileURL
    }

    public func load() throws -> [DownloadCategory] {
        guard !loaded else { return sortedModels() }
        if !FileManager.default.fileExists(atPath: categoriesURL.path) {
            let defaults = Self.defaultCategories(folder: defaultFolder)
            models = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
            rawObjects = try Dictionary(uniqueKeysWithValues: defaults.map { category in
                let data = try JSONEncoder().encode(category)
                return (category.id, try JSONValue(data: data))
            })
            loaded = true
            try persistAll()
            return defaults
        }

        do {
            let value = try JSONValue(data: Data(contentsOf: categoriesURL))
            let data = try value.data()
            let decoded = try JSONDecoder().decode([DownloadCategory].self, from: data)
            var loadedModels: [DownloadID: DownloadCategory] = [:]
            var loadedRaw: [DownloadID: JSONValue] = [:]
            if case .array(let values) = value {
                for (raw, category) in zip(values, decoded) {
                    var valid = try category.validated()
                    if let names = Self.englishBuiltInNames[valid.id], valid.name == names.english {
                        valid.name = names.chinese
                    }
                    guard loadedModels[valid.id] == nil else {
                        throw CategoryStoreError.invalid("分类 ID 重复")
                    }
                    loadedModels[valid.id] = valid
                    loadedRaw[valid.id] = raw
                }
            } else {
                throw CategoryStoreError.corrupt(categoriesURL, "根值不是 JSON 数组")
            }
            models = loadedModels
            rawObjects = loadedRaw
            loaded = true
            var renamedBuiltInCategory = false
            for (id, category) in models {
                guard let names = Self.englishBuiltInNames[id], category.name == names.chinese,
                      case .object(var object) = rawObjects[id],
                      object["name"] == .string(names.english) else {
                    continue
                }
                object["name"] = .string(names.chinese)
                rawObjects[id] = .object(object)
                renamedBuiltInCategory = true
            }
            if renamedBuiltInCategory {
                try persistAll()
            }
            return sortedModels()
        } catch let error as CategoryStoreError {
            throw error
        } catch {
            throw CategoryStoreError.corrupt(categoriesURL, error.localizedDescription)
        }
    }

    public func list() throws -> [DownloadCategory] { try load() }

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
        let model = try DownloadCategory(
            id: id,
            name: name,
            icon: icon,
            path: path,
            usePath: usePath,
            acceptedFileTypes: acceptedFileTypes,
            acceptedURLPatterns: acceptedURLPatterns
        ).validated()
        try persist(model)
        models[id] = model
        return model
    }

    @discardableResult
    public func save(_ category: DownloadCategory) throws -> DownloadCategory {
        _ = try load()
        let valid = try category.validated()
        guard models[valid.id] != nil else { throw CategoryStoreError.notFound(valid.id) }
        try persist(valid)
        models[valid.id] = valid
        return valid
    }

    public func remove(id: DownloadID) throws {
        _ = try load()
        guard models[id] != nil else { throw CategoryStoreError.notFound(id) }
        models[id] = nil
        rawObjects[id] = nil
        try persistAll()
    }

    /// Move task IDs to one category and remove them from every other category.
    /// This keeps legacy `items` arrays consistent with `DownloadRecord.categoryID`.
    public func assignItems(_ ids: [DownloadID], to categoryID: DownloadID?) throws {
        _ = try load()
        let uniqueIDs = Array(Set(ids.filter { $0 > 0 }))
        let categoryIDs = Array(models.keys)
        guard let categoryID else {
            for id in categoryIDs {
                guard var category = models[id] else { continue }
                category.items.removeAll { uniqueIDs.contains($0) }
                models[id] = category
            }
            try persistAll()
            return
        }
        guard models[categoryID] != nil else { throw CategoryStoreError.notFound(categoryID) }
        for id in categoryIDs {
            guard var category = models[id] else { continue }
            category.items.removeAll { uniqueIDs.contains($0) }
            models[id] = category
        }
        if var target = models[categoryID] {
            target.items.append(contentsOf: uniqueIDs)
            target.items = Array(Set(target.items)).sorted()
            models[categoryID] = target
        }
        try persistAll()
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
        let definitions: [(String, String, [String])] = [
            ("压缩文件", "archivebox", ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg", "tgz"]),
            ("程序", "app.dashed", ["apk", "exe", "msi", "bat", "sh", "jar", "app", "deb", "rpm", "bin"]),
            ("视频", "film", ["mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v", "3gp", "mpeg", "ts"]),
            ("音乐", "music.note", ["mp3", "wav", "aac", "flac", "ogg", "aiff", "wma", "m4a"]),
            ("图片", "photo", ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "svg", "webp", "heic", "ico", "raw", "psd"]),
            ("文档", "doc.text", ["doc", "docx", "pdf", "txt", "rtf", "odt", "xls", "xlsx", "ppt", "pptx", "csv", "epub", "pages"])
        ]
        return definitions.enumerated().map { index, definition in
            DownloadCategory(
                id: DownloadID(index),
                name: definition.0,
                icon: definition.1,
                path: folder.appendingPathComponent(definition.0, isDirectory: true).path,
                acceptedFileTypes: definition.2
            )
        }
    }

    private static let englishBuiltInNames: [DownloadID: (english: String, chinese: String)] = [
        0: ("Compressed", "压缩文件"),
        1: ("Programs", "程序"),
        2: ("Videos", "视频"),
        3: ("Music", "音乐"),
        4: ("Pictures", "图片"),
        5: ("Documents", "文档")
    ]

    private func sortedModels() -> [DownloadCategory] {
        models.values.sorted { lhs, rhs in
            if lhs.id <= 100 && rhs.id > 100 { return true }
            if lhs.id > 100 && rhs.id <= 100 { return false }
            return lhs.id < rhs.id
        }
    }

    private func persist(_ category: DownloadCategory) throws {
        let encoded = try JSONEncoder().encode(category)
        guard case .object(let object) = try JSONValue(data: encoded) else {
            throw CategoryStoreError.writeFailed(categoriesURL, "分类编码结果不是对象")
        }
        var merged = object
        if case .object(let previous) = rawObjects[category.id] {
            merged = previous.merging(object) { _, new in new }
        }
        rawObjects[category.id] = .object(merged)
        try persistAll()
    }

    private func persistAll() throws {
        let values = sortedModels().compactMap { rawObjects[$0.id] }
        let data: Data
        do {
            data = try JSONValue.array(values).data(prettyPrinted: true)
        } catch {
            throw CategoryStoreError.writeFailed(categoriesURL, error.localizedDescription)
        }
        let temporary = categoriesURL.deletingLastPathComponent()
            .appendingPathComponent(".categories.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CategoryStoreError.writeFailed(categoriesURL, "无法创建临时文件")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: categoriesURL.path) {
                _ = try FileManager.default.replaceItemAt(categoriesURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: categoriesURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CategoryStoreError.writeFailed(categoriesURL, error.localizedDescription)
        }
    }
}

private func wildcardMatch(_ pattern: String, _ value: String) -> Bool {
    let pattern = Array(pattern.lowercased())
    let value = Array(value.lowercased())
    var memo: [String: Bool] = [:]

    func match(_ pi: Int, _ vi: Int) -> Bool {
        let key = "\(pi):\(vi)"
        if let cached = memo[key] { return cached }
        let result: Bool
        if pi == pattern.count {
            result = vi == value.count
        } else if pattern[pi] == "*" {
            result = match(pi + 1, vi) || (vi < value.count && match(pi, vi + 1))
        } else {
            result = vi < value.count && pattern[pi] == value[vi] && match(pi + 1, vi + 1)
        }
        memo[key] = result
        return result
    }

    return match(0, 0)
}
