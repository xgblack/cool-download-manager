import Foundation
import Network

final class RangeFixtureServer: @unchecked Sendable {
    struct Statistics: Codable, Sendable {
        var requestCount: Int
        var dataRequestCount: Int
        var failedDataRequestCount: Int
        var maximumConcurrentDataRequests: Int
        var bytesSent: Int64
    }

    private struct MutableStatistics {
        var requestCount = 0
        var dataRequestCount = 0
        var failedDataRequestCount = 0
        var activeDataRequests = 0
        var maximumConcurrentDataRequests = 0
        var bytesSent: Int64 = 0
    }

    private struct ParsedRequest {
        let range: ClosedRange<Int64>?
        let hasInvalidRange: Bool
    }

    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Error>?
        private var result: Result<UInt16, Error>?

        func wait() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock { () -> Result<UInt16, Error>? in
                    if let result {
                        return result
                    }
                    self.continuation = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        }

        func resolve(_ result: Result<UInt16, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<UInt16, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private let contentLength: Int64
    private let bytesPerSecond: Int64
    private let firstByteDelay: DispatchTimeInterval
    private let failFirstDataRequests: Int
    private let listener: NWListener
    // Each connection must be able to advance independently. A serial queue
    // would turn the per-connection throttle into an unintended global
    // throttle and make parallel-range results meaningless.
    private let queue = DispatchQueue(
        label: "com.cooldownloadmanager.benchmark.fixture",
        attributes: .concurrent
    )
    private let statisticsLock = NSLock()
    private var mutableStatistics = MutableStatistics()
    private let pattern: Data
    private let chunkSize = 256 * 1024
    private let maximumRequestBytes = 64 * 1024

    init(
        contentLength: Int64,
        bytesPerSecond: Int64,
        firstByteDelayMilliseconds: Int,
        failFirstDataRequests: Int = 0
    ) throws {
        guard contentLength > 0 else { throw FixtureServerError.invalidContentLength }
        guard failFirstDataRequests >= 0 else {
            throw FixtureServerError.invalidFailureCount
        }
        self.contentLength = contentLength
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.firstByteDelay = .milliseconds(max(0, firstByteDelayMilliseconds))
        self.failFirstDataRequests = failFirstDataRequests

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters)

        var bytes = [UInt8](repeating: 0, count: chunkSize + 251)
        for index in bytes.indices {
            bytes[index] = UInt8(index % 251)
        }
        self.pattern = Data(bytes)
    }

    func start() async throws -> URL {
        let gate = StartGate()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else {
                    gate.resolve(.failure(FixtureServerError.missingPort))
                    return
                }
                gate.resolve(.success(port.rawValue))
            case .failed(let error):
                gate.resolve(.failure(error))
            case .cancelled:
                gate.resolve(.failure(FixtureServerError.cancelledBeforeReady))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        let port = try await gate.wait()
        return URL(string: "http://127.0.0.1:\(port)/fixture.bin")!
    }

    func stop() {
        listener.cancel()
    }

    func resetStatistics() {
        statisticsLock.withLock {
            mutableStatistics = MutableStatistics()
        }
    }

    func statistics() -> Statistics {
        statisticsLock.withLock {
            Statistics(
                requestCount: mutableStatistics.requestCount,
                dataRequestCount: mutableStatistics.dataRequestCount,
                failedDataRequestCount: mutableStatistics.failedDataRequestCount,
                maximumConcurrentDataRequests: mutableStatistics.maximumConcurrentDataRequests,
                bytesSent: mutableStatistics.bytesSent
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }
            guard nextBuffer.count <= maximumRequestBytes else {
                sendError(status: 413, reason: "Payload Too Large", on: connection)
                return
            }
            if let request = parseRequest(nextBuffer) {
                serve(request, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
            } else {
                receiveRequest(connection, buffer: nextBuffer)
            }
        }
    }

    private func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let headerRange = data.range(of: Data([13, 10, 13, 10])),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              requestLine.hasPrefix("GET ") else {
            return ParsedRequest(range: nil, hasInvalidRange: false)
        }

        let rangeValue = lines.dropFirst().first { line in
            line.lowercased().hasPrefix("range:")
        }?.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rangeValue else {
            return ParsedRequest(range: nil, hasInvalidRange: false)
        }
        guard rangeValue.hasPrefix("bytes=") else {
            return ParsedRequest(range: nil, hasInvalidRange: true)
        }
        let bounds = rangeValue.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              start >= 0 else {
            return ParsedRequest(range: nil, hasInvalidRange: true)
        }
        let end = bounds[1].isEmpty ? contentLength - 1 : Int64(bounds[1])
        guard let end, end >= start, end < contentLength else {
            return ParsedRequest(range: nil, hasInvalidRange: true)
        }
        return ParsedRequest(range: start...end, hasInvalidRange: false)
    }

    private func serve(_ request: ParsedRequest, on connection: NWConnection) {
        statisticsLock.withLock { mutableStatistics.requestCount += 1 }
        if request.hasInvalidRange {
            sendError(status: 416, reason: "Range Not Satisfiable", on: connection)
            return
        }

        let responseRange = request.range ?? 0...(contentLength - 1)
        let isProbe = responseRange.lowerBound == 0
            && responseRange.upperBound == 0
            && request.range != nil
        if !isProbe {
            let shouldFail = statisticsLock.withLock { () -> Bool in
                mutableStatistics.dataRequestCount += 1
                guard mutableStatistics.failedDataRequestCount < failFirstDataRequests else {
                    return false
                }
                mutableStatistics.failedDataRequestCount += 1
                return true
            }
            if shouldFail {
                sendError(status: 503, reason: "Service Unavailable", on: connection)
                return
            }
            statisticsLock.withLock {
                mutableStatistics.activeDataRequests += 1
                mutableStatistics.maximumConcurrentDataRequests = max(
                    mutableStatistics.maximumConcurrentDataRequests,
                    mutableStatistics.activeDataRequests
                )
            }
        }

        let status = request.range == nil ? 200 : 206
        let reason = status == 200 ? "OK" : "Partial Content"
        let length = responseRange.upperBound - responseRange.lowerBound + 1
        var headers = "HTTP/1.1 \(status) \(reason)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Content-Length: \(length)\r\n"
        headers += "Content-Type: application/octet-stream\r\n"
        headers += "ETag: \"benchmark-v1\"\r\n"
        headers += "Connection: close\r\n"
        if request.range != nil {
            headers += "Content-Range: bytes \(responseRange.lowerBound)-\(responseRange.upperBound)/\(contentLength)\r\n"
        }
        headers += "\r\n"
        let headerData = Data(headers.utf8)

        queue.asyncAfter(deadline: .now() + firstByteDelay) { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            connection.send(content: headerData, completion: .contentProcessed { error in
                guard error == nil else {
                    self.finish(connection, countedAsDataRequest: !isProbe)
                    return
                }
                self.sendBody(
                    on: connection,
                    offset: responseRange.lowerBound,
                    remaining: length,
                    countedAsDataRequest: !isProbe
                )
            })
        }
    }

    private func sendBody(
        on connection: NWConnection,
        offset: Int64,
        remaining: Int64,
        countedAsDataRequest: Bool
    ) {
        guard remaining > 0 else {
            finish(connection, countedAsDataRequest: countedAsDataRequest)
            return
        }
        let count = min(chunkSize, Int(remaining))
        let patternOffset = Int(offset % 251)
        let chunk = Data(pattern[patternOffset..<(patternOffset + count)])
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                self.finish(connection, countedAsDataRequest: countedAsDataRequest)
                return
            }
            self.statisticsLock.withLock {
                self.mutableStatistics.bytesSent += Int64(count)
            }
            let next: @Sendable () -> Void = {
                self.sendBody(
                    on: connection,
                    offset: offset + Int64(count),
                    remaining: remaining - Int64(count),
                    countedAsDataRequest: countedAsDataRequest
                )
            }
            if self.bytesPerSecond > 0 {
                let delay = Double(count) / Double(self.bytesPerSecond)
                self.queue.asyncAfter(deadline: .now() + delay, execute: next)
            } else {
                self.queue.async(execute: next)
            }
        })
    }

    private func finish(_ connection: NWConnection, countedAsDataRequest: Bool) {
        if countedAsDataRequest {
            statisticsLock.withLock {
                mutableStatistics.activeDataRequests = max(
                    0,
                    mutableStatistics.activeDataRequests - 1
                )
            }
        }
        connection.cancel()
    }

    private func sendError(status: Int, reason: String, on connection: NWConnection) {
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum FixtureServerError: Error, LocalizedError {
    case invalidContentLength
    case invalidFailureCount
    case missingPort
    case cancelledBeforeReady

    var errorDescription: String? {
        switch self {
        case .invalidContentLength:
            return "Fixture content length must be positive"
        case .missingPort:
            return "Loopback fixture did not publish its bound port"
        case .cancelledBeforeReady:
            return "Loopback fixture was cancelled before becoming ready"
        case .invalidFailureCount:
            return "Fixture failure count must not be negative"
        }
    }
}
