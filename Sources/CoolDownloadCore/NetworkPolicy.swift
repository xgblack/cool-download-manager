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

/// Pull-based response channel with bounded buffering. URLSession callbacks
/// cannot await a slow consumer, so the corresponding data task is suspended
/// while more than one MiB is waiting to be written.
private final class URLSessionBodyChannel: @unchecked Sendable {
    private enum Completion {
        case finished
        case failed(Error)
    }

    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bufferedBytes = 0
    private var waitingConsumer: CheckedContinuation<Data?, Error>?
    private var completion: Completion?
    private weak var task: URLSessionDataTask?
    private var taskIsSuspended = false

    private let highWaterMark = 1024 * 1024
    private let lowWaterMark = 512 * 1024

    func attach(task: URLSessionDataTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return completion != nil
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        var consumer: CheckedContinuation<Data?, Error>?
        lock.lock()
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
        lock.unlock()
        consumer?.resume(returning: data)
    }

    func finish(throwing error: Error? = nil) {
        var consumer: CheckedContinuation<Data?, Error>?
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        completion = error.map(Completion.failed) ?? .finished
        task = nil
        if chunks.isEmpty {
            consumer = waitingConsumer
            waitingConsumer = nil
        }
        lock.unlock()

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
        lock.lock()
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
        }
        lock.unlock()

        taskToCancel?.cancel()
        if shouldResumeTask {
            taskToCancel?.resume()
        }
        consumer?.resume(throwing: CancellationError())
    }

    func next() async throws -> Data? {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<Data?, Error>?
                lock.lock()
                if !chunks.isEmpty {
                    let data = chunks.removeFirst()
                    bufferedBytes -= data.count
                    if taskIsSuspended, bufferedBytes <= lowWaterMark {
                        task?.resume()
                        taskIsSuspended = false
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
                lock.unlock()
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }
}

private final class URLSessionRequestContext: @unchecked Sendable {
    private let lock = NSLock()
    private let bodyChannel = URLSessionBodyChannel()
    private var responseContinuation: CheckedContinuation<HTTPTransportResponse, Error>?
    private var responseResult: Result<HTTPTransportResponse, Error>?
    private var responseResolved = false
    private var stagedData = Data()
    private var isTerminal = false

    private let outputChunkSize = 256 * 1024

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

    func receive(response: HTTPURLResponse) {
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
            cancelBody: { channel.cancel() }
        )
        resolveResponse(.success(transportResponse))
    }

    func receive(data: Data) {
        var outputs: [Data] = []
        lock.lock()
        if !isTerminal {
            stagedData.append(data)
            while stagedData.count >= outputChunkSize {
                outputs.append(Data(stagedData.prefix(outputChunkSize)))
                stagedData.removeFirst(outputChunkSize)
            }
        }
        lock.unlock()
        for output in outputs {
            bodyChannel.send(output)
        }
    }

    func complete(error: Error?) {
        var output: Data?
        lock.lock()
        if !isTerminal {
            isTerminal = true
            if !stagedData.isEmpty {
                output = stagedData
                stagedData = Data()
            }
        }
        lock.unlock()
        if let output {
            bodyChannel.send(output)
        }
        bodyChannel.finish(throwing: error)
        resolveResponse(.failure(
            error ?? DownloadCoreError.responseMismatch("响应未返回 HTTP 标头")
        ))
    }

    func fail(_ error: Error) {
        lock.withLock {
            isTerminal = true
            stagedData.removeAll(keepingCapacity: false)
        }
        resolveResponse(.failure(error))
        bodyChannel.finish(throwing: error)
    }

    func cancel() {
        lock.withLock {
            isTerminal = true
            stagedData.removeAll(keepingCapacity: false)
        }
        resolveResponse(.failure(CancellationError()))
        bodyChannel.cancel()
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
            completionHandler(.cancel)
            return
        }
        context.receive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        context(for: dataTask)?.receive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let context = contextLock.withLock {
            contexts.removeValue(forKey: task.taskIdentifier)
        }
        context?.complete(error: error)
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
}

/// Builds URLSession requests while applying the configured macOS network
/// policy. The delegate is retained separately because URLSession does not
/// retain its delegate strongly for the lifetime of the session on all SDKs.
final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    static let minimumConnectionsPerHost = 64

    private let session: URLSession
    private let delegate: URLSessionDelegateProxy
    let configuredMaximumConnectionsPerHost: Int

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        networkConfiguration: HTTPNetworkConfiguration = .default
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
        let context = URLSessionRequestContext()
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
