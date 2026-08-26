import Foundation
import Testing
import CoolDownloadCore
@testable import CoolDownloadManager

@Suite("分片速度采样")
struct DownloadPartSpeedSamplerTests {
    @Test("累积短间隔字节并计算各分片速度")
    func calculatesIndependentPartSpeeds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var sampler = DownloadPartSpeedSampler(minimumSampleInterval: 0.25, idleInterval: 1.5)
        var record = makeRecord(parts: [
            DownloadPart(id: 0, from: 0, to: 9_999),
            DownloadPart(id: 1, from: 10_000, to: 19_999)
        ])

        sampler.update([record], at: start)
        #expect(sampler.speed(for: record.id, partID: 0, at: start) == nil)

        record.parts[0].downloaded = 512
        record.parts[1].downloaded = 1_024
        sampler.update([record], at: start.addingTimeInterval(0.1))
        #expect(sampler.speed(for: record.id, partID: 0, at: start.addingTimeInterval(0.1)) == nil)

        record.parts[0].downloaded = 2_048
        record.parts[1].downloaded = 4_096
        let sampleDate = start.addingTimeInterval(0.5)
        sampler.update([record], at: sampleDate)

        #expect(sampler.speed(for: record.id, partID: 0, at: sampleDate) == 4_096)
        #expect(sampler.speed(for: record.id, partID: 1, at: sampleDate) == 8_192)
    }

    @Test("空闲、暂停与完成的分片不保留活动速度")
    func clearsInactivePartSpeeds() {
        let start = Date(timeIntervalSince1970: 2_000)
        var sampler = DownloadPartSpeedSampler(minimumSampleInterval: 0.25, idleInterval: 1.5)
        var record = makeRecord(parts: [DownloadPart(id: 0, from: 0, to: 9_999)])

        sampler.update([record], at: start)
        record.parts[0].downloaded = 1_000
        let sampleDate = start.addingTimeInterval(0.5)
        sampler.update([record], at: sampleDate)
        #expect(sampler.speed(for: record.id, partID: 0, at: sampleDate) == 2_000)
        #expect(sampler.speed(for: record.id, partID: 0, at: sampleDate.addingTimeInterval(1.5)) == 0)

        record.status = .paused
        sampler.update([record], at: sampleDate.addingTimeInterval(1.6))
        #expect(sampler.speed(for: record.id, partID: 0, at: sampleDate.addingTimeInterval(1.6)) == nil)

        record.status = .downloading
        record.parts[0].completed = true
        sampler.update([record], at: sampleDate.addingTimeInterval(2))
        #expect(sampler.speed(for: record.id, partID: 0, at: sampleDate.addingTimeInterval(2)) == nil)
    }

    @Test("进度回退会重置采样基线")
    func resetsAfterProgressRollback() {
        let start = Date(timeIntervalSince1970: 3_000)
        var sampler = DownloadPartSpeedSampler(minimumSampleInterval: 0.25, idleInterval: 1.5)
        var record = makeRecord(parts: [DownloadPart(id: 0, from: 0, to: 9_999, downloaded: 1_000)])

        sampler.update([record], at: start)
        record.parts[0].downloaded = 2_000
        sampler.update([record], at: start.addingTimeInterval(0.5))
        #expect(sampler.speed(for: record.id, partID: 0, at: start.addingTimeInterval(0.5)) == 2_000)

        record.parts[0].downloaded = 500
        sampler.update([record], at: start.addingTimeInterval(1))
        #expect(sampler.speed(for: record.id, partID: 0, at: start.addingTimeInterval(1)) == nil)

        record.parts[0].downloaded = 1_500
        sampler.update([record], at: start.addingTimeInterval(1.5))
        #expect(sampler.speed(for: record.id, partID: 0, at: start.addingTimeInterval(1.5)) == 2_000)
    }

    @Test("更新单个任务不会清理其他任务的速度")
    func preservesOtherDownloadSamples() {
        let start = Date(timeIntervalSince1970: 4_000)
        var sampler = DownloadPartSpeedSampler(minimumSampleInterval: 0.25, idleInterval: 1.5)
        var first = makeRecord(id: 42, parts: [DownloadPart(id: 0, from: 0, to: 9_999)])
        var second = makeRecord(id: 43, parts: [DownloadPart(id: 0, from: 0, to: 9_999)])

        sampler.update([first, second], at: start)
        first.parts[0].downloaded = 1_000
        second.parts[0].downloaded = 2_000
        let sampleDate = start.addingTimeInterval(0.5)
        sampler.update([first, second], at: sampleDate)

        first.parts[0].downloaded = 2_000
        sampler.update(first, at: start.addingTimeInterval(1))
        #expect(sampler.speed(for: second.id, partID: 0, at: start.addingTimeInterval(1)) == 4_000)
    }

    private func makeRecord(id: DownloadID = 42, parts: [DownloadPart]) -> DownloadRecord {
        DownloadRecord(
            id: id,
            source: DownloadSource(kind: .http, link: "https://example.test/file.bin"),
            folder: "/tmp",
            name: "file.bin",
            status: .downloading,
            downloadedBytes: parts.reduce(0) { $0 + $1.downloaded },
            totalBytes: 20_000,
            parts: parts
        )
    }
}
