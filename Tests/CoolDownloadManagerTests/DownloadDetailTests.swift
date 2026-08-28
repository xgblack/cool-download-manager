import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("下载详情")
struct DownloadDetailTests {
    @Test("修改时间使用中文年月日和二十四小时制")
    func formatsModificationDateInChinese() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 26,
            hour: 22,
            minute: 12,
            second: 51
        )))

        #expect(
            DownloadDetailDateText.string(from: date, timeZone: timeZone)
                == "2026年8月26日 22:12:51"
        )
    }

    @Test("失败任务没有 Range 工作块时显示服务器错误")
    func reportsFailedEmptyParts() {
        let record = DownloadRecord(
            id: 7,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .failed,
            error: "服务器返回 HTTP 403"
        )

        #expect(emptyRangeWorkMessage(for: record) == "失败：服务器返回 HTTP 403")
    }

    @Test("没有 Range 工作块时不暗示正在使用更多连接")
    func reportsEmptyRangeWork() {
        let record = DownloadRecord(
            id: 8,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .downloading
        )

        #expect(emptyRangeWorkMessage(for: record) == "暂无 Range 工作块")
    }

    @Test("进度页按任务、主机、全局优先级显示最大连接数")
    func displaysConfiguredConnectionLimit() {
        var record = DownloadRecord(
            id: 9,
            source: DownloadSource(kind: .http, link: "https://cdn.example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin"
        )
        let hostSettings = [
            PerHostSettingsItem(host: "*.example.test", threadCount: 4),
            PerHostSettingsItem(host: "cdn.example.test", threadCount: 8)
        ]

        #expect(displayedConnectionLimit(
            for: record,
            globalLimit: 16,
            perHostSettings: hostSettings
        ) == 8)

        record.taskSettings = DownloadTaskSettings(threadCount: 12)
        #expect(displayedConnectionLimit(
            for: record,
            globalLimit: 16,
            perHostSettings: hostSettings
        ) == 12)

        record.taskSettings = nil
        record.source.link = "https://other.invalid/file.bin"
        #expect(displayedConnectionLimit(
            for: record,
            globalLimit: 16,
            perHostSettings: hostSettings
        ) == 16)
    }

    @Test("活动连接数在暂停后清零并忽略过期事件")
    @MainActor
    func tracksActiveConnectionCountOnlyWhileDownloading() {
        let store = DownloadListStore(service: nil)
        var record = DownloadRecord(
            id: 10,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .downloading
        )
        store.apply([record], announceCompletion: false)
        store.apply(.activeConnectionCountChanged(id: record.id, count: 3))
        #expect(store.activeConnectionCount(for: record.id) == 3)

        record.status = .paused
        record.revision += 1
        store.apply([record], announceCompletion: false)
        #expect(store.activeConnectionCount(for: record.id) == 0)

        store.apply(.activeConnectionCountChanged(id: record.id, count: 2))
        #expect(store.activeConnectionCount(for: record.id) == 0)
    }

    @Test("旧下载事件不能覆盖较新的暂停状态")
    @MainActor
    func staleDownloadEventDoesNotResumePausedTask() {
        let store = DownloadListStore(service: nil)
        var paused = DownloadRecord(
            id: 9,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .paused
        )
        paused.revision = 12
        store.apply([paused], announceCompletion: false)

        var staleDownloading = paused
        staleDownloading.status = .downloading
        staleDownloading.revision = 11
        store.apply([staleDownloading])

        #expect(store.record(id: paused.id)?.status == .paused)
        #expect(store.record(id: paused.id)?.revision == 12)
        #expect(store.progressID == nil)
    }

    @Test("平均速度只计算当前下载会话")
    @MainActor
    func averageSpeedUsesCurrentActiveSession() throws {
        let store = DownloadListStore(service: nil)
        let sessionStart = Date(timeIntervalSince1970: 10_000)
        var record = DownloadRecord(
            id: 10,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .downloading,
            downloadedBytes: 1_000,
            createdAt: sessionStart.addingTimeInterval(-86_400)
        )
        store.apply([record], announceCompletion: false, at: sessionStart)

        record.downloadedBytes = 2_000
        record.updatedAt = sessionStart.addingTimeInterval(2)
        record.revision += 1
        store.apply([record], announceCompletion: false, at: record.updatedAt)

        let speed = try #require(store.speed(for: record.id, average: true, at: record.updatedAt))
        #expect(speed == 500)
    }

    @Test("列表暂停和停止不会打开下载进度窗口")
    @MainActor
    func listPauseAndStopSuppressPendingProgressWindow() {
        func makeStore(id: DownloadID) -> DownloadListStore {
            let store = DownloadListStore(service: nil)
            var record = DownloadRecord(
                id: id,
                source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
                folder: "/tmp",
                name: "file.bin"
            )
            store.apply([record], announceCompletion: false)
            store.selectedIDs = [id]
            record.status = .downloading
            record.updatedAt = record.updatedAt.addingTimeInterval(1)
            record.revision += 1
            store.apply([record])
            return store
        }

        let pausedStore = makeStore(id: 11)
        #expect(pausedStore.progressID == 11)
        pausedStore.pauseSelected()
        #expect(pausedStore.progressID == nil)

        let stoppedStore = makeStore(id: 12)
        #expect(stoppedStore.progressID == 12)
        stoppedStore.stopAll()
        #expect(stoppedStore.progressID == nil)
    }
}
