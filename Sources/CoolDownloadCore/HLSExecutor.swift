import Foundation

public typealias HLSCheckpointHandler = @Sendable (
    _ totalBytes: Int64,
    _ segmentIndex: Int,
    _ segmentCount: Int,
    _ segmentBytes: Int64,
    _ snapshot: HLSResumeSnapshot
) async -> Void

public typealias HLSManifestResolvedHandler = @Sendable (
    _ snapshot: HLSResumeSnapshot,
    _ renditions: [HLSRendition]
) async -> Void

public final class HLSExecutor: @unchecked Sendable {
    public static let maximumMasterDepth = 3

    private let transport: any HTTPTransport
    private let parser: HLSParser

    public init(
        transport: any HTTPTransport,
        parser: HLSParser = HLSParser()
    ) {
        self.transport = transport
        self.parser = parser
    }

    public func resolvePlaylist(
        at url: URL,
        headers: [String: String]? = nil,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        downloadID: DownloadID? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HLSResolvedPlaylist {
        var currentURL = url
        var selectedVariant: HLSVariant?
        var renditions: [HLSRendition] = []

        for depth in 0...Self.maximumMasterDepth {
            let data = try await fetchManifest(
                url: currentURL,
                headers: headers,
                fileDescriptorBudget: fileDescriptorBudget,
                downloadID: downloadID,
                activity: activity
            )
            let playlist = try parser.parse(data, baseURL: currentURL)
            switch playlist.kind {
            case .media:
                guard !playlist.segments.isEmpty else {
                    throw DownloadCoreError.unsupportedHLS("播放列表不包含媒体分片")
                }
                return HLSResolvedPlaylist(
                    playlist: playlist,
                    selectedVariant: selectedVariant,
                    renditions: renditions.map(Self.redactedRendition),
                    fingerprint: parser.fingerprint(for: playlist)
                )
            case .master:
                guard depth < Self.maximumMasterDepth,
                      let variant = parser.selectHighestBandwidthVariant(from: playlist) else {
                    throw DownloadCoreError.unsupportedHLS("主播放列表嵌套层级过深或没有可用 variant")
                }
                renditions.append(contentsOf: playlist.renditions)
                selectedVariant = variant
                currentURL = variant.uri
            }
        }
        throw DownloadCoreError.unsupportedHLS("主播放列表嵌套层级过深")
    }

    public func download(
        source: DownloadSource,
        writer: PartFileWriter,
        resumeSnapshot: HLSResumeSnapshot? = nil,
        completedSegments: Set<Int> = [],
        completedPartMetadata: [DownloadPart] = [],
        progress: (@Sendable (Int64, Int, Int, Int64) async -> Void)? = nil,
        checkpoint: HLSCheckpointHandler? = nil,
        manifestResolved: HLSManifestResolvedHandler? = nil,
        rateLimiter: DownloadRateLimiter? = nil,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        downloadID: DownloadID? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HLSDownloadResult {
        let playlistURL = try validatedPlaylistURL(source.link)
        let resolved = try await resolvePlaylist(
            at: playlistURL,
            headers: source.headers,
            fileDescriptorBudget: fileDescriptorBudget,
            downloadID: downloadID,
            activity: activity
        )
        let playlist = resolved.playlist

        var resume = try await prepareResume(
            snapshot: resumeSnapshot,
            fingerprint: resolved.fingerprint,
            playlist: playlist,
            completedSegments: completedSegments,
            completedPartMetadata: completedPartMetadata,
            writer: writer
        )
        let initialSnapshot = HLSResumeSnapshot(
            fingerprint: resolved.fingerprint,
            completedSegmentSequence: resume.completedSegmentSequence,
            outputByteBoundary: resume.outputByteBoundary
        )
        await manifestResolved?(initialSnapshot, resolved.renditions)

        var totalBytes = resume.outputByteBoundary
        var lastWrittenMap = resume.lastWrittenMap
        for (index, segment) in playlist.segments.enumerated() {
            if index < resume.nextSegmentIndex { continue }
            try Task.checkCancellation()
            let boundary = totalBytes
            do {
                if segment.map != lastWrittenMap, let map = segment.map {
                    totalBytes += try await appendResource(
                        url: map.uri,
                        byteRange: map.byteRange,
                        headers: source.headers,
                        writer: writer,
                        rateLimiter: rateLimiter,
                        fileDescriptorBudget: fileDescriptorBudget,
                        downloadID: downloadID,
                        activity: activity
                    )
                    lastWrittenMap = map
                }
                totalBytes += try await appendResource(
                    url: segment.uri,
                    byteRange: segment.byteRange,
                    headers: source.headers,
                    writer: writer,
                    rateLimiter: rateLimiter,
                    fileDescriptorBudget: fileDescriptorBudget,
                    downloadID: downloadID,
                    activity: activity
                )
                try Task.checkCancellation()
            } catch {
                try? await writer.truncate(to: boundary)
                throw error
            }

            let snapshot = HLSResumeSnapshot(
                fingerprint: resolved.fingerprint,
                completedSegmentSequence: segment.sequence,
                outputByteBoundary: totalBytes
            )
            let segmentBytes = totalBytes - boundary
            await progress?(totalBytes, index, playlist.segments.count, segmentBytes)
            await checkpoint?(totalBytes, index, playlist.segments.count, segmentBytes, snapshot)
            resume.completedSegmentSequence = segment.sequence
            resume.outputByteBoundary = totalBytes
        }

        return HLSDownloadResult(
            totalBytes: totalBytes,
            segmentCount: playlist.segments.count,
            fingerprint: resolved.fingerprint,
            renditions: resolved.renditions,
            completedSegmentSequence: resume.completedSegmentSequence
        )
    }

    private struct ResumeState {
        var nextSegmentIndex: Int
        var completedSegmentSequence: Int64?
        var outputByteBoundary: Int64
        var lastWrittenMap: HLSMap?
    }

    private func prepareResume(
        snapshot: HLSResumeSnapshot?,
        fingerprint: HLSManifestFingerprint,
        playlist: HLSPlaylist,
        completedSegments: Set<Int>,
        completedPartMetadata: [DownloadPart],
        writer: PartFileWriter
    ) async throws -> ResumeState {
        if let lastLegacyIndex = completedSegments.max() {
            guard completedSegments == Set(0...lastLegacyIndex),
                  lastLegacyIndex < playlist.segments.count else {
                throw DownloadCoreError.responseMismatch(
                    "HLS 已完成分片不是连续的播放列表前缀"
                )
            }
        }
        guard let snapshot else {
            if try await writer.length() > 0 || !completedSegments.isEmpty {
                try await writer.truncate()
            }
            return ResumeState(
                nextSegmentIndex: 0,
                completedSegmentSequence: nil,
                outputByteBoundary: 0,
                lastWrittenMap: nil
            )
        }
        guard snapshot.fingerprint == fingerprint else {
            throw DownloadCoreError.resourceChanged
        }
        guard snapshot.outputByteBoundary >= 0 else {
            throw DownloadCoreError.responseMismatch("HLS 恢复边界无效")
        }

        let nextIndex: Int
        let lastMap: HLSMap?
        if let completedSequence = snapshot.completedSegmentSequence {
            guard completedSequence >= playlist.mediaSequence,
                  completedSequence - playlist.mediaSequence < Int64(playlist.segments.count) else {
                throw DownloadCoreError.responseMismatch("HLS 恢复序列不在当前播放列表内")
            }
            let index = Int(completedSequence - playlist.mediaSequence)
            guard playlist.segments[index].sequence == completedSequence else {
                throw DownloadCoreError.responseMismatch("HLS 恢复序列不连续")
            }
            nextIndex = index + 1
            lastMap = playlist.segments[index].map
        } else {
            nextIndex = 0
            lastMap = nil
        }

        let actualLength = try await writer.length()
        if actualLength < snapshot.outputByteBoundary {
            try await writer.truncate()
            return ResumeState(
                nextSegmentIndex: 0,
                completedSegmentSequence: nil,
                outputByteBoundary: 0,
                lastWrittenMap: nil
            )
        }
        if actualLength > snapshot.outputByteBoundary {
            try await writer.truncate(to: snapshot.outputByteBoundary)
        }

        if !completedPartMetadata.isEmpty {
            let grouped = Dictionary(grouping: completedPartMetadata, by: \.id)
            guard grouped.values.allSatisfy({ $0.count == 1 }) else {
                throw DownloadCoreError.responseMismatch("HLS 分片元数据 ID 重复")
            }
            let completedIDs = Set(completedPartMetadata.filter(\.completed).map(\.id))
            if nextIndex > 0, completedIDs != Set(0..<nextIndex) {
                throw DownloadCoreError.responseMismatch("HLS 已完成分片不是连续的播放列表前缀")
            }
        }
        return ResumeState(
            nextSegmentIndex: nextIndex,
            completedSegmentSequence: snapshot.completedSegmentSequence,
            outputByteBoundary: snapshot.outputByteBoundary,
            lastWrittenMap: lastMap
        )
    }

    private func fetchManifest(
        url: URL,
        headers: [String: String]?,
        fileDescriptorBudget: HTTPFileDescriptorBudget?,
        downloadID: DownloadID?,
        activity: HTTPRequestActivityHandler?
    ) async throws -> Data {
        var request = makeRequest(url: url, headers: headers)
        request.timeoutInterval = 30
        return try await withResponse(
            for: request,
            fileDescriptorBudget: fileDescriptorBudget,
            downloadID: downloadID,
            activity: activity
        ) { [self] response in
            guard response.statusCode == 200 else {
                if (400...599).contains(response.statusCode) {
                    throw DownloadCoreError.httpStatus(response.statusCode)
                }
                throw DownloadCoreError.responseMismatch("HLS 播放列表未返回 200")
            }
            if response.header("Content-Range") != nil {
                throw DownloadCoreError.responseMismatch("HLS 播放列表意外返回 Content-Range")
            }
            if let rawLength = response.header("Content-Length") {
                guard let length = Int64(rawLength), length >= 0 else {
                    throw DownloadCoreError.responseMismatch("Content-Length 不是非负整数")
                }
                guard length <= Int64(self.parser.maximumManifestBytes) else {
                    throw DownloadCoreError.unsupportedHLS("播放列表超过大小限制")
                }
            }

            var data = Data()
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard chunk.count <= self.parser.maximumManifestBytes - data.count else {
                    throw DownloadCoreError.unsupportedHLS("播放列表超过大小限制")
                }
                data.append(chunk)
            }
            return data
        }
    }

    private func appendResource(
        url: URL,
        byteRange: HLSByteRange?,
        headers: [String: String]?,
        writer: PartFileWriter,
        rateLimiter: DownloadRateLimiter?,
        fileDescriptorBudget: HTTPFileDescriptorBudget?,
        downloadID: DownloadID?,
        activity: HTTPRequestActivityHandler?
    ) async throws -> Int64 {
        var request = makeRequest(url: url, headers: headers)
        if let byteRange {
            request.setValue(byteRange.headerValue, forHTTPHeaderField: "Range")
        }
        return try await withResponse(
            for: request,
            fileDescriptorBudget: fileDescriptorBudget,
            downloadID: downloadID,
            activity: activity
        ) { [self] response in
            let expectedLength: Int64?
            if let byteRange {
                guard response.statusCode == 206 else {
                    if response.statusCode >= 400 {
                        throw DownloadCoreError.httpStatus(response.statusCode)
                    }
                    throw DownloadCoreError.responseMismatch("BYTERANGE 请求未返回 206")
                }
                guard let contentRange = response.header("Content-Range"),
                      let parsed = self.parseContentRange(contentRange),
                      parsed.start == byteRange.offset,
                      parsed.end == byteRange.end,
                      parsed.total.map({ $0 >= byteRange.end + 1 }) ?? true else {
                    throw DownloadCoreError.responseMismatch("Content-Range 与 HLS BYTERANGE 不匹配")
                }
                if let contentLength = try self.validatedContentLength(
                    response.header("Content-Length")
                ), contentLength != byteRange.length {
                    throw DownloadCoreError.responseMismatch(
                        "Content-Length 与 HLS BYTERANGE 不匹配"
                    )
                }
                expectedLength = byteRange.length
            } else {
                guard response.statusCode == 200 else {
                    if response.statusCode >= 400 {
                        throw DownloadCoreError.httpStatus(response.statusCode)
                    }
                    throw DownloadCoreError.responseMismatch("普通 HLS 资源未返回 200")
                }
                if response.header("Content-Range") != nil {
                    throw DownloadCoreError.responseMismatch("普通 HLS 资源意外返回 Content-Range")
                }
                expectedLength = try self.validatedContentLength(
                    response.header("Content-Length")
                )
            }

            var received: Int64 = 0
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard received <= Int64.max - Int64(chunk.count) else {
                    throw DownloadCoreError.responseMismatch("HLS 响应长度溢出")
                }
                let next = received + Int64(chunk.count)
                if let expectedLength, next > expectedLength {
                    throw DownloadCoreError.responseMismatch("HLS 响应正文长于声明长度")
                }
                try await rateLimiter?.consume(chunk.count)
                try await writer.append(chunk)
                received = next
            }
            if let expectedLength, received != expectedLength {
                throw DownloadCoreError.responseMismatch("HLS 响应正文短于声明长度")
            }
            return received
        }
    }

    private func withResponse<T: Sendable>(
        for request: URLRequest,
        fileDescriptorBudget: HTTPFileDescriptorBudget?,
        downloadID: DownloadID?,
        activity: HTTPRequestActivityHandler?,
        operation: @escaping @Sendable (HTTPTransportResponse) async throws -> T
    ) async throws -> T {
        try await withHTTPFileDescriptorLease(
            budget: fileDescriptorBudget,
            downloadID: downloadID
        ) { [self] in
            try await withHTTPRequestActivity(activity) {
                let response = try await self.transport.response(for: request)
                defer { response.cancelBody() }
                return try await operation(response)
            }
        }
    }

    private func makeRequest(url: URL, headers: [String: String]?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func validatedPlaylistURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw DownloadCoreError.invalidURL(raw)
        }
        return url
    }

    private struct ContentRange {
        let start: Int64
        let end: Int64
        let total: Int64?
    }

    private func parseContentRange(_ raw: String) -> ContentRange? {
        let components = raw.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2 else { return nil }
        let prefix = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.lowercased().hasPrefix("bytes ") else { return nil }
        let bounds = prefix.dropFirst("bytes ".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]), start >= 0,
              let end = Int64(bounds[1]), end >= start else { return nil }
        let total = components[1] == "*" ? nil : Int64(components[1])
        guard end < Int64.max,
              total.map({ $0 >= end + 1 }) ?? true else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    private func validatedContentLength(_ raw: String?) throws -> Int64? {
        guard let raw else { return nil }
        guard let value = Int64(raw), value >= 0 else {
            throw DownloadCoreError.responseMismatch("Content-Length 不是非负整数")
        }
        return value
    }

    private static func redactedRendition(_ value: HLSRendition) -> HLSRendition {
        HLSRendition(
            type: value.type,
            groupID: value.groupID,
            name: value.name,
            language: value.language,
            isDefault: value.isDefault,
            autoselect: value.autoselect,
            uri: nil
        )
    }
}
