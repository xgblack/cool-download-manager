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

    func release(_ item: HTTPRangeWorkItem) {
        guard inFlight.remove(item.partID) != nil else { return }
        pending.append(item)
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
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Lease, Error>)] = []

    init(limit: Int) {
        let normalized = max(1, limit)
        self.limit = normalized
    }

    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        let waiterID = UUID()
        let lease: Lease = try await withTaskCancellationHandler(operation: {
            try await self.acquireOrWait(waiterID: waiterID)
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

    private func acquireOrWait(waiterID: UUID) async throws -> Lease {
        if activeLeases.count < limit {
            let lease = Lease(id: UUID())
            activeLeases.insert(lease.id)
            return lease
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Lease, Error>) in
            // Cancellation may arrive after the initial check but before the
            // continuation is inserted. Re-check while holding actor
            // isolation so a cancelled waiter cannot be stranded.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((waiterID, continuation))
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
            let waiter = waiters.removeFirst()
            let lease = Lease(id: UUID())
            activeLeases.insert(lease.id)
            waiter.continuation.resume(returning: lease)
        }
    }

    func usage() -> (active: Int, waiting: Int, limit: Int) {
        (activeLeases.count, waiters.count, limit)
    }
}
