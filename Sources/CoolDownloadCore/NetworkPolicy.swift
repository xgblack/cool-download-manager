import Foundation

/// The proxy modes exposed by the historical desktop settings. `system`
/// deliberately leaves URLSession's configuration untouched so macOS can
/// apply the user's current proxy and PAC configuration.
public enum HTTPProxyMode: String, Sendable, Equatable {
    case system
    case direct
    case manual
    case pac
}

/// A small reference shared by a transport response and its URLSession
/// delegate callbacks. URLSession reports task metrics after response headers
/// arrive, so the response must expose a live value rather than a copied
/// snapshot. Only protocol-level facts are retained; URL, header and payload
/// data never enter the metrics object.
public final class HTTPTransportResponseMetrics: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let networkProtocolName: String?
        public let reusedConnection: Bool?

        public init(
            networkProtocolName: String? = nil,
            reusedConnection: Bool? = nil
        ) {
            self.networkProtocolName = networkProtocolName
            self.reusedConnection = reusedConnection
        }
    }

    private let lock = NSLock()
    private var value = Snapshot()
    private var hasUpdate = false
    private var observers: [UUID: @Sendable (Snapshot) -> Void] = [:]

    public init() {}

    public func snapshot() -> Snapshot {
        lock.withLock { value }
    }

    /// Registers a callback for the first protocol metrics update. The
    /// callback is invoked outside the lock and may run synchronously when
    /// metrics arrived before the observer was registered.
    @discardableResult
    func observe(_ handler: @escaping @Sendable (Snapshot) -> Void) -> UUID {
        let id = UUID()
        let registration = lock.withLock {
            observers[id] = handler
            return (value, hasUpdate)
        }
        if registration.1 {
            handler(registration.0)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        _ = lock.withLock {
            observers.removeValue(forKey: id)
        }
    }

    func update(
        networkProtocolName: String?,
        reusedConnection: Bool?
    ) {
        let notification = lock.withLock {
            value = Snapshot(
                networkProtocolName: networkProtocolName ?? value.networkProtocolName,
                reusedConnection: reusedConnection ?? value.reusedConnection
            )
            hasUpdate = true
            return (value, Array(observers.values))
        }
        for observer in notification.1 {
            observer(notification.0)
        }
    }
}

/// Tracks the terminal callbacks that delimit one URLSession task. Metrics
/// are best-effort, but a response context must remain registered until both
/// the task and its metrics callback have arrived so protocol observations are
/// not lost when callback order changes.
struct URLSessionRequestLifecycle: Sendable, Equatable {
    private(set) var didReceiveResponse = false
    private(set) var didComplete = false
    private(set) var didCollectMetrics = false

    mutating func markResponse() {
        didReceiveResponse = true
    }

    mutating func markMetrics() -> Bool {
        didCollectMetrics = true
        return didComplete && didReceiveResponse
    }

    mutating func markComplete() -> Bool {
        didComplete = true
        // A task without an HTTP response has no response context or body
        // stream to observe, so it can be discarded even when metrics are
        // unavailable. HTTP responses stay registered until metrics arrive.
        return didCollectMetrics || !didReceiveResponse
    }

    mutating func expireMetrics() -> Bool {
        guard didReceiveResponse, didComplete, !didCollectMetrics else { return false }
        didCollectMetrics = true
        return true
    }
}

/// Network policy used when the core creates a URLSession transport.
///
/// URLSession can apply proxy and TLS policy directly. The system resolver is
/// used for DNS because URLSession does not expose a per-session resolver on
/// macOS.
public struct HTTPNetworkConfiguration: Sendable, Equatable {
    public var proxyMode: HTTPProxyMode
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String
    public var proxyPassword: String
    public var proxyPACURL: String
    public var ignoreSSLCertificates: Bool

    public init(
        proxyMode: HTTPProxyMode = .system,
        proxyHost: String = "",
        proxyPort: Int = 8080,
        proxyUsername: String = "",
        proxyPassword: String = "",
        proxyPACURL: String = "",
        ignoreSSLCertificates: Bool = false
    ) {
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.proxyPACURL = proxyPACURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ignoreSSLCertificates = ignoreSSLCertificates
    }

    public static let `default` = Self()
}

/// Bounds response bytes retained by all URLSession body channels created by
/// one downloader. A channel still applies its one MiB high-water mark, while
/// this gate prevents many active ranges from multiplying that allowance
/// without limit. Waiting callers hold no socket or response buffer.
public actor HTTPResponseBufferBudget {
    /// One shared process budget keeps separate URLSession transports from
    /// multiplying the same response-buffer allowance.
    public static let shared = HTTPResponseBufferBudget()

    public struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
        fileprivate let capacity: Int
    }

    private let capacity: Int
    private var available: Int
    private var waiters: [(id: UUID, requested: Int, continuation: CheckedContinuation<Lease, Error>)] = []
    private var active: [UUID: Int] = [:]

    public init(capacity: Int = 16 * 1024 * 1024) {
        self.capacity = max(1, capacity)
        self.available = max(1, capacity)
    }

    public func acquire(_ requested: Int = 1024 * 1024) async throws -> Lease {
        try Task.checkCancellation()
        let amount = min(max(1, requested), capacity)
        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await acquireOrWait(id: waiterID, requested: amount)
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func acquireOrWait(id: UUID, requested: Int) async throws -> Lease {
        if available >= requested {
            return grant(requested)
        }
        return try await withCheckedThrowingContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((id: id, requested: requested, continuation: continuation))
            }
        }
    }

    public func release(_ lease: Lease) {
        guard let amount = active.removeValue(forKey: lease.id) else { return }
        available = min(capacity, available + amount)
        resumeAvailableWaiters()
    }

    public func usage() -> (activeBytes: Int, waiting: Int, capacity: Int) {
        (capacity - available, waiters.count, capacity)
    }

    private func grant(_ requested: Int) -> Lease {
        let lease = Lease(id: UUID(), capacity: requested)
        available -= requested
        active[lease.id] = requested
        return lease
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeAvailableWaiters() {
        var index = 0
        while index < waiters.count {
            guard available >= waiters[index].requested else {
                index += 1
                continue
            }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: grant(waiter.requested))
        }
    }
}

/// Pull-based response channel with bounded buffering. URLSession callbacks
/// cannot await a slow consumer, so the corresponding data task is suspended
/// while more than one MiB is waiting to be written.
private final class URLSessionBodyChannel: @unchecked Sendable {
    private enum Completion {
        case finished
        case failed(Error)
    }

    // URLSession delegate callbacks are synchronous. Suspending a data task
    // is only advisory and can leave already queued callbacks holding many
    // megabytes. A condition makes the callback wait for consumer progress,
    // providing real backpressure while keeping the queue bounded.
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var bufferedBytes = 0
    private var waitingConsumer: CheckedContinuation<Data?, Error>?
    private var completion: Completion?
    private weak var task: URLSessionDataTask?
    private var taskIsSuspended = false
    private var drainHandler: (@Sendable () -> Void)?
    private var drainNotified = false

    private let highWaterMark = 1024 * 1024
    private let lowWaterMark = 512 * 1024

    func setDrainHandler(_ handler: @escaping @Sendable () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        drainHandler = handler
    }

    func attach(task: URLSessionDataTask) {
        condition.lock()
        let shouldCancel = {
            self.task = task
            return completion != nil
        }()
        condition.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        // Contexts normally emit 256 KiB chunks. Keep this class safe for a
        // transport that delivers a larger callback as well.
        if data.count > highWaterMark {
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + highWaterMark)
                send(Data(data[offset..<end]))
                offset = end
            }
            return
        }

        var consumer: CheckedContinuation<Data?, Error>?
        condition.lock()
        while completion == nil,
              waitingConsumer == nil,
              bufferedBytes + data.count > highWaterMark {
            if !taskIsSuspended, let task {
                task.suspend()
                taskIsSuspended = true
            }
            condition.wait()
        }
        if completion == nil {
            if let waitingConsumer {
                consumer = waitingConsumer
                self.waitingConsumer = nil
            } else {
                chunks.append(data)
                bufferedBytes += data.count
                if bufferedBytes >= highWaterMark, !taskIsSuspended, let task {
                    task.suspend()
                    taskIsSuspended = true
                }
            }
        }
        condition.unlock()
        consumer?.resume(returning: data)
    }

    func finish(throwing error: Error? = nil) {
        var consumer: CheckedContinuation<Data?, Error>?
        var drained: (@Sendable () -> Void)?
        condition.lock()
        guard completion == nil else {
            condition.unlock()
            return
        }
        completion = error.map(Completion.failed) ?? .finished
        task = nil
        if chunks.isEmpty {
            consumer = waitingConsumer
            waitingConsumer = nil
            drained = markDrainedLocked()
        }
        condition.broadcast()
        condition.unlock()

        drained?()
        guard let consumer else { return }
        if let error {
            consumer.resume(throwing: error)
        } else {
            consumer.resume(returning: nil)
        }
    }

    func cancel() {
        var consumer: CheckedContinuation<Data?, Error>?
        var taskToCancel: URLSessionDataTask?
        var shouldResumeTask = false
        var drained: (@Sendable () -> Void)?
        condition.lock()
        if completion == nil || !chunks.isEmpty {
            completion = .failed(CancellationError())
            chunks.removeAll(keepingCapacity: false)
            bufferedBytes = 0
            consumer = waitingConsumer
            waitingConsumer = nil
            taskToCancel = task
            task = nil
            shouldResumeTask = taskIsSuspended
            taskIsSuspended = false
            drained = markDrainedLocked()
        }
        condition.broadcast()
        condition.unlock()

        taskToCancel?.cancel()
        if shouldResumeTask {
            taskToCancel?.resume()
        }
        drained?()
        consumer?.resume(throwing: CancellationError())
    }

    func next() async throws -> Data? {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<Data?, Error>?
                var taskToResume: URLSessionDataTask?
                var drained: (@Sendable () -> Void)?
                condition.lock()
                if !chunks.isEmpty {
                    let data = chunks.removeFirst()
                    bufferedBytes -= data.count
                    if taskIsSuspended, bufferedBytes <= lowWaterMark {
                        taskToResume = task
                        taskIsSuspended = false
                    }
                    if bufferedBytes == 0, completion != nil {
                        drained = markDrainedLocked()
                    }
                    immediate = .success(data)
                } else if let completion {
                    switch completion {
                    case .finished:
                        immediate = .success(nil)
                    case .failed(let error):
                        immediate = .failure(error)
                    }
                } else if waitingConsumer == nil {
                    waitingConsumer = continuation
                } else {
                    immediate = .failure(
                        DownloadCoreError.responseMismatch("响应正文不能被并发读取")
                    )
                }
                condition.broadcast()
                condition.unlock()
                taskToResume?.resume()
                drained?()
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func markDrainedLocked() -> (@Sendable () -> Void)? {
        guard !drainNotified else { return nil }
        drainNotified = true
        return drainHandler
    }
}

private final class URLSessionRequestContext: @unchecked Sendable {
    private let lock = NSLock()
    private let bodyChannel = URLSessionBodyChannel()
    private let responseBufferBudget: HTTPResponseBufferBudget
    private var responseBufferLease: HTTPResponseBufferBudget.Lease?
    let networkMetrics = HTTPTransportResponseMetrics()
    private var responseContinuation: CheckedContinuation<HTTPTransportResponse, Error>?
    private var responseResult: Result<HTTPTransportResponse, Error>?
    private var responseResolved = false
    private var isTerminal = false
    private var lifecycle = URLSessionRequestLifecycle()

    private let outputChunkSize = 256 * 1024

    init(
        responseBufferBudget: HTTPResponseBufferBudget,
        responseBufferLease: HTTPResponseBufferBudget.Lease
    ) {
        self.responseBufferBudget = responseBufferBudget
        self.responseBufferLease = responseBufferLease
        self.bodyChannel.setDrainHandler { [weak self] in
            self?.releaseResponseBuffer()
        }
    }

    func attach(task: URLSessionDataTask) {
        bodyChannel.attach(task: task)
    }

    func waitForResponse() async throws -> HTTPTransportResponse {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<HTTPTransportResponse, Error>?
                lock.lock()
                if let responseResult {
                    immediate = responseResult
                    self.responseResult = nil
                } else if responseContinuation == nil, !responseResolved {
                    responseContinuation = continuation
                } else {
                    immediate = .failure(
                        DownloadCoreError.responseMismatch("响应标头被重复读取")
                    )
                }
                lock.unlock()
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func receive(response: HTTPURLResponse) -> Bool {
        lock.withLock {
            lifecycle.markResponse()
        }
        let channel = bodyChannel
        let body = AsyncThrowingStream<Data, Error>(unfolding: {
            try await channel.next()
        })
        let transportResponse = HTTPTransportResponse(
            statusCode: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            },
            body: body,
            networkMetrics: networkMetrics,
            cancelBody: { [self] in cancelBody() }
        )
        resolveResponse(.success(transportResponse))
        return lock.withLock {
            lifecycle.didComplete && lifecycle.didCollectMetrics
        }
    }

    /// Returns true when both terminal callbacks have arrived and the
    /// delegate can safely discard this context. URLSession may deliver task
    /// metrics before or after `didCompleteWithError`; removing the context on
    /// either callback alone loses protocol observations or leaves the body
    /// stream without its completion signal.
    func receive(metrics: URLSessionTaskMetrics) -> Bool {
        if let transaction = metrics.transactionMetrics.last {
            networkMetrics.update(
                networkProtocolName: transaction.networkProtocolName,
                reusedConnection: transaction.isReusedConnection
            )
        }
        return lock.withLock { lifecycle.markMetrics() }
    }

    func expireMetrics() -> Bool {
        lock.withLock { lifecycle.expireMetrics() }
    }

    func receive(data: Data) {
        guard !data.isEmpty else { return }
        let acceptsData = lock.withLock { !isTerminal }
        guard acceptsData else { return }

        // URLSession may deliver a callback larger than the consumer's
        // bounded channel. Split it incrementally instead of appending to a
        // staging Data and repeatedly removeFirst(), which copies the
        // remainder and can make allocations grow with the whole download.
        if data.count <= outputChunkSize {
            bodyChannel.send(data)
            return
        }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + outputChunkSize)
            bodyChannel.send(Data(data[offset..<end]))
            offset = end
        }
    }

    func complete(error: Error?) -> Bool {
        let shouldRemove: Bool
        lock.lock()
        shouldRemove = lifecycle.markComplete()
        if !isTerminal {
            isTerminal = true
        }
        lock.unlock()
        bodyChannel.finish(throwing: error)
        resolveResponse(.failure(
            error ?? DownloadCoreError.responseMismatch("响应未返回 HTTP 标头")
        ))
        return shouldRemove
    }

    func fail(_ error: Error) {
        lock.withLock {
            isTerminal = true
        }
        resolveResponse(.failure(error))
        bodyChannel.finish(throwing: error)
    }

    func cancel() {
        lock.withLock {
            isTerminal = true
        }
        resolveResponse(.failure(CancellationError()))
        bodyChannel.cancel()
    }

    func cancelBody() {
        bodyChannel.cancel()
    }

    private func releaseResponseBuffer() {
        let lease: HTTPResponseBufferBudget.Lease? = lock.withLock {
            let lease = responseBufferLease
            responseBufferLease = nil
            return lease
        }
        guard let lease else { return }
        Task { await responseBufferBudget.release(lease) }
    }

    private func resolveResponse(_ result: Result<HTTPTransportResponse, Error>) {
        var continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        lock.lock()
        if !responseResolved {
            responseResolved = true
            if let responseContinuation {
                continuation = responseContinuation
                self.responseContinuation = nil
            } else {
                responseResult = result
            }
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// URLSession delegate for streaming response bodies plus the authentication
/// cases that cannot be represented by request headers.
private final class URLSessionDelegateProxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let metricsCleanupDelay: Duration = .seconds(5)
    private let configuration: HTTPNetworkConfiguration
    private let contextLock = NSLock()
    private var contexts: [Int: URLSessionRequestContext] = [:]

    init(configuration: HTTPNetworkConfiguration) {
        self.configuration = configuration
    }

    func register(_ context: URLSessionRequestContext, for task: URLSessionDataTask) {
        contextLock.withLock {
            contexts[task.taskIdentifier] = context
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = context(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            context.fail(DownloadCoreError.responseMismatch("响应不是 HTTP"))
            removeContext(for: dataTask)
            completionHandler(.cancel)
            return
        }
        if context.receive(response: response) {
            removeContext(for: dataTask)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        context(for: dataTask)?.receive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = context(for: task) else { return }
        if context.complete(error: error) {
            removeContext(for: task)
        } else {
            scheduleMetricsCleanup(for: task.taskIdentifier, context: context)
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        if let context = context(for: task), context.receive(metrics: metrics) {
            removeContext(for: task)
        }
    }

    private func respond(
        to challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let method = protectionSpace.authenticationMethod

        let isProxyAuthentication = protectionSpace.isProxy()
            || method == "NSURLAuthenticationMethodHTTPProxy"
            || method == "NSURLAuthenticationMethodHTTPSProxy"
        if isProxyAuthentication,
           !configuration.proxyUsername.isEmpty,
           challenge.previousFailureCount == 0 {
            completionHandler(
                .useCredential,
                URLCredential(
                    user: configuration.proxyUsername,
                    password: configuration.proxyPassword,
                    persistence: .none
                )
            )
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
           configuration.ignoreSSLCertificates,
           let trust = protectionSpace.serverTrust,
           challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private func context(for task: URLSessionTask) -> URLSessionRequestContext? {
        contextLock.withLock { contexts[task.taskIdentifier] }
    }

    private func removeContext(for task: URLSessionTask) {
        _ = contextLock.withLock {
            contexts.removeValue(forKey: task.taskIdentifier)
        }
    }

    private func context(for taskIdentifier: Int) -> URLSessionRequestContext? {
        contextLock.withLock { contexts[taskIdentifier] }
    }

    private func removeContext(for taskIdentifier: Int, ifSame context: URLSessionRequestContext) {
        contextLock.withLock {
            guard let current = contexts[taskIdentifier], current === context else { return }
            contexts.removeValue(forKey: taskIdentifier)
        }
    }

    /// URLSession normally reports task metrics immediately after completion,
    /// but the delegate contract does not make that callback a hard
    /// requirement. Keep a completed HTTP context briefly for a late metrics
    /// callback, then release the dictionary entry so a missing callback
    /// cannot retain one context per request forever.
    private func scheduleMetricsCleanup(
        for taskIdentifier: Int,
        context: URLSessionRequestContext
    ) {
        Task { [weak self, weak context] in
            do {
                try await Task.sleep(for: Self.metricsCleanupDelay)
            } catch {
                return
            }
            guard let self, let context,
                  let current = self.context(for: taskIdentifier),
                  current === context,
                  context.expireMetrics() else {
                return
            }
            self.removeContext(for: taskIdentifier, ifSame: context)
        }
    }
}

/// Builds URLSession requests while applying the configured macOS network
/// policy. The delegate is retained separately because URLSession does not
/// retain its delegate strongly for the lifetime of the session on all SDKs.
final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    static let minimumConnectionsPerHost = 64
    static let responseBufferReservation = 1024 * 1024

    private let session: URLSession
    private let delegate: URLSessionDelegateProxy
    private let responseBufferBudget: HTTPResponseBufferBudget
    let configuredMaximumConnectionsPerHost: Int

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        networkConfiguration: HTTPNetworkConfiguration = .default,
        responseBufferBudget: HTTPResponseBufferBudget = .shared
    ) {
        let networkConfiguration = networkConfiguration
        let sessionConfiguration = configuration
        Self.applyProxy(networkConfiguration, to: sessionConfiguration)
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.httpMaximumConnectionsPerHost = max(
            sessionConfiguration.httpMaximumConnectionsPerHost,
            Self.minimumConnectionsPerHost
        )
        configuredMaximumConnectionsPerHost = sessionConfiguration.httpMaximumConnectionsPerHost
        let delegate = URLSessionDelegateProxy(configuration: networkConfiguration)
        self.delegate = delegate
        self.responseBufferBudget = responseBufferBudget
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let responseBufferLease = try await responseBufferBudget.acquire(Self.responseBufferReservation)
        let context = URLSessionRequestContext(
            responseBufferBudget: responseBufferBudget,
            responseBufferLease: responseBufferLease
        )
        let task = session.dataTask(with: request)
        context.attach(task: task)
        delegate.register(context, for: task)
        task.resume()
        do {
            return try await context.waitForResponse()
        } catch {
            context.cancel()
            throw error
        }
    }

    private static func applyProxy(
        _ configuration: HTTPNetworkConfiguration,
        to sessionConfiguration: URLSessionConfiguration
    ) {
        switch configuration.proxyMode {
        case .system:
            // An untouched URLSession configuration follows macOS system
            // proxy and PAC settings.
            break
        case .direct:
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "FTPEnable": 0,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0
            ]
        case .manual:
            guard !configuration.proxyHost.isEmpty else { return }
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": configuration.proxyHost,
                "HTTPPort": configuration.proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": configuration.proxyHost,
                "HTTPSPort": configuration.proxyPort,
                "ProxyAutoConfigEnable": 0
            ]
        case .pac:
            guard !configuration.proxyPACURL.isEmpty else { return }
            sessionConfiguration.connectionProxyDictionary = [
                "ProxyAutoConfigEnable": 1,
                "ProxyAutoConfigURLString": configuration.proxyPACURL
            ]
        }
    }
}

enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
