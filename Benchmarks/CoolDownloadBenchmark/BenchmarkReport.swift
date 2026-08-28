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

struct ResourceMetricSummary: Codable, Sendable {
    let userCPUMilliseconds: Double
    let systemCPUMilliseconds: Double
    let startingResidentMemoryBytes: UInt64
    let peakResidentMemoryBytes: UInt64
    let peakResidentMemoryDeltaBytes: UInt64
    let peakOpenFileDescriptorCount: Int
    let kernelAccountedWriteBytes: UInt64
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
