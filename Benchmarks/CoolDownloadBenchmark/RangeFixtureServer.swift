import Foundation
import Network

final class RangeFixtureServer: @unchecked Sendable {
    /// Benchmark-only impairment applied after a matching Range has sent a
    /// configurable prefix. It never reaches production downloader settings.
    struct SlowRangeConfiguration: Codable, Sendable, Equatable {
        let start: Int64
        let end: Int64?
        let prefixBytes: Int64
        let bytesPerSecond: Int64
        let pauseMilliseconds: Int

        init(
            start: Int64,
            end: Int64? = nil,
            prefixBytes: Int64 = 0,
            bytesPerSecond: Int64 = 0,
            pauseMilliseconds: Int = 0
        ) {
            self.start = start
            self.end = end
            self.prefixBytes = max(0, prefixBytes)
            self.bytesPerSecond = max(0, bytesPerSecond)
            self.pauseMilliseconds = max(0, pauseMilliseconds)
        }

        func matches(_ range: ClosedRange<Int64>) -> Bool {
            guard range.lowerBound == start else { return false }
            guard let end else { return true }
            return range.upperBound == end
        }
    }

    struct RequestTiming: Codable, Sendable, Equatable {
        let rangeStart: Int64?
        let rangeEnd: Int64?
        let statusCode: Int
        let isProbe: Bool
        let failed: Bool
        let firstByteMilliseconds: Double?
        let responseMilliseconds: Double?
        let bytesSent: Int64
    }

    struct Statistics: Codable, Sendable {
        var requestCount: Int
        var dataRequestCount: Int
        var failedDataRequestCount: Int
        var maximumConcurrentDataRequests: Int
        var bytesSent: Int64
        var requestTimings: [RequestTiming]

        init(
            requestCount: Int,
            dataRequestCount: Int,
            failedDataRequestCount: Int,
            maximumConcurrentDataRequests: Int,
            bytesSent: Int64,
            requestTimings: [RequestTiming] = []
        ) {
            self.requestCount = requestCount
            self.dataRequestCount = dataRequestCount
            self.failedDataRequestCount = failedDataRequestCount
            self.maximumConcurrentDataRequests = maximumConcurrentDataRequests
            self.bytesSent = bytesSent
            self.requestTimings = requestTimings
        }

        private enum CodingKeys: String, CodingKey {
            case requestCount
            case dataRequestCount
            case failedDataRequestCount
            case maximumConcurrentDataRequests
            case bytesSent
            case requestTimings
        }

        /// Early schema-1 reports did not record failed fixture responses.
        /// Missing counters are observational and default to zero so those
        /// reports remain decodable after the schema-4 metrics were added.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
            dataRequestCount = try container.decodeIfPresent(
                Int.self,
                forKey: .dataRequestCount
            ) ?? 0
            failedDataRequestCount = try container.decodeIfPresent(
                Int.self,
                forKey: .failedDataRequestCount
            ) ?? 0
            maximumConcurrentDataRequests = try container.decodeIfPresent(
                Int.self,
                forKey: .maximumConcurrentDataRequests
            ) ?? 0
            bytesSent = try container.decodeIfPresent(Int64.self, forKey: .bytesSent) ?? 0
            requestTimings = try container.decodeIfPresent(
                [RequestTiming].self,
                forKey: .requestTimings
            ) ?? []
        }
    }

    private struct MutableStatistics {
        var requestCount = 0
        var dataRequestCount = 0
        var failedDataRequestCount = 0
        var activeDataRequests = 0
        var maximumConcurrentDataRequests = 0
        var bytesSent: Int64 = 0
        var requestTimings: [MutableRequestTiming] = []
    }

    private struct MutableRequestTiming {
        let rangeStart: Int64?
        let rangeEnd: Int64?
        let isProbe: Bool
        let startedAtNanoseconds: UInt64
        var statusCode: Int
        var failed: Bool
        var firstByteMilliseconds: Double?
        var responseMilliseconds: Double?
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
    private let slowRange: SlowRangeConfiguration?
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
        failFirstDataRequests: Int = 0,
        slowRange: SlowRangeConfiguration? = nil
    ) throws {
        guard contentLength > 0 else { throw FixtureServerError.invalidContentLength }
        guard failFirstDataRequests >= 0 else {
            throw FixtureServerError.invalidFailureCount
        }
        if let slowRange {
            guard slowRange.start >= 0,
                  slowRange.end.map({ $0 >= slowRange.start && $0 < contentLength }) ?? true else {
                throw FixtureServerError.invalidSlowRange
            }
        }
        self.contentLength = contentLength
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.firstByteDelay = .milliseconds(max(0, firstByteDelayMilliseconds))
        self.failFirstDataRequests = failFirstDataRequests
        self.slowRange = slowRange

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
                bytesSent: mutableStatistics.bytesSent,
                requestTimings: mutableStatistics.requestTimings.map { timing in
                    RequestTiming(
                        rangeStart: timing.rangeStart,
                        rangeEnd: timing.rangeEnd,
                        statusCode: timing.statusCode,
                        isProbe: timing.isProbe,
                        failed: timing.failed,
                        firstByteMilliseconds: timing.firstByteMilliseconds,
                        responseMilliseconds: timing.responseMilliseconds,
                        bytesSent: timing.bytesSent
                    )
                }
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
        let responseRange = request.range ?? 0...(contentLength - 1)
        let isProbe = responseRange.lowerBound == 0
            && responseRange.upperBound == 0
            && request.range != nil
        let timingIndex = statisticsLock.withLock { () -> Int in
            mutableStatistics.requestCount += 1
            let index = mutableStatistics.requestTimings.count
            mutableStatistics.requestTimings.append(MutableRequestTiming(
                rangeStart: request.range?.lowerBound,
                rangeEnd: request.range?.upperBound,
                isProbe: isProbe,
                startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                statusCode: request.hasInvalidRange ? 416 : 0,
                failed: request.hasInvalidRange,
                firstByteMilliseconds: nil,
                responseMilliseconds: nil
            ))
            return index
        }
        if request.hasInvalidRange {
            finishTiming(timingIndex, statusCode: 416, failed: true)
            sendError(status: 416, reason: "Range Not Satisfiable", on: connection)
            return
        }

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
                finishTiming(timingIndex, statusCode: 503, failed: true)
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
        setTimingStatus(timingIndex, statusCode: status)
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
                self.markTimingFirstByte(timingIndex)
                guard error == nil else {
                    self.finish(
                        connection,
                        countedAsDataRequest: !isProbe,
                        timingIndex: timingIndex
                    )
                    return
                }
                self.sendBody(
                    on: connection,
                    offset: responseRange.lowerBound,
                    remaining: length,
                    countedAsDataRequest: !isProbe,
                    timingIndex: timingIndex,
                    slowRange: self.slowRange?.matches(responseRange) == true
                        ? self.slowRange
                        : nil,
                    sent: 0,
                    pauseApplied: false
                )
            })
        }
    }

    private func sendBody(
        on connection: NWConnection,
        offset: Int64,
        remaining: Int64,
        countedAsDataRequest: Bool,
        timingIndex: Int,
        slowRange: SlowRangeConfiguration?,
        sent: Int64,
        pauseApplied: Bool
    ) {
        guard remaining > 0 else {
            finish(
                connection,
                countedAsDataRequest: countedAsDataRequest,
                timingIndex: timingIndex
            )
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
                self.finish(
                    connection,
                    countedAsDataRequest: countedAsDataRequest,
                    timingIndex: timingIndex
                )
                return
            }
            let nextSent = sent + Int64(count)
            self.statisticsLock.withLock {
                self.mutableStatistics.bytesSent += Int64(count)
                guard self.mutableStatistics.requestTimings.indices.contains(timingIndex) else {
                    return
                }
                self.mutableStatistics.requestTimings[timingIndex].bytesSent += Int64(count)
            }
            if remaining == Int64(count) {
                self.finish(
                    connection,
                    countedAsDataRequest: countedAsDataRequest,
                    timingIndex: timingIndex
                )
                return
            }
            let next: @Sendable () -> Void = {
                self.sendBody(
                    on: connection,
                    offset: offset + Int64(count),
                    remaining: remaining - Int64(count),
                    countedAsDataRequest: countedAsDataRequest,
                    timingIndex: timingIndex,
                    slowRange: slowRange,
                    sent: nextSent,
                    pauseApplied: pauseApplied || self.crossedSlowBoundary(
                        slowRange,
                        sent: sent,
                        nextSent: nextSent
                    )
                )
            }
            let delay: Double
            if let slowRange, nextSent >= slowRange.prefixBytes {
                let crossesBoundary = !pauseApplied && sent < slowRange.prefixBytes
                if crossesBoundary, slowRange.pauseMilliseconds > 0 {
                    delay = Double(slowRange.pauseMilliseconds) / 1_000
                } else if slowRange.bytesPerSecond > 0 {
                    delay = Double(count) / Double(slowRange.bytesPerSecond)
                } else {
                    delay = 0
                }
            } else if self.bytesPerSecond > 0 {
                delay = Double(count) / Double(self.bytesPerSecond)
            } else {
                delay = 0
            }
            if delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay, execute: next)
            } else {
                self.queue.async(execute: next)
            }
        })
    }

    private func finish(
        _ connection: NWConnection,
        countedAsDataRequest: Bool,
        timingIndex: Int
    ) {
        if countedAsDataRequest {
            statisticsLock.withLock {
                mutableStatistics.activeDataRequests = max(
                    0,
                    mutableStatistics.activeDataRequests - 1
                )
            }
        }
        finishTiming(timingIndex, statusCode: nil, failed: nil)
        connection.cancel()
    }

    private func crossedSlowBoundary(
        _ slowRange: SlowRangeConfiguration?,
        sent: Int64,
        nextSent: Int64
    ) -> Bool {
        guard let slowRange else { return false }
        return sent < slowRange.prefixBytes && nextSent >= slowRange.prefixBytes
    }

    private func setTimingStatus(_ index: Int, statusCode: Int) {
        statisticsLock.withLock {
            guard mutableStatistics.requestTimings.indices.contains(index) else { return }
            mutableStatistics.requestTimings[index].statusCode = statusCode
        }
    }

    private func markTimingFirstByte(_ index: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        statisticsLock.withLock {
            guard mutableStatistics.requestTimings.indices.contains(index) else { return }
            var timing = mutableStatistics.requestTimings[index]
            guard timing.firstByteMilliseconds == nil else { return }
            timing.firstByteMilliseconds = Double(
                now - timing.startedAtNanoseconds
            ) / 1_000_000
            mutableStatistics.requestTimings[index] = timing
        }
    }

    private func finishTiming(
        _ index: Int,
        statusCode: Int?,
        failed: Bool?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        statisticsLock.withLock {
            guard mutableStatistics.requestTimings.indices.contains(index) else { return }
            var timing = mutableStatistics.requestTimings[index]
            if let statusCode { timing.statusCode = statusCode }
            if let failed { timing.failed = failed }
            if timing.responseMilliseconds == nil {
                timing.responseMilliseconds = Double(
                    now - timing.startedAtNanoseconds
                ) / 1_000_000
            }
            mutableStatistics.requestTimings[index] = timing
        }
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
    case invalidSlowRange
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
        case .invalidSlowRange:
            return "Fixture slow Range configuration is invalid"
        }
    }
}
