import Foundation

/// A small shared limiter used by all connections belonging to one download.
/// Sharing the actor is important when a task uses parallel byte ranges: the
/// configured limit applies to the task as a whole rather than once per part.
public actor DownloadRateLimiter {
    private static let maximumSleepNanoseconds: UInt64 = 100_000_000

    private var bytesPerSecond: Int64
    private var startedAt: Date
    private var consumedBytes: Int64 = 0
    private var configurationRevision: UInt64 = 0

    public init(bytesPerSecond: Int64) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.startedAt = Date()
    }

    func updateLimit(bytesPerSecond: Int64) {
        let normalizedLimit = max(0, bytesPerSecond)
        guard normalizedLimit != self.bytesPerSecond else { return }
        self.bytesPerSecond = normalizedLimit
        startedAt = Date()
        consumedBytes = 0
        configurationRevision &+= 1
    }

    public func consume(_ byteCount: Int) async throws {
        guard bytesPerSecond > 0, byteCount > 0 else { return }
        consumedBytes += Int64(byteCount)
        let revision = configurationRevision

        while revision == configurationRevision, bytesPerSecond > 0 {
            let expectedElapsed = Double(consumedBytes) / Double(bytesPerSecond)
            let elapsed = Date().timeIntervalSince(startedAt)
            let wait = expectedElapsed - elapsed
            guard wait > 0 else { return }
            let nanoseconds = min(
                UInt64(wait * 1_000_000_000),
                Self.maximumSleepNanoseconds
            )
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }
}
