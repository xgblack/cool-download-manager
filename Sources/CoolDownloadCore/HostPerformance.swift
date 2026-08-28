import Foundation

/// Privacy-preserving identity for a HTTP destination.  Only the protocol,
/// normalized host and effective port are retained; paths, query strings and
/// request headers never become part of a performance record.
public struct HostPerformanceKey: Codable, Hashable, Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(scheme: String, host: String, port: Int? = nil) {
        let normalizedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedScheme == "http" || normalizedScheme == "https" else {
            return nil
        }
        guard let normalizedHost = Self.normalizeHost(host) else {
            return nil
        }
        let effectivePort = port ?? Self.defaultPort(for: normalizedScheme)
        guard (1...65_535).contains(effectivePort) else {
            return nil
        }
        self.scheme = normalizedScheme
        self.host = normalizedHost
        self.port = effectivePort
    }

    public init?(url: URL) {
        guard let scheme = url.scheme,
              let host = url.host else {
            return nil
        }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    public init?(link: String) {
        guard let url = URL(string: link) else {
            return nil
        }
        self.init(url: url)
    }

    /// A stable, non-URL representation useful for dictionary ordering and
    /// diagnostics. It intentionally omits every URL component except the key.
    public var storageKey: String {
        "\(scheme)|\(host)|\(port)"
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    private static func normalizeHost(_ rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              host.count <= 253,
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"),
              !host.contains("?"),
              !host.contains("#"),
              !host.contains("@") else {
            return nil
        }
        return host
    }
}

public enum HostPerformanceError: Error, LocalizedError, Sendable, Equatable {
    case corrupt(URL, String)
    case invalid(String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, let reason):
            return "无法读取主机性能画像 \(url.path)：\(reason)"
        case .invalid(let reason):
            return reason
        case .writeFailed(let url, let reason):
            return "无法保存主机性能画像 \(url.path)：\(reason)"
        }
    }
}

/// A bounded, expiring aggregate of observations for one HTTP host.
public struct HostPerformanceRecord: Codable, Equatable, Sendable {
    public var key: HostPerformanceKey
    public var updatedAt: Date
    public var successCount: Int
    public var failureCount: Int
    public var preferredConnectionLimit: Int
    public var smoothedGoodputBytesPerSecond: Double?

    public init(
        key: HostPerformanceKey,
        updatedAt: Date = Date(),
        successCount: Int = 0,
        failureCount: Int = 0,
        preferredConnectionLimit: Int = 1,
        smoothedGoodputBytesPerSecond: Double? = nil
    ) {
        self.key = key
        self.updatedAt = updatedAt
        self.successCount = successCount
        self.failureCount = failureCount
        self.preferredConnectionLimit = preferredConnectionLimit
        self.smoothedGoodputBytesPerSecond = smoothedGoodputBytesPerSecond
    }

    fileprivate func validated() throws -> Self {
        guard let canonicalKey = HostPerformanceKey(
            scheme: key.scheme,
            host: key.host,
            port: key.port
        ) else {
            throw HostPerformanceError.invalid("主机性能画像的主机标识无效")
        }
        guard successCount >= 0, failureCount >= 0 else {
            throw HostPerformanceError.invalid("主机性能计数不能为负数")
        }
        guard (1...64).contains(preferredConnectionLimit) else {
            throw HostPerformanceError.invalid("主机性能连接数必须在 1 到 64 之间")
        }
        if let goodput = smoothedGoodputBytesPerSecond,
           (!goodput.isFinite || goodput <= 0) {
            throw HostPerformanceError.invalid("主机性能吞吐必须是有限的正数")
        }
        var copy = self
        copy.key = canonicalKey
        return copy
    }
}

/// Stores only host-level performance hints. A bad or unavailable hint must
/// never prevent a download, so callers can treat errors as a cache miss.
public actor HostPerformanceStore {
    public nonisolated let settingsURL: URL

    private let ttl: TimeInterval
    private let maximumRecords: Int
    private let now: @Sendable () -> Date
    private var values: [HostPerformanceKey: HostPerformanceRecord] = [:]
    private var loaded = false

    public init(
        dataRoot: URL,
        ttl: TimeInterval = 7 * 24 * 60 * 60,
        maximumRecords: Int = 256,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.ttl = max(0, ttl)
        self.maximumRecords = max(1, maximumRecords)
        self.now = now
        let options = dataRoot.standardizedFileURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("options", isDirectory: true)
        try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
        settingsURL = options.appendingPathComponent("hostPerformance.json")
    }

    public func load() throws -> [HostPerformanceRecord] {
        if loaded {
            return sortedValues()
        }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            loaded = true
            values = [:]
            return []
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decoded = try decoder.decode([HostPerformanceRecord].self, from: data)
            let normalized = try normalize(decoded, at: now())
            let changed = normalized.count != decoded.count
                || normalized != decoded.sorted { $0.key.storageKey < $1.key.storageKey }
            values = Dictionary(uniqueKeysWithValues: normalized.map { ($0.key, $0) })
            loaded = true
            if changed {
                try write(normalized)
            }
            return sortedValues()
        } catch let error as HostPerformanceError {
            throw error
        } catch {
            throw HostPerformanceError.corrupt(settingsURL, error.localizedDescription)
        }
    }

    public func all() throws -> [HostPerformanceRecord] {
        try load()
    }

    public func record(for key: HostPerformanceKey) throws -> HostPerformanceRecord? {
        _ = try load()
        return values[key]
    }

    public func record(for link: String) throws -> HostPerformanceRecord? {
        guard let key = HostPerformanceKey(link: link) else {
            return nil
        }
        return try record(for: key)
    }

    /// Replaces the cache. This is also useful for deterministic migration and
    /// tests; normal runtime code should prefer `observe`.
    @discardableResult
    public func save(_ records: [HostPerformanceRecord]) throws -> [HostPerformanceRecord] {
        _ = try load()
        let normalized = try normalize(records, at: now())
        try write(normalized)
        values = Dictionary(uniqueKeysWithValues: normalized.map { ($0.key, $0) })
        loaded = true
        return sortedValues()
    }

    /// Adds one aggregate sample using an EWMA for goodput. The alpha is kept
    /// deliberately conservative so one transient CDN result cannot swing the
    /// recommendation immediately.
    @discardableResult
    public func observe(
        key: HostPerformanceKey,
        succeeded: Bool,
        preferredConnectionLimit: Int? = nil,
        goodputBytesPerSecond: Double? = nil,
        at timestamp: Date? = nil
    ) throws -> HostPerformanceRecord {
        _ = try load()
        var value = values[key] ?? HostPerformanceRecord(key: key)
        value.updatedAt = timestamp ?? now()
        if succeeded {
            value.successCount += 1
            if let preferredConnectionLimit {
                value.preferredConnectionLimit = min(64, max(1, preferredConnectionLimit))
            }
            if let goodputBytesPerSecond,
               goodputBytesPerSecond.isFinite,
               goodputBytesPerSecond > 0 {
                if let previous = value.smoothedGoodputBytesPerSecond {
                    value.smoothedGoodputBytesPerSecond = previous * 0.75 + goodputBytesPerSecond * 0.25
                } else {
                    value.smoothedGoodputBytesPerSecond = goodputBytesPerSecond
                }
            }
        } else {
            value.failureCount += 1
        }
        value = try value.validated()
        values[key] = value
        let bounded = try normalize(Array(values.values), at: now())
        values = Dictionary(uniqueKeysWithValues: bounded.map { ($0.key, $0) })
        try write(bounded)
        return value
    }

    private func sortedValues() -> [HostPerformanceRecord] {
        values.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.key.storageKey < $1.key.storageKey
        }
    }

    private func normalize(
        _ records: [HostPerformanceRecord],
        at timestamp: Date
    ) throws -> [HostPerformanceRecord] {
        let cutoff = timestamp.addingTimeInterval(-ttl)
        var result: [HostPerformanceRecord] = []
        var seen = Set<HostPerformanceKey>()
        for record in records {
            let validated = try record.validated()
            guard seen.insert(validated.key).inserted else {
                throw HostPerformanceError.invalid("主机性能画像不能重复：\(validated.key.storageKey)")
            }
            guard validated.updatedAt >= cutoff else {
                continue
            }
            result.append(validated)
        }
        result.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.key.storageKey < $1.key.storageKey
        }
        if result.count > maximumRecords {
            result.removeLast(result.count - maximumRecords)
        }
        return result
    }

    private func write(_ records: [HostPerformanceRecord]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            let temporary = settingsURL.deletingLastPathComponent()
                .appendingPathComponent(".hostPerformance.\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw HostPerformanceError.writeFailed(settingsURL, "无法创建临时文件")
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
                throw error
            }
        } catch let error as HostPerformanceError {
            throw error
        } catch {
            throw HostPerformanceError.writeFailed(settingsURL, error.localizedDescription)
        }
    }
}
