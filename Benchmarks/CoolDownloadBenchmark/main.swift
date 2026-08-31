import CoolDownloadCore
import Foundation
import CoreData

#if canImport(Darwin)
import Darwin
#endif

@main
struct CoolDownloadBenchmarkMain {
    static func main() async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let arguments = Array(CommandLine.arguments.dropFirst())
            if let invocation = try InternalInvocation.parse(arguments: arguments) {
                switch invocation.mode {
                case .normal:
                    let run = try await runSingle(invocation: invocation)
                    FileHandle.standardOutput.write(try encoder.encode(run))
                case .recoveryInterrupt:
                    try await runUntilInterrupted(invocation: invocation)
                case .recoveryResume:
                    let result = try await runRecoveryResume(invocation: invocation)
                    FileHandle.standardOutput.write(try encoder.encode(result))
                }
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }

            let configuration = try BenchmarkConfiguration.parse(arguments: arguments)
            if configuration.persistenceBenchmark {
                let report = try await PersistenceBenchmarkRunner.run(configuration: configuration)
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
                return
            }
            if configuration.interruptionAfterMilliseconds != nil {
                let report = try await runRecoveryScenario(configuration: configuration)
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
                return
            }
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
            schemaVersion: 5,
            generatedAt: Date(),
            environment: .current,
            configuration: configuration.redactedForReport(),
            runs: measuredRuns
        )
    }

    private static func runRecoveryScenario(
        configuration: BenchmarkConfiguration
    ) async throws -> BenchmarkRecoveryReport {
        guard let interruptionAfterMilliseconds = configuration.interruptionAfterMilliseconds,
              let requestedConnections = configuration.connections.first else {
            throw BenchmarkRunError.invalidRecoveryConfiguration
        }

        let server = try RangeFixtureServer(
            contentLength: configuration.sizeBytes,
            bytesPerSecond: configuration.perConnectionBytesPerSecond,
            firstByteDelayMilliseconds: configuration.firstByteDelayMilliseconds,
            failFirstDataRequests: configuration.failFirstDataRequests,
            slowRange: configuration.slowRangeConfiguration()
        )
        let sourceURL = try await server.start()
        defer { server.stop() }

        let parent = configuration.downloadsRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent(
            "cooldm-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var childConfiguration = configuration
        childConfiguration.sourceURL = sourceURL.absoluteString
        childConfiguration.expectedSizeBytes = configuration.sizeBytes
        childConfiguration.downloadsRootPath = nil
        childConfiguration.fixedRunRootPath = root.path
        childConfiguration.keepFiles = true
        childConfiguration.outputPath = nil
        childConfiguration.interruptionAfterMilliseconds = nil
        childConfiguration.resumeExisting = false

        fputs(
            "recovery: start child, wait \(interruptionAfterMilliseconds) ms after persisted task\n",
            stderr
        )
        let firstChild = try launchChildProcess(
            configuration: childConfiguration,
            requestedConnections: requestedConnections,
            repetition: 1,
            mode: .recoveryInterrupt
        )

        let persistedBeforeKill = try await waitForPersistedTask(
            root: root,
            process: firstChild.process,
            delayAfterCreation: .milliseconds(interruptionAfterMilliseconds),
            timeout: .seconds(configuration.timeoutSeconds)
        )
        guard firstChild.process.isRunning == false || persistedBeforeKill != nil else {
            throw BenchmarkRunError.recoveryTaskWasNotPersisted
        }
        if firstChild.process.isRunning {
            #if canImport(Darwin)
            _ = Darwin.kill(firstChild.process.processIdentifier, SIGKILL)
            #else
            firstChild.process.terminate()
            #endif
            firstChild.process.waitUntilExit()
        }

        let firstError = firstChild.errorPipe.fileHandleForReading.readDataToEndOfFile()
        if !firstError.isEmpty {
            FileHandle.standardError.write(firstError)
        }
        let persisted = readPersistedTask(at: root) ?? persistedBeforeKill
        guard let persisted else {
            throw BenchmarkRunError.recoveryTaskWasNotPersisted
        }
        guard persisted.status != DownloadStatus.completed.rawValue else {
            throw BenchmarkRunError.recoveryCompletedBeforeInterruption
        }

        // Keep the server counters for the resumed phase separate from the
        // intentionally killed first phase.
        server.resetStatistics()
        childConfiguration.resumeExisting = true
        fputs("recovery: restart child and resume id=\(persisted.id)\n", stderr)
        let resumeOutput = try runChildProcessOutput(
            configuration: childConfiguration,
            requestedConnections: requestedConnections,
            repetition: 1,
            mode: .recoveryResume
        )
        let resumed: BenchmarkRecoveryChildResult
        do {
            resumed = try JSONDecoder().decode(
                BenchmarkRecoveryChildResult.self,
                from: resumeOutput.output
            )
        } catch {
            let rawOutput = String(data: resumeOutput.output, encoding: .utf8)
                ?? "<non-UTF8 output>"
            throw BenchmarkRunError.invalidChildOutput(rawOutput)
        }

        let serverStatistics = server.statistics()
        let verified = resumed.bootRecoveredPausedState
            && resumed.run.verified
            && serverStatistics.bytesSent > 0
        return BenchmarkRecoveryReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: .current,
            configuration: configuration.redactedForReport(),
            requestedConnectionsPerTask: requestedConnections,
            firstProcessTerminationStatus: firstChild.process.terminationStatus,
            persistedStatusBeforeRestart: persisted.status,
            persistedBytesBeforeRestart: persisted.downloadedBytes,
            bootRecoveredPausedState: resumed.bootRecoveredPausedState,
            resumedRun: resumed.run,
            server: serverStatistics,
            verified: verified
        )
    }

    private static func runUntilInterrupted(
        invocation: InternalInvocation
    ) async throws {
        let configuration = invocation.configuration
        guard let rootPath = configuration.fixedRunRootPath,
              let rawURL = configuration.sourceURL,
              let sourceURL = URL(string: rawURL) else {
            throw BenchmarkRunError.invalidRecoveryConfiguration
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let service = try makeService(
            configuration: configuration,
            requestedConnections: invocation.requestedConnections,
            root: root,
            downloads: downloads,
            networkConfiguration: try configuration.networkConfiguration(),
            metrics: NoopDownloadMetricsSink()
        )
        try await service.boot()
        _ = try await service.add(AddDownloadRequest(
            source: DownloadSource(
                kind: .http,
                link: sourceURL.absoluteString,
                suggestedName: "recovery.bin"
            ),
            folder: downloads.path,
            name: "recovery.bin",
            start: true
        ))
        // The parent deliberately terminates this process. Keeping the task
        // alive after completion also lets the parent detect an unexpectedly
        // fast fixture instead of silently claiming a recovery run.
        while true {
            try await Task.sleep(for: .seconds(60))
        }
    }

    private static func runRecoveryResume(
        invocation: InternalInvocation
    ) async throws -> BenchmarkRecoveryChildResult {
        let configuration = invocation.configuration
        guard let rootPath = configuration.fixedRunRootPath,
              let rawURL = configuration.sourceURL,
              let sourceURL = URL(string: rawURL) else {
            throw BenchmarkRunError.invalidRecoveryConfiguration
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)

        // Boot once only to capture the state transition caused by a previous
        // process. The helper's scope releases its store lock before the
        // actual measured resume creates a fresh service below.
        let bootState = try await inspectRecoveryBoot(
            configuration: configuration,
            requestedConnections: invocation.requestedConnections,
            root: root,
            downloads: downloads
        )

        var measuredConfiguration = configuration
        measuredConfiguration.resumeExisting = true
        let run = try await runOnce(
            configuration: measuredConfiguration,
            requestedConnections: invocation.requestedConnections,
            repetition: invocation.repetition,
            sourceURL: sourceURL,
            server: nil,
            networkConfiguration: try measuredConfiguration.networkConfiguration()
        )
        return BenchmarkRecoveryChildResult(
            bootRecoveredPausedState: bootState.recoveredPaused,
            persistedBytesAtBoot: bootState.persistedBytes,
            run: run
        )
    }

    private static func inspectRecoveryBoot(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        root: URL,
        downloads: URL
    ) async throws -> (recoveredPaused: Bool, persistedBytes: Int64) {
        let service = try makeService(
            configuration: configuration,
            requestedConnections: requestedConnections,
            root: root,
            downloads: downloads,
            networkConfiguration: try configuration.networkConfiguration(),
            metrics: NoopDownloadMetricsSink()
        )
        try await service.boot()
        let bootRecords = await service.snapshot().downloads
        guard let bootRecord = bootRecords.first(where: {
            $0.status != .completed && $0.status != .cancelled
        }) else {
            await service.shutdown()
            throw BenchmarkRunError.recoveryTaskWasNotPersisted
        }
        let result = (
            recoveredPaused: bootRecord.status == .paused,
            persistedBytes: bootRecord.downloadedBytes
        )
        await service.shutdown()
        return result
    }

    private static func waitForPersistedTask(
        root: URL,
        process: Process,
        delayAfterCreation: Duration,
        timeout: Duration
    ) async throws -> PersistedTaskSnapshot? {
        let deadline = ContinuousClock.now + timeout
        var snapshot: PersistedTaskSnapshot?
        while process.isRunning,
              ContinuousClock.now < deadline,
              snapshot == nil {
            snapshot = readPersistedTask(at: root)
            if snapshot == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        guard snapshot != nil else { return readPersistedTask(at: root) }

        let killAt = ContinuousClock.now + delayAfterCreation
        while process.isRunning, ContinuousClock.now < killAt {
            try await Task.sleep(for: .milliseconds(20))
        }
        return readPersistedTask(at: root) ?? snapshot
    }

    private static func readPersistedTask(at root: URL) -> PersistedTaskSnapshot? {
        let storeURL = root.appendingPathComponent("metadata.sqlite")
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let database = try? MetadataDatabase(rootURL: root, readOnly: true) else {
            return nil
        }
        return try? database.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadTask")
            request.fetchLimit = 1
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            guard let task = try context.fetch(request).first,
                  let id = (task.value(forKey: "id") as? NSNumber)?.int64Value,
                  let status = task.value(forKey: "status") as? String else {
                return nil
            }
            return PersistedTaskSnapshot(
                id: id,
                status: status,
                downloadedBytes: (task.value(forKey: "downloadedBytes") as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    private static func makeService(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        root: URL,
        downloads: URL,
        networkConfiguration: HTTPNetworkConfiguration,
        metrics: any DownloadMetricsSink
    ) throws -> DownloadService {
        DownloadService(
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
                useSparseFileAllocation: true,
                speedLimit: configuration.globalBytesPerSecond
            ),
            retryPolicy: DownloadRetryPolicy(
                maxAttempts: configuration.retryAttempts,
                delay: .milliseconds(configuration.retryDelayMilliseconds)
            ),
            metrics: metrics
        )
    }

    private static func runChildProcess(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        repetition: Int
    ) throws -> BenchmarkRun {
        let output = try runChildProcessOutput(
            configuration: configuration,
            requestedConnections: requestedConnections,
            repetition: repetition,
            mode: .normal
        )
        do {
            return try JSONDecoder().decode(BenchmarkRun.self, from: output.output)
        } catch {
            let rawOutput = String(data: output.output, encoding: .utf8) ?? "<non-UTF8 output>"
            throw BenchmarkRunError.invalidChildOutput(rawOutput)
        }
    }

    private static func runChildProcessOutput(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        repetition: Int,
        mode: InternalInvocation.Mode
    ) throws -> ChildProcessOutput {
        let child = try launchChildProcess(
            configuration: configuration,
            requestedConnections: requestedConnections,
            repetition: repetition,
            mode: mode
        )
        child.process.waitUntilExit()

        let output = child.outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = child.errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard child.process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)
                ?? "child process exited with status \(child.process.terminationStatus)"
            throw BenchmarkRunError.childProcessFailed(message)
        }
        if !errorOutput.isEmpty {
            FileHandle.standardError.write(errorOutput)
        }
        return ChildProcessOutput(
            output: output,
            error: errorOutput,
            terminationStatus: child.process.terminationStatus
        )
    }

    private static func launchChildProcess(
        configuration: BenchmarkConfiguration,
        requestedConnections: Int,
        repetition: Int,
        mode: InternalInvocation.Mode
    ) throws -> LaunchedChildProcess {
        let encoder = JSONEncoder()
        let encodedConfiguration = try encoder.encode(configuration).base64EncodedString()
        guard let executableURL = Bundle.main.executableURL else {
            throw BenchmarkRunError.missingExecutable
        }

        let process = Process()
        process.executableURL = executableURL
        var arguments = [
            "--internal-configuration", encodedConfiguration,
            "--internal-connections", String(requestedConnections),
            "--internal-repetition", String(repetition)
        ]
        switch mode {
        case .normal:
            break
        case .recoveryInterrupt:
            arguments.append("--internal-recovery-interrupt")
        case .recoveryResume:
            arguments.append("--internal-recovery-resume")
        }
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        return LaunchedChildProcess(
            process: process,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )
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
            failFirstDataRequests: configuration.failFirstDataRequests,
            slowRange: configuration.slowRangeConfiguration()
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
        let root = configuration.fixedRunRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? parent.appendingPathComponent(
            "cooldm-benchmark-\(UUID().uuidString)",
            isDirectory: true
        )
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
        let service = try makeService(
            configuration: configuration,
            requestedConnections: requestedConnections,
            root: root,
            downloads: downloads,
            networkConfiguration: networkConfiguration,
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
            if configuration.resumeExisting {
                ids = (await service.snapshot().downloads)
                    .filter { $0.status != .completed && $0.status != .cancelled }
                    .map(\.id)
                guard !ids.isEmpty else {
                    throw BenchmarkRunError.recoveryTaskWasNotPersisted
                }
                try await service.resume(ids: ids)
            } else {
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
        let serverStatistics = server?.statistics()
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
            taskMetrics: BenchmarkMetricSummarizer.summarizeTasks(events),
            rangeTailMetrics: BenchmarkMetricSummarizer.summarizeRangeTail(
                serverStatistics,
                configuration: configuration.slowRangeConfiguration()
            ),
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
            server: serverStatistics,
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
        // Keep validation bounded and out of the Foundation autorelease pool:
        // repeatedly calling read(upToCount:) on a multi-gigabyte file can
        // retain every temporary Data object until the process exits. The
        // fixture's byte pattern repeats every 251 bytes, so each chunk can
        // be checked with a small number of C-level comparisons.
        let chunkSize = 4 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let pattern = (0..<251).map(UInt8.init)
        var offset: Int64 = 0
        while offset < expectedBytes {
            let bytesRead: Int
            while true {
                let result = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    return Darwin.read(handle.fileDescriptor, baseAddress, rawBuffer.count)
                }
                if result >= 0 {
                    bytesRead = result
                    break
                }
                if errno == EINTR {
                    continue
                }
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: fileURL.path]
                )
            }
            guard bytesRead > 0 else { return false }

            let valid = buffer.withUnsafeBytes { rawBuffer in
                pattern.withUnsafeBufferPointer { patternBuffer in
                    guard let dataBase = rawBuffer.baseAddress,
                          let patternBase = patternBuffer.baseAddress else {
                        return false
                    }
                    var compared = 0
                    var patternOffset = Int(offset % 251)
                    while compared < bytesRead {
                        let count = min(bytesRead - compared, 251 - patternOffset)
                        if memcmp(
                            dataBase.advanced(by: compared),
                            patternBase.advanced(by: patternOffset),
                            count
                        ) != 0 {
                            return false
                        }
                        compared += count
                        patternOffset = 0
                    }
                    return true
                }
            }
            guard valid else { return false }
            offset += Int64(bytesRead)
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
    case invalidRecoveryConfiguration
    case recoveryTaskWasNotPersisted
    case recoveryCompletedBeforeInterruption
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
        case .invalidRecoveryConfiguration:
            return "Invalid process-recovery benchmark configuration"
        case .recoveryTaskWasNotPersisted:
            return "Recovery benchmark did not find a persisted resumable task"
        case .recoveryCompletedBeforeInterruption:
            return "Recovery benchmark completed before the child could be interrupted"
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
    enum Mode {
        case normal
        case recoveryInterrupt
        case recoveryResume
    }

    let configuration: BenchmarkConfiguration
    let requestedConnections: Int
    let repetition: Int
    let mode: Mode

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
        let mode: Mode
        if arguments.contains("--internal-recovery-interrupt") {
            mode = .recoveryInterrupt
        } else if arguments.contains("--internal-recovery-resume") {
            mode = .recoveryResume
        } else {
            mode = .normal
        }
        return Self(
            configuration: try JSONDecoder().decode(
                BenchmarkConfiguration.self,
                from: configurationData
            ),
            requestedConnections: requestedConnections,
            repetition: repetition,
            mode: mode
        )
    }
}

private struct PersistedTaskSnapshot {
    let id: DownloadID
    let status: String
    let downloadedBytes: Int64
}

private struct LaunchedChildProcess {
    let process: Process
    let outputPipe: Pipe
    let errorPipe: Pipe
}

private struct ChildProcessOutput {
    let output: Data
    let error: Data
    let terminationStatus: Int32
}
