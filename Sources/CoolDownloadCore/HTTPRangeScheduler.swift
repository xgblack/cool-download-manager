import Foundation

/// A range that can be claimed by one download worker. The lease is runtime
/// state; only the byte counters are copied back to the persisted part.
struct HTTPRangeWorkItem: Sendable, Equatable {
    let partID: Int
    let start: Int64
    let end: Int64
    let downloaded: Int64
}

/// Owns pending range work independently from the DownloadService actor. A
/// worker can claim one item, then return for the next item without creating a
/// task for every persisted part.
actor HTTPRangeWorkQueue {
    private var pending: [HTTPRangeWorkItem]
    private var inFlight: Set<Int> = []

    init(parts: [DownloadPart]) {
        pending = parts.compactMap { part in
            guard !part.completed,
                  let end = part.to else {
                return nil
            }
            let start = part.from + part.downloaded
            guard start <= end else { return nil }
            return HTTPRangeWorkItem(
                partID: part.id,
                start: start,
                end: end,
                downloaded: part.downloaded
            )
        }
    }

    func claim() -> HTTPRangeWorkItem? {
        guard !pending.isEmpty else { return nil }
        let item = pending.removeFirst()
        inFlight.insert(item.partID)
        return item
    }

    func complete(partID: Int) {
        inFlight.remove(partID)
    }

    func pendingCount() -> Int {
        pending.count
    }

    func remainingCount() -> Int {
        pending.count + inFlight.count
    }

    func isDrained() -> Bool {
        pending.isEmpty && inFlight.isEmpty
    }

    func release(_ item: HTTPRangeWorkItem) {
        guard inFlight.remove(item.partID) != nil else { return }
        pending.append(item)
    }

}

struct HTTPRangeConcurrencyUpdate: Sendable, Equatable {
    enum Reason: String, Sendable, Equatable {
        case increased
        case insufficientGain
        case degraded
        case latency
        case failure
    }

    let previousLimit: Int
    let currentLimit: Int
    let stableLimit: Int
    let measuredGoodputBytesPerSecond: Double
    let reason: Reason
}

struct HTTPRangeConcurrencyObservation: Sendable, Equatable {
    let stableLimit: Int
    let stableGoodputBytesPerSecond: Double?
}

/// Probes 1/2/4/8-style stages up to the configured task ceiling. A stage
/// collects one completed request from every active worker; only a candidate
/// whose aggregate goodput improves by at least ten percent without doubling
/// the stage's slowest request is retained. Workers already inside a request
/// finish naturally after a reduction.
actor HTTPRangeConcurrencyController {
    private struct Waiter {
        let id: UUID
        let workerIndex: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximum: Int
    private var activeLimit: Int
    private var stableLimit: Int
    private var stableGoodput: Double?
    private var stageRatesByWorker: [Int: Double] = [:]
    private var stageLatenciesByWorker: [Int: UInt64] = [:]
    private var stableLatencyNanoseconds: Double?
    private var cooldownUntil = ContinuousClock.now
    private var stopped = false
    private var waiters: [Waiter] = []

    init(
        maximum: Int,
        initialLimit: Int = 1,
        initialGoodputBytesPerSecond: Double? = nil
    ) {
        self.maximum = max(1, maximum)
        let boundedInitialLimit = min(max(1, initialLimit), self.maximum)
        self.activeLimit = boundedInitialLimit
        self.stableLimit = boundedInitialLimit
        if let initialGoodputBytesPerSecond,
           initialGoodputBytesPerSecond > 0 {
            self.stableGoodput = initialGoodputBytesPerSecond
        } else {
            self.stableGoodput = nil
        }
    }

    func waitForPermit(workerIndex: Int) async -> Bool {
        guard workerIndex >= 0, workerIndex < maximum else { return false }
        guard !stopped else { return false }
        if workerIndex < activeLimit {
            return !Task.isCancelled
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if stopped {
                    continuation.resume(returning: false)
                } else if workerIndex < activeLimit {
                    continuation.resume(returning: !Task.isCancelled)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(
                        id: waiterID,
                        workerIndex: workerIndex,
                        continuation: continuation
                    ))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
    }

    func reportCompletion(
        workerIndex: Int,
        bytes: Int64,
        elapsed: Duration,
        remainingWork: Int
    ) -> HTTPRangeConcurrencyUpdate? {
        guard !stopped,
              workerIndex >= 0,
              workerIndex < activeLimit,
              bytes > 0,
              elapsed > .zero else {
            return nil
        }
        let elapsedNanoseconds = max(1, downloadMetricsNanoseconds(elapsed))
        stageRatesByWorker[workerIndex] = Double(bytes) * 1_000_000_000
            / Double(elapsedNanoseconds)
        stageLatenciesByWorker[workerIndex] = elapsedNanoseconds
        guard stageRatesByWorker.count >= activeLimit else {
            return nil
        }

        let measuredGoodput = stageRatesByWorker.values.reduce(0, +)
        let measuredLatencyNanoseconds = Double(
            stageLatenciesByWorker.values.max() ?? elapsedNanoseconds
        )
        let previousLimit = activeLimit
        let update: HTTPRangeConcurrencyUpdate?

        if stableGoodput == nil {
            stableLimit = activeLimit
            stableGoodput = measuredGoodput
            stableLatencyNanoseconds = measuredLatencyNanoseconds
            update = increaseIfUseful(
                previousLimit: previousLimit,
                measuredGoodput: measuredGoodput,
                remainingWork: remainingWork
            )
        } else if activeLimit == stableLimit {
            guard let baseline = stableGoodput else { return nil }
            if measuredGoodput < baseline * 0.9, activeLimit > 1 {
                activeLimit = previousLevel(before: activeLimit)
                stableLimit = activeLimit
                stableGoodput = nil
                stableLatencyNanoseconds = nil
                cooldownUntil = ContinuousClock.now + .seconds(10)
                update = HTTPRangeConcurrencyUpdate(
                    previousLimit: previousLimit,
                    currentLimit: activeLimit,
                    stableLimit: stableLimit,
                    measuredGoodputBytesPerSecond: measuredGoodput,
                    reason: .degraded
                )
            } else if exceedsLatencyBudget(measuredLatencyNanoseconds), activeLimit > 1 {
                activeLimit = previousLevel(before: activeLimit)
                stableLimit = activeLimit
                stableGoodput = nil
                stableLatencyNanoseconds = nil
                cooldownUntil = ContinuousClock.now + .seconds(10)
                update = HTTPRangeConcurrencyUpdate(
                    previousLimit: previousLimit,
                    currentLimit: activeLimit,
                    stableLimit: stableLimit,
                    measuredGoodputBytesPerSecond: measuredGoodput,
                    reason: .latency
                )
            } else {
                stableGoodput = (baseline + measuredGoodput) / 2
                if let stableLatencyNanoseconds {
                    self.stableLatencyNanoseconds = (
                        stableLatencyNanoseconds + measuredLatencyNanoseconds
                    ) / 2
                } else {
                    stableLatencyNanoseconds = measuredLatencyNanoseconds
                }
                update = increaseIfUseful(
                    previousLimit: previousLimit,
                    measuredGoodput: measuredGoodput,
                    remainingWork: remainingWork
                )
            }
        } else {
            guard let baseline = stableGoodput else { return nil }
            if measuredGoodput >= baseline * 1.1 {
                if exceedsLatencyBudget(measuredLatencyNanoseconds) {
                    activeLimit = stableLimit
                    cooldownUntil = ContinuousClock.now + .seconds(10)
                    update = HTTPRangeConcurrencyUpdate(
                        previousLimit: previousLimit,
                        currentLimit: activeLimit,
                        stableLimit: stableLimit,
                        measuredGoodputBytesPerSecond: measuredGoodput,
                        reason: .latency
                    )
                } else {
                    stableLimit = activeLimit
                    stableGoodput = measuredGoodput
                    stableLatencyNanoseconds = measuredLatencyNanoseconds
                    update = increaseIfUseful(
                        previousLimit: previousLimit,
                        measuredGoodput: measuredGoodput,
                        remainingWork: remainingWork
                    )
                }
            } else {
                activeLimit = stableLimit
                cooldownUntil = ContinuousClock.now + .seconds(10)
                update = HTTPRangeConcurrencyUpdate(
                    previousLimit: previousLimit,
                    currentLimit: activeLimit,
                    stableLimit: stableLimit,
                    measuredGoodputBytesPerSecond: measuredGoodput,
                    reason: .insufficientGain
                )
            }
        }
        resetStage()
        if activeLimit > previousLimit {
            resumeAvailableWaiters()
        }
        return update
    }

    func reportFailure(statusCode: Int? = nil) -> HTTPRangeConcurrencyUpdate? {
        guard !stopped, affectsConcurrency(statusCode: statusCode) else { return nil }
        let previousLimit = activeLimit
        activeLimit = activeLimit > stableLimit
            ? stableLimit
            : previousLevel(before: activeLimit)
        stableLimit = activeLimit
        stableGoodput = nil
        stableLatencyNanoseconds = nil
        cooldownUntil = ContinuousClock.now + .seconds(10)
        resetStage()
        return HTTPRangeConcurrencyUpdate(
            previousLimit: previousLimit,
            currentLimit: activeLimit,
            stableLimit: stableLimit,
            measuredGoodputBytesPerSecond: 0,
            reason: .failure
        )
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume(returning: false)
        }
    }

    func currentLimit() -> Int {
        activeLimit
    }

    func observation() -> HTTPRangeConcurrencyObservation {
        HTTPRangeConcurrencyObservation(
            stableLimit: stableLimit,
            stableGoodputBytesPerSecond: stableGoodput
        )
    }

    private func nextLevel(after level: Int) -> Int {
        min(maximum, max(level + 1, level * 2))
    }

    private func previousLevel(before level: Int) -> Int {
        max(1, level / 2)
    }

    private func resetStage() {
        stageRatesByWorker.removeAll(keepingCapacity: true)
        stageLatenciesByWorker.removeAll(keepingCapacity: true)
    }

    /// A candidate stage must not trade a large tail-latency increase for
    /// aggregate bytes per second. This is deliberately a coarse guard until
    /// URLSession transaction RTT samples are available across all platforms.
    private func exceedsLatencyBudget(_ measuredNanoseconds: Double) -> Bool {
        guard let stableLatencyNanoseconds,
              stableLatencyNanoseconds > 0 else {
            return false
        }
        return measuredNanoseconds > stableLatencyNanoseconds * 2
    }

    /// Permanent client errors do not indicate that the server is overloaded;
    /// only transport failures and retryable HTTP statuses should lower the
    /// active stage. The outer retry policy still surfaces the original error.
    private func affectsConcurrency(statusCode: Int?) -> Bool {
        guard let statusCode else { return true }
        switch statusCode {
        case 408, 425, 429, 500...599:
            return true
        default:
            return false
        }
    }

    private func increaseIfUseful(
        previousLimit: Int,
        measuredGoodput: Double,
        remainingWork: Int
    ) -> HTTPRangeConcurrencyUpdate? {
        guard activeLimit < maximum,
              ContinuousClock.now >= cooldownUntil else {
            return nil
        }
        let nextLimit = nextLevel(after: activeLimit)
        guard remainingWork >= nextLimit else { return nil }
        activeLimit = nextLimit
        return HTTPRangeConcurrencyUpdate(
            previousLimit: previousLimit,
            currentLimit: activeLimit,
            stableLimit: stableLimit,
            measuredGoodputBytesPerSecond: measuredGoodput,
            reason: .increased
        )
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func resumeAvailableWaiters() {
        guard !stopped else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.workerIndex < activeLimit {
                waiter.continuation.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

/// A cancellable async semaphore used to cap actual in-flight HTTP requests
/// across all running downloads. Waiting workers do not hold a network task or
/// response buffer until a lease is available.
actor HTTPRangeConnectionBudget {
    struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
    }

    private var limit: Int
    private var activeLeases: Set<UUID> = []
    private var waiters: [(id: UUID, taskID: DownloadID?, continuation: CheckedContinuation<Lease, Error>)] = []
    private var lastGrantedTaskID: DownloadID?

    init(limit: Int) {
        let normalized = max(1, limit)
        self.limit = normalized
    }

    func acquire(taskID: DownloadID? = nil) async throws -> Lease {
        try Task.checkCancellation()
        let waiterID = UUID()
        let lease: Lease = try await withTaskCancellationHandler(operation: {
            try await self.acquireOrWait(waiterID: waiterID, taskID: taskID)
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
        // A release can resume a waiter at the same time cancellation reaches
        // its handler. Returning a lease to an already-cancelled caller would
        // strand that capacity because the caller never enters its request
        // body. Return it before surfacing cancellation instead.
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func acquireOrWait(waiterID: UUID, taskID: DownloadID?) async throws -> Lease {
        if activeLeases.count < limit {
            return grant(taskID: taskID)
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Lease, Error>) in
            // Cancellation may arrive after the initial check but before the
            // continuation is inserted. Re-check while holding actor
            // isolation so a cancelled waiter cannot be stranded.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((waiterID, taskID, continuation))
            }
        }
    }

    func release(_ lease: Lease) {
        guard activeLeases.remove(lease.id) != nil else { return }
        // A runtime limit reduction cannot cancel active requests. The loop
        // below admits no waiter until excess leases have naturally drained.
        resumeAvailableWaiters()
    }

    func updateLimit(_ requestedLimit: Int) {
        let newLimit = max(1, requestedLimit)
        limit = newLimit
        resumeAvailableWaiters()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeAvailableWaiters() {
        while activeLeases.count < limit, !waiters.isEmpty {
            let index = nextWaiterIndex()
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: grant(taskID: waiter.taskID))
        }
    }

    private func grant(taskID: DownloadID?) -> Lease {
        let lease = Lease(id: UUID())
        activeLeases.insert(lease.id)
        lastGrantedTaskID = taskID
        return lease
    }

    /// Prefer a different task from the one that most recently received a
    /// lease. If only that task is waiting, preserve FIFO progress instead of
    /// starving it. This is intentionally task-level fairness; workers within
    /// one task still share the same queue and adaptive controller.
    private func nextWaiterIndex() -> Int {
        guard let lastGrantedTaskID else { return 0 }
        return waiters.firstIndex { $0.taskID != lastGrantedTaskID } ?? 0
    }

    func usage() -> (active: Int, waiting: Int, limit: Int) {
        (activeLeases.count, waiters.count, limit)
    }
}

/// A process-wide reservation guard for file descriptors used by download
/// tasks. One reservation is held by each open part file and one by each HTTP
/// request for the lifetime of its response body. Waiting callers do not open
/// a file or create a socket until a reservation is available.
public actor HTTPFileDescriptorBudget {
    public struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
        fileprivate let units: Int
    }

    private var limit: Int
    private var activeUnits = 0
    private var active: [UUID: Int] = [:]
    private var waiters: [(
        id: UUID,
        taskID: DownloadID?,
        units: Int,
        continuation: CheckedContinuation<Lease, Error>
    )] = []
    private var lastGrantedTaskID: DownloadID?

    public init(limit: Int = 128) {
        self.limit = max(1, limit)
    }

    public func acquire(units requestedUnits: Int = 1, taskID: DownloadID? = nil) async throws -> Lease {
        try Task.checkCancellation()
        let units = min(max(1, requestedUnits), limit)
        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await acquireOrWait(
                waiterID: waiterID,
                units: units,
                taskID: taskID
            )
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func acquireOrWait(
        waiterID: UUID,
        units: Int,
        taskID: DownloadID?
    ) async throws -> Lease {
        if activeUnits + units <= limit {
            return grant(units: units, taskID: taskID)
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Lease, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((waiterID, taskID, units, continuation))
            }
        }
    }

    public func release(_ lease: Lease) {
        guard let units = active.removeValue(forKey: lease.id) else { return }
        activeUnits = max(0, activeUnits - units)
        resumeAvailableWaiters()
    }

    public func updateLimit(_ requestedLimit: Int) {
        limit = max(1, requestedLimit)
        resumeAvailableWaiters()
    }

    public func usage() -> (activeUnits: Int, waiting: Int, limit: Int) {
        (activeUnits, waiters.count, limit)
    }

    private func grant(units: Int, taskID: DownloadID?) -> Lease {
        let lease = Lease(id: UUID(), units: units)
        active[lease.id] = units
        activeUnits += units
        lastGrantedTaskID = taskID
        return lease
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeAvailableWaiters() {
        while !waiters.isEmpty {
            guard let index = nextWaiterIndexThatFits() else { return }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: grant(units: waiter.units, taskID: waiter.taskID))
        }
    }

    private func nextWaiterIndexThatFits() -> Int? {
        let candidates = waiters.indices.filter {
            activeUnits + waiters[$0].units <= limit
        }
        guard !candidates.isEmpty else { return nil }
        if let lastGrantedTaskID,
           let fair = candidates.first(where: { waiters[$0].taskID != lastGrantedTaskID }) {
            return fair
        }
        return candidates[0]
    }
}

/// Runs one operation while holding a file-descriptor reservation. The
/// reservation is released before the operation returns, including when the
/// operation throws or is cancelled. This avoids the delayed release that an
/// unstructured task in a `defer` block would introduce.
func withHTTPFileDescriptorLease<T: Sendable>(
    budget: HTTPFileDescriptorBudget?,
    downloadID: DownloadID?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let budget else {
        return try await operation()
    }
    let lease = try await budget.acquire(taskID: downloadID)
    do {
        let value = try await operation()
        await budget.release(lease)
        return value
    } catch {
        await budget.release(lease)
        throw error
    }
}

/// Limits only retry attempts, independently from normal range concurrency.
/// A retry waiter is scheduled fairly across task IDs so one failing download
/// cannot consume every retry slot while other tasks remain paused.
actor HTTPRetryBudget {
    struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
    }

    private var limit: Int
    private var active: Set<UUID> = []
    private var waiters: [(
        id: UUID,
        taskID: DownloadID?,
        continuation: CheckedContinuation<Lease, Error>
    )] = []
    private var lastGrantedTaskID: DownloadID?

    init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    func acquire(taskID: DownloadID? = nil) async throws -> Lease {
        try Task.checkCancellation()
        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await acquireOrWait(waiterID: waiterID, taskID: taskID)
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func acquireOrWait(waiterID: UUID, taskID: DownloadID?) async throws -> Lease {
        if active.count < limit {
            return grant(taskID: taskID)
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Lease, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((waiterID, taskID, continuation))
            }
        }
    }

    func release(_ lease: Lease) {
        guard active.remove(lease.id) != nil else { return }
        resumeAvailableWaiters()
    }

    func updateLimit(_ requestedLimit: Int) {
        limit = max(1, requestedLimit)
        resumeAvailableWaiters()
    }

    func usage() -> (active: Int, waiting: Int, limit: Int) {
        (active.count, waiters.count, limit)
    }

    private func grant(taskID: DownloadID?) -> Lease {
        let lease = Lease(id: UUID())
        active.insert(lease.id)
        lastGrantedTaskID = taskID
        return lease
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeAvailableWaiters() {
        while active.count < limit, !waiters.isEmpty {
            let index: Int
            if let lastGrantedTaskID,
               let fair = waiters.firstIndex(where: { $0.taskID != lastGrantedTaskID }) {
                index = fair
            } else {
                index = 0
            }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: grant(taskID: waiter.taskID))
        }
    }
}
