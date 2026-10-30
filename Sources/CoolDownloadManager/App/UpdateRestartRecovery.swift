import Foundation
import CoolDownloadCore

/// A one-shot handoff for an explicitly requested update restart. Normal quits
/// never create it, so manually paused downloads keep their existing semantics.
@MainActor
struct UpdateRestartRecovery {
    static let key = "pendingUpdateRestartDownloads"
    private let defaults: UserDefaults

    private struct Record: Codable {
        let targetBuild: Int
        let createdAt: Date
        let downloadIDs: [DownloadID]
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func save(targetBuild: String, downloads: [DownloadRecord], now: Date = Date()) throws {
        guard let build = Int(targetBuild), build > 0 else { throw UpdateRoutingError.invalidFeed }
        let ids = downloads.filter {
            $0.status == .downloading || $0.status == .preparing || $0.status == .retrying
        }.map(\.id).sorted()
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            let record = Record(targetBuild: build, createdAt: now, downloadIDs: ids)
            defaults.set(try JSONEncoder().encode(record), forKey: Self.key)
        }
    }

    func consume(currentBuild: Int, now: Date = Date()) throws -> [DownloadID] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        defer { defaults.removeObject(forKey: Self.key) }
        let record = try JSONDecoder().decode(Record.self, from: data)
        let age = now.timeIntervalSince(record.createdAt)
        guard age >= -300, age <= 24 * 3_600, currentBuild >= record.targetBuild else { return [] }
        return record.downloadIDs
    }
}
