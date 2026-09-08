import Foundation
import Darwin
import Testing
@testable import CoolDownloadCore

/// Run alone: process-wide RSS/FD measurements are not attributable when other
/// suites run concurrently. All artifacts stay in the printed temporary root.
@Suite("Commercial one-hour soak")
struct CommercialSoakTests {
    @Test(
        "16 fixed records: one hour of retry, redownload, pause and resume",
        .enabled(
            if: ProcessInfo.processInfo.environment["CDM_RUN_SOAK"] == "1",
            "Opt-in only: about 62 minutes (60s warm-up, 1h load, final drain and 30s FD recovery); retains temporary files."
        ),
        .timeLimit(.minutes(70))
    )
    func fixedRecordSoak() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooldm-commercial-soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appendingPathComponent("soak.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        // The log descriptor is included in both FD measurements. Nothing is
        // removed, including on assertion failure or cancellation.
        do {
            try writeLog("root=\(root.path) transport=deterministic-HTTPTransport URLSession_socket_coverage=false", to: log)
            let idle = try resources()
            try writeLog("idle rss_bytes=\(idle.rss) fd=\(idle.fd)", to: log)
            // A separate scope releases the service/store/transport before the
            // 30-second FD observation, while retaining all metadata and files.
            try await exercise(root: root, log: log)
            try writeLog("shutdown_complete waiting_for_fd_recovery_seconds=30", to: log)
            try await Task.sleep(for: .seconds(30))
            let recovered = try resources()
            try writeLog("fd_recovery baseline=\(idle.fd) final=\(recovered.fd) allowed=\(idle.fd + 10) rss_bytes=\(recovered.rss)", to: log)
            try #require(recovered.fd <= idle.fd + 10, "FDs did not return to idle +10 within 30 seconds")
            try writeLog("PASS artifacts_retained=\(root.path)", to: log)
            try log.close()
        } catch {
            // Preserve the original failure even if the log device also fails.
            do {
                try writeLog("FAIL error=\(error) artifacts_retained=\(root.path)", to: log)
                try log.close()
            } catch { print("SOAK log finalization failed: \(error); root=\(root.path)") }
            throw error
        }
    }

    private func exercise(root: URL, log: FileHandle) async throws {
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        for index in 0..<(1024 * 1024) {
            bytes[index] = UInt8((index * 31 + index / 251) % 256)
        }
        let content = Data(bytes)
        let transport = SoakTransport(content: content)
        let store = try DownloadStore(rootURL: root.appendingPathComponent("metadata", isDirectory: true))
        let service = DownloadService(
            store: store,
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root.appendingPathComponent("downloads", isDirectory: true),
            schedulerConfiguration: .init(maxConcurrentDownloads: 16, maxConnectionsPerDownload: 1),
            retryPolicy: .init(maxAttempts: 3, delay: .milliseconds(50))
        )
        do {
            try await service.boot()
            var ids: [DownloadID] = []
            for index in 0..<16 {
                ids.append(try await service.add(AddDownloadRequest(
                    source: DownloadSource(
                        kind: .http, link: "https://soak.invalid/\(index)", suggestedName: "soak-\(index).bin"
                    ),
                    start: false
                )))
            }
            let fixedIDs = Set(ids)
            try #require(fixedIDs.count == 16)
            let started = ContinuousClock.now
            var measuredStart: ContinuousClock.Instant?
            var nextSample: ContinuousClock.Instant?
            var firstRSS: UInt64?
            var lastRSS: UInt64 = 0
            var sampleCount = 0
            var cycle = 0
            var verifiedBytes: UInt64 = 0

            // Warm up with the same workload; the measured hour begins only
            // after the warm-up sample, not at process/test startup.
            while measuredStart == nil || ContinuousClock.now < measuredStart! + .seconds(3600) {
                let cycleStart = ContinuousClock.now
                await transport.beginCycle()
                if cycle == 0 { try await service.resume(ids: ids) }
                else { try await service.redownload(ids: ids) }
                // The fixture holds bodies after partial progress, so pause
                // cannot accidentally exercise only queued/completed records.
                let active = try await waitFor(service: service, ids: fixedIDs, phase: "partial-progress") {
                    $0.allSatisfy { $0.status == .downloading && $0.downloadedBytes > 0 }
                }
                try #require(active.allSatisfy { $0.downloadedBytes < content.count })
                try await service.pause(ids: ids)
                let paused: [DownloadRecord] = await service.snapshot().downloads
                try #require(Set(paused.map(\.id)) == fixedIDs)
                try #require(paused.allSatisfy { $0.status == .paused && $0.downloadedBytes > 0 })
                await transport.releaseBodies()
                try await service.resume(ids: ids)
                let completed = try await waitFor(service: service, ids: fixedIDs, phase: "completion") {
                    $0.allSatisfy { $0.status == .completed }
                }
                for record in completed {
                    try #require(record.downloadedBytes == content.count)
                    let bytes = try Data(contentsOf: record.destinationURL)
                    try #require(bytes == content, "Completed file differs from deterministic source bytes")
                    verifiedBytes += UInt64(bytes.count)
                }
                let persisted = try await store.load()
                try #require(Set(persisted.map(\.id)) == fixedIDs)
                try #require(persisted.allSatisfy { $0.status == .completed })
                cycle += 1
                let stats = await transport.statistics()
                try #require(stats.failures == cycle * 16, "Every record must exercise a transient 503 each cycle")
                try #require(stats.resumes >= cycle * 16, "Every paused record must issue a nonzero byte range")
                try writeLog("cycle=\(cycle) elapsed=\(started.duration(to: .now)) records=16 verified_bytes=\(verifiedBytes) injected_503=\(stats.failures) resumed_ranges=\(stats.resumes)", to: log)

                let now = ContinuousClock.now
                if measuredStart == nil && now >= started + .seconds(60) {
                    let sample = try resources()
                    firstRSS = sample.rss
                    lastRSS = sample.rss
                    sampleCount = 1
                    measuredStart = now
                    nextSample = now + .seconds(600)
                    try writeLog("rss_sample measured_seconds=0 warmup=\(started.duration(to: now)) rss_bytes=\(sample.rss) fd=\(sample.fd)", to: log)
                } else if let next = nextSample, now >= next, let measuredStart {
                    let sample = try resources()
                    lastRSS = sample.rss
                    sampleCount += 1
                    nextSample = next + .seconds(600)
                    try writeLog("rss_sample measured_elapsed=\(measuredStart.duration(to: now)) rss_bytes=\(sample.rss) fd=\(sample.fd)", to: log)
                }
                // Avoid turning a lifecycle soak into an unbounded write-rate
                // benchmark. Each cycle transfers 16 MiB; no history is added.
                let rest = ContinuousClock.now.duration(to: cycleStart + .seconds(10))
                if rest > .zero { try await Task.sleep(for: rest) }
            }
            // Take the final sample at the same completed-record phase as the
            // baseline, before shutting down or releasing the database.
            let final = try resources()
            lastRSS = final.rss
            let baseline = try #require(firstRSS)
            let allowance = max(UInt64(32 * 1024 * 1024), baseline / 10)
            try writeLog("rss_final measured_elapsed=\(measuredStart!.duration(to: .now)) samples=\(sampleCount) first_bytes=\(baseline) last_bytes=\(lastRSS) allowed_growth_bytes=\(allowance) cycles=\(cycle) verified_bytes=\(verifiedBytes)", to: log)
            try #require(sampleCount >= 6, "Missing ten-minute RSS samples")
            try #require(lastRSS <= baseline + allowance, "RSS growth exceeds max(32 MiB, 10%); investigate with Allocations")
            await service.shutdown()
        } catch {
            await service.shutdown()
            throw error
        }
    }

    private func waitFor(
        service: DownloadService, ids: Set<DownloadID>, phase: String,
        predicate: ([DownloadRecord]) -> Bool
    ) async throws -> [DownloadRecord] {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let records = await service.snapshot().downloads
            try #require(Set(records.map(\.id)) == ids)
            try #require(!records.contains { $0.status == .failed || $0.status == .waitingForSourceRefresh }, "Unexpected terminal failure during \(phase)")
            if predicate(records) { return records }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SoakFailure.timeout(phase)
    }

    private func writeLog(_ line: String, to handle: FileHandle) throws {
        let line = "SOAK \(Date().ISO8601Format()) \(line)\n"
        print(line, terminator: "")
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
    }

    private func resources() throws -> (rss: UInt64, fd: Int) {
        // Unlike best-effort metrics, a failed OS observation must not turn
        // into zero RSS/FD and produce a false pass.
        var usage = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard status == 0, usage.ri_resident_size > 0 else { throw SoakFailure.resourceObservation }
        let fd = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        guard fd > 0 else { throw SoakFailure.resourceObservation }
        return (usage.ri_resident_size, fd)
    }
}

private enum SoakFailure: Error {
    case timeout(String)
    case resourceObservation
    case invalidRange
}

/// The existing test fixtures are file-private. This local byte source uses
/// the production HTTPTransport seam; it does not model sockets or URLSession.
private actor SoakTransport: HTTPTransport {
    private let content: Data
    private var failedPaths: Set<String> = []
    private var holdingBodies = true
    private var failures = 0
    private var resumes = 0

    init(content: Data) { self.content = content }

    func beginCycle() {
        failedPaths.removeAll(keepingCapacity: true)
        holdingBodies = true
    }

    func releaseBodies() { holdingBodies = false }
    func statistics() -> (failures: Int, resumes: Int) { (failures, resumes) }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        try Task.checkCancellation()
        let range = request.value(forHTTPHeaderField: "Range")
        var start = 0
        var end = content.count - 1
        if let range {
            guard range.hasPrefix("bytes=") else { throw SoakFailure.invalidRange }
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let lower = Int(bounds[0]) else { throw SoakFailure.invalidRange }
            start = lower
            if !bounds[1].isEmpty {
                guard let upper = Int(bounds[1]) else { throw SoakFailure.invalidRange }
                end = upper
            }
            guard start >= 0, end >= start, end < content.count else { throw SoakFailure.invalidRange }
        }
        let probe = request.httpMethod == "HEAD" || (start == 0 && end == 0)
        if !probe, failedPaths.insert(request.url!.path).inserted {
            failures += 1
            return HTTPTransportResponse(
                statusCode: 503, headers: ["Content-Length": "0"],
                body: AsyncThrowingStream { $0.finish() }
            )
        }
        if !probe && start > 0 { resumes += 1 }
        var headers = [
            "Content-Length": String(end - start + 1), "Accept-Ranges": "bytes", "ETag": "\"soak-v1\""
        ]
        if range != nil { headers["Content-Range"] = "bytes \(start)-\(end)/\(content.count)" }
        let bytes = content
        let lower = start
        let upper = end
        let isHead = request.httpMethod == "HEAD"
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = Task {
            do {
                if !isHead {
                    var offset = lower
                    while offset <= upper {
                        try Task.checkCancellation()
                        if !probe {
                            if offset - lower >= 256 * 1024 {
                                while self.holdingBodies {
                                    try await Task.sleep(for: .milliseconds(20))
                                }
                            }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        let next = min(offset + 16 * 1024, upper + 1)
                        pair.continuation.yield(Data(bytes[offset..<next]))
                        offset = next
                    }
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { _ in producer.cancel() }
        return HTTPTransportResponse(
            statusCode: range == nil ? 200 : 206, headers: headers, body: pair.stream,
            cancelBody: { producer.cancel() }
        )
    }
}
