import Foundation
import CoolDownloadCore

enum DownloadTimePresentation {
    static func full(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN"))
            .year().month().day().hour().minute().second())
    }
}

struct DownloadSelectionSummary: Equatable {
    let count: Int
    let knownBytes: Int64
    let unknownCount: Int
    let overflowed: Bool

    init(records: [DownloadRecord]) {
        count = records.count
        var bytes: Int64 = 0
        var unknown = 0
        var overflow = false
        for record in records {
            guard let total = record.totalBytes, total >= 0 else { unknown += 1; continue }
            let sum = bytes.addingReportingOverflow(total)
            if sum.overflow { overflow = true; bytes = .max }
            else { bytes = sum.partialValue }
        }
        knownBytes = bytes
        unknownCount = unknown
        overflowed = overflow
    }

    func text(unit: String) -> String {
        var result = "已选 \(count) 项"
        if overflowed { result += " · 合计超出统计范围" }
        else if unknownCount < count {
            result += " · \(unknownCount > 0 ? "已知" : "合计") \(ByteQuantityText.format(bytes: knownBytes, unit: unit, isSpeed: false))"
        }
        if unknownCount > 0 { result += " · \(unknownCount) 项大小未知" }
        return result
    }
}
