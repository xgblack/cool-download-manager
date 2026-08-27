import Foundation

public struct HLSDownloadResult: Sendable {
    public let totalBytes: Int64
    public let segmentCount: Int
}

public final class HLSDownloader: @unchecked Sendable {
    private let transport: any HTTPTransport

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

    public func download(
        source: DownloadSource,
        writer: PartFileWriter,
        completedSegments: Set<Int> = [],
        completedPartMetadata: [DownloadPart] = [],
        progress: (@Sendable (Int64, Int, Int, Int64) async -> Void)? = nil,
        rateLimiter: DownloadRateLimiter? = nil
    ) async throws -> HLSDownloadResult {
        guard let playlistURL = URL(string: source.link),
              let scheme = playlistURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadCoreError.invalidURL(source.link)
        }

        let playlist = try await loadPlaylist(at: playlistURL, headers: source.headers, depth: 0)
        guard !playlist.segments.isEmpty else {
            throw DownloadCoreError.unsupportedHLS("播放列表不包含媒体分片")
        }
        var effectiveCompletedSegments = completedSegments
        var initialLength = try await writer.length()
        if let lastCompleted = effectiveCompletedSegments.max() {
            let expectedPrefix = Set(0...lastCompleted)
            guard effectiveCompletedSegments == expectedPrefix,
                  lastCompleted < playlist.segments.count else {
                throw DownloadCoreError.responseMismatch(
                    "HLS 已完成分片不是连续的播放列表前缀"
                )
            }

            // The part file can contain a fully written segment whose progress
            // marker was not persisted before a crash. Use byte boundaries in
            // the completed metadata to truncate that extra suffix instead of
            // appending the segment a second time. Old metadata without byte
            // boundaries is rebuilt from the playlist, which is slower but safe.
            let metadata = Dictionary(
                uniqueKeysWithValues: completedPartMetadata.map { ($0.id, $0) }
            )
            let prefixEnds = effectiveCompletedSegments.compactMap { id -> Int64? in
                guard let part = metadata[id],
                      let to = part.to,
                      part.downloaded > 0,
                      part.to! - part.from + 1 == part.downloaded else {
                    return nil
                }
                return to + 1
            }
            if prefixEnds.count != effectiveCompletedSegments.count {
                try await writer.truncate()
                initialLength = 0
                effectiveCompletedSegments.removeAll()
            } else if let expectedPrefixLength = prefixEnds.max() {
                if initialLength < expectedPrefixLength {
                    try await writer.truncate()
                    initialLength = 0
                    effectiveCompletedSegments.removeAll()
                } else if initialLength > expectedPrefixLength {
                    try await writer.truncate(to: expectedPrefixLength)
                    initialLength = expectedPrefixLength
                }
            }
        }
        if effectiveCompletedSegments.isEmpty && initialLength > 0 {
            // A partial segment has no safe byte boundary. Rebuild from the
            // beginning rather than appending a duplicate or truncated media
            // fragment on the next attempt.
            try await writer.truncate()
            initialLength = 0
        }

        var totalBytes = initialLength
        if let mapURL = playlist.initializationURL, effectiveCompletedSegments.isEmpty {
            let data = try await fetchData(url: mapURL, headers: source.headers, rateLimiter: rateLimiter)
            try await writer.append(data)
            totalBytes += Int64(data.count)
        }

        for (index, segmentURL) in playlist.segments.enumerated() {
            if effectiveCompletedSegments.contains(index) { continue }
            let data = try await fetchData(url: segmentURL, headers: source.headers, rateLimiter: rateLimiter)
            try Task.checkCancellation()
            try await writer.append(data)
            totalBytes += Int64(data.count)
            await progress?(totalBytes, index, playlist.segments.count, Int64(data.count))
        }
        return HLSDownloadResult(totalBytes: totalBytes, segmentCount: playlist.segments.count)
    }

    private struct Playlist {
        let segments: [URL]
        let initializationURL: URL?
    }

    private func loadPlaylist(
        at url: URL,
        headers: [String: String]?,
        depth: Int
    ) async throws -> Playlist {
        guard depth < 3 else {
            throw DownloadCoreError.unsupportedHLS("主播放列表嵌套层级过深")
        }
        let data = try await fetchData(url: url, headers: headers)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadCoreError.unsupportedHLS("播放列表不是 UTF-8 文本")
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else {
            throw DownloadCoreError.unsupportedHLS("缺少 #EXTM3U 标头")
        }
        if let variant = highestBandwidthVariant(lines: lines, baseURL: url) {
            return try await loadPlaylist(at: variant, headers: headers, depth: depth + 1)
        }

        var segments: [URL] = []
        var initializationURL: URL?
        var expectsSegmentURI = false
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-KEY") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                if method.uppercased() != "NONE" {
                    throw DownloadCoreError.unsupportedHLS("加密 HLS 需要密钥提供方")
                }
            }
            if line.hasPrefix("#EXT-X-BYTERANGE") {
                throw DownloadCoreError.unsupportedHLS("尚未实现分片字节范围")
            }
            if line.hasPrefix("#EXT-X-MAP") {
                guard let rawURI = attribute("URI", in: line),
                      let resolved = URL(string: rawURI, relativeTo: url)?.absoluteURL else {
                    throw DownloadCoreError.unsupportedHLS("初始化分片 URI 无效")
                }
                initializationURL = resolved
            }
            if line.hasPrefix("#EXTINF") {
                expectsSegmentURI = true
                continue
            }
            guard expectsSegmentURI, !line.hasPrefix("#") else { continue }
            guard let segmentURL = URL(string: line, relativeTo: url)?.absoluteURL else {
                throw DownloadCoreError.unsupportedHLS("分片 URI 无效")
            }
            segments.append(segmentURL)
            expectsSegmentURI = false
        }
        return Playlist(segments: segments, initializationURL: initializationURL)
    }

    private func highestBandwidthVariant(lines: [String], baseURL: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF") {
            guard index + 1 < lines.count,
                  !lines[index + 1].hasPrefix("#"),
                  let variantURL = URL(string: lines[index + 1], relativeTo: baseURL)?.absoluteURL else {
                continue
            }
            let bandwidth = Int(attribute("BANDWIDTH", in: lines[index]) ?? "0") ?? 0
            if best == nil || bandwidth > best!.bandwidth {
                best = (bandwidth, variantURL)
            }
        }
        return best?.url
    }

    private func attribute(_ name: String, in line: String) -> String? {
        let prefix = "\(name)="
        guard let range = line.range(of: prefix, options: [.caseInsensitive]) else { return nil }
        let suffix = line[range.upperBound...]
        if suffix.first == "\"", let end = suffix.dropFirst().firstIndex(of: "\"") {
            return String(suffix[suffix.index(after: suffix.startIndex)..<end])
        }
        return String(suffix.split(separator: ",").first ?? "")
    }

    private func fetchData(
        url: URL,
        headers: [String: String]?,
        rateLimiter: DownloadRateLimiter? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        headers?.forEach { key, value in request.setValue(value, forHTTPHeaderField: key) }
        let response = try await transport.response(for: request)
        defer { response.cancelBody() }
        guard (200...299).contains(response.statusCode) else {
            throw DownloadCoreError.httpStatus(response.statusCode)
        }
        var result = Data()
        for try await chunk in response.body {
            try Task.checkCancellation()
            try await rateLimiter?.consume(chunk.count)
            result.append(chunk)
        }
        return result
    }
}
