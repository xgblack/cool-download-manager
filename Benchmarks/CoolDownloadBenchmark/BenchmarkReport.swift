import CoolDownloadCore
import Foundation

struct BenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let environment: BenchmarkEnvironment
    let configuration: BenchmarkConfiguration
    let runs: [BenchmarkRun]
}

struct BenchmarkEnvironment: Codable, Sendable {
    let operatingSystem: String
    let architecture: String
    let processorCount: Int

    static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return Self(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }
}

struct BenchmarkRun: Codable, Sendable {
    let requestedConnectionsPerTask: Int
    let repetition: Int
    let taskCount: Int
    let bytesPerTask: Int64
    let elapsedSeconds: Double
    let aggregateGoodputMiBPerSecond: Double
    let requestMetrics: RequestMetricSummary
    let protocolMetrics: ProtocolMetricSummary
    let checkpointMetrics: CheckpointMetricSummary
    let checkpointPhaseMetrics: [String: CheckpointPhaseMetricSummary]
    let eventMetrics: EventMetricSummary
    /// Optional for compatibility with schema-version 4 reports produced
    /// before task-level completion statistics were added.
    let taskMetrics: TaskMetricSummary?
    /// Optional local-fixture tail observations. External runs and reports
    /// produced before schema version 5 leave this field absent.
    let rangeTailMetrics: RangeTailMetricSummary?
    let resources: ResourceMetricSummary
    /// Local fixture counters are unavailable when `--url` targets an
    /// external source.
    let server: RangeFixtureServer.Statistics?
    let verified: Bool
}

struct RequestMetricSummary: Codable, Sendable {
    let ordinaryGetCount: Int
    let rangeCount: Int
    let probeCount: Int
    let retryCount: Int
    let failedResponseCount: Int
    let totalResponseBytes: Int64
    let firstByteAverageMilliseconds: Double
    let firstByteP95Milliseconds: Double
    let responseP95Milliseconds: Double
}

extension RequestMetricSummary {
    private enum CodingKeys: String, CodingKey {
        case ordinaryGetCount
        case rangeCount
        case probeCount
        case retryCount
        case failedResponseCount
        case totalResponseBytes
        case firstByteAverageMilliseconds
        case firstByteP95Milliseconds
        case responseP95Milliseconds
    }

    /// The first schema-version 4 probe reports did not yet include failed
    /// response and response-latency fields. Treat absent values as empty
    /// observations instead of rejecting an otherwise valid report.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ordinaryGetCount = try container.decodeIfPresent(Int.self, forKey: .ordinaryGetCount) ?? 0
        rangeCount = try container.decodeIfPresent(Int.self, forKey: .rangeCount) ?? 0
        probeCount = try container.decodeIfPresent(Int.self, forKey: .probeCount) ?? 0
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        failedResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .failedResponseCount
        ) ?? 0
        totalResponseBytes = try container.decodeIfPresent(
            Int64.self,
            forKey: .totalResponseBytes
        ) ?? 0
        firstByteAverageMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .firstByteAverageMilliseconds
        ) ?? 0
        firstByteP95Milliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .firstByteP95Milliseconds
        ) ?? 0
        responseP95Milliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .responseP95Milliseconds
        ) ?? 0
    }
}

struct ProtocolMetricSummary: Codable, Sendable {
    let observedRequestCount: Int
    let protocolCounts: [String: Int]
    let reusedConnectionCount: Int
}

struct CheckpointMetricSummary: Codable, Sendable {
    let count: Int
    let failedCount: Int
    let totalMilliseconds: Double
    let p95Milliseconds: Double
    let encodedBytes: Int64
    let logicalWriteBytes: Int64
    let kernelAccountedWriteBytes: UInt64
    let synchronizeCount: Int
}

struct CheckpointPhaseMetricSummary: Codable, Sendable {
    let count: Int
    let totalMilliseconds: Double
    let p95Milliseconds: Double
    let bytes: Int64
}

struct EventMetricSummary: Codable, Sendable {
    let count: Int
    let totalMilliseconds: Double
}

/// Completion-level values make multi-task fairness visible without
/// persisting task IDs, URLs or other user data.
struct TaskMetricSummary: Codable, Sendable {
    let completedTaskCount: Int
    let failedTaskCount: Int
    let minimumGoodputMiBPerSecond: Double
    let medianGoodputMiBPerSecond: Double
    let maximumGoodputMiBPerSecond: Double
    /// 1.0 means all completed tasks observed the same completion goodput.
    let completionFairnessRatio: Double
    let completionElapsedP95Milliseconds: Double
}

struct ResourceMetricSummary: Codable, Sendable {
    let userCPUMilliseconds: Double
    let systemCPUMilliseconds: Double
    let startingResidentMemoryBytes: UInt64
    let peakResidentMemoryBytes: UInt64
    let peakResidentMemoryDeltaBytes: UInt64
    let peakOpenFileDescriptorCount: Int
    let kernelAccountedWriteBytes: UInt64
}

extension BenchmarkRun {
    private enum CodingKeys: String, CodingKey {
        case requestedConnectionsPerTask
        case repetition
        case taskCount
        case bytesPerTask
        case elapsedSeconds
        case aggregateGoodputMiBPerSecond
        case requestMetrics
        case protocolMetrics
        case checkpointMetrics
        case checkpointPhaseMetrics
        case eventMetrics
        case taskMetrics
        case rangeTailMetrics
        case resources
        case server
        case verified
    }

    /// Protocol and checkpoint phase metrics were added after the first
    /// schema-version 4 reports. They are observational fields, so an older
    /// report can be decoded with empty summaries while retaining all core
    /// throughput and correctness values.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedConnectionsPerTask = try container.decode(
            Int.self,
            forKey: .requestedConnectionsPerTask
        )
        repetition = try container.decode(Int.self, forKey: .repetition)
        taskCount = try container.decode(Int.self, forKey: .taskCount)
        bytesPerTask = try container.decode(Int64.self, forKey: .bytesPerTask)
        elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
        aggregateGoodputMiBPerSecond = try container.decode(
            Double.self,
            forKey: .aggregateGoodputMiBPerSecond
        )
        requestMetrics = try container.decode(RequestMetricSummary.self, forKey: .requestMetrics)
        protocolMetrics = try container.decodeIfPresent(
            ProtocolMetricSummary.self,
            forKey: .protocolMetrics
        ) ?? ProtocolMetricSummary(
            observedRequestCount: 0,
            protocolCounts: [:],
            reusedConnectionCount: 0
        )
        checkpointMetrics = try container.decode(
            CheckpointMetricSummary.self,
            forKey: .checkpointMetrics
        )
        checkpointPhaseMetrics = try container.decodeIfPresent(
            [String: CheckpointPhaseMetricSummary].self,
            forKey: .checkpointPhaseMetrics
        ) ?? [:]
        eventMetrics = try container.decode(EventMetricSummary.self, forKey: .eventMetrics)
        taskMetrics = try container.decodeIfPresent(TaskMetricSummary.self, forKey: .taskMetrics)
        rangeTailMetrics = try container.decodeIfPresent(
            RangeTailMetricSummary.self,
            forKey: .rangeTailMetrics
        )
        resources = try container.decode(ResourceMetricSummary.self, forKey: .resources)
        server = try container.decodeIfPresent(
            RangeFixtureServer.Statistics.self,
            forKey: .server
        )
        verified = try container.decode(Bool.self, forKey: .verified)
    }
}

struct RangeTailMetricSummary: Codable, Sendable, Equatable {
    let configured: Bool
    let matchingRequestCount: Int
    let completedRequestCount: Int
    let responseP95Milliseconds: Double
    let totalBytesSent: Int64
}

/// A small, benchmark-only report for a hard process interruption followed by
/// a fresh service boot and resume. It intentionally keeps this lifecycle
/// evidence separate from the normal throughput matrix.
struct BenchmarkRecoveryReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let environment: BenchmarkEnvironment
    let configuration: BenchmarkConfiguration
    let requestedConnectionsPerTask: Int
    let firstProcessTerminationStatus: Int32
    let persistedStatusBeforeRestart: String?
    let persistedBytesBeforeRestart: Int64
    let bootRecoveredPausedState: Bool
    let resumedRun: BenchmarkRun
    let server: RangeFixtureServer.Statistics
    let verified: Bool
}

/// Internal child output is kept separate so the public recovery report does
/// not expose an on-disk path or a transient status payload.
struct BenchmarkRecoveryChildResult: Codable, Sendable {
    let bootRecoveredPausedState: Bool
    let persistedBytesAtBoot: Int64
    let run: BenchmarkRun
}

final class ResourcePeakRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var peakResidentMemoryBytes: UInt64 = 0
    private var peakOpenFileDescriptorCount = 0

    func sample(_ snapshot: DownloadResourceSnapshot) {
        lock.withLock {
            peakResidentMemoryBytes = max(peakResidentMemoryBytes, snapshot.residentMemoryBytes)
            peakOpenFileDescriptorCount = max(
                peakOpenFileDescriptorCount,
                snapshot.openFileDescriptorCount
            )
        }
    }

    func peaks() -> (residentMemoryBytes: UInt64, openFileDescriptorCount: Int) {
        lock.withLock { (peakResidentMemoryBytes, peakOpenFileDescriptorCount) }
    }
}

enum BenchmarkMetricSummarizer {
    static func summarizeRangeTail(
        _ statistics: RangeFixtureServer.Statistics?,
        configuration: RangeFixtureServer.SlowRangeConfiguration?
    ) -> RangeTailMetricSummary? {
        guard let configuration else { return nil }
        let timings = statistics?.requestTimings ?? []
        let matching = timings.filter { timing in
            guard timing.rangeStart == configuration.start else { return false }
            guard let end = configuration.end else { return true }
            return timing.rangeEnd == end
        }
        let completed = matching.filter {
            !$0.failed && $0.responseMilliseconds != nil
        }
        let latencies = completed.compactMap(\.responseMilliseconds)
        return RangeTailMetricSummary(
            configured: true,
            matchingRequestCount: matching.count,
            completedRequestCount: completed.count,
            responseP95Milliseconds: percentile(latencies, percentile: 0.95),
            totalBytesSent: matching.reduce(0) { $0 + $1.bytesSent }
        )
    }

    static func summarizeRequests(_ events: [DownloadMetricEvent]) -> RequestMetricSummary {
        var ordinaryGetCount = 0
        var rangeCount = 0
        var probeCount = 0
        var retryCount = 0
        var failedResponseCount = 0
        var totalResponseBytes: Int64 = 0
        var firstByteMilliseconds: [Double] = []
        var responseMilliseconds: [Double] = []

        for event in events {
            switch event {
            case .httpResponseFirstByte(_, _, let latencyNanoseconds):
                firstByteMilliseconds.append(milliseconds(latencyNanoseconds))
            case .httpRequestFinished(
                _, _, let kind, let statusCode, let bytes, let elapsedNanoseconds
            ):
                totalResponseBytes += bytes
                responseMilliseconds.append(milliseconds(elapsedNanoseconds))
                if statusCode == nil || statusCode! >= 400 {
                    failedResponseCount += 1
                }
                switch kind {
                case .ordinaryGet: ordinaryGetCount += 1
                case .range: rangeCount += 1
                case .probeRange, .probeFallback: probeCount += 1
                }
            case .retryScheduled:
                retryCount += 1
            default:
                break
            }
        }

        return RequestMetricSummary(
            ordinaryGetCount: ordinaryGetCount,
            rangeCount: rangeCount,
            probeCount: probeCount,
            retryCount: retryCount,
            failedResponseCount: failedResponseCount,
            totalResponseBytes: totalResponseBytes,
            firstByteAverageMilliseconds: average(firstByteMilliseconds),
            firstByteP95Milliseconds: percentile(firstByteMilliseconds, percentile: 0.95),
            responseP95Milliseconds: percentile(responseMilliseconds, percentile: 0.95)
        )
    }

    static func summarizeProtocols(_ events: [DownloadMetricEvent]) -> ProtocolMetricSummary {
        var observedRequestCount = 0
        var protocolCounts: [String: Int] = [:]
        var reusedConnectionCount = 0

        for event in events {
            guard case .httpRequestProtocol(
                _, _, _, let networkProtocolName, let reusedConnection
            ) = event else { continue }
            observedRequestCount += 1
            if let networkProtocolName, !networkProtocolName.isEmpty {
                protocolCounts[networkProtocolName, default: 0] += 1
            }
            if reusedConnection == true {
                reusedConnectionCount += 1
            }
        }
        return ProtocolMetricSummary(
            observedRequestCount: observedRequestCount,
            protocolCounts: protocolCounts,
            reusedConnectionCount: reusedConnectionCount
        )
    }

    static func summarizeCheckpoints(_ events: [DownloadMetricEvent]) -> CheckpointMetricSummary {
        var durations: [Double] = []
        var failedCount = 0
        var encodedBytes: Int64 = 0
        var logicalWriteBytes: Int64 = 0
        var kernelWriteBytes: UInt64 = 0
        var synchronizeCount = 0

        for event in events {
            guard case .checkpoint(
                _, let elapsedNanoseconds, let eventEncodedBytes,
                let eventLogicalWriteBytes, let eventKernelWriteBytes,
                let eventSynchronizeCount, let succeeded
            ) = event else { continue }
            durations.append(milliseconds(elapsedNanoseconds))
            if !succeeded { failedCount += 1 }
            encodedBytes += eventEncodedBytes
            logicalWriteBytes += eventLogicalWriteBytes
            kernelWriteBytes &+= eventKernelWriteBytes
            synchronizeCount += eventSynchronizeCount
        }

        return CheckpointMetricSummary(
            count: durations.count,
            failedCount: failedCount,
            totalMilliseconds: durations.reduce(0, +),
            p95Milliseconds: percentile(durations, percentile: 0.95),
            encodedBytes: encodedBytes,
            logicalWriteBytes: logicalWriteBytes,
            kernelAccountedWriteBytes: kernelWriteBytes,
            synchronizeCount: synchronizeCount
        )
    }

    static func summarizeCheckpointPhases(
        _ events: [DownloadMetricEvent]
    ) -> [String: CheckpointPhaseMetricSummary] {
        var durations: [DownloadCheckpointPhase: [Double]] = [:]
        var bytes: [DownloadCheckpointPhase: Int64] = [:]

        for event in events {
            guard case .checkpointPhase(
                _, let phase, let elapsedNanoseconds, let eventBytes
            ) = event else { continue }
            durations[phase, default: []].append(milliseconds(elapsedNanoseconds))
            bytes[phase, default: 0] += eventBytes
        }

        return durations.reduce(into: [:]) { result, entry in
            let (phase, values) = entry
            result[phase.rawValue] = CheckpointPhaseMetricSummary(
                count: values.count,
                totalMilliseconds: values.reduce(0, +),
                p95Milliseconds: percentile(values, percentile: 0.95),
                bytes: bytes[phase, default: 0]
            )
        }
    }

    static func summarizeEvents(_ events: [DownloadMetricEvent]) -> EventMetricSummary {
        var count = 0
        var totalMilliseconds = 0.0
        for event in events {
            guard case .eventPublished(_, _, _, let elapsedNanoseconds) = event else { continue }
            count += 1
            totalMilliseconds += milliseconds(elapsedNanoseconds)
        }
        return EventMetricSummary(count: count, totalMilliseconds: totalMilliseconds)
    }

    static func summarizeTasks(_ events: [DownloadMetricEvent]) -> TaskMetricSummary {
        var completed = 0
        var failed = 0
        var rates: [Double] = []
        var elapsedMilliseconds: [Double] = []

        for event in events {
            guard case .taskFinished(
                _, let elapsedNanoseconds, let bytes, let succeeded, _
            ) = event else { continue }
            if succeeded {
                completed += 1
                let seconds = Double(elapsedNanoseconds) / 1_000_000_000
                if seconds > 0, bytes >= 0 {
                    rates.append(Double(bytes) / 1024 / 1024 / seconds)
                }
            } else {
                failed += 1
            }
            elapsedMilliseconds.append(Double(elapsedNanoseconds) / 1_000_000)
        }

        let minimum = rates.min() ?? 0
        let maximum = rates.max() ?? 0
        let fairness = maximum > 0 ? minimum / maximum : 0
        return TaskMetricSummary(
            completedTaskCount: completed,
            failedTaskCount: failed,
            minimumGoodputMiBPerSecond: minimum,
            medianGoodputMiBPerSecond: percentile(rates, percentile: 0.5),
            maximumGoodputMiBPerSecond: maximum,
            completionFairnessRatio: fairness,
            completionElapsedP95Milliseconds: percentile(
                elapsedMilliseconds,
                percentile: 0.95
            )
        )
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1)
        return sorted[max(0, index)]
    }
}
