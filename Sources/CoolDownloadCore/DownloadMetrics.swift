import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The kind of HTTP stream observed by the downloader. A range request is
/// counted separately from metadata probes so connection tuning can use the
/// actual data-stream count rather than a configured worker count.
public enum HTTPRequestMetricKind: String, Sendable, Equatable {
    case range
    case ordinaryGet
    case probeRange
    case probeFallback
}

/// A durable checkpoint phase used to locate storage-path bottlenecks without
/// recording file paths or payload data.
public enum DownloadCheckpointPhase: String, Sendable, Equatable, Hashable {
    case projectionEncode
    case fetch
    case attributeUpdate
    case partDiff
    case contextSave
    case sqliteFileDelta
    // Retained for benchmark report compatibility with pre-Core Data runs.
    case recordEncode
    case recordWrite
    case recordSynchronize
    case recordReplace
    case sidecarEncode
    case sidecarWrite
    case sidecarSynchronize
    case sidecarReplace
}

/// A point-in-time process resource sample attached to task and checkpoint
/// metrics. `diskWriteBytes` is the kernel-accounted process write counter,
/// which is useful for comparing runs but is not a device-level fsync count.
public struct DownloadResourceSnapshot: Sendable, Equatable {
    public let userCPUTimeNanoseconds: UInt64
    public let systemCPUTimeNanoseconds: UInt64
    public let residentMemoryBytes: UInt64
    public let openFileDescriptorCount: Int
    public let diskWriteBytes: UInt64

    public init(
        userCPUTimeNanoseconds: UInt64 = 0,
        systemCPUTimeNanoseconds: UInt64 = 0,
        residentMemoryBytes: UInt64 = 0,
        openFileDescriptorCount: Int = 0,
        diskWriteBytes: UInt64 = 0
    ) {
        self.userCPUTimeNanoseconds = userCPUTimeNanoseconds
        self.systemCPUTimeNanoseconds = systemCPUTimeNanoseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.openFileDescriptorCount = openFileDescriptorCount
        self.diskWriteBytes = diskWriteBytes
    }

    /// Captures best-effort process counters without introducing a profiling
    /// dependency. `proc_pid_rusage` provides current RSS and byte counters;
    /// `getrusage` remains a CPU/RSS fallback when that query is unavailable.
    public static func capture() -> Self {
        #if canImport(Darwin)
        var processUsage = rusage_info_current()
        let processUsageResult = withUnsafeMutablePointer(to: &processUsage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        if processUsageResult == 0 {
            return Self(
                userCPUTimeNanoseconds: processUsage.ri_user_time,
                systemCPUTimeNanoseconds: processUsage.ri_system_time,
                residentMemoryBytes: processUsage.ri_resident_size,
                openFileDescriptorCount: openFileDescriptorCount(),
                diskWriteBytes: processUsage.ri_diskio_byteswritten
            )
        }

        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return Self(openFileDescriptorCount: openFileDescriptorCount())
        }

        let userSeconds = max(Int64(0), Int64(usage.ru_utime.tv_sec))
        let userMicroseconds = max(Int64(0), Int64(usage.ru_utime.tv_usec))
        let systemSeconds = max(Int64(0), Int64(usage.ru_stime.tv_sec))
        let systemMicroseconds = max(Int64(0), Int64(usage.ru_stime.tv_usec))
        return Self(
            userCPUTimeNanoseconds: UInt64(userSeconds) * 1_000_000_000
                + UInt64(userMicroseconds) * 1_000,
            systemCPUTimeNanoseconds: UInt64(systemSeconds) * 1_000_000_000
                + UInt64(systemMicroseconds) * 1_000,
            residentMemoryBytes: UInt64(max(Int64(0), Int64(usage.ru_maxrss))),
            openFileDescriptorCount: openFileDescriptorCount(),
            diskWriteBytes: 0
        )
        #else
        return Self(openFileDescriptorCount: openFileDescriptorCount())
        #endif
    }

    private static func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    func diskWriteDelta(from previous: Self) -> UInt64 {
        diskWriteBytes >= previous.diskWriteBytes
            ? diskWriteBytes - previous.diskWriteBytes
            : 0
    }
}

/// Metrics emitted by the core. Events intentionally contain no URL, header,
/// cookie, authorization value, or response body, so a production sink can
/// persist them without leaking download credentials.
public enum DownloadMetricEvent: Sendable, Equatable {
    case taskStarted(
        id: DownloadID,
        timestampNanoseconds: UInt64,
        resources: DownloadResourceSnapshot
    )
    case taskFinished(
        id: DownloadID,
        elapsedNanoseconds: UInt64,
        bytes: Int64,
        succeeded: Bool,
        resources: DownloadResourceSnapshot
    )
    case httpRequestStarted(
        downloadID: DownloadID?,
        requestID: UUID,
        kind: HTTPRequestMetricKind,
        timestampNanoseconds: UInt64
    )
    case httpResponseFirstByte(
        downloadID: DownloadID?,
        requestID: UUID,
        latencyNanoseconds: UInt64
    )
    case httpRequestProtocol(
        downloadID: DownloadID?,
        requestID: UUID,
        kind: HTTPRequestMetricKind,
        networkProtocolName: String?,
        reusedConnection: Bool?
    )
    case httpRequestFinished(
        downloadID: DownloadID?,
        requestID: UUID,
        kind: HTTPRequestMetricKind,
        statusCode: Int?,
        bytes: Int64,
        elapsedNanoseconds: UInt64
    )
    case retryScheduled(
        id: DownloadID,
        attempt: Int,
        delayNanoseconds: UInt64
    )
    case checkpoint(
        id: DownloadID,
        elapsedNanoseconds: UInt64,
        encodedBytes: Int64,
        logicalWriteBytes: Int64,
        kernelAccountedWriteBytes: UInt64,
        synchronizeCount: Int,
        succeeded: Bool
    )
    case checkpointPhase(
        id: DownloadID,
        phase: DownloadCheckpointPhase,
        elapsedNanoseconds: UInt64,
        bytes: Int64
    )
    case eventPublished(
        id: DownloadID?,
        eventName: String,
        subscriberCount: Int,
        elapsedNanoseconds: UInt64
    )
}

/// A deliberately small injection point. The default sink is a no-op, so
/// normal downloads do not allocate an event buffer or perform I/O for
/// metrics. Implementations must be thread-safe because HTTP workers report
/// events concurrently.
public protocol DownloadMetricsSink: Sendable {
    /// Disabled sinks must be effectively free on the download hot path.
    var isEnabled: Bool { get }
    func record(_ event: DownloadMetricEvent)
}

public extension DownloadMetricsSink {
    var isEnabled: Bool { true }
}

public struct NoopDownloadMetricsSink: DownloadMetricsSink {
    public init() {}

    public var isEnabled: Bool { false }

    public func record(_ event: DownloadMetricEvent) {
        _ = event
    }
}

/// An in-memory sink useful for tests, local profiling and diagnostics. It is
/// bounded to avoid a long-running download turning metrics into an
/// unbounded memory consumer.
public final class DownloadMetricsCollector: @unchecked Sendable, DownloadMetricsSink {
    private let lock = NSLock()
    private let maximumEventCount: Int
    private var storedEvents: [DownloadMetricEvent] = []

    public init(maximumEventCount: Int = 10_000) {
        self.maximumEventCount = max(1, maximumEventCount)
    }

    public func record(_ event: DownloadMetricEvent) {
        lock.withLock {
            if storedEvents.count == maximumEventCount {
                storedEvents.removeFirst()
            }
            storedEvents.append(event)
        }
    }

    public func snapshot() -> [DownloadMetricEvent] {
        lock.withLock { storedEvents }
    }

    public func reset() {
        lock.withLock { storedEvents.removeAll(keepingCapacity: true) }
    }
}

@inline(__always)
func downloadMetricsNow() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

@inline(__always)
func downloadMetricsElapsed(since start: UInt64) -> UInt64 {
    let now = downloadMetricsNow()
    return now >= start ? now - start : 0
}

@inline(__always)
func downloadMetricsNanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let attoseconds = max(0, components.attoseconds)
    let secondNanoseconds = UInt64(seconds) * 1_000_000_000
    let fractionalNanoseconds = UInt64(attoseconds / 1_000_000_000)
    return secondNanoseconds &+ fractionalNanoseconds
}
