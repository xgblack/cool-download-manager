import CoolDownloadCore
import Foundation

@main
struct CoolDownloadBenchmarkMain {
    static func main() async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let arguments = Array(CommandLine.arguments.dropFirst())
            if let invocation = try InternalInvocation.parse(arguments: arguments) {
                let run = try await runSingle(invocation: invocation)
                FileHandle.standardOutput.write(try encoder.encode(run))
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }

            let configuration = try BenchmarkConfiguration.parse(arguments: arguments)
            let report = try runIsolatedMatrix(configuration: configuration)
            let data = try encoder.encode(report)
            if let outputPath = configuration.outputPath {
                let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: outputURL, options: .atomic)
                fputs("report: \(outputURL.path)\n", stderr)
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch BenchmarkCLIError.helpRequested {
            print(BenchmarkConfiguration.usage)
        } catch {
            fputs("CoolDownloadBenchmark: \(error.localizedDescription)\n\n", stderr)
            fputs(BenchmarkConfiguration.usage + "\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func runIsolatedMatrix(
        configuration: BenchmarkConfiguration
    ) throws -> BenchmarkReport {
        var measuredRuns: [BenchmarkRun] = []
        for connections in configuration.connections {
            let totalRuns = configuration.warmups + configuration.repetitions
            for runIndex in 0..<totalRuns {
                let isWarmup = runIndex < configuration.warmups
                fputs(
                    "connections=\(connections) tasks=\(configuration.taskCount) "
                        + (isWarmup ? "warmup=\(runIndex + 1)" : "run=\(runIndex - configuration.warmups + 1)")
                        + "\n",
                    stderr
                )
                let run = try runChildProcess(
                    configuration: configuration,
                    requestedConnections: connections,
                    repetition: runIndex - configuration.warmups + 1
                )
                if !isWarmup {
                    measuredRuns.append(run)
                    fputs(
                        String(
                            format: "  %.2f MiB/s, %.3f s, checkpoint %.2f ms, peak RSS %.1f MiB\n",
                            run.aggregateGoodputMiBPerSecond,
                            run.elapsedSeconds,
                            run.checkpointMetrics.totalMilliseconds,
                            Double(run.resources.peakResidentMemoryBytes) / 1024 / 1024
                        ),
                        stderr
                    )
                }
            }
        }

        return BenchmarkReport(
            schemaVersion: 4,
            generatedAt: Date(),
            environment: .current,
            configuration: configuration.redactedForReport(),
            runs: measuredRuns
        )
    }

    private static func runChildProcess(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        repetition: Int
    ) throws -> BenchmarkRun {
        let encoder = JSONEncoder()
        let encodedConfiguration = try encoder.encode(configuration).base64EncodedString()
        guard let executableURL = Bundle.main.executableURL else {
            throw BenchmarkRunError.missingExecutable
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--internal-configuration", encodedConfiguration,
            "--internal-connections", String(requestedConnections),
            "--internal-repetition", String(repetition)
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)
                ?? "child process exited with status \(process.terminationStatus)"
            throw BenchmarkRunError.childProcessFailed(message)
        }
        if !errorOutput.isEmpty {
            FileHandle.standardError.write(errorOutput)
        }
        do {
            return try JSONDecoder().decode(BenchmarkRun.self, from: output)
        } catch {
            let rawOutput = String(data: output, encoding: .utf8) ?? "<non-UTF8 output>"
            throw BenchmarkRunError.invalidChildOutput(rawOutput)
        }
    }

    private static func runSingle(invocation: InternalInvocation) async throws -> BenchmarkRun {
        let configuration = invocation.configuration
        if let rawURL = configuration.sourceURL {
            guard let sourceURL = URL(string: rawURL),
                  let scheme = sourceURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  sourceURL.host != nil else {
                throw BenchmarkRunError.invalidExternalURL(rawURL)
            }
            return try await runOnce(
                configuration: configuration,
                requestedConnections: invocation.requestedConnections,
                repetition: invocation.repetition,
                sourceURL: sourceURL,
                server: nil,
                networkConfiguration: try configuration.networkConfiguration()
            )
        }

        let server = try RangeFixtureServer(
            contentLength: configuration.sizeBytes,
            bytesPerSecond: configuration.perConnectionBytesPerSecond,
            firstByteDelayMilliseconds: configuration.firstByteDelayMilliseconds,
            failFirstDataRequests: configuration.failFirstDataRequests
        )
        let sourceURL = try await server.start()
        defer { server.stop() }
        return try await runOnce(
            configuration: configuration,
            requestedConnections: invocation.requestedConnections,
            repetition: invocation.repetition,
            sourceURL: sourceURL,
            server: server,
            networkConfiguration: .default
        )
    }

    private static func runOnce(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        repetition: Int,
        sourceURL: URL,
        server: RangeFixtureServer?,
        networkConfiguration: HTTPNetworkConfiguration
    ) async throws -> BenchmarkRun {
        let parent = configuration.downloadsRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? FileManager.default.temporaryDirectory
        let root = parent
            .appendingPathComponent("cooldm-benchmark-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let keepFiles = configuration.keepFiles
        defer {
            if !keepFiles {
                try? FileManager.default.removeItem(at: root)
            }
        }
        if keepFiles {
            fputs("files: \(root.path)\n", stderr)
        }

        let metrics = DownloadMetricsCollector(maximumEventCount: 100_000)
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(networkConfiguration: networkConfiguration),
            hlsDownloader: HLSDownloader(networkConfiguration: networkConfiguration),
            defaultFolder: downloads,
            schedulerConfiguration: DownloadSchedulerConfiguration(
                maxConcurrentDownloads: configuration.taskCount,
                maxConnectionsPerDownload: requestedConnections,
                dynamicPartCreation: true,
                minimumPartSize: configuration.minimumPartSizeBytes,
                maxTotalConnections: configuration.globalConnections,
                maxOpenFileDescriptors: configuration.maxOpenFileDescriptors,
                useSparseFileAllocation: true
            ),
            retryPolicy: DownloadRetryPolicy(
                maxAttempts: configuration.retryAttempts,
                delay: .milliseconds(configuration.retryDelayMilliseconds)
            ),
            metrics: metrics
        )
        try await service.boot()
        server?.resetStatistics()

        let startResources = DownloadResourceSnapshot.capture()
        let peaks = ResourcePeakRecorder()
        peaks.sample(startResources)
        let sampler = Task {
            while !Task.isCancelled {
                peaks.sample(DownloadResourceSnapshot.capture())
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        let startedAt = ContinuousClock.now
        var ids: [DownloadID] = []
        do {
            for taskIndex in 0..<configuration.taskCount {
                let taskURL: URL
                let suggestedName: String
                if configuration.sourceURL == nil {
                    taskURL = sourceURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("fixture-\(taskIndex).bin")
                    suggestedName = "fixture-\(taskIndex).bin"
                } else {
                    taskURL = sourceURL
                    suggestedName = "external-\(taskIndex).bin"
                }
                let id = try await service.add(AddDownloadRequest(
                    source: DownloadSource(
                        kind: .http,
                        link: taskURL.absoluteString,
                        suggestedName: suggestedName
                    ),
                    folder: downloads.path,
                    name: suggestedName,
                    start: true
                ))
                ids.append(id)
            }
            try await waitForCompletion(
                ids: Set(ids),
                service: service,
                timeout: .seconds(configuration.timeoutSeconds)
            )
        } catch {
            sampler.cancel()
            _ = await sampler.result
            await service.shutdown()
            throw error
        }
        let elapsed = ContinuousClock.now - startedAt
        sampler.cancel()
        _ = await sampler.result
        let endResources = DownloadResourceSnapshot.capture()
        peaks.sample(endResources)

        let snapshot = await service.snapshot()
        // Verification can throw (a missing destination, a checksum mismatch,
        // or an unreadable mounted volume). Stop the service before touching
        // the run directory so cleanup never races an actor that is still
        // writing its record or holding the store lock.
        await service.shutdown()
        var verified = true
        var completedByteCounts: [Int64] = []
        for id in ids {
            guard let record = snapshot.downloads.first(where: { $0.id == id }) else {
                verified = false
                continue
            }
            let fileVerified: Bool
            if configuration.sourceURL == nil {
                fileVerified = try validatePattern(
                    fileURL: record.destinationURL,
                    expectedBytes: configuration.sizeBytes
                )
            } else {
                fileVerified = try validateExternalFile(
                    fileURL: record.destinationURL,
                    expectedBytes: configuration.expectedSizeBytes,
                    expectedSHA256: configuration.expectedSHA256
                )
            }
            if let attributes = try? FileManager.default.attributesOfItem(
                atPath: record.destinationURL.path
            ), let fileSize = attributes[.size] as? NSNumber {
                completedByteCounts.append(fileSize.int64Value)
            }
            verified = verified && fileVerified
        }
        guard verified else { throw BenchmarkRunError.contentMismatch }

        let seconds = durationSeconds(elapsed)
        let bytesPerTask = configuration.sourceURL == nil
            ? configuration.sizeBytes
            : (completedByteCounts.first ?? configuration.sizeBytes)
        let totalBytes = completedByteCounts.isEmpty
            ? bytesPerTask * Int64(configuration.taskCount)
            : completedByteCounts.reduce(0, +)
        let events = metrics.snapshot()
        let peakValues = peaks.peaks()
        return BenchmarkRun(
            requestedConnectionsPerTask: requestedConnections,
            repetition: repetition,
            taskCount: configuration.taskCount,
            bytesPerTask: bytesPerTask,
            elapsedSeconds: seconds,
            aggregateGoodputMiBPerSecond: Double(totalBytes) / 1024 / 1024 / seconds,
            requestMetrics: BenchmarkMetricSummarizer.summarizeRequests(events),
            protocolMetrics: BenchmarkMetricSummarizer.summarizeProtocols(events),
            checkpointMetrics: BenchmarkMetricSummarizer.summarizeCheckpoints(events),
            checkpointPhaseMetrics: BenchmarkMetricSummarizer.summarizeCheckpointPhases(events),
            eventMetrics: BenchmarkMetricSummarizer.summarizeEvents(events),
            resources: ResourceMetricSummary(
                userCPUMilliseconds: nanosecondsDelta(
                    endResources.userCPUTimeNanoseconds,
                    startResources.userCPUTimeNanoseconds
                ) / 1_000_000,
                systemCPUMilliseconds: nanosecondsDelta(
                    endResources.systemCPUTimeNanoseconds,
                    startResources.systemCPUTimeNanoseconds
                ) / 1_000_000,
                startingResidentMemoryBytes: startResources.residentMemoryBytes,
                peakResidentMemoryBytes: peakValues.residentMemoryBytes,
                peakResidentMemoryDeltaBytes: unsignedDelta(
                    peakValues.residentMemoryBytes,
                    startResources.residentMemoryBytes
                ),
                peakOpenFileDescriptorCount: peakValues.openFileDescriptorCount,
                kernelAccountedWriteBytes: unsignedDelta(
                    endResources.diskWriteBytes,
                    startResources.diskWriteBytes
                )
            ),
            server: server?.statistics(),
            verified: verified
        )
    }

    private static func validateExternalFile(
        fileURL: URL,
        expectedBytes: Int64?,
        expectedSHA256: String?
    ) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let actualBytes = (attributes[.size] as? NSNumber)?.int64Value else {
            return false
        }
        if let expectedBytes, actualBytes != expectedBytes {
            return false
        }
        guard let expectedSHA256 else { return true }
        let checksum = try FileChecksumCalculator().calculate(
            fileURL: fileURL,
            algorithm: .sha256
        )
        return checksum.value.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    private static func waitForCompletion(
        ids: Set<DownloadID>,
        service: DownloadService,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let records = await service.snapshot().downloads.filter { ids.contains($0.id) }
            if let failed = records.first(where: { $0.status == .failed }) {
                throw BenchmarkRunError.downloadFailed(failed.error ?? "unknown error")
            }
            if records.count == ids.count, records.allSatisfy({ $0.status == .completed }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BenchmarkRunError.timedOut
    }

    private static func validatePattern(fileURL: URL, expectedBytes: Int64) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else { return false }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            for (index, byte) in data.enumerated() {
                if byte != UInt8((offset + Int64(index)) % 251) {
                    return false
                }
            }
            offset += Int64(data.count)
        }
        return offset == expectedBytes
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func nanosecondsDelta(_ end: UInt64, _ start: UInt64) -> Double {
        Double(unsignedDelta(end, start))
    }

    private static func unsignedDelta(_ end: UInt64, _ start: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

enum BenchmarkRunError: Error, LocalizedError {
    case timedOut
    case downloadFailed(String)
    case contentMismatch
    case missingExecutable
    case childProcessFailed(String)
    case invalidChildOutput(String)
    case invalidExternalURL(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Benchmark download timed out"
        case .downloadFailed(let message):
            return "Benchmark download failed: \(message)"
        case .contentMismatch:
            return "Downloaded bytes do not match the deterministic fixture"
        case .missingExecutable:
            return "Unable to locate the benchmark executable for process isolation"
        case .childProcessFailed(let message):
            return "Isolated benchmark run failed: \(message)"
        case .invalidChildOutput(let output):
            return "Isolated benchmark returned invalid JSON: \(output)"
        case .invalidExternalURL(let value):
            return "Invalid external HTTP(S) source URL: \(value)"
        }
    }
}

private struct InternalInvocation {
    let configuration: BenchmarkConfiguration
    let requestedConnections: Int
    let repetition: Int

    static func parse(arguments: [String]) throws -> Self? {
        guard let configurationIndex = arguments.firstIndex(of: "--internal-configuration") else {
            return nil
        }
        guard configurationIndex + 1 < arguments.count,
              let configurationData = Data(base64Encoded: arguments[configurationIndex + 1]),
              let connectionsIndex = arguments.firstIndex(of: "--internal-connections"),
              connectionsIndex + 1 < arguments.count,
              let requestedConnections = Int(arguments[connectionsIndex + 1]),
              let repetitionIndex = arguments.firstIndex(of: "--internal-repetition"),
              repetitionIndex + 1 < arguments.count,
              let repetition = Int(arguments[repetitionIndex + 1]) else {
            throw BenchmarkRunError.invalidChildOutput("invalid internal invocation")
        }
        return Self(
            configuration: try JSONDecoder().decode(
                BenchmarkConfiguration.self,
                from: configurationData
            ),
            requestedConnections: requestedConnections,
            repetition: repetition
        )
    }
}
