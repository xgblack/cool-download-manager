import Foundation

public struct HTTPDownloadResult: Sendable {
    public let statusCode: Int
    public let startOffset: Int64
    public let totalBytes: Int64?
    public let bytesWritten: Int64
    public let etag: String?
    public let lastModified: String?
    public let fileName: String?

    public init(
        statusCode: Int,
        startOffset: Int64,
        totalBytes: Int64?,
        bytesWritten: Int64 = 0,
        etag: String? = nil,
        lastModified: String? = nil,
        fileName: String? = nil
    ) {
        self.statusCode = statusCode
        self.startOffset = startOffset
        self.totalBytes = totalBytes
        self.bytesWritten = bytesWritten
        self.etag = etag
        self.lastModified = lastModified
        self.fileName = fileName
    }
}

public struct HTTPResourceMetadata: Sendable, Equatable {
    public let totalBytes: Int64?
    public let supportsRanges: Bool
    public let etag: String?
    public let lastModified: String?
    public let fileName: String?

    public init(
        totalBytes: Int64?,
        supportsRanges: Bool,
        etag: String? = nil,
        lastModified: String? = nil,
        fileName: String? = nil
    ) {
        self.totalBytes = totalBytes
        self.supportsRanges = supportsRanges
        self.etag = etag
        self.lastModified = lastModified
        self.fileName = fileName
    }
}

public struct HTTPTransportResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>
    /// Live URLSession protocol metrics. The value may be populated after the
    /// response is returned and is therefore intentionally reference-backed.
    public let networkMetrics: HTTPTransportResponseMetrics
    private let cancelBodyHandler: @Sendable () -> Void

    public init(
        statusCode: Int,
        headers: [String: String],
        body: AsyncThrowingStream<Data, Error>,
        networkMetrics: HTTPTransportResponseMetrics = HTTPTransportResponseMetrics(),
        cancelBody: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.networkMetrics = networkMetrics
        self.cancelBodyHandler = cancelBody
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func cancelBody() {
        cancelBodyHandler()
    }
}

public protocol HTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> HTTPTransportResponse
}

/// Reports the lifetime of one active HTTP data request. The callback runs
/// after any file-descriptor reservation is acquired and before the transport
/// starts, then runs again after the response body has been fully consumed or
/// the request fails.
public typealias HTTPRequestActivityHandler = @Sendable (_ active: Bool) async -> Void

func withHTTPRequestActivity<T: Sendable>(
    _ activity: HTTPRequestActivityHandler?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let activity else {
        return try await operation()
    }
    await activity(true)
    do {
        let value = try await operation()
        await activity(false)
        return value
    } catch {
        await activity(false)
        throw error
    }
}

public final class HTTPDownloader: @unchecked Sendable {
    private let transport: any HTTPTransport
    private let defaultMetrics: any DownloadMetricsSink
    private let bufferSize = 64 * 1024

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        networkConfiguration: HTTPNetworkConfiguration = .default,
        metrics: any DownloadMetricsSink = NoopDownloadMetricsSink()
    ) {
        self.transport = URLSessionHTTPTransport(
            configuration: configuration,
            networkConfiguration: networkConfiguration
        )
        self.defaultMetrics = metrics
    }

    public init(
        transport: any HTTPTransport,
        metrics: any DownloadMetricsSink = NoopDownloadMetricsSink()
    ) {
        self.transport = transport
        self.defaultMetrics = metrics
    }

    public func probe(
        source: DownloadSource,
        metrics: (any DownloadMetricsSink)? = nil,
        downloadID: DownloadID? = nil,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HTTPResourceMetadata {
        let url = try validatedURL(source.link)
        let sink = metrics ?? defaultMetrics
        do {
            return try await probeRange(
                source: source,
                url: url,
                metrics: sink,
                downloadID: downloadID,
                fileDescriptorBudget: fileDescriptorBudget,
                activity: activity
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DownloadCoreError {
            switch error {
            case .responseMismatch:
                // A non-conforming range response can still have a usable
                // ordinary GET representation.
                return try await probeSingleConnection(
                    source: source,
                    url: url,
                    metrics: sink,
                    downloadID: downloadID,
                    fileDescriptorBudget: fileDescriptorBudget,
                    activity: activity
                )
            case .httpStatus(let status) where status == 405 || status == 416 || status == 501:
                // These statuses mean the range form is unavailable. Retry
                // the metadata request without a Range header.
                return try await probeSingleConnection(
                    source: source,
                    url: url,
                    metrics: sink,
                    downloadID: downloadID,
                    fileDescriptorBudget: fileDescriptorBudget,
                    activity: activity
                )
            default:
                throw error
            }
        } catch {
            try Task.checkCancellation()
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            // Transport failures are not evidence that Range is unsupported.
            // Propagate them instead of issuing a second request that can
            // duplicate a timeout or hide the original network error.
            throw error
        }
    }

    public func download(
        source: DownloadSource,
        offset: Int64,
        writer: PartFileWriter,
        progress: (@Sendable (Int64) async -> Void)? = nil,
        expectedETag: String? = nil,
        expectedLastModified: String? = nil,
        rateLimiter: DownloadRateLimiter? = nil,
        metrics: (any DownloadMetricsSink)? = nil,
        downloadID: DownloadID? = nil,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HTTPDownloadResult {
        let url = try validatedURL(source.link)
        let sink = metrics ?? defaultMetrics
        let tracker = sink.isEnabled ? HTTPMetricTracker(
            sink: sink,
            downloadID: downloadID,
            kind: .ordinaryGet
        ) : nil
        defer { tracker?.finish() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        applyHeaders(source.headers, to: &request)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let validator = expectedETag ?? expectedLastModified {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }

        let preparedRequest = request
        return try await withHTTPFileDescriptorLease(
            budget: fileDescriptorBudget,
            downloadID: downloadID
        ) { [self] in
            try await withHTTPRequestActivity(activity) {
                let response = try await self.transport.response(for: preparedRequest)
            tracker?.markResponse(response)
            defer { response.cancelBody() }
            let statusCode = response.statusCode
            guard (200...299).contains(statusCode) else {
                throw DownloadCoreError.httpStatus(statusCode)
            }
            let responseContentLength = try Self.validatedContentLength(response.header("Content-Length"))

            let isResume = offset > 0
            var actualOffset = offset
            var contentRangeTotal: Int64?
            if isResume && statusCode == 200 {
                try self.validateValidators(
                    response,
                    expectedETag: expectedETag,
                    expectedLastModified: expectedLastModified
                )
                try await writer.truncate()
                actualOffset = 0
            } else if isResume && statusCode != 206 {
                throw DownloadCoreError.resumeNotSupported
            }

            if statusCode == 206 {
                try self.validateValidators(
                    response,
                    expectedETag: expectedETag,
                    expectedLastModified: expectedLastModified
                )
                guard let contentRange = response.header("Content-Range"),
                      let parsedRange = Self.parseContentRange(contentRange) else {
                    throw DownloadCoreError.responseMismatch(
                        "206 响应未包含有效的 Content-Range"
                    )
                }
                guard parsedRange.start == offset else {
                    throw DownloadCoreError.responseMismatch(
                        "Content-Range 起始位置为 \(parsedRange.start)，应为 \(offset)"
                    )
                }
                if let total = parsedRange.total {
                    let minimumTotal = parsedRange.end.map({ $0 + 1 }) ?? parsedRange.start
                    guard total >= minimumTotal else {
                        throw DownloadCoreError.responseMismatch("Content-Range 总大小小于起始位置")
                    }
                    contentRangeTotal = total
                }
                if let end = parsedRange.end,
                   let contentLength = responseContentLength,
                   contentLength != end - parsedRange.start + 1 {
                    throw DownloadCoreError.responseMismatch(
                        "Content-Length 与 Content-Range 不匹配"
                    )
                }
            }

            let expectedBodyLength: Int64? = responseContentLength
                ?? (statusCode == 206 ? Self.contentRangeLength(response.header("Content-Range")) : nil)
            let originalOffset = actualOffset

            var buffer = Data()
            buffer.reserveCapacity(self.bufferSize)
            var writtenBytes = actualOffset
            var responseBodyBytes: Int64 = 0
            for try await chunk in response.body {
                try Task.checkCancellation()
                if !chunk.isEmpty {
                    tracker?.markFirstByteIfNeeded()
                    tracker?.addBytes(Int64(chunk.count))
                }
                try await rateLimiter?.consume(chunk.count)
                if let expectedBodyLength,
                   responseBodyBytes + Int64(chunk.count) > expectedBodyLength {
                    let remaining = max(0, expectedBodyLength - responseBodyBytes)
                    let allowed = Int(min(remaining, Int64(chunk.count)))
                    if allowed > 0 {
                        let output = Data(chunk.prefix(allowed))
                        try await writer.append(output)
                        writtenBytes += Int64(output.count)
                        responseBodyBytes += Int64(output.count)
                    }
                    try await writer.truncate(to: originalOffset)
                    throw DownloadCoreError.responseMismatch(
                        "接收的数据超过预期大小 \(expectedBodyLength) 字节"
                    )
                }
                responseBodyBytes += Int64(chunk.count)
                if chunk.count >= self.bufferSize {
                    if !buffer.isEmpty {
                        let output = buffer
                        buffer.removeAll(keepingCapacity: true)
                        try await writer.append(output)
                        writtenBytes += Int64(output.count)
                        await progress?(writtenBytes)
                    }
                    try await writer.append(chunk)
                    writtenBytes += Int64(chunk.count)
                    await progress?(writtenBytes)
                } else {
                    buffer.append(chunk)
                    if buffer.count >= self.bufferSize {
                        let output = buffer
                        buffer.removeAll(keepingCapacity: true)
                        try await writer.append(output)
                        writtenBytes += Int64(output.count)
                        await progress?(writtenBytes)
                    }
                }
            }
            if !buffer.isEmpty {
                try await writer.append(buffer)
                writtenBytes += Int64(buffer.count)
                await progress?(writtenBytes)
            }

            if let expectedBodyLength, responseBodyBytes != expectedBodyLength {
                try await writer.truncate(to: originalOffset)
                throw DownloadCoreError.responseMismatch(
                    "实际接收 \(responseBodyBytes) 字节，应为 \(expectedBodyLength) 字节"
                )
            }

            let responseLength = responseContentLength
            let totalBytes = contentRangeTotal ?? responseLength.map { actualOffset + $0 }
            return HTTPDownloadResult(
                statusCode: statusCode,
                startOffset: actualOffset,
                totalBytes: totalBytes,
                bytesWritten: responseBodyBytes,
                etag: response.header("ETag"),
                lastModified: response.header("Last-Modified"),
                fileName: DownloadFileNameResolver.fromContentDisposition(
                    response.header("Content-Disposition")
                )
            )
            }
        }
    }

    public func downloadRange(
        source: DownloadSource,
        start: Int64,
        end: Int64,
        writer: PartFileWriter,
        expectedETag: String? = nil,
        expectedLastModified: String? = nil,
        progress: (@Sendable (Int64) async -> Void)? = nil,
        rateLimiter: DownloadRateLimiter? = nil,
        metrics: (any DownloadMetricsSink)? = nil,
        downloadID: DownloadID? = nil,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HTTPDownloadResult {
        guard start >= 0, end >= start else {
            throw DownloadCoreError.responseMismatch("请求的字节范围无效")
        }
        let url = try validatedURL(source.link)
        let sink = metrics ?? defaultMetrics
        let tracker = sink.isEnabled ? HTTPMetricTracker(
            sink: sink,
            downloadID: downloadID,
            kind: .range
        ) : nil
        defer { tracker?.finish() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        applyHeaders(source.headers, to: &request)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        if let validator = expectedETag ?? expectedLastModified {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        let preparedRequest = request
        return try await withHTTPFileDescriptorLease(
            budget: fileDescriptorBudget,
            downloadID: downloadID
        ) { [self] in
            try await withHTTPRequestActivity(activity) {
                let response = try await self.transport.response(for: preparedRequest)
            tracker?.markResponse(response)
            defer { response.cancelBody() }
            guard response.statusCode == 206 else {
                if response.statusCode == 200 {
                    throw DownloadCoreError.resumeNotSupported
                }
                throw DownloadCoreError.httpStatus(response.statusCode)
            }
            try self.validateValidators(
                response,
                expectedETag: expectedETag,
                expectedLastModified: expectedLastModified
            )
            guard let contentRange = response.header("Content-Range"),
                  let parsedRange = Self.parseContentRange(contentRange),
                  parsedRange.start == start,
                  parsedRange.end == end else {
                throw DownloadCoreError.responseMismatch(
                    "Content-Range 与请求的 bytes=\(start)-\(end) 不匹配"
                )
            }
            let expectedBodyLength = end - start + 1
            let responseContentLength = try Self.validatedContentLength(response.header("Content-Length"))
            if let contentLength = responseContentLength,
               contentLength != expectedBodyLength {
                throw DownloadCoreError.responseMismatch("Content-Length 与请求的范围不匹配")
            }
            if let total = parsedRange.total, total < end + 1 {
                throw DownloadCoreError.responseMismatch("Content-Range 总大小小于请求的范围")
            }

            var written: Int64 = 0
            for try await chunk in response.body {
                try Task.checkCancellation()
                if !chunk.isEmpty {
                    tracker?.markFirstByteIfNeeded()
                    tracker?.addBytes(Int64(chunk.count))
                }
                try await rateLimiter?.consume(chunk.count)
                let chunkLength = Int64(chunk.count)
                guard written + chunkLength <= expectedBodyLength else {
                    throw DownloadCoreError.responseMismatch(
                        "接收的数据超过请求范围的预期大小 \(expectedBodyLength) 字节"
                    )
                }
                try await writer.write(chunk, at: start + written)
                written += chunkLength
                await progress?(written)
            }
            guard written == expectedBodyLength else {
                throw DownloadCoreError.responseMismatch(
                    "请求范围实际接收 \(written) 字节，应为 \(expectedBodyLength) 字节"
                )
            }
            return HTTPDownloadResult(
                statusCode: response.statusCode,
                startOffset: start,
                totalBytes: parsedRange.total,
                bytesWritten: written,
                etag: response.header("ETag"),
                lastModified: response.header("Last-Modified"),
                fileName: DownloadFileNameResolver.fromContentDisposition(
                    response.header("Content-Disposition")
                )
            )
            }
        }
    }

    private func validatedURL(_ link: String) throws -> URL {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadCoreError.invalidURL(link)
        }
        return url
    }

    private func applyHeaders(_ headers: [String: String]?, to request: inout URLRequest) {
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        // URLSession transparently decodes gzip/deflate responses. A download
        // manager must persist the exact representation advertised by the
        // server; otherwise Content-Length and byte ranges describe compressed
        // bytes while the delegate delivers decompressed bytes. Request the
        // identity representation for every download and probe.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    private func probeRange(
        source: DownloadSource,
        url: URL,
        metrics: any DownloadMetricsSink,
        downloadID: DownloadID?,
        fileDescriptorBudget: HTTPFileDescriptorBudget?,
        activity: HTTPRequestActivityHandler?
    ) async throws -> HTTPResourceMetadata {
        let tracker = metrics.isEnabled ? HTTPMetricTracker(
            sink: metrics,
            downloadID: downloadID,
            kind: .probeRange
        ) : nil
        defer { tracker?.finish() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        applyHeaders(source.headers, to: &request)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let preparedRequest = request
        return try await withHTTPFileDescriptorLease(
            budget: fileDescriptorBudget,
            downloadID: downloadID
        ) { [self] in
            try await withHTTPRequestActivity(activity) {
                let response = try await self.transport.response(for: preparedRequest)
            tracker?.markResponse(response)
            defer { response.cancelBody() }
            guard (200...299).contains(response.statusCode) else {
                throw DownloadCoreError.httpStatus(response.statusCode)
            }

            let etag = response.header("ETag")
            let lastModified = response.header("Last-Modified")
            let fileName = DownloadFileNameResolver.fromContentDisposition(
                response.header("Content-Disposition")
            )
            let contentLength = try Self.validatedContentLength(response.header("Content-Length"))

            if response.statusCode == 206 {
                guard let contentRange = response.header("Content-Range"),
                      let parsed = Self.parseContentRange(contentRange),
                      parsed.start == 0,
                      parsed.end == 0,
                      let total = parsed.total else {
                    throw DownloadCoreError.responseMismatch(
                        "Range 探测响应未包含有效的 Content-Range"
                    )
                }
                guard contentLength.map({ $0 == 1 }) ?? true else {
                    throw DownloadCoreError.responseMismatch("Range 探测响应长度不是 1 字节")
                }
                let bodyLength = try await self.drain(response.body) { bytes in
                    if bytes > 0 {
                        tracker?.markFirstByteIfNeeded()
                        tracker?.addBytes(bytes)
                    }
                }
                guard bodyLength == 1 else {
                    throw DownloadCoreError.responseMismatch("Range 探测实际接收 \(bodyLength) 字节，应为 1 字节")
                }
                return HTTPResourceMetadata(
                    totalBytes: total,
                    supportsRanges: true,
                    etag: etag,
                    lastModified: lastModified,
                    fileName: fileName
                )
            }

            return HTTPResourceMetadata(
                totalBytes: contentLength,
                supportsRanges: false,
                etag: etag,
                lastModified: lastModified,
                fileName: fileName
            )
            }
        }
    }

    private func probeSingleConnection(
        source: DownloadSource,
        url: URL,
        metrics: any DownloadMetricsSink,
        downloadID: DownloadID?,
        fileDescriptorBudget: HTTPFileDescriptorBudget?,
        activity: HTTPRequestActivityHandler?
    ) async throws -> HTTPResourceMetadata {
        let tracker = metrics.isEnabled ? HTTPMetricTracker(
            sink: metrics,
            downloadID: downloadID,
            kind: .probeFallback
        ) : nil
        defer { tracker?.finish() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        applyHeaders(source.headers, to: &request)

        let preparedRequest = request
        return try await withHTTPFileDescriptorLease(
            budget: fileDescriptorBudget,
            downloadID: downloadID
        ) { [self] in
            try await withHTTPRequestActivity(activity) {
                let response = try await self.transport.response(for: preparedRequest)
            tracker?.markResponse(response)
            defer { response.cancelBody() }
            guard (200...299).contains(response.statusCode) else {
                throw DownloadCoreError.httpStatus(response.statusCode)
            }
            return HTTPResourceMetadata(
                totalBytes: try Self.validatedContentLength(response.header("Content-Length")),
                supportsRanges: false,
                etag: response.header("ETag"),
                lastModified: response.header("Last-Modified"),
                fileName: DownloadFileNameResolver.fromContentDisposition(
                    response.header("Content-Disposition")
                )
            )
            }
        }
    }

    private func validateValidators(
        _ response: HTTPTransportResponse,
        expectedETag: String?,
        expectedLastModified: String?
    ) throws {
        if let expectedETag {
            guard response.header("ETag") == expectedETag else {
                throw DownloadCoreError.resourceChanged
            }
        }
        if expectedETag == nil, let expectedLastModified {
            guard response.header("Last-Modified") == expectedLastModified else {
                throw DownloadCoreError.resourceChanged
            }
        }
    }

    private func drain(
        _ body: AsyncThrowingStream<Data, Error>,
        onBytes: ((Int64) -> Void)? = nil
    ) async throws -> Int64 {
        var count: Int64 = 0
        for try await chunk in body {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            onBytes?(Int64(chunk.count))
        }
        return count
    }

    private struct ContentRange {
        let start: Int64
        let end: Int64?
        let total: Int64?
    }

    private static func parseContentRange(_ value: String) -> ContentRange? {
        let components = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rangeComponent = components.first else { return nil }
        let range = rangeComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard range.hasPrefix("bytes ") else { return nil }
        let bounds = range.dropFirst("bytes ".count)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]), start >= 0 else { return nil }
        let end = bounds.count > 1 && bounds[1] != "*" ? Int64(bounds[1]) : nil
        guard end == nil || end! >= start else { return nil }
        let total = components.count > 1 && components[1] != "*" ? Int64(components[1]) : nil
        guard total == nil || total! >= (end.map { $0 + 1 } ?? start) else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    private static func contentRangeLength(_ value: String?) -> Int64? {
        guard let value, let range = parseContentRange(value), let end = range.end else {
            return nil
        }
        return end - range.start + 1
    }

    private static func nonNegativeInteger(_ value: String?) -> Int64? {
        guard let value, let integer = Int64(value), integer >= 0 else { return nil }
        return integer
    }

    private static func validatedContentLength(_ value: String?) throws -> Int64? {
        guard let value else { return nil }
        guard let integer = nonNegativeInteger(value) else {
            throw DownloadCoreError.responseMismatch("Content-Length 不是非负整数")
        }
        return integer
    }
}

private final class HTTPMetricTracker: @unchecked Sendable {
    private static let protocolMetricsGracePeriod: Duration = .seconds(1)
    private let lock = NSLock()
    private let sink: any DownloadMetricsSink
    private let downloadID: DownloadID?
    private let requestID = UUID()
    private let kind: HTTPRequestMetricKind
    private let startedAt = downloadMetricsNow()
    private var statusCode: Int?
    private var networkMetrics: HTTPTransportResponseMetrics?
    private var receivedFirstByte = false
    private var bytes: Int64 = 0
    private var finished = false
    private var protocolRecorded = false
    private var metricsObserverID: UUID?
    private var protocolObservationTask: Task<Void, Never>?

    init(
        sink: any DownloadMetricsSink,
        downloadID: DownloadID?,
        kind: HTTPRequestMetricKind
    ) {
        self.sink = sink
        self.downloadID = downloadID
        self.kind = kind
        sink.record(.httpRequestStarted(
            downloadID: downloadID,
            requestID: requestID,
            kind: kind,
            timestampNanoseconds: startedAt
        ))
    }

    func markResponse(_ response: HTTPTransportResponse) {
        let networkMetrics = lock.withLock {
            self.statusCode = response.statusCode
            self.networkMetrics = response.networkMetrics
            return response.networkMetrics
        }
        let observerID = networkMetrics.observe { [weak self] snapshot in
            self?.recordProtocol(snapshot)
        }
        let registrationState = lock.withLock {
            guard !protocolRecorded else { return (true, false) }
            metricsObserverID = observerID
            return (false, finished)
        }
        if registrationState.0 {
            networkMetrics.removeObserver(observerID)
        }
        // `response(for:)` returns after the HTTP response has arrived. Record
        // TTFB here so metadata probes that intentionally cancel their bodies
        // remain visible in the same metric as streamed downloads.
        markFirstByteIfNeeded()
        if registrationState.1 {
            armProtocolObservationIfNeeded()
        }
    }

    func markFirstByteIfNeeded() {
        let shouldRecord = lock.withLock { () -> Bool in
            guard !receivedFirstByte else { return false }
            receivedFirstByte = true
            return true
        }
        guard shouldRecord else { return }
        sink.record(.httpResponseFirstByte(
            downloadID: downloadID,
            requestID: requestID,
            latencyNanoseconds: downloadMetricsElapsed(since: startedAt)
        ))
    }

    func addBytes(_ additionalBytes: Int64) {
        guard additionalBytes > 0 else { return }
        lock.withLock {
            bytes += additionalBytes
        }
    }

    func finish() {
        let result = lock.withLock {
            () -> (statusCode: Int?, bytes: Int64, networkMetrics: HTTPTransportResponseMetrics?)? in
            guard !finished else { return nil }
            finished = true
            return (statusCode, bytes, networkMetrics)
        }
        guard let result else { return }
        recordProtocol(result.networkMetrics?.snapshot() ?? .init())
        sink.record(.httpRequestFinished(
            downloadID: downloadID,
            requestID: requestID,
            kind: kind,
            statusCode: result.statusCode,
            bytes: result.bytes,
            elapsedNanoseconds: downloadMetricsElapsed(since: startedAt)
        ))
        armProtocolObservationIfNeeded()
    }

    private func recordProtocol(_ snapshot: HTTPTransportResponseMetrics.Snapshot) {
        guard snapshot.networkProtocolName != nil || snapshot.reusedConnection != nil else {
            return
        }
        let cleanup: (HTTPTransportResponseMetrics?, UUID?, Task<Void, Never>?)? = lock.withLock {
            guard !protocolRecorded else { return nil }
            protocolRecorded = true
            let metrics = networkMetrics
            let observerID = metricsObserverID
            metricsObserverID = nil
            let observationTask = protocolObservationTask
            protocolObservationTask = nil
            return (metrics, observerID, observationTask)
        }
        guard let cleanup else { return }
        cleanup.2?.cancel()
        if let metrics = cleanup.0, let observerID = cleanup.1 {
            metrics.removeObserver(observerID)
        }
        sink.record(.httpRequestProtocol(
            downloadID: downloadID,
            requestID: requestID,
            kind: kind,
            networkProtocolName: snapshot.networkProtocolName,
            reusedConnection: snapshot.reusedConnection
        ))
    }

    private func armProtocolObservationIfNeeded() {
        let registration: (HTTPTransportResponseMetrics, UUID)? = lock.withLock {
            guard !protocolRecorded,
                  let networkMetrics,
                  let observerID = metricsObserverID,
                  protocolObservationTask == nil else {
                return nil
            }
            return (networkMetrics, observerID)
        }
        guard let registration else { return }
        let networkMetrics = registration.0
        let observerID = registration.1
        let task = Task { [self] in
            do {
                try await Task.sleep(for: Self.protocolMetricsGracePeriod)
            } catch {
                return
            }
            expireProtocolObservation(networkMetrics: networkMetrics, observerID: observerID)
        }
        let cancel = lock.withLock {
            guard !protocolRecorded, protocolObservationTask == nil else { return true }
            protocolObservationTask = task
            return false
        }
        if cancel {
            task.cancel()
        }
    }

    private func expireProtocolObservation(
        networkMetrics: HTTPTransportResponseMetrics,
        observerID: UUID
    ) {
        let shouldRemove = lock.withLock {
            guard !protocolRecorded, metricsObserverID == observerID else { return false }
            protocolRecorded = true
            metricsObserverID = nil
            protocolObservationTask = nil
            return true
        }
        if shouldRemove {
            networkMetrics.removeObserver(observerID)
        }
    }
}
