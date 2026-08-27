import Foundation
import Darwin
import CoolDownloadCore

private func seconds(_ value: timeval) -> Double {
    Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
}

private func usage() -> rusage {
    var value = rusage()
    _ = getrusage(RUSAGE_SELF, &value)
    return value
}

@main
struct DownloadBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count == 5,
              let connections = Int(CommandLine.arguments[2]),
              let expectedBytes = Int64(CommandLine.arguments[3]) else {
            fputs("usage: Bench <url> <connections> <expected-bytes> <output-root>\n", stderr)
            exit(64)
        }

        let sourceURL = CommandLine.arguments[1]
        let outputRoot = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let speedLimit = ProcessInfo.processInfo.environment["BENCH_SPEED_LIMIT"].flatMap(Int64.init) ?? 0

        let service = DownloadService(
            store: try DownloadStore(rootURL: outputRoot.appendingPathComponent("state", isDirectory: true)),
            defaultFolder: outputRoot,
            schedulerConfiguration: DownloadSchedulerConfiguration(
                maxConcurrentDownloads: 1,
                maxConnectionsPerDownload: connections,
                dynamicPartCreation: true,
                useSparseFileAllocation: true,
                speedLimit: speedLimit
            ),
            retryPolicy: DownloadRetryPolicy(maxAttempts: 1)
        )
        try await service.boot()

        let before = usage()
        let startedAt = Date()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: sourceURL, suggestedName: "payload.bin"),
            start: true
        ))

        let deadline = Date().addingTimeInterval(180)
        var finalRecord: DownloadRecord?
        while Date() < deadline {
            if let record = await service.snapshot().downloads.first(where: { $0.id == id }),
               record.status == .completed || record.status == .failed {
                finalRecord = record
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let after = usage()

        guard let record = finalRecord else {
            fputs("benchmark timed out\n", stderr)
            exit(2)
        }
        guard record.status == .completed else {
            fputs("benchmark failed: \(record.error ?? "unknown")\n", stderr)
            exit(3)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: record.destinationURL.path)
        let fileBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard fileBytes == expectedBytes else {
            fputs("size mismatch: \(fileBytes) != \(expectedBytes)\n", stderr)
            exit(4)
        }

        let userCPU = seconds(after.ru_utime) - seconds(before.ru_utime)
        let systemCPU = seconds(after.ru_stime) - seconds(before.ru_stime)
        let throughputMiB = Double(fileBytes) / 1_048_576 / elapsed
        print([
            "connections=\(connections)",
            "elapsed_s=\(String(format: "%.4f", elapsed))",
            "throughput_mib_s=\(String(format: "%.3f", throughputMiB))",
            "user_cpu_s=\(String(format: "%.4f", userCPU))",
            "system_cpu_s=\(String(format: "%.4f", systemCPU))",
            "max_rss_bytes=\(after.ru_maxrss)",
            "parts=\(record.parts.count)",
            "revision=\(record.revision)",
            "file_bytes=\(fileBytes)"
        ].joined(separator: " "))
        await service.shutdown()
    }
}
