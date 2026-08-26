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

    public init(statusCode: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> HTTPTransportResponse
}

public final class HTTPDownloader: @unchecked Sendable {
    private let transport: any HTTPTransport
    private let bufferSize = 64 * 1024

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        networkConfiguration: HTTPNetworkConfiguration = .default
    ) {
        self.transport = URLSessionHTTPTransport(
            configuration: configuration,
            networkConfiguration: networkConfiguration
        )
    }

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func probe(source: DownloadSource) async throws -> HTTPResourceMetadata {
        let url = try validatedURL(source.link)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        applyHeaders(source.headers, to: &request)

        let response = try await transport.response(for: request)
        let statusCode = response.statusCode
        guard (200...299).contains(statusCode) || statusCode == 405 || statusCode == 501 else {
            throw DownloadCoreError.httpStatus(statusCode)
        }
        let length = try Self.validatedContentLength(response.header("Content-Length"))
        let acceptsRanges = response.header("Accept-Ranges")?
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("bytes") == .orderedSame } == true
        let etag = response.header("ETag")
        let lastModified = response.header("Last-Modified")
        let fileName = DownloadFileNameResolver.fromContentDisposition(
            response.header("Content-Disposition")
        )
        _ = try await drain(response.body)

        if statusCode != 405 && statusCode != 501,
           length != nil,
           acceptsRanges {
            return HTTPResourceMetadata(
                totalBytes: length,
                supportsRanges: true,
                etag: etag,
                lastModified: lastModified,
                fileName: fileName
            )
        }

        if statusCode != 405 && statusCode != 501, let length {
            // A known-length HEAD response without an explicit byte-range
            // capability is safer to treat as single-connection than to
            // issue a GET probe that could stream the entire file.
            return HTTPResourceMetadata(
                totalBytes: length,
                supportsRanges: false,
                etag: etag,
                lastModified: lastModified,
                fileName: fileName
            )
        }

        // Some servers omit Accept-Ranges or reject HEAD. A one-byte range
        // probe is the authoritative fallback for parallel downloads.
        var rangeRequest = URLRequest(url: url)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 30
        applyHeaders(source.headers, to: &rangeRequest)
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let rangeResponse = try await transport.response(for: rangeRequest)
        let rangeETag = rangeResponse.header("ETag") ?? etag
        let rangeLastModified = rangeResponse.header("Last-Modified") ?? lastModified
        let rangeFileName = DownloadFileNameResolver.fromContentDisposition(
            rangeResponse.header("Content-Disposition")
        ) ?? fileName
        let rangeContentLength = try Self.validatedContentLength(rangeResponse.header("Content-Length"))
        let rangeBodyLength = try await drain(rangeResponse.body)
        if rangeResponse.statusCode == 206,
           let contentRange = rangeResponse.header("Content-Range"),
           let parsed = Self.parseContentRange(contentRange),
           parsed.start == 0,
           parsed.end == 0,
           let total = parsed.total,
           rangeBodyLength == 1,
           rangeContentLength.map({ $0 == 1 }) ?? true {
            return HTTPResourceMetadata(
                totalBytes: total,
                supportsRanges: true,
                etag: rangeETag,
                lastModified: rangeLastModified,
                fileName: rangeFileName
            )
        }
        let fallbackLength = rangeContentLength ?? length
        return HTTPResourceMetadata(
            totalBytes: fallbackLength,
            supportsRanges: false,
            etag: rangeETag,
            lastModified: rangeLastModified,
            fileName: rangeFileName
        )
    }

    public func download(
        source: DownloadSource,
        offset: Int64,
        writer: PartFileWriter,
        progress: (@Sendable (Int64) async -> Void)? = nil,
        expectedETag: String? = nil,
        expectedLastModified: String? = nil,
        rateLimiter: DownloadRateLimiter? = nil
    ) async throws -> HTTPDownloadResult {
        let url = try validatedURL(source.link)

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

        let response = try await transport.response(for: request)
        let statusCode = response.statusCode
        guard (200...299).contains(statusCode) else {
            throw DownloadCoreError.httpStatus(statusCode)
        }
        let responseContentLength = try Self.validatedContentLength(response.header("Content-Length"))

        let isResume = offset > 0
        var actualOffset = offset
        var contentRangeTotal: Int64?
        if isResume && statusCode == 200 {
            try validateValidators(
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
            try validateValidators(
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
        buffer.reserveCapacity(bufferSize)
        var writtenBytes = actualOffset
        var responseBodyBytes: Int64 = 0
        for try await chunk in response.body {
            try Task.checkCancellation()
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
            buffer.append(chunk)
            responseBodyBytes += Int64(chunk.count)
            while buffer.count >= bufferSize {
                let output = buffer.prefix(bufferSize)
                try await writer.append(Data(output))
                writtenBytes += Int64(output.count)
                await progress?(writtenBytes)
                buffer.removeFirst(output.count)
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

    public func downloadRange(
        source: DownloadSource,
        start: Int64,
        end: Int64,
        writer: PartFileWriter,
        expectedETag: String? = nil,
        expectedLastModified: String? = nil,
        progress: (@Sendable (Int64) async -> Void)? = nil,
        rateLimiter: DownloadRateLimiter? = nil
    ) async throws -> HTTPDownloadResult {
        guard start >= 0, end >= start else {
            throw DownloadCoreError.responseMismatch("请求的字节范围无效")
        }
        let url = try validatedURL(source.link)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        applyHeaders(source.headers, to: &request)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        if let validator = expectedETag ?? expectedLastModified {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        let response = try await transport.response(for: request)
        guard response.statusCode == 206 else {
            if response.statusCode == 200 {
                throw DownloadCoreError.resumeNotSupported
            }
            throw DownloadCoreError.httpStatus(response.statusCode)
        }
        try validateValidators(
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

    private func drain(_ body: AsyncThrowingStream<Data, Error>) async throws -> Int64 {
        var count: Int64 = 0
        for try await chunk in body {
            try Task.checkCancellation()
            count += Int64(chunk.count)
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
