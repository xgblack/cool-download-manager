import Foundation

/// A small shared limiter used by all connections belonging to one download.
/// Sharing the actor is important when a task uses parallel byte ranges: the
/// configured limit applies to the task as a whole rather than once per part.
public actor DownloadRateLimiter {
    private static let maximumSleepNanoseconds: UInt64 = 100_000_000

    private var bytesPerSecond: Int64
    /// A task limiter can inherit one shared limiter. Explicit task/host
    /// overrides remain local caps while the parent enforces the aggregate
    /// application budget.
    private var parent: DownloadRateLimiter?
    private var startedAt: Date
    private var consumedBytes: Int64 = 0
    private var configurationRevision: UInt64 = 0

    public init(bytesPerSecond: Int64, parent: DownloadRateLimiter? = nil) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.parent = parent
        self.startedAt = Date()
    }

    func updateLimit(bytesPerSecond: Int64) {
        update(bytesPerSecond: bytesPerSecond, parent: parent)
    }

    func update(bytesPerSecond: Int64, parent: DownloadRateLimiter?) {
        let normalizedLimit = max(0, bytesPerSecond)
        guard normalizedLimit != self.bytesPerSecond || parent !== self.parent else { return }
        self.bytesPerSecond = normalizedLimit
        self.parent = parent
        startedAt = Date()
        consumedBytes = 0
        configurationRevision &+= 1
    }

    public func consume(_ byteCount: Int) async throws {
        guard byteCount > 0 else { return }
        // Acquire the shared budget before the task-local budget.  This makes
        // the global setting an aggregate cap for all inheriting tasks while
        // preserving explicit task/host overrides as independent limits.
        if let parent {
            try await parent.consume(byteCount)
        }
        guard bytesPerSecond > 0 else { return }
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
