import Foundation

public struct PerHostSettingsItem: Codable, Equatable, Sendable, Identifiable {
    public var host: String
    public var username: String?
    public var password: String?
    public var userAgent: String?
    /// An explicit per-host connection ceiling. Empty values inherit the
    /// global ceiling while automatic jobs may still use a learned profile as
    /// their initial stage.
    public var threadCount: Int?
    /// A host-local cap. `nil` or zero leaves only the global aggregate cap.
    public var speedLimit: Int64?

    public var id: String { host }

    public init(
        host: String,
        username: String? = nil,
        password: String? = nil,
        userAgent: String? = nil,
        threadCount: Int? = nil,
        speedLimit: Int64? = nil
    ) {
        self.host = host
        self.username = username
        self.password = password
        self.userAgent = userAgent
        self.threadCount = threadCount
        self.speedLimit = speedLimit
    }

    public func validated() throws -> Self {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.count <= 253 else {
            throw PerHostSettingsError.invalid("主机不能为空且不能超过 253 个字符")
        }
        guard !normalized.contains("/") else {
            throw PerHostSettingsError.invalid("主机设置不能包含路径")
        }
        if let threadCount, !(1...64).contains(threadCount) {
            throw PerHostSettingsError.invalid("主机线程数必须在 1 到 64 之间")
        }
        if let speedLimit, speedLimit < 0 {
            throw PerHostSettingsError.invalid("主机速度限制不能为负数")
        }
        var copy = self
        copy.host = normalized
        return copy
    }

    public func matches(host value: String) -> Bool {
        let pattern = host.lowercased()
        let candidate = value.lowercased()
        return Self.glob(pattern, candidate)
    }

    private static func glob(_ pattern: String, _ value: String) -> Bool {
        let p = Array(pattern)
        let v = Array(value)
        var table = Array(repeating: Array(repeating: false, count: v.count + 1), count: p.count + 1)
        table[0][0] = true
        guard !p.isEmpty else { return value.isEmpty }
        for i in 1..<(p.count + 1) where p[i - 1] == "*" {
            table[i][0] = table[i - 1][0]
        }
        for i in 1..<(p.count + 1) {
            for j in 1..<(v.count + 1) {
                if p[i - 1] == "*" {
                    table[i][j] = table[i - 1][j] || table[i][j - 1]
                } else {
                    table[i][j] = table[i - 1][j - 1] && p[i - 1] == v[j - 1]
                }
            }
        }
        return table[p.count][v.count]
    }
}

public enum PerHostSettingsError: Error, LocalizedError, Sendable, Equatable {
    case corrupt(URL, String)
    case invalid(String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, let reason): return "无法读取主机设置 \(url.path)：\(reason)"
        case .invalid(let reason): return reason
        case .writeFailed(let url, let reason): return "无法保存主机设置 \(url.path)：\(reason)"
        }
    }
}

public actor PerHostSettingsStore {
    public nonisolated let settingsURL: URL
    private var values: [PerHostSettingsItem] = []
    private var loaded = false

    public init(dataRoot: URL) throws {
        let options = dataRoot.standardizedFileURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("options", isDirectory: true)
        try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
        settingsURL = options.appendingPathComponent("perHostSettings.json")
    }

    public func load() throws -> [PerHostSettingsItem] {
        if loaded { return values }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            loaded = true
            values = []
            return values
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            let decoded = try JSONDecoder().decode([PerHostSettingsItem].self, from: data)
            values = try normalize(decoded)
            loaded = true
            return values
        } catch let error as PerHostSettingsError {
            throw error
        } catch {
            throw PerHostSettingsError.corrupt(settingsURL, error.localizedDescription)
        }
    }

    @discardableResult
    public func save(_ items: [PerHostSettingsItem]) throws -> [PerHostSettingsItem] {
        _ = try load()
        let normalized = try normalize(items)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(normalized)
        } catch {
            throw PerHostSettingsError.writeFailed(settingsURL, error.localizedDescription)
        }
        let temporary = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(".perHostSettings.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw PerHostSettingsError.writeFailed(settingsURL, "无法创建临时文件")
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
            values = normalized
            loaded = true
            return normalized
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PerHostSettingsError.writeFailed(settingsURL, error.localizedDescription)
        }
    }

    public func matching(host: String) throws -> PerHostSettingsItem? {
        try load()
            .sorted { lhs, rhs in
                lhs.host.filter { $0 == "*" }.count < rhs.host.filter { $0 == "*" }.count
            }
            .first { $0.matches(host: host) }
    }

    private func normalize(_ items: [PerHostSettingsItem]) throws -> [PerHostSettingsItem] {
        var result: [PerHostSettingsItem] = []
        var seen = Set<String>()
        for item in items {
            let normalized = try item.validated()
            guard seen.insert(normalized.host).inserted else {
                throw PerHostSettingsError.invalid("主机设置不能重复：\(normalized.host)")
            }
            result.append(normalized)
        }
        return result
    }
}
