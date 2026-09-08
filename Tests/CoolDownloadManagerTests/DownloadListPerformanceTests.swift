import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("大列表性能", .serialized)
@MainActor
struct DownloadListPerformanceTests {
    // Run unchanged before/after in the same build configuration, on an idle
    // machine. Fixture creation, assertions and printing are outside timings.
    // No timing gate: debug/CI results must not be confused with release UI QA.
    @Test("历史记录加16活动任务", arguments: [1_000, 10_000])
    func listWorkload(historyCount: Int) {
        let store = DownloadListStore(service: nil)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<(historyCount + 16)).map { index in
            DownloadRecord(
                id: Int64(index + 1),
                source: DownloadSource(kind: .http, link: "https://example.test/files/\(index).bin"),
                folder: "/tmp",
                name: "file-\(index).bin",
                status: index < historyCount ? .completed : .downloading,
                downloadedBytes: 1_024,
                totalBytes: 1_048_576,
                queueID: Int64(index % 4),
                categoryID: Int64(index % 6),
                createdAt: epoch.addingTimeInterval(Double(index)),
                updatedAt: epoch
            )
        }
        store.apply(records, announceCompletion: false)
        var active = Array(records.suffix(16))
        store.selectedIDs = Set(active.map(\.id))
        var samples: [String: [Double]] = [:]
        let clock = ContinuousClock()
        var checksum: Int64 = 0

        func sample(_ name: String, iteration: Int, _ body: () -> Void) {
            let start = clock.now
            body()
            let duration = start.duration(to: clock.now).components
            let milliseconds = Double(duration.seconds) * 1_000
                + Double(duration.attoseconds) / 1e15
            if iteration >= 3 { samples[name, default: []].append(milliseconds) }
        }

        for iteration in 0..<33 {
            // One batch means 16 sequential production .updated events, not
            // one synthetic snapshot. There is no batch API in the store.
            for index in active.indices {
                active[index].revision += 1
                active[index].downloadedBytes += 1_024
                active[index].updatedAt = epoch.addingTimeInterval(Double(iteration + 1))
            }
            sample("16-events", iteration: iteration) {
                for record in active { store.apply(.updated(record)) }
            }
            store.filter = .all
            store.searchText = ""
            for order in DownloadSort.allCases {
                store.sort = order
                sample("visible-\(order.rawValue)-first", iteration: iteration) {
                    checksum += Int64(store.visibleDownloads.count)
                }
                sample("visible-\(order.rawValue)-repeat3", iteration: iteration) {
                    for _ in 0..<3 { checksum += Int64(store.visibleDownloads.count) }
                }
            }
            sample("lookup-selection", iteration: iteration) {
                // Include the oldest history ID (worst case for a newest-first
                // linear scan), an absent ID, and all active records.
                for id in [Int64(1), -1] + active.map(\.id) {
                    checksum += store.record(id: id)?.downloadedBytes ?? 0
                    _ = store.speed(for: id)
                }
                checksum += Int64(store.selectedDownloads.count)
                if store.canPauseSelection { checksum += 1 }
            }
            sample("search-filter", iteration: iteration) {
                store.searchText = "file-1"
                store.filter = .completed
                checksum += Int64(store.visibleDownloads.count)
                store.searchText = ""
                store.filter = .active
                checksum += Int64(store.visibleDownloads.count)
            }
            #expect(store.visibleDownloads.count == 16)
            #expect(store.record(id: active[0].id)?.downloadedBytes == active[0].downloadedBytes)
            #expect(store.record(id: -1) == nil)
        }
        #expect(checksum > 0)
        for name in samples.keys.sorted() {
            let values = samples[name]!.sorted()
            let p95 = values[Int(ceil(Double(values.count) * 0.95)) - 1]
            print("LIST_PERF history=\(historyCount) active=16 metric=\(name) n=\(values.count) median_ms=\(values[values.count / 2]) p95_ms=\(p95)")
        }
    }

    @Test("派生列表在进度、状态、名称、来源和删除后保持新鲜")
    func derivedListsStayCurrent() {
        let store = DownloadListStore(service: nil)
        var record = DownloadRecord(
            id: 1,
            source: DownloadSource(kind: .http, link: "https://example.test/old"),
            folder: "/tmp", name: "old", status: .downloading
        )
        store.apply([record], announceCompletion: false)
        store.filter = .active
        #expect(store.visibleDownloads.map(\.id) == [1])
        let stale = record
        record.revision += 1
        record.downloadedBytes = 512
        store.apply(.updated(record))
        #expect(store.visibleDownloads.first?.downloadedBytes == 512)
        record.revision += 1
        record.status = .completed
        record.name = "new"
        record.source.link = "https://example.test/replaced"
        record.queueID = 7
        record.categoryID = 8
        store.apply(.updated(record))
        store.apply(.updated(stale))
        #expect(store.visibleDownloads.isEmpty)
        store.filter = .completed
        store.searchText = " NEW "
        #expect(store.visibleDownloads.map(\.id) == [1])
        store.searchText = "replaced"
        #expect(store.visibleDownloads.map(\.id) == [1])
        store.filter = .queue(7)
        #expect(store.visibleDownloads.map(\.id) == [1])
        store.filter = .category(8)
        #expect(store.visibleDownloads.map(\.id) == [1])
        store.selectedIDs = [1]
        #expect(store.selectedDownloads.first?.status == .completed)
        store.apply(.removed(id: 1))
        #expect(store.record(id: 1) == nil)
        #expect(store.visibleDownloads.isEmpty)
        #expect(store.selectedDownloads.isEmpty)
    }
}
