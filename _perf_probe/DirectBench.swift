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
struct DirectDownloadBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count == 5,
              let connections = Int(CommandLine.arguments[2]),
              let expectedBytes = Int64(CommandLine.arguments[3]) else {
            fputs("usage: DirectBench <url> <connections> <expected-bytes> <output-root>\n", stderr)
            exit(64)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = DownloadRecord(
            id: 1,
            source: DownloadSource(kind: .http, link: CommandLine.arguments[1]),
            folder: root.path,
            name: "payload.bin"
        )
        let writer = try PartFileWriter(record: record)
        let downloader = HTTPDownloader()
        let rateLimiter = ProcessInfo.processInfo.environment["BENCH_ZERO_LIMITER"] == "1"
            ? DownloadRateLimiter(bytesPerSecond: 0)
            : nil

        let before = usage()
        let startedAt = Date()
        let bodyBytes: Int64
        if connections <= 1 {
            bodyBytes = try await downloader.download(
                source: record.source,
                offset: 0,
                writer: writer,
                rateLimiter: rateLimiter
            ).bytesWritten
        } else {
            let metadata = try await downloader.probe(source: record.source)
            guard metadata.supportsRanges, metadata.totalBytes == expectedBytes else { exit(5) }
            try await writer.prepare(length: expectedBytes, sparse: true)
            let partCount = min(connections, Int(expectedBytes))
            let chunkSize = (expectedBytes + Int64(partCount) - 1) / Int64(partCount)
            bodyBytes = try await withThrowingTaskGroup(of: Int64.self) { group in
                for index in 0..<partCount {
                    let start = Int64(index) * chunkSize
                    guard start < expectedBytes else { continue }
                    let end = min(expectedBytes - 1, start + chunkSize - 1)
                    group.addTask {
                        try await downloader.downloadRange(
                            source: record.source,
                            start: start,
                            end: end,
                            writer: writer,
                            expectedETag: metadata.etag,
                            expectedLastModified: metadata.lastModified,
                            rateLimiter: rateLimiter
                        ).bytesWritten
                    }
                }
                var total: Int64 = 0
                for try await count in group { total += count }
                return total
            }
        }
        try await writer.finish()
        let elapsed = Date().timeIntervalSince(startedAt)
        let after = usage()
        let attributes = try FileManager.default.attributesOfItem(atPath: record.destinationURL.path)
        let fileBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard fileBytes == expectedBytes else { exit(4) }

        print([
            "connections=\(connections)",
            "elapsed_s=\(String(format: "%.4f", elapsed))",
            "throughput_mib_s=\(String(format: "%.3f", Double(fileBytes) / 1_048_576 / elapsed))",
            "user_cpu_s=\(String(format: "%.4f", seconds(after.ru_utime) - seconds(before.ru_utime)))",
            "system_cpu_s=\(String(format: "%.4f", seconds(after.ru_stime) - seconds(before.ru_stime)))",
            "max_rss_bytes=\(after.ru_maxrss)",
            "body_bytes=\(bodyBytes)",
            "file_bytes=\(fileBytes)"
        ].joined(separator: " "))
    }
}
