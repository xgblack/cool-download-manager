import Foundation

/// The action to perform when every item in a queue has completed.
public enum QueueCompletionAction: String, Codable, Sendable, CaseIterable {
    case none
    case shutdown
    case sleep
    case hibernate
    case lock
}

/// Runtime scheduling options copied from the persisted queue model. Keeping
/// this value separate from `DownloadQueueModel` lets the download actor apply
/// a consistent policy without depending on a storage actor or a SwiftUI
/// view.
public struct DownloadQueuePolicy: Sendable, Equatable {
    public var maxConcurrent: Int
    public var stopQueueOnEmpty: Bool
    public var completionAction: QueueCompletionAction

    public init(
        maxConcurrent: Int = 2,
        stopQueueOnEmpty: Bool = false,
        completionAction: QueueCompletionAction = .none
    ) {
        self.maxConcurrent = min(max(1, maxConcurrent), 32)
        self.stopQueueOnEmpty = stopQueueOnEmpty
        self.completionAction = completionAction
    }
}

/// Emitted once after a started queue has no remaining downloadable items.
/// The app layer decides how to present or execute the optional power action;
/// the core never invokes an operating-system power command by itself.
public enum DownloadQueueEvent: Sendable, Equatable {
    case becameEmpty(queueID: DownloadID, completionAction: QueueCompletionAction)
}

/// Queue scheduling values are kept in the same shape as the historical
/// Kotlin JSON. Times use a stable HH:mm string. Older Kotlin files encode
/// days as `DayOfWeek` names while newer Swift files use ISO weekday numbers
/// (1 = Monday ... 7 = Sunday), so the decoder accepts both forms.
public struct QueueSchedule: Codable, Equatable, Sendable {
    public var daysOfWeek: Set<Int>
    public var startTime: String
    public var endTime: String
    public var enabledStartTime: Bool
    public var enabledEndTime: Bool

    public init(
        daysOfWeek: Set<Int> = Set(1...7),
        startTime: String = "02:30",
        endTime: String = "07:30",
        enabledStartTime: Bool = false,
        enabledEndTime: Bool = false
    ) {
        self.daysOfWeek = daysOfWeek
        self.startTime = startTime
        self.endTime = endTime
        self.enabledStartTime = enabledStartTime
        self.enabledEndTime = enabledEndTime
    }

    public static let `default` = Self()

    public var isEnabled: Bool { enabledStartTime || enabledEndTime }

    public func isActive(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }
        let weekday = calendar.component(.weekday, from: date)
        // Calendar weekday is Sunday=1; the persisted format is Monday=1.
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        guard daysOfWeek.contains(isoWeekday) else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = Self.minutes(startTime) ?? 0
        let end = Self.minutes(endTime) ?? 0
        switch (enabledStartTime, enabledEndTime) {
        case (true, true):
            if start <= end { return (start...end).contains(current) }
            return current >= start || current <= end
        case (true, false):
            return current >= start
        case (false, true):
            return current <= end
        case (false, false):
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case daysOfWeek, startTime, endTime, enabledStartTime, enabledEndTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDays: [Int]
        if let numericDays = try? container.decode([Int].self, forKey: .daysOfWeek) {
            decodedDays = numericDays
        } else if let namedDays = try? container.decode([String].self, forKey: .daysOfWeek) {
            decodedDays = try namedDays.map { name in
                guard let day = Self.isoWeekday(for: name) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .daysOfWeek,
                        in: container,
                        debugDescription: "Unknown weekday name: \(name)"
                    )
                }
                return day
            }
        } else if !container.contains(.daysOfWeek) {
            decodedDays = Array(Set(1...7)).sorted()
        } else if try container.decodeNil(forKey: .daysOfWeek) {
            decodedDays = Array(Set(1...7)).sorted()
        } else {
            throw DecodingError.typeMismatch(
                [Int].self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.daysOfWeek],
                    debugDescription: "daysOfWeek must be an array of ISO weekday numbers or Kotlin weekday names"
                )
            )
        }
        self.init(
            daysOfWeek: Set(decodedDays.filter { (1...7).contains($0) }),
            startTime: try container.decodeIfPresent(String.self, forKey: .startTime) ?? "02:30",
            endTime: try container.decodeIfPresent(String.self, forKey: .endTime) ?? "07:30",
            enabledStartTime: try container.decodeIfPresent(Bool.self, forKey: .enabledStartTime) ?? false,
            enabledEndTime: try container.decodeIfPresent(Bool.self, forKey: .enabledEndTime) ?? false
        )
        if daysOfWeek.isEmpty {
            daysOfWeek = Set(1...7)
        }
    }

    private static func isoWeekday(for value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let number = Int(normalized), (1...7).contains(number) {
            return number
        }
        switch normalized {
        case "MONDAY": return 1
        case "TUESDAY": return 2
        case "WEDNESDAY": return 3
        case "THURSDAY": return 4
        case "FRIDAY": return 5
        case "SATURDAY": return 6
        case "SUNDAY": return 7
        default: return nil
        }
    }

    public func validate() throws {
        guard !daysOfWeek.isEmpty, daysOfWeek.allSatisfy({ (1...7).contains($0) }) else {
            throw QueueStoreError.invalid("队列至少需要一个有效活动日")
        }
        guard Self.isValidTime(startTime), Self.isValidTime(endTime) else {
            throw QueueStoreError.invalid("队列调度时间必须使用 HH:mm 格式")
        }
    }

    private static func isValidTime(_ value: String) -> Bool {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    private static func minutes(_ value: String) -> Int? {
        let components = value.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

public struct DownloadQueueModel: Codable, Equatable, Sendable, Identifiable {
    public let id: DownloadID
    public var name: String
    public var maxConcurrent: Int
    public var queueItems: [DownloadID]
    public var scheduledTimes: QueueSchedule
    public var stopQueueOnEmpty: Bool
    public var completionAction: QueueCompletionAction

    public init(
        id: DownloadID,
        name: String,
        maxConcurrent: Int = 2,
        queueItems: [DownloadID] = [],
        scheduledTimes: QueueSchedule = .default,
        stopQueueOnEmpty: Bool = false,
        completionAction: QueueCompletionAction = .none
    ) {
        self.id = id
        self.name = name
        self.maxConcurrent = maxConcurrent
        self.queueItems = queueItems
        self.scheduledTimes = scheduledTimes
        self.stopQueueOnEmpty = stopQueueOnEmpty
        self.completionAction = completionAction
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, maxConcurrent, queueItems, scheduledTimes, stopQueueOnEmpty, completionAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(DownloadID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            maxConcurrent: try container.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2,
            queueItems: try container.decodeIfPresent([DownloadID].self, forKey: .queueItems) ?? [],
            scheduledTimes: try container.decodeIfPresent(QueueSchedule.self, forKey: .scheduledTimes) ?? .default,
            stopQueueOnEmpty: try container.decodeIfPresent(Bool.self, forKey: .stopQueueOnEmpty) ?? false,
            completionAction: try container.decodeIfPresent(QueueCompletionAction.self, forKey: .completionAction) ?? .none
        )
    }

    public func validated() throws -> Self {
        guard id >= 0 else { throw QueueStoreError.invalid("队列 ID 无效") }
        guard (1...32).contains(name.count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueueStoreError.invalid("队列名称长度必须在 1 到 32 个字符之间")
        }
        guard (1...32).contains(maxConcurrent) else {
            throw QueueStoreError.invalid("队列并发数必须在 1 到 32 之间")
        }
        guard Set(queueItems).count == queueItems.count, queueItems.allSatisfy({ $0 > 0 }) else {
            throw QueueStoreError.invalid("队列项目列表包含无效或重复任务")
        }
        try scheduledTimes.validate()
        return self
    }
}

public enum QueueStoreError: Error, LocalizedError, Sendable, Equatable {
    case corrupt(URL, String)
    case invalid(String)
    case notFound(DownloadID)
    case cannotDeleteMainQueue
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, let reason): return "无法读取队列 \(url.path)：\(reason)"
        case .invalid(let reason): return reason
        case .notFound(let id): return "找不到队列 \(id)"
        case .cannotDeleteMainQueue: return "主队列不能删除"
        case .writeFailed(let url, let reason): return "无法保存队列 \(url.path)：\(reason)"
        }
    }
}

/// Actor-isolated CRUD store for queue files. Unknown JSON keys are retained
/// so upgrading the native client does not erase fields written by older
/// releases.
public actor QueueStore {
    public nonisolated let queuesURL: URL
    private var rawObjects: [DownloadID: JSONValue] = [:]
    private var loaded = false
    private var models: [DownloadID: DownloadQueueModel] = [:]

    public init(dataRoot: URL) throws {
        queuesURL = dataRoot.standardizedFileURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("download_db", isDirectory: true)
            .appendingPathComponent("queues", isDirectory: true)
        try FileManager.default.createDirectory(at: queuesURL, withIntermediateDirectories: true)
    }

    public func load() throws -> [DownloadQueueModel] {
        if loaded {
            return sortedModels()
        }
        var loadedModels: [DownloadID: DownloadQueueModel] = [:]
        let files = try FileManager.default.contentsOfDirectory(
            at: queuesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for file in files where file.pathExtension == "json" {
            do {
                let value = try JSONValue(data: Data(contentsOf: file))
                let data = try value.data()
                let model = try JSONDecoder().decode(DownloadQueueModel.self, from: data).validated()
                loadedModels[model.id] = model
                rawObjects[model.id] = value
            } catch let error as QueueStoreError {
                throw error
            } catch {
                throw QueueStoreError.corrupt(file, error.localizedDescription)
            }
        }
        models = loadedModels
        loaded = true
        if models.isEmpty {
            models[0] = DownloadQueueModel(id: 0, name: "Main")
        }
        return sortedModels()
    }

    public func list() throws -> [DownloadQueueModel] {
        try load()
    }

    public func model(id: DownloadID) throws -> DownloadQueueModel {
        _ = try load()
        guard let model = models[id] else { throw QueueStoreError.notFound(id) }
        return model
    }

    @discardableResult
    public func create(name: String) throws -> DownloadQueueModel {
        _ = try load()
        let id = max(models.keys.max() ?? 0, 10) + 1
        let model = try DownloadQueueModel(id: id, name: name).validated()
        try persist(model)
        models[id] = model
        return model
    }

    @discardableResult
    public func save(_ model: DownloadQueueModel) throws -> DownloadQueueModel {
        _ = try load()
        let validated = try model.validated()
        guard models[validated.id] != nil else { throw QueueStoreError.notFound(validated.id) }
        try persist(validated)
        models[validated.id] = validated
        return validated
    }

    /// Moves task IDs to one queue and removes stale references from every
    /// other queue. Queue metadata and DownloadRecord.queueID can therefore be
    /// updated together by the UI and browser integration paths.
    public func assignItems(_ ids: [DownloadID], to queueID: DownloadID?) throws {
        _ = try load()
        let uniqueIDs = Array(Set(ids.filter { $0 > 0 }))
        let queueIDs = Array(models.keys)
        if let queueID, models[queueID] == nil {
            throw QueueStoreError.notFound(queueID)
        }
        for id in queueIDs {
            guard var queue = models[id] else { continue }
            queue.queueItems.removeAll { uniqueIDs.contains($0) }
            models[id] = queue
        }
        if let queueID, var target = models[queueID] {
            target.queueItems.append(contentsOf: uniqueIDs)
            target.queueItems = Array(Set(target.queueItems)).sorted()
            models[queueID] = target
        }
        for model in models.values {
            try persist(model)
        }
    }

    public func remove(id: DownloadID) throws {
        _ = try load()
        guard id != 0 else { throw QueueStoreError.cannotDeleteMainQueue }
        guard models[id] != nil else { throw QueueStoreError.notFound(id) }
        let target = queuesURL.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.removeItem(at: target) }
            catch { throw QueueStoreError.writeFailed(target, error.localizedDescription) }
        }
        models[id] = nil
        rawObjects[id] = nil
    }

    public func replaceItems(queueID: DownloadID, itemIDs: [DownloadID]) throws {
        var model = try self.model(id: queueID)
        model.queueItems = itemIDs
        _ = try save(model)
    }

    private func sortedModels() -> [DownloadQueueModel] {
        models.values.sorted { lhs, rhs in
            if lhs.id == 0 { return true }
            if rhs.id == 0 { return false }
            return lhs.id < rhs.id
        }
    }

    private func persist(_ model: DownloadQueueModel) throws {
        var object: [String: JSONValue]
        if case .object(let existing) = rawObjects[model.id] {
            object = existing
        } else {
            object = [:]
        }
        let encoded = try JSONEncoder().encode(model)
        guard case .object(let encodedObject) = try JSONValue(data: encoded) else {
            throw QueueStoreError.writeFailed(queuesURL, "队列编码结果不是对象")
        }
        object.merge(encodedObject) { _, new in new }
        let data = try JSONValue.object(object).data(prettyPrinted: true)
        let target = queuesURL.appendingPathComponent("\(model.id).json")
        let temporary = queuesURL.appendingPathComponent(
            ".\(model.id).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw QueueStoreError.writeFailed(target, "无法创建临时文件")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            rawObjects[model.id] = .object(object)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw QueueStoreError.writeFailed(target, error.localizedDescription)
        }
    }
}
