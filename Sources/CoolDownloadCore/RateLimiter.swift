import Foundation

/// A small shared limiter used by all connections belonging to one download.
/// Sharing the actor is important when a task uses parallel byte ranges: the
/// configured limit applies to the task as a whole rather than once per part.
public actor DownloadRateLimiter {
    private let bytesPerSecond: Int64
    private let startedAt: Date
    private var consumedBytes: Int64 = 0

    public init(bytesPerSecond: Int64) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.startedAt = Date()
    }

    public func consume(_ byteCount: Int) async throws {
        guard bytesPerSecond > 0, byteCount > 0 else { return }
        consumedBytes += Int64(byteCount)
        let expectedElapsed = Double(consumedBytes) / Double(bytesPerSecond)
        let elapsed = Date().timeIntervalSince(startedAt)
        let wait = expectedElapsed - elapsed
        guard wait > 0 else { return }
        let nanoseconds = UInt64(min(wait, 60) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
