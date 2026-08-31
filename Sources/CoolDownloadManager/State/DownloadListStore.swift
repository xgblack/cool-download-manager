import Foundation
import SwiftUI
import CoolDownloadCore

enum DownloadFilter: Hashable, Sendable {
    case all
    case active
    case completed
    case failed
    case paused
    case queue(DownloadID)
    case category(DownloadID)

    var title: String {
        switch self {
        case .all: return "全部下载"
        case .active: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .paused: return "已暂停"
        case .queue: return "队列"
        case .category: return "分类"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "arrow.down.circle"
        case .active: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .paused: return "pause.circle"
        case .queue: return "list.bullet.rectangle"
        case .category: return "folder"
        }
    }
}

enum DownloadSort: String, CaseIterable, Sendable {
    case createdNewest
    case name
    case status

    var title: String {
        switch self {
        case .createdNewest: return "添加日期"
        case .name: return "名称"
        case .status: return "状态"
        }
    }
}

struct DownloadPartSpeedSampler {
    private struct ProgressSample {
        var bytes: Int64
        var date: Date
    }

    private struct SpeedSample {
        var bytesPerSecond: Double
        var date: Date
    }

    private let minimumSampleInterval: TimeInterval
    private let idleInterval: TimeInterval
    private var progressByDownload: [DownloadID: [Int: ProgressSample]] = [:]
    private var speedsByDownload: [DownloadID: [Int: SpeedSample]] = [:]

    init(minimumSampleInterval: TimeInterval = 0.25, idleInterval: TimeInterval = 1.5) {
        self.minimumSampleInterval = max(0.05, minimumSampleInterval)
        self.idleInterval = max(self.minimumSampleInterval, idleInterval)
    }

    mutating func update(_ records: [DownloadRecord], at now: Date) {
        let availableDownloadIDs = Set(records.map(\.id))
        progressByDownload = progressByDownload.filter { availableDownloadIDs.contains($0.key) }
        speedsByDownload = speedsByDownload.filter { availableDownloadIDs.contains($0.key) }
        for record in records {
            update(record, at: now)
        }
    }

    mutating func update(_ record: DownloadRecord, at now: Date) {
        guard record.status == .downloading, !record.parts.isEmpty else {
            remove(downloadID: record.id)
            return
        }

        let availablePartIDs = Set(record.parts.map(\.id))
        var progress = (progressByDownload[record.id] ?? [:])
            .filter { availablePartIDs.contains($0.key) }
        var speeds = (speedsByDownload[record.id] ?? [:])
            .filter { availablePartIDs.contains($0.key) }

        for part in record.parts {
            guard !part.completed else {
                progress.removeValue(forKey: part.id)
                speeds.removeValue(forKey: part.id)
                continue
            }

            let bytes = max(0, part.downloaded)
            guard let previous = progress[part.id] else {
                progress[part.id] = ProgressSample(bytes: bytes, date: now)
                speeds.removeValue(forKey: part.id)
                continue
            }

            let elapsed = now.timeIntervalSince(previous.date)
            let delta = bytes - previous.bytes
            guard elapsed > 0, delta >= 0 else {
                progress[part.id] = ProgressSample(bytes: bytes, date: now)
                speeds.removeValue(forKey: part.id)
                continue
            }

            if delta > 0, elapsed >= minimumSampleInterval {
                speeds[part.id] = SpeedSample(
                    bytesPerSecond: Double(delta) / elapsed,
                    date: now
                )
                progress[part.id] = ProgressSample(bytes: bytes, date: now)
            } else if delta == 0, elapsed >= idleInterval {
                speeds[part.id] = SpeedSample(bytesPerSecond: 0, date: now)
                progress[part.id] = ProgressSample(bytes: bytes, date: now)
            }
        }

        if progress.isEmpty {
            progressByDownload.removeValue(forKey: record.id)
        } else {
            progressByDownload[record.id] = progress
        }
        if speeds.isEmpty {
            speedsByDownload.removeValue(forKey: record.id)
        } else {
            speedsByDownload[record.id] = speeds
        }
    }

    mutating func remove(downloadID: DownloadID) {
        progressByDownload.removeValue(forKey: downloadID)
        speedsByDownload.removeValue(forKey: downloadID)
    }

    func speed(for downloadID: DownloadID, partID: Int, at now: Date) -> Double? {
        guard let sample = speedsByDownload[downloadID]?[partID] else { return nil }
        let age = now.timeIntervalSince(sample.date)
        guard age >= 0 else { return nil }
        return age >= idleInterval ? 0 : sample.bytesPerSecond
    }
}

@MainActor
final class DownloadListStore: ObservableObject {
    @Published private(set) var downloads: [DownloadRecord] = []
    @Published var selectedIDs: Set<DownloadID> = []
    @Published var filter: DownloadFilter = .all
    @Published var searchText = ""
    @Published var sort: DownloadSort = .createdNewest
    @Published var errorMessage: String?
    @Published private(set) var completedID: DownloadID?
    @Published private(set) var progressID: DownloadID?
    @Published private(set) var failedID: DownloadID?
    @Published private(set) var speeds: [DownloadID: Double] = [:]
    @Published private(set) var activeConnectionCounts: [DownloadID: Int] = [:]

    let service: DownloadService?
    /// Called after a snapshot no longer contains records that were visible
    /// before. AppStore uses this to prune queue/category indexes.
    var onRemovedIDs: ((Set<DownloadID>) -> Void)?
    /// Called after a record has been applied and transitions to completed.
    /// This callback belongs to the download lifecycle rather than a visible
    /// SwiftUI window, so completion UI can still be presented when the main
    /// window is closed.
    var onDownloadCompleted: ((DownloadRecord) -> Void)?
    /// Called after a task transitions into its initial preparing/downloading
    /// state. Keep this at the lifecycle layer so progress UI does not depend
    /// on the main list window being alive.
    var onDownloadStarted: ((DownloadRecord) -> Void)?
    private var eventTask: Task<Void, Never>?
    private var knownStatuses: [DownloadID: DownloadStatus] = [:]
    private var previousProgress: [DownloadID: (bytes: Int64, date: Date)] = [:]
    private var averageSpeedSessions: [DownloadID: (bytes: Int64, date: Date)] = [:]
    private var partSpeedSampler = DownloadPartSpeedSampler()
    private var suppressedProgressIDs: Set<DownloadID> = []

    init(service: DownloadService?) {
        self.service = service
    }

    deinit {
        eventTask?.cancel()
    }

    var visibleDownloads: [DownloadRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = downloads.filter { record in
            matchesFilter(record) &&
                (query.isEmpty || record.name.lowercased().contains(query) || record.source.link.lowercased().contains(query))
        }

        switch sort {
        case .createdNewest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .name:
            return filtered.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .status:
            return filtered.sorted {
                statusRank($0.status) < statusRank($1.status)
            }
        }
    }

    var selectedDownloads: [DownloadRecord] {
        downloads.filter { selectedIDs.contains($0.id) }
    }

    var hasSelection: Bool { !selectedIDs.isEmpty }

    var canStartSelection: Bool {
        selectedDownloads.contains { record in
            record.status == .added || record.status == .paused || record.status == .failed || record.status == .cancelled
        }
    }

    var canPauseSelection: Bool {
        selectedDownloads.contains { record in
            record.status == .preparing || record.status == .downloading || record.status == .retrying
        }
    }

    var canRetrySelection: Bool {
        selectedDownloads.contains { record in
            record.status == .failed || record.status == .cancelled
        }
    }

    func reload() async {
        guard let service else { return }
        let snapshot = await service.snapshot()
        apply(snapshot.downloads, announceCompletion: false)
    }

    func beginObserving() {
        guard eventTask == nil, let service else { return }
        eventTask = Task { [weak self] in
            let events = await service.events()
            for await event in events {
                guard !Task.isCancelled else { break }
                // Use the record carried by the event. A browser-initiated
                // download can move from added to preparing/downloading
                // before a snapshot round trip completes; re-reading only a
                // snapshot here could miss the transition that opens the
                // progress window.
                self?.apply(event)
            }
        }
    }

    func apply(_ event: DownloadEvent) {
        switch event {
        case .created(let record), .updated(let record):
            if let current = downloads.first(where: { $0.id == record.id }),
               shouldKeepCurrent(current, over: record) {
                return
            }
            let now = Date()
            partSpeedSampler.update(record, at: now)
            var next = downloads.filter { $0.id != record.id }
            next.append(record)
            apply(next, updatePartSpeeds: false, at: now)
        case .removed(let id):
            setActiveConnectionCount(0, for: id)
            partSpeedSampler.remove(downloadID: id)
            guard downloads.contains(where: { $0.id == id }) else { return }
            apply(downloads.filter { $0.id != id }, updatePartSpeeds: false)
        case .activeConnectionCountChanged(let id, let count):
            setActiveConnectionCount(count, for: id)
        }
    }

    func apply(
        _ records: [DownloadRecord],
        announceCompletion: Bool = true,
        updatePartSpeeds: Bool = true,
        at now: Date = Date()
    ) {
        let currentByID = Dictionary(uniqueKeysWithValues: downloads.map { ($0.id, $0) })
        let acceptedRecords = records.map { incoming in
            guard let current = currentByID[incoming.id], shouldKeepCurrent(current, over: incoming) else {
                return incoming
            }
            return current
        }
        let previousStatuses = knownStatuses
        let previousIDs = Set(knownStatuses.keys)
        if updatePartSpeeds {
            partSpeedSampler.update(acceptedRecords, at: now)
        }
        var nextProgress: [DownloadID: (bytes: Int64, date: Date)] = [:]
        var nextSpeeds: [DownloadID: Double] = [:]
        for record in acceptedRecords {
            if let previous = previousProgress[record.id] {
                let elapsed = now.timeIntervalSince(previous.date)
                let delta = record.downloadedBytes - previous.bytes
                if elapsed > 0, delta >= 0 {
                    nextSpeeds[record.id] = Double(delta) / elapsed
                }
            }
            nextProgress[record.id] = (record.downloadedBytes, now)
        }
        previousProgress = nextProgress
        speeds = nextSpeeds
        let availableIDs = Set(acceptedRecords.map(\.id))
        averageSpeedSessions = averageSpeedSessions.filter { availableIDs.contains($0.key) }
        for record in acceptedRecords {
            if record.status == .downloading {
                let currentSession = averageSpeedSessions[record.id]
                if previousStatuses[record.id] != .downloading
                    || currentSession == nil
                    || record.downloadedBytes < currentSession?.bytes ?? 0 {
                    averageSpeedSessions[record.id] = (record.downloadedBytes, now)
                }
            } else {
                averageSpeedSessions[record.id] = nil
            }
        }
        downloads = acceptedRecords.sorted { $0.createdAt > $1.createdAt }
        knownStatuses = Dictionary(uniqueKeysWithValues: acceptedRecords.map { ($0.id, $0.status) })
        let downloadingIDs = Set(acceptedRecords.lazy.filter { $0.status == .downloading }.map(\.id))
        let staleRuntimeIDs = activeConnectionCounts.keys.filter { !downloadingIDs.contains($0) }
        if !staleRuntimeIDs.isEmpty {
            var nextCounts = activeConnectionCounts
            staleRuntimeIDs.forEach { nextCounts[$0] = nil }
            activeConnectionCounts = nextCounts
        }
        let removedIDs = previousIDs.subtracting(knownStatuses.keys)
        if !removedIDs.isEmpty {
            onRemovedIDs?(removedIDs)
        }
        if announceCompletion, let completed = acceptedRecords.first(where: { record in
            record.status == .completed && previousStatuses[record.id] != .completed
        }) {
            completedID = completed.id
            onDownloadCompleted?(completed)
        }
        if announceCompletion, let started = acceptedRecords.first(where: { record in
            (record.status == .preparing || record.status == .downloading)
                && previousStatuses[record.id] != .preparing
                && previousStatuses[record.id] != .downloading
        }) {
            if suppressedProgressIDs.remove(started.id) == nil {
                progressID = started.id
                onDownloadStarted?(started)
            }
        }
        if announceCompletion, let failed = acceptedRecords.first(where: { record in
            record.status == .failed && previousStatuses[record.id] != .failed
        }) {
            failedID = failed.id
        }
        selectedIDs = selectedIDs.intersection(availableIDs)
        suppressedProgressIDs.formIntersection(availableIDs)
    }

    func speed(for id: DownloadID, average: Bool = false, at date: Date = Date()) -> Double? {
        guard let record = downloads.first(where: { $0.id == id }), record.downloadedBytes > 0 else {
            return nil
        }
        if average {
            guard let session = averageSpeedSessions[id] else { return nil }
            let elapsed = date.timeIntervalSince(session.date)
            let downloaded = record.downloadedBytes - session.bytes
            guard elapsed > 0, downloaded >= 0 else { return nil }
            return Double(downloaded) / elapsed
        }
        return speeds[id]
    }

    func speed(for id: DownloadID, partID: Int, at date: Date = Date()) -> Double? {
        partSpeedSampler.speed(for: id, partID: partID, at: date)
    }

    func activeConnectionCount(for id: DownloadID) -> Int {
        activeConnectionCounts[id] ?? 0
    }

    private func setActiveConnectionCount(_ count: Int, for id: DownloadID) {
        let normalized = max(0, count)
        let isDownloading = downloads.first(where: { $0.id == id })?.status == .downloading
        let nextCount = isDownloading ? normalized : 0
        guard activeConnectionCounts[id] != nextCount else { return }
        var nextCounts = activeConnectionCounts
        nextCounts[id] = nextCount == 0 ? nil : nextCount
        activeConnectionCounts = nextCounts
    }

    func acknowledgeCompletion() {
        completedID = nil
    }

    func acknowledgeProgress() {
        progressID = nil
    }

    func acknowledgeFailure() {
        failedID = nil
    }

    func selectAllVisible() {
        selectedIDs = Set(visibleDownloads.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func toggleSelection(_ id: DownloadID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func addAndStart(
        link: String,
        name: String?,
        folder: URL,
        queueID: DownloadID? = nil,
        categoryID: DownloadID? = nil,
        startImmediately: Bool = true
    ) {
        guard let service else {
            errorMessage = "下载核心尚未准备好"
            return
        }
        let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLink.isEmpty else {
            errorMessage = "请输入下载地址"
            return
        }

        let links = trimmedLink
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        Task { [weak self] in
            do {
                for link in links {
                    _ = try await service.add(
                        AddDownloadRequest(
                            source: DownloadSource(
                                kind: .http,
                                link: link,
                                suggestedName: links.count == 1 ? name?.nilIfBlank : nil
                            ),
                            folder: folder.path,
                            name: links.count == 1 ? name?.nilIfBlank : nil,
                            queueID: queueID,
                            categoryID: categoryID,
                            start: startImmediately
                        )
                    )
                }
                await self?.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func addBatch(
        pattern: String,
        start: Int,
        end: Int,
        wildcardLength: BatchWildcardLength,
        folder: URL,
        startImmediately: Bool
    ) {
        guard let service else {
            errorMessage = "下载核心尚未准备好"
            return
        }
        let links: [String]
        do {
            links = try BatchDownloadExpander().expand(
                pattern: pattern,
                start: start,
                end: end,
                wildcardLength: wildcardLength
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        Task { [weak self] in
            do {
                for link in links {
                    _ = try await service.add(AddDownloadRequest(
                        source: DownloadSource(kind: .http, link: link),
                        folder: folder.path,
                        start: startImmediately
                    ))
                }
                await self?.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func startSelected() {
        let ids = selectedDownloads
            .filter { $0.status == .added || $0.status == .paused || $0.status == .failed || $0.status == .cancelled }
            .map(\.id)
        suppressedProgressIDs.subtract(ids)
        perform(ids: ids) { service, ids in
            try await service.resume(ids: ids)
        }
    }

    /// Operates on one task without changing the table selection. Utility
    /// panels use these methods so their controls do not disturb the main
    /// download list.
    func start(id: DownloadID) {
        guard let record = record(id: id),
              record.status == .added || record.status == .paused
                || record.status == .failed || record.status == .cancelled else {
            return
        }
        suppressedProgressIDs.remove(id)
        perform(ids: [id]) { service, ids in
            try await service.resume(ids: ids)
        }
    }

    func pauseSelected() {
        let ids = selectedDownloads
            .filter { $0.status == .preparing || $0.status == .downloading || $0.status == .retrying }
            .map(\.id)
        suppressProgressPresentation(for: ids)
        perform(ids: ids) { service, ids in
            try await service.pause(ids: ids)
        }
    }

    func pause(id: DownloadID) {
        guard let record = record(id: id),
              record.status == .preparing || record.status == .downloading || record.status == .retrying else {
            return
        }
        suppressProgressPresentation(for: [id])
        perform(ids: [id]) { service, ids in
            try await service.pause(ids: ids)
        }
    }

    func retrySelected() {
        let ids = selectedDownloads
            .filter { $0.status == .failed || $0.status == .cancelled }
            .map(\.id)
        suppressedProgressIDs.subtract(ids)
        perform(ids: ids) { service, ids in
            try await service.retry(ids: ids)
        }
    }

    func retry(id: DownloadID) {
        guard let record = record(id: id), record.status == .failed || record.status == .cancelled else {
            return
        }
        suppressedProgressIDs.remove(id)
        perform(ids: [id]) { service, ids in
            try await service.retry(ids: ids)
        }
    }

    func redownloadSelected() {
        let ids = selectedDownloads
            .filter { $0.status == .completed }
            .map(\.id)
        suppressedProgressIDs.subtract(ids)
        perform(ids: ids) { service, ids in
            try await service.redownload(ids: ids)
        }
    }

    func redownload(id: DownloadID) {
        guard let record = record(id: id), record.status == .completed else { return }
        suppressedProgressIDs.remove(id)
        perform(ids: [id]) { service, ids in
            try await service.redownload(ids: ids)
        }
    }

    func updateTaskSettings(id: DownloadID, settings: DownloadTaskSettings?) async throws {
        guard let service else {
            throw DownloadCoreError.cancelled
        }
        _ = try await service.updateTaskSettings(id: id, settings: settings)
        await reload()
    }

    @discardableResult
    func patchSource(
        id: DownloadID,
        link: String,
        headers: [String: String]?
    ) async throws -> DownloadSourcePatchResult {
        guard let service else {
            throw DownloadCoreError.cancelled
        }
        let result = try await service.patchSource(
            id: id,
            patch: DownloadSourcePatch(link: link, headers: headers)
        )
        await reload()
        return result
    }

    func removeSelected(removeFiles: Bool = false) {
        perform(ids: Array(selectedIDs)) { service, ids in
            try await service.remove(ids: ids, removeFiles: removeFiles)
        }
    }

    func removeCompleted() {
        let ids = downloads.filter { $0.status == .completed }.map(\.id)
        perform(ids: ids) { service, ids in
            try await service.remove(ids: ids, removeFiles: false)
        }
    }

    func removeIncomplete() {
        let ids = downloads.filter { $0.status != .completed }.map(\.id)
        perform(ids: ids) { service, ids in
            try await service.remove(ids: ids, removeFiles: false)
        }
    }

    func removeAll() {
        perform(ids: downloads.map(\.id)) { service, ids in
            try await service.remove(ids: ids, removeFiles: false)
        }
    }

    func startQueue(_ queueID: DownloadID, orderedIDs: [DownloadID]? = nil) {
        perform(ids: [], allowEmpty: true) { service, _ in
            try await service.startQueue(id: queueID, orderedIDs: orderedIDs)
        }
    }

    func stopQueue(_ queueID: DownloadID) {
        let ids = downloads
            .filter {
                $0.queueID == queueID
                    && ($0.status == .preparing || $0.status == .downloading || $0.status == .retrying)
            }
            .map(\.id)
        suppressProgressPresentation(for: ids)
        perform(ids: [], allowEmpty: true) { service, _ in
            try await service.stopQueue(id: queueID)
        }
    }

    func stopAll() {
        let ids = downloads
            .filter { $0.status == .preparing || $0.status == .downloading || $0.status == .retrying }
            .map(\.id)
        guard !ids.isEmpty else { return }
        suppressProgressPresentation(for: ids)
        perform(ids: ids) { service, ids in
            try await service.pause(ids: ids)
        }
    }

    func record(id: DownloadID) -> DownloadRecord? {
        downloads.first { $0.id == id }
    }

    private func suppressProgressPresentation(for ids: [DownloadID]) {
        suppressedProgressIDs.formUnion(ids)
        if let progressID, ids.contains(progressID) {
            self.progressID = nil
        }
    }

    private func shouldKeepCurrent(_ current: DownloadRecord, over incoming: DownloadRecord) -> Bool {
        if current.revision != incoming.revision {
            return current.revision > incoming.revision
        }
        if current.updatedAt != incoming.updatedAt {
            return current.updatedAt > incoming.updatedAt
        }
        return current.downloadedBytes > incoming.downloadedBytes
    }

    private func perform(
        ids: [DownloadID],
        allowEmpty: Bool = false,
        operation: @escaping (DownloadService, [DownloadID]) async throws -> Void
    ) {
        guard let service else {
            errorMessage = "下载核心尚未准备好"
            return
        }
        guard allowEmpty || !ids.isEmpty else { return }
        Task { [weak self] in
            do {
                try await operation(service, ids)
                await self?.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func matchesFilter(_ record: DownloadRecord) -> Bool {
        switch filter {
        case .all:
            return true
        case .active:
            return record.status == .preparing || record.status == .downloading || record.status == .retrying
        case .completed:
            return record.status == .completed
        case .failed:
            return record.status == .failed || record.status == .waitingForSourceRefresh
        case .paused:
            return record.status == .paused
        case .queue(let id):
            return record.queueID == id
        case .category(let id):
            return record.categoryID == id
        }
    }

    private func statusRank(_ status: DownloadStatus) -> Int {
        switch status {
        case .downloading: return 0
        case .preparing: return 1
        case .retrying: return 2
        case .waitingForSourceRefresh: return 3
        case .paused: return 4
        case .failed: return 5
        case .added: return 6
        case .cancelled: return 7
        case .completed: return 8
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
