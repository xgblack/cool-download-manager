import Foundation
import Testing
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
}
