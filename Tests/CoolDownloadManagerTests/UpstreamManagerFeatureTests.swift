import AppKit
import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@MainActor
@Suite("上游功能原生界面状态")
struct UpstreamManagerFeatureTests {
    @Test("automatic limiting follows foreground, idle and unavailable-detection policy")
    func speedPolicy() {
        var settings = AppSettingsModel.defaults()
        settings.speedLimit = 8192
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: false, isUserInteracting: true) == 0)
        settings.speedLimiterEnabled = true
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: true, isUserInteracting: false) == 8192)
        settings.limitWhileUsingOtherApps = true
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: true, isUserInteracting: true) == 0)
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: false, isUserInteracting: true) == 8192)
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: false, isUserInteracting: false) == 0)
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: false, isUserInteracting: nil) == 8192)
        settings.speedLimiterEnabled = false
        #expect(settings.effectiveGlobalSpeedLimit(isAppActive: false, isUserInteracting: nil) == 0)
    }

    @Test("activity monitoring observes idle transitions, unavailable readings and stops polling when disabled")
    func activityMonitor() {
        var idle: TimeInterval = 31
        let monitor = ApplicationActivityMonitor(idleTime: { idle })
        var samples: [ApplicationActivityMonitor.Sample] = []
        monitor.onChange = { samples.append($0) }
        monitor.setMonitoring(true)
        #expect(monitor.sample.isUserInteracting == false)
        idle = 5
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(monitor.sample.isUserInteracting == true)
        idle = .nan
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(monitor.sample.isUserInteracting == nil)
        monitor.setMonitoring(false)
        let count = samples.count
        idle = 0
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(samples.count == count)
        monitor.setMonitoring(true)
        #expect(monitor.sample.isUserInteracting == true)
        monitor.setMonitoring(false)
    }

    @Test("menu changes merge into unedited draft fields and preserve explicit edits")
    func draftMerge() {
        let initial = AppSettingsModel.defaults()
        let draft = SettingsViewState(model: initial, perHostItems: [])
        draft.model.theme = "dark"
        var external = initial
        external.speedLimiterEnabled = true
        external.limitWhileUsingOtherApps = true
        external.speedLimit = 8192
        draft.mergeSpeedLimiterSettings(external)
        #expect(draft.model.theme == "dark")
        #expect(draft.model.speedLimiterEnabled)
        #expect(draft.model.limitWhileUsingOtherApps)
        #expect(draft.model.speedLimit == 8192)
        draft.model.speedLimit = 16384
        draft.model.speedLimiterEnabled = false
        external.speedLimit = 32768
        draft.mergeSpeedLimiterSettings(external)
        #expect(draft.model.speedLimit == 16384 && !draft.model.speedLimiterEnabled)
        #expect(draft.isDirty)
    }

    @Test("unit inputs reject junk, overflow, fractional bytes and out-of-range values")
    func unitInput() {
        #expect(ByteQuantityText.parse("1.5", unit: "BinaryBytes", exponent: 2, range: 1024...Int64.max) == 1_572_864)
        #expect(ByteQuantityText.parse("8", unit: "DecimalBits", exponent: 0, range: 1...Int64.max) == 1)
        for text in ["", "1junk", "-1", "NaN", "999999999999999999999999999", "1,2"] {
            #expect(ByteQuantityText.parse(text, unit: "BinaryBytes", exponent: 0, range: 1...Int64.max) == nil)
        }
        #expect(ByteQuantityText.parse("0.5", unit: "BinaryBytes", exponent: 0, range: 0...100) == nil)
        #expect(ByteQuantityText.parse("1023", unit: "BinaryBytes", exponent: 0, range: 1024...2048) == nil)
        #expect(ByteQuantityText.parse(String(Int64.max), unit: "BinaryBytes", exponent: 0, range: 1...Int64.max) == Int64.max)
        #expect(ByteQuantityText.format(bytes: 16 * 1024 * 1024, unit: "BinaryBytes", isSpeed: false) == "16 MiB")
        #expect(ByteQuantityText.format(bytes: 256 * 1024, unit: "BinaryBytes", isSpeed: true) == "256 KiB/s")
    }

    @Test("selection summaries distinguish zero and unknown sizes without wrapping totals")
    func selectionSummary() {
        var zero = record(id: 1)
        zero.totalBytes = 0
        var known = record(id: 2)
        known.totalBytes = 2048
        let unknown = record(id: 3)
        let summary = DownloadSelectionSummary(records: [zero, known, unknown])
        #expect(summary.count == 3 && summary.knownBytes == 2048 && summary.unknownCount == 1)
        #expect(summary.text(unit: "BinaryBytes") == "已选 3 项 · 已知 2 KiB · 1 项大小未知")
        #expect(DownloadSelectionSummary(records: [zero]).text(unit: "BinaryBytes") == "已选 1 项 · 合计 0 B")
        #expect(DownloadSelectionSummary(records: [unknown]).text(unit: "BinaryBytes") == "已选 1 项 · 1 项大小未知")
        known.totalBytes = .max
        zero.totalBytes = 1
        let large = DownloadSelectionSummary(records: [known, zero])
        #expect(large.overflowed && large.knownBytes == .max)
    }

    @Test("list summaries track size updates and deletion, date sorting places missing dates last")
    func listUpdates() {
        let list = DownloadListStore(service: nil)
        var first = record(id: 1)
        var second = record(id: 2)
        let unknown = record(id: 3)
        first.startedAt = Date(timeIntervalSince1970: 10)
        second.startedAt = Date(timeIntervalSince1970: 20)
        first.completedAt = Date(timeIntervalSince1970: 30)
        second.completedAt = Date(timeIntervalSince1970: 25)
        list.apply([unknown, second, first], announceCompletion: false)
        list.sort = .startedNewest
        #expect(list.visibleDownloads.map(\.id) == [2, 1, 3])
        list.sort = .completedNewest
        #expect(list.visibleDownloads.map(\.id) == [1, 2, 3])
        list.selectedIDs = [1, 2]
        #expect(DownloadSelectionSummary(records: list.selectedDownloads).unknownCount == 2)
        first.totalBytes = 1024
        first.revision += 1
        list.apply(.updated(first))
        #expect(DownloadSelectionSummary(records: list.selectedDownloads).knownBytes == 1024)
        list.apply(.removed(id: 2))
        #expect(list.selectedIDs == [1])
        #expect(DownloadSelectionSummary(records: list.selectedDownloads).count == 1)
        list.selectedIDs.removeAll()
        #expect(DownloadSelectionSummary(records: list.selectedDownloads).count == 0)
    }

    @Test("Open With refuses unfinished or missing files and reports invalid applications")
    func openFailures() throws {
        var item = record(id: 1)
        #expect(DownloadFileOpener.validationError(for: item) == "下载尚未完成，暂时无法打开文件。")
        item.status = .completed
        var result: String?
        DownloadFileOpener.open(item) { result = $0 }
        #expect(result == "下载文件已被移动或删除，无法打开。")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-open-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        item.folder = root.path
        try Data("file".utf8).write(to: item.destinationURL)
        #expect(DownloadFileOpener.validationError(for: item) == nil)
        DownloadFileOpener.open(item, application: root.appendingPathComponent("missing.app")) { result = $0 }
        #expect(result == "所选应用不存在或不是有效的 macOS 应用。")
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    @Test("unknown timestamps remain explicitly absent")
    func absentDates() {
        #expect(DownloadTimePresentation.full(nil) == "—")
        #expect(!DownloadTimePresentation.full(Date(timeIntervalSince1970: 1)).isEmpty)
    }

    private func record(id: DownloadID) -> DownloadRecord {
        DownloadRecord(id: id, source: DownloadSource(kind: .http, link: "https://fixture.invalid/file"),
                       folder: "/tmp/cooldm-nonexistent-\(UUID().uuidString)", name: "file.bin", createdAt: Date(timeIntervalSince1970: 1))
    }
}
