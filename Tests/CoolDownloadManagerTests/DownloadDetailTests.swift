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

    @Test("失败任务没有分片时显示服务器错误而不是等待")
    func reportsFailedEmptyParts() {
        let record = DownloadRecord(
            id: 7,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .failed,
            error: "服务器返回 HTTP 403"
        )

        #expect(emptyPartsMessage(for: record) == "失败：服务器返回 HTTP 403")
    }

    @Test("准备中的空分片仍显示等待")
    func reportsWaitingEmptyParts() {
        let record = DownloadRecord(
            id: 8,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .downloading
        )

        #expect(emptyPartsMessage(for: record) == "等待服务器返回分片信息")
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
