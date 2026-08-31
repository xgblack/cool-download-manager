import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("HLS typed pipeline")
struct HLSPipelineTests {
    @Test("master attributes preserve quoted commas and rendition metadata")
    func masterAttributes() throws {
        let parser = HLSParser()
        let playlist = try parser.parse("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Chinese",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="audio"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=200,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="audio"
        high/index.m3u8
        """, baseURL: URL(string: "https://video.example/master.m3u8")!)

        #expect(playlist.kind == .master)
        #expect(playlist.variants.count == 2)
        #expect(playlist.variants[1].codecs == "avc1.640028,mp4a.40.2")
        #expect(parser.selectHighestBandwidthVariant(from: playlist)?.uri.path == "/high/index.m3u8")
        #expect(playlist.renditions == [HLSRendition(
            type: .audio,
            groupID: "audio",
            name: "Chinese",
            language: "zh",
            isDefault: true,
            autoselect: true,
            uri: URL(string: "https://video.example/audio/index.m3u8")
        )])
    }

    @Test("redacted rendition metadata and resume snapshots survive a database reopen")
    func persistedRenditionsRemainRedacted() async throws {
        let transport = HLSFixtureTransport(
            manifests: [
                "/master.m3u8": """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Chinese",LANGUAGE="zh",URI="audio/index.m3u8?token=rendition-secret"
                #EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO="audio"
                video/index.m3u8
                """,
                "/video/index.m3u8": """
                #EXTM3U
                #EXT-X-MEDIA-SEQUENCE:8
                #EXTINF:1,
                segment.ts
                #EXT-X-ENDLIST
                """
            ],
            resources: [:]
        )
        let source = DownloadSource(
            kind: .hls,
            link: "https://video.example/master.m3u8"
        )
        let resolved = try await HLSDownloader(transport: transport).resolvePlaylist(source: source)
        #expect(resolved.renditions.count == 1)
        #expect(resolved.renditions.first?.uri == nil)

        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = HLSResumeSnapshot(
            fingerprint: resolved.fingerprint,
            completedSegmentSequence: 8,
            outputByteBoundary: 3
        )
        let record = DownloadRecord(
            id: 90,
            source: source,
            folder: root.path,
            name: "video.ts",
            status: .paused,
            downloadedBytes: 3,
            parts: [DownloadPart(id: 0, from: 0, to: 2, downloaded: 3, completed: true)],
            hlsResumeSnapshot: snapshot,
            hlsRenditions: resolved.renditions
        )
        let store = try DownloadStore(rootURL: root)
        try await store.save(record)

        let readOnlyDatabase = try MetadataDatabase(rootURL: root, readOnly: true)
        let reopened = try DownloadStore(rootURL: root, database: readOnlyDatabase)
        let loaded = try #require(try await reopened.load().first)
        #expect(loaded.hlsResumeSnapshot == snapshot)
        #expect(loaded.hlsRenditions == resolved.renditions)
        #expect(loaded.hlsRenditions?.first?.uri == nil)

        let metadataPath = root.appendingPathComponent("metadata.sqlite").path
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: metadataPath + suffix)
            guard let data = try? Data(contentsOf: url) else { continue }
            #expect(!data.contains(Data("rendition-secret".utf8)))
        }
    }

    @Test("media parser resolves ranges maps sequence and discontinuities")
    func mediaSemantics() throws {
        let parser = HLSParser()
        let playlist = try parser.parse("""
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
        #EXTINF:1.5,
        #EXT-X-BYTERANGE:3@4
        media.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:2,
        #EXT-X-BYTERANGE:3
        media.mp4
        #EXT-X-ENDLIST
        """, baseURL: URL(string: "https://video.example/index.m3u8?token=first")!)

        #expect(playlist.kind == .media)
        #expect(playlist.mediaSequence == 42)
        #expect(playlist.endList)
        #expect(playlist.segments.map(\.sequence) == [42, 43])
        #expect(playlist.segments.map(\.byteRange) == [
            HLSByteRange(length: 3, offset: 4),
            HLSByteRange(length: 3, offset: 7)
        ])
        #expect(playlist.segments[0].map?.byteRange == HLSByteRange(length: 4, offset: 0))
        #expect(playlist.segments.map(\.discontinuityGroup) == [0, 1])

        let rotated = try parser.parse("""
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
        #EXTINF:1.5,
        #EXT-X-BYTERANGE:3@4
        media.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:2,
        #EXT-X-BYTERANGE:3
        media.mp4
        #EXT-X-ENDLIST
        """, baseURL: URL(string: "https://video.example/index.m3u8?token=second")!)
        #expect(parser.fingerprint(for: playlist) == parser.fingerprint(for: rotated))

        let unknownQuery = try parser.parse("""
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
        #EXTINF:1.5,
        #EXT-X-BYTERANGE:3@4
        media.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:2,
        #EXT-X-BYTERANGE:3
        media.mp4
        #EXT-X-ENDLIST
        """, baseURL: URL(string: "https://video.example/index.m3u8?version=2")!)
        #expect(parser.fingerprint(for: playlist) != parser.fingerprint(for: unknownQuery))
        #expect(!parser.fingerprint(for: unknownQuery).canonicalPlaylist.contains("version=2"))
    }

    @Test("parser rejects unsafe or unsupported media semantics")
    func parserFailures() throws {
        let parser = HLSParser()
        let limitedParser = HLSParser(maximumManifestBytes: 64)
        let base = URL(string: "https://video.example/index.m3u8")!

        try expectHLSFailure(contains: "Live") {
            _ = try parser.parse("#EXTM3U\n#EXTINF:1,\none.ts\n", baseURL: base)
        }
        try expectHLSFailure(contains: "加密") {
            _ = try parser.parse("""
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXTINF:1,
            one.ts
            #EXT-X-ENDLIST
            """, baseURL: base)
        }
        try expectHLSFailure(contains: "同一 URI") {
            _ = try parser.parse("""
            #EXTM3U
            #EXTINF:1,
            #EXT-X-BYTERANGE:2@0
            one.ts
            #EXTINF:1,
            #EXT-X-BYTERANGE:2
            two.ts
            #EXT-X-ENDLIST
            """, baseURL: base)
        }
        try expectHLSFailure(contains: "大小限制") {
            _ = try limitedParser.parse(Data(repeating: 0x41, count: 65), baseURL: base)
        }
        try expectHLSFailure(contains: "UTF-8") {
            _ = try parser.parse(Data([0xff, 0xfe]), baseURL: base)
        }
        try expectHLSFailure(contains: "#EXTM3U") {
            _ = try parser.parse("<MPD></MPD>", baseURL: base)
        }
    }

    @Test("executor streams MAP and byte ranges with exact response validation")
    func rangeExecution() async throws {
        let transport = HLSFixtureTransport(
            manifests: ["/index.m3u8": """
            #EXTM3U
            #EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
            #EXTINF:1,
            #EXT-X-BYTERANGE:3@4
            media.mp4
            #EXTINF:1,
            #EXT-X-BYTERANGE:3
            media.mp4
            #EXT-X-ENDLIST
            """],
            resources: ["/media.mp4": Data("0123456789".utf8)],
            chunkSize: 2
        )
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = hlsRecord(id: 1, root: root)
        let writer = try PartFileWriter(record: record)
        let result = try await HLSDownloader(transport: transport).download(
            source: record.source,
            writer: writer
        )

        #expect(result.totalBytes == 10)
        #expect(result.segmentCount == 2)
        #expect(try Data(contentsOf: record.incompleteURL) == Data("0123456789".utf8))
        #expect(transport.ranges() == ["bytes=0-3", "bytes=4-6", "bytes=7-9"])
        #expect(transport.headerValues("Accept-Encoding").allSatisfy { $0 == "identity" })
    }

    @Test("ordinary segments reject unsolicited partial responses")
    func ordinarySegmentRejectsPartialResponse() async throws {
        let transport = HLSFixtureTransport(
            manifests: ["/index.m3u8": """
            #EXTM3U
            #EXTINF:1,
            media.ts
            #EXT-X-ENDLIST
            """],
            resources: ["/media.ts": Data("abcd".utf8)],
            partialWithoutRangeLengths: ["/media.ts": 2]
        )
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = hlsRecord(id: 5, root: root)
        let writer = try PartFileWriter(record: record)

        do {
            _ = try await HLSDownloader(transport: transport).download(
                source: record.source,
                writer: writer
            )
            Issue.record("unsolicited 206 should fail")
        } catch let error as DownloadCoreError {
            guard case .responseMismatch = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(try await writer.length() == 0)
    }

    @Test("manifests reject unsolicited partial responses")
    func manifestRejectsPartialResponse() async throws {
        let transport = HLSFixtureTransport(
            manifests: ["/index.m3u8": """
            #EXTM3U
            #EXTINF:1,
            media.ts
            #EXT-X-ENDLIST
            """],
            resources: ["/media.ts": Data("abcd".utf8)],
            partialManifestPaths: ["/index.m3u8"]
        )
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = hlsRecord(id: 6, root: root)
        let writer = try PartFileWriter(record: record)

        do {
            _ = try await HLSDownloader(transport: transport).download(
                source: record.source,
                writer: writer
            )
            Issue.record("unsolicited manifest 206 should fail")
        } catch let error as DownloadCoreError {
            guard case .responseMismatch = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(!transport.paths().contains("/media.ts"))
        #expect(try await writer.length() == 0)
    }

    @Test("executor rolls a malformed range response back to the last segment")
    func malformedRangeRollback() async throws {
        let transport = HLSFixtureTransport(
            manifests: ["/index.m3u8": """
            #EXTM3U
            #EXTINF:1,
            #EXT-X-BYTERANGE:3@0
            media.mp4
            #EXTINF:1,
            #EXT-X-BYTERANGE:3@3
            media.mp4
            #EXT-X-ENDLIST
            """],
            resources: ["/media.mp4": Data("abcdef".utf8)],
            malformedRangeStart: 3
        )
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = hlsRecord(id: 2, root: root)
        let writer = try PartFileWriter(record: record)
        let capture = HLSCheckpointCapture()
        do {
            _ = try await HLSDownloader(transport: transport).download(
                source: record.source,
                writer: writer,
                checkpoint: { _, _, _, _, snapshot in
                    await capture.record(snapshot)
                }
            )
            Issue.record("malformed Content-Range should fail")
        } catch let error as DownloadCoreError {
            guard case .responseMismatch = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        let checkpointCount = await capture.checkpointCount()
        #expect(checkpointCount == 1)
        #expect(try await writer.length() == 3)
        #expect(try Data(contentsOf: record.incompleteURL) == Data("abc".utf8))
    }

    @Test("snapshot resumes only an identical manifest prefix")
    func snapshotResume() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:10
        #EXTINF:1,
        one.ts
        #EXTINF:1,
        two.ts
        #EXT-X-ENDLIST
        """
        let firstTransport = HLSFixtureTransport(
            manifests: ["/index.m3u8": manifest],
            resources: [
                "/one.ts": Data("one".utf8),
                "/two.ts": Data("two".utf8)
            ],
            failingPaths: ["/two.ts"]
        )
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = hlsRecord(id: 3, root: root)
        let writer = try PartFileWriter(record: record)
        let capture = HLSCheckpointCapture()
        do {
            _ = try await HLSDownloader(transport: firstTransport).download(
                source: record.source,
                writer: writer,
                checkpoint: { _, _, _, _, value in
                    await capture.record(value)
                }
            )
            Issue.record("second segment should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .httpStatus(503))
        }
        let capturedSnapshot = await capture.latestSnapshot()
        let saved = try #require(capturedSnapshot)
        #expect(saved.completedSegmentSequence == 10)
        #expect(saved.outputByteBoundary == 3)

        let resumedTransport = HLSFixtureTransport(
            manifests: ["/index.m3u8": manifest],
            resources: [
                "/one.ts": Data("one".utf8),
                "/two.ts": Data("two".utf8)
            ]
        )
        let result = try await HLSDownloader(transport: resumedTransport).download(
            source: record.source,
            writer: writer,
            resumeSnapshot: saved,
            completedSegments: [0],
            completedPartMetadata: [
                DownloadPart(id: 0, from: 0, to: 2, downloaded: 3, completed: true)
            ]
        )
        #expect(result.totalBytes == 6)
        #expect(try Data(contentsOf: record.incompleteURL) == Data("onetwo".utf8))
        #expect(!resumedTransport.paths().contains("/one.ts"))

        let changedTransport = HLSFixtureTransport(
            manifests: ["/index.m3u8": manifest.replacingOccurrences(of: "two.ts", with: "changed.ts")],
            resources: ["/changed.ts": Data("bad".utf8)]
        )
        do {
            _ = try await HLSDownloader(transport: changedTransport).download(
                source: record.source,
                writer: writer,
                resumeSnapshot: saved,
                completedSegments: [0],
                completedPartMetadata: [
                    DownloadPart(id: 0, from: 0, to: 2, downloaded: 3, completed: true)
                ]
            )
            Issue.record("changed manifest should not append")
        } catch let error as DownloadCoreError {
            #expect(error == .resourceChanged)
        }
        #expect(!changedTransport.paths().contains("/changed.ts"))
    }

    private func expectHLSFailure(
        contains text: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("expected HLS parser failure")
        } catch let error as DownloadCoreError {
            guard case .unsupportedHLS(let reason) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(reason.contains(text))
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooldm-hls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func hlsRecord(id: DownloadID, root: URL) -> DownloadRecord {
        DownloadRecord(
            id: id,
            source: DownloadSource(kind: .hls, link: "https://video.example/index.m3u8"),
            folder: root.path,
            name: "video.ts"
        )
    }
}

private actor HLSCheckpointCapture {
    private var count = 0
    private var snapshot: HLSResumeSnapshot?

    func record(_ value: HLSResumeSnapshot) {
        count += 1
        snapshot = value
    }

    func checkpointCount() -> Int {
        count
    }

    func latestSnapshot() -> HLSResumeSnapshot? {
        snapshot
    }
}

private final class HLSFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let manifests: [String: String]
    private let resources: [String: Data]
    private let chunkSize: Int
    private let malformedRangeStart: Int64?
    private let failingPaths: Set<String>
    private let partialWithoutRangeLengths: [String: Int]
    private let partialManifestPaths: Set<String>
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(
        manifests: [String: String],
        resources: [String: Data],
        chunkSize: Int = 64 * 1024,
        malformedRangeStart: Int64? = nil,
        failingPaths: Set<String> = [],
        partialWithoutRangeLengths: [String: Int] = [:],
        partialManifestPaths: Set<String> = []
    ) {
        self.manifests = manifests
        self.resources = resources
        self.chunkSize = max(1, chunkSize)
        self.malformedRangeStart = malformedRangeStart
        self.failingPaths = failingPaths
        self.partialWithoutRangeLengths = partialWithoutRangeLengths
        self.partialManifestPaths = partialManifestPaths
    }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        lock.withLock { requests.append(request) }
        let path = request.url?.path ?? ""
        if failingPaths.contains(path) {
            return response(status: 503, headers: [:], body: Data())
        }
        if let manifest = manifests[path] {
            let body = Data(manifest.utf8)
            if partialManifestPaths.contains(path) {
                return response(
                    status: 206,
                    headers: [
                        "Content-Range": "bytes 0-\(max(0, body.count - 1))/\(body.count)",
                        "Content-Length": String(body.count)
                    ],
                    body: body
                )
            }
            return response(
                status: 200,
                headers: ["Content-Length": String(body.count)],
                body: body
            )
        }
        guard let resource = resources[path] else {
            return response(status: 404, headers: [:], body: Data())
        }
        guard let rawRange = request.value(forHTTPHeaderField: "Range") else {
            if let requestedLength = partialWithoutRangeLengths[path] {
                let length = min(max(0, requestedLength), resource.count)
                let body = resource.prefix(length)
                return response(
                    status: 206,
                    headers: [
                        "Content-Range": "bytes 0-\(max(0, length - 1))/\(resource.count)",
                        "Content-Length": String(length)
                    ],
                    body: Data(body)
                )
            }
            return response(
                status: 200,
                headers: ["Content-Length": String(resource.count)],
                body: resource
            )
        }
        guard let range = parseRange(rawRange),
              range.lowerBound >= 0,
              range.upperBound < Int64(resource.count) else {
            return response(status: 416, headers: [:], body: Data())
        }
        let body = Data(resource[Int(range.lowerBound)...Int(range.upperBound)])
        let reportedStart = range.lowerBound == malformedRangeStart
            ? range.lowerBound + 1
            : range.lowerBound
        return response(
            status: 206,
            headers: [
                "Content-Range": "bytes \(reportedStart)-\(range.upperBound)/\(resource.count)",
                "Content-Length": String(body.count)
            ],
            body: body
        )
    }

    func ranges() -> [String] {
        lock.withLock {
            requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
        }
    }

    func paths() -> [String] {
        lock.withLock { requests.compactMap { $0.url?.path } }
    }

    func headerValues(_ name: String) -> [String] {
        lock.withLock { requests.compactMap { $0.value(forHTTPHeaderField: name) } }
    }

    private func response(
        status: Int,
        headers: [String: String],
        body: Data
    ) -> HTTPTransportResponse {
        let size = chunkSize
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            var offset = 0
            while offset < body.count {
                let end = min(body.count, offset + size)
                continuation.yield(Data(body[offset..<end]))
                offset = end
            }
            continuation.finish()
        }
        return HTTPTransportResponse(statusCode: status, headers: headers, body: stream)
    }

    private func parseRange(_ raw: String) -> ClosedRange<Int64>? {
        guard raw.hasPrefix("bytes=") else { return nil }
        let values = raw.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard values.count == 2,
              let start = Int64(values[0]),
              let end = Int64(values[1]), end >= start else { return nil }
        return start...end
    }
}
