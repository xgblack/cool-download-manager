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
}
