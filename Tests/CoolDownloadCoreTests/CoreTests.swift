import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("CoolDownloadCore")
struct CoreTests {
    @Test("store saves, loads and locks a data root")
    func storeRoundTripAndLock() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var store: DownloadStore? = try DownloadStore(rootURL: root)
        let record = makeRecord(id: 7, folder: root)
        try await store?.save(record)

        #expect(throws: DownloadCoreError.storageLocked(root.appendingPathComponent("config/download.lock"))) {
            _ = try DownloadStore(rootURL: root)
        }
        let savedURL = root.appendingPathComponent("config/download_db/downloadlist/7.json")
        #expect(FileManager.default.fileExists(atPath: savedURL.path))

        store = nil
        let reopened = try DownloadStore(rootURL: root)
        let loaded = try await reopened.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == record.id)
        #expect(loaded.first?.source == record.source)
        #expect(loaded.first?.folder == record.folder)
        #expect(loaded.first?.name == record.name)
    }

    @Test("part file is resumed and atomically finished")
    func partFileResume() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = makeRecord(id: 3, folder: root)

        do {
            let writer = try PartFileWriter(record: record)
            try await writer.append(Data("abc".utf8))
            #expect(try await writer.length() == 3)
        }
        let resumed = try PartFileWriter(record: record)
        #expect(try await resumed.length() == 3)
        try await resumed.append(Data("def".utf8))
        try await resumed.finish()

        #expect(try Data(contentsOf: record.destinationURL) == Data("abcdef".utf8))
        #expect(!FileManager.default.fileExists(atPath: record.incompleteURL.path))
    }

    @Test("HTTP downloader validates range and restarts when ignored")
    func httpRange() async throws {
        let transport = MemoryTransport()
        let downloader = HTTPDownloader(transport: transport)
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/file.bin")
        let record = makeRecord(id: 1, folder: root, source: source)
        let writer = try PartFileWriter(record: record)
        try await writer.append(Data("abc".utf8))

        transport.handler = { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=3-" {
                return MemoryTransport.reply(status: 206, headers: [
                    "Content-Range": "bytes 3-5/6", "Content-Length": "3"
                ], body: Data("def".utf8))
            }
            return MemoryTransport.reply(status: 200, headers: [
                "Content-Length": "6"
            ], body: Data("abcdef".utf8))
        }

        let result = try await downloader.download(source: source, offset: 3, writer: writer)
        #expect(result.statusCode == 206)
        #expect(result.startOffset == 3)
        #expect(result.totalBytes == 6)
        #expect(try await writer.length() == 6)

        transport.handler = { _ in
            MemoryTransport.reply(status: 206, headers: [
                "Content-Range": "bytes 4-5/6", "Content-Length": "2"
            ], body: Data("ef".utf8))
        }
        do {
            _ = try await downloader.download(source: source, offset: 3, writer: writer)
            Issue.record("mismatched Content-Range should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .responseMismatch("Content-Range starts at 4, expected 3"))
        }
    }

    @Test("HTTP downloader surfaces server errors")
    func httpError() async throws {
        let transport = MemoryTransport()
        let downloader = HTTPDownloader(transport: transport)
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/missing")
        let writer = try PartFileWriter(record: makeRecord(id: 4, folder: root, source: source))
        transport.handler = { _ in
            MemoryTransport.reply(status: 404, headers: [:], body: Data())
        }
        do {
            _ = try await downloader.download(source: source, offset: 0, writer: writer)
            Issue.record("HTTP 404 should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .httpStatus(404))
        }
    }

    @Test("HTTP downloader rejects a response body longer than Content-Length")
    func httpExtraBytes() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: ["Content-Length": "3"], body: Data("abcd".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/extra")
        let writer = try PartFileWriter(record: makeRecord(id: 10, folder: root, source: source))

        do {
            _ = try await HTTPDownloader(transport: transport).download(
                source: source,
                offset: 0,
                writer: writer
            )
            Issue.record("an oversized response body should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .responseMismatch("received more than 3 bytes"))
        }
        #expect(try await writer.length() == 0)
    }

    @Test("HTTP downloader rejects a response body shorter than Content-Length")
    func httpShortBytes() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: ["Content-Length": "4"], body: Data("abc".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/short")
        let writer = try PartFileWriter(record: makeRecord(id: 14, folder: root, source: source))

        do {
            _ = try await HTTPDownloader(transport: transport).download(
                source: source,
                offset: 0,
                writer: writer
            )
            Issue.record("a short response body should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .responseMismatch("received 3 bytes, expected 4"))
        }
        #expect(try await writer.length() == 0)
    }

    @Test("HTTP downloader rejects malformed Content-Range without crashing")
    func malformedContentRange() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 206, headers: ["Content-Range": "bytes"], body: Data())
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/malformed-range")
        let writer = try PartFileWriter(record: makeRecord(id: 15, folder: root, source: source))
        do {
            _ = try await HTTPDownloader(transport: transport).download(source: source, offset: 1, writer: writer)
            Issue.record("malformed Content-Range should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .responseMismatch("206 response did not include a valid Content-Range"))
        }
    }

    @Test("HTTP downloader rejects malformed Content-Length")
    func malformedContentLength() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(
                status: 200,
                headers: ["Content-Length": "not-a-number"],
                body: Data("abc".utf8)
            )
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/malformed-length")
        let writer = try PartFileWriter(record: makeRecord(id: 16, folder: root, source: source))
        do {
            _ = try await HTTPDownloader(transport: transport).download(source: source, offset: 0, writer: writer)
            Issue.record("malformed Content-Length should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .responseMismatch("Content-Length is not a non-negative integer"))
        }
        #expect(try await writer.length() == 0)
    }

    @Test("boot converts stale active records into resumable paused records")
    func bootRecoversActiveRecord() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        var record = makeRecord(id: 11, folder: root)
        record.status = .downloading
        record.downloadedBytes = 4
        try await store.save(record)

        let service = DownloadService(store: store, defaultFolder: root)
        try await service.boot()
        let recovered = try #require(await service.snapshot().downloads.first)
        #expect(recovered.status == .paused)
        #expect(recovered.downloadedBytes == 4)
    }

    @Test("scheduler never exceeds its configured concurrent download limit")
    func schedulerLimit() async throws {
        let transport = SlowTransport(delay: .milliseconds(80))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root,
            schedulerConfiguration: DownloadSchedulerConfiguration(maxConcurrentDownloads: 1)
        )
        try await service.boot()
        let first = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/one", suggestedName: "one.bin"),
            start: true
        ))
        let second = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/two", suggestedName: "two.bin"),
            start: true
        ))

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let records = await service.snapshot().downloads
            if records.allSatisfy({ [first, second].contains($0.id) && $0.status == .completed }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let records = await service.snapshot().downloads
        #expect(records.filter { [first, second].contains($0.id) }.allSatisfy { $0.status == .completed })
        #expect(transport.maxObserved() == 1)
    }

    @Test("queue metadata is persisted and queue start does not start other queues")
    func queueStart() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: ["Content-Length": "2"], body: Data("ok".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(
            store: store,
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root
        )
        try await service.boot()
        let queued = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/queued", suggestedName: "queued.bin"),
            queueID: 7
        ))
        let other = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/other", suggestedName: "other.bin"),
            queueID: 8
        ))

        try await service.startQueue(id: 7)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await service.snapshot().downloads.first(where: { $0.id == queued })?.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let records = await service.snapshot().downloads
        #expect(records.first(where: { $0.id == queued })?.status == .completed)
        #expect(records.first(where: { $0.id == other })?.status == .added)
        #expect(records.first(where: { $0.id == queued })?.queueID == 7)
        #expect((await store.record(id: queued))?.queueID == 7)
    }

    @Test("service retries transient HTTP failures and records the final success")
    func transientRetry() async throws {
        let transport = RetryTransport(failuresBeforeSuccess: 2)
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root,
            retryPolicy: DownloadRetryPolicy(maxAttempts: 3, delay: .milliseconds(1))
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/retry", suggestedName: "retry.bin"),
            start: true
        ))

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await service.snapshot().downloads.first(where: { $0.id == id })?.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.snapshot().downloads.first(where: { $0.id == id })?.status == .completed)
        #expect(transport.requestCount() == 3)
    }

    @Test("removing an active task waits for cancellation before deleting its record")
    func removeActiveTask() async throws {
        let transport = SlowTransport(delay: .milliseconds(100))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(
            store: store,
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/remove", suggestedName: "remove.bin"),
            start: true
        ))
        try await Task.sleep(for: .milliseconds(20))
        try await service.remove(ids: [id], removeFiles: true)
        #expect(await service.snapshot().downloads.isEmpty)
        #expect(await store.record(id: id) == nil)
    }

    @Test("download service completes and persists a file")
    func serviceCompletes() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: [
                "Content-Length": "11"
            ], body: Data("hello world".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/hello.txt", suggestedName: "hello.txt"),
            start: true
        ))

        let deadline = ContinuousClock.now + .seconds(5)
        var completed: DownloadRecord?
        while ContinuousClock.now < deadline {
            completed = await service.snapshot().downloads.first { $0.id == id && $0.status == .completed }
            if completed != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = try #require(completed)
        #expect(record.downloadedBytes == 11)
        #expect(try Data(contentsOf: record.destinationURL) == Data("hello world".utf8))
    }

    @Test("download service uses configured parallel ranges and persists parts")
    func serviceParallelRanges() async throws {
        let content = Data("0123456789abcdefghijklmnop".utf8)
        let transport = RangeTransport(content: content)
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(
            store: store,
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root,
            schedulerConfiguration: DownloadSchedulerConfiguration(
                maxConcurrentDownloads: 1,
                maxConnectionsPerDownload: 3
            )
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(
                kind: .http,
                link: "https://fixture.invalid/parallel.bin",
                suggestedName: "parallel.bin"
            ),
            start: true
        ))

        let deadline = ContinuousClock.now + .seconds(5)
        var completed: DownloadRecord?
        while ContinuousClock.now < deadline {
            completed = await service.snapshot().downloads.first { $0.id == id && $0.status == .completed }
            if completed != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = try #require(completed)
        #expect(record.totalBytes == Int64(content.count))
        #expect(record.parts.count == 3)
        #expect(record.parts.allSatisfy { $0.completed })
        #expect(try Data(contentsOf: record.destinationURL) == content)
        #expect(transport.requestCount() == 3)
    }

    @Test("HLS downloader selects a variant and concatenates media segments")
    func hlsDownload() async throws {
        let transport = MemoryTransport()
        transport.handler = { request in
            switch request.url?.path {
            case "/master.m3u8":
                return MemoryTransport.reply(status: 200, headers: [:], body: Data("""
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=100
                low/index.m3u8
                #EXT-X-STREAM-INF:BANDWIDTH=200
                high/index.m3u8
                """.utf8))
            case "/high/index.m3u8":
                return MemoryTransport.reply(status: 200, headers: [:], body: Data("""
                #EXTM3U
                #EXTINF:1,
                first.ts
                #EXTINF:1,
                second.ts
                #EXT-X-ENDLIST
                """.utf8))
            case "/high/first.ts":
                return MemoryTransport.reply(status: 200, headers: [:], body: Data("one".utf8))
            case "/high/second.ts":
                return MemoryTransport.reply(status: 200, headers: [:], body: Data("two".utf8))
            default:
                return MemoryTransport.reply(status: 404, headers: [:], body: Data())
            }
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .hls, link: "https://fixture.invalid/master.m3u8")
        let record = makeRecord(id: 5, folder: root, source: source)
        let writer = try PartFileWriter(record: record)
        let result = try await HLSDownloader(transport: transport).download(source: source, writer: writer)
        #expect(result.segmentCount == 2)
        #expect(result.totalBytes == 6)
        #expect(try await writer.length() == 6)
        try await writer.finish()
        #expect(try Data(contentsOf: record.destinationURL) == Data("onetwo".utf8))
    }

    @Test("HLS downloader rejects encrypted playlists explicitly")
    func hlsEncryptionError() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: [:], body: Data("""
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI=key.bin
            #EXTINF:1,
            segment.ts
            """.utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .hls, link: "https://fixture.invalid/index.m3u8")
        let writer = try PartFileWriter(record: makeRecord(id: 6, folder: root, source: source))
        do {
            _ = try await HLSDownloader(transport: transport).download(source: source, writer: writer)
            Issue.record("encrypted HLS should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .unsupportedHLS("encrypted HLS requires a key provider"))
        }
    }

    @Test("HLS resume rejects non-contiguous completed segment metadata")
    func hlsNonContiguousResume() async throws {
        let transport = MemoryTransport()
        transport.handler = { request in
            if request.url?.path == "/index.m3u8" {
                return MemoryTransport.reply(status: 200, headers: [:], body: Data("""
                #EXTM3U
                #EXTINF:1,
                first.ts
                #EXTINF:1,
                second.ts
                #EXT-X-ENDLIST
                """.utf8))
            }
            return MemoryTransport.reply(status: 200, headers: [:], body: Data("segment".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .hls, link: "https://fixture.invalid/index.m3u8")
        let writer = try PartFileWriter(record: makeRecord(id: 12, folder: root, source: source))
        try await writer.append(Data("first".utf8))

        do {
            _ = try await HLSDownloader(transport: transport).download(
                source: source,
                writer: writer,
                completedSegments: [1]
            )
            Issue.record("non-contiguous HLS metadata should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .responseMismatch("HLS completed segments are not a contiguous playlist prefix"))
        }
    }

    @Test("HLS resume rebuilds an unconfirmed partial segment")
    func hlsPartialSegmentRestart() async throws {
        let transport = MemoryTransport()
        transport.handler = { request in
            if request.url?.path == "/index.m3u8" {
                return MemoryTransport.reply(status: 200, headers: [:], body: Data("""
                #EXTM3U
                #EXTINF:1,
                segment.ts
                #EXT-X-ENDLIST
                """.utf8))
            }
            return MemoryTransport.reply(status: 200, headers: [:], body: Data("fresh".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DownloadSource(kind: .hls, link: "https://fixture.invalid/index.m3u8")
        let record = makeRecord(id: 13, folder: root, source: source)
        let writer = try PartFileWriter(record: record)
        try await writer.append(Data("stale".utf8))
        _ = try await HLSDownloader(transport: transport).download(source: source, writer: writer)
        try await writer.finish()
        #expect(try Data(contentsOf: record.destinationURL) == Data("fresh".utf8))
    }

    @Test("HTTP downloader probes range support and writes an exact range")
    func httpRangeProbeAndWrite() async throws {
        let content = Data("0123456789abcdef".utf8)
        let transport = RangeTransport(content: content)
        let downloader = HTTPDownloader(transport: transport)
        let metadata = try await downloader.probe(source: DownloadSource(
            kind: .http,
            link: "https://fixture.invalid/range.bin"
        ))
        #expect(metadata.totalBytes == Int64(content.count))
        #expect(metadata.supportsRanges)
        #expect(metadata.etag == "\"v1\"")

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = makeRecord(id: 20, folder: root)
        let writer = try PartFileWriter(record: record)
        let result = try await downloader.downloadRange(
            source: record.source,
            start: 4,
            end: 9,
            writer: writer,
            expectedETag: "\"v1\""
        )
        #expect(result.bytesWritten == 6)
        #expect(result.totalBytes == Int64(content.count))
        #expect(try await writer.length() == 10)
        #expect(try Data(contentsOf: record.incompleteURL) == Data(repeating: 0, count: 4) + Data("456789".utf8))
    }

    @Test("HTTP downloader refuses a changed validator for a partial response")
    func httpValidatorMismatch() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(
                status: 206,
                headers: [
                    "Content-Range": "bytes 3-5/6",
                    "Content-Length": "3",
                    "ETag": "\"v2\""
                ],
                body: Data("def".utf8)
            )
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = makeRecord(id: 21, folder: root)
        let writer = try PartFileWriter(record: record)
        do {
            _ = try await HTTPDownloader(transport: transport).download(
                source: record.source,
                offset: 3,
                writer: writer,
                expectedETag: "\"v1\""
            )
            Issue.record("changed ETag should reject a resumed response")
        } catch let error as DownloadCoreError {
            #expect(error == .resourceChanged)
        }
    }

    @Test("legacy Kotlin JSON is projected without dropping unknown fields")
    func legacyJSON() throws {
        let data = Data("""
        {
          "type": "http",
          "id": 42,
          "link": "https://example.test/archive.zip",
          "headers": {"Cookie": "session=keep"},
          "folder": "/tmp/downloads",
          "name": "archive.zip",
          "contentLength": 12,
          "etag": "\\\"v1\\\"",
          "lastModified": "Wed, 21 Oct 2015 07:28:00 GMT",
          "dateAdded": 1700000000000,
          "status": "Paused",
          "futureField": {"keep": true}
        }
        """.utf8)
        let decoded = try LegacyJSONCodec.decodeRecord(data: data)
        #expect(decoded.record.id == 42)
        #expect(decoded.record.status == .paused)
        #expect(decoded.record.source.headers?["Cookie"] == "session=keep")
        #expect(decoded.record.totalBytes == 12)
        #expect(decoded.record.etag == "\"v1\"")
        #expect(decoded.record.lastModified == "Wed, 21 Oct 2015 07:28:00 GMT")

        var changed = decoded.record
        changed.status = .completed
        let encoded = try LegacyJSONCodec.encodeRecord(changed, preserving: decoded.rawObject)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect((object?["futureField"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(object?["status"] as? String == "Completed")
    }

    @Test("legacy parts sidecar is restored and written back")
    func partsSidecar() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        let record = makeRecord(id: 8, folder: root)
        try await store.save(record)
        let partsURL = root.appendingPathComponent("config/download_db/parts/8.json")
        try Data("""
        {"type":"ranges","list":[{"from":0,"to":4,"current":5}]}
        """.utf8).write(to: partsURL)
        let loaded = try await store.load()
        #expect(loaded.first?.parts.first?.completed == true)
        #expect(loaded.first?.downloadedBytes == 0)
        var updated = try #require(loaded.first)
        updated.downloadedBytes = 5
        try await store.save(updated)
        let savedParts = try String(contentsOf: partsURL, encoding: .utf8)
        #expect(savedParts.contains("current"))
        updated.parts = []
        try await store.save(updated)
        #expect(!FileManager.default.fileExists(atPath: partsURL.path))
    }

    private func makeRecord(
        id: DownloadID,
        folder: URL,
        source: DownloadSource = DownloadSource(kind: .http, link: "https://fixture.invalid/file")
    ) -> DownloadRecord {
        DownloadRecord(id: id, source: source, folder: folder.path, name: "file-\(id).bin")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-download-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class MemoryTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    var handler: (@Sendable (URLRequest) -> Reply)?

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        guard let reply = handler?(request) else {
            throw URLError(.unknown)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(reply.body)
            continuation.finish()
        }
        return HTTPTransportResponse(statusCode: reply.status, headers: reply.headers, body: stream)
    }

    static func reply(status: Int, headers: [String: String], body: Data) -> Reply {
        Reply(status: status, headers: headers, body: body)
    }
}

private final class SlowTransport: HTTPTransport, @unchecked Sendable {
    private let delay: Duration
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        incrementActive()

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                try? await Task.sleep(for: delay)
                decrementActive()
                continuation.yield(Data("ok".utf8))
                continuation.finish()
            }
        }
        return HTTPTransportResponse(
            statusCode: 200,
            headers: ["Content-Length": "2"],
            body: stream
        )
    }

    func maxObserved() -> Int {
        readMaximum()
    }

    private func incrementActive() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    private func decrementActive() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    private func readMaximum() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
}

private final class RetryTransport: HTTPTransport, @unchecked Sendable {
    private let failuresBeforeSuccess: Int
    private let lock = NSLock()
    private var requests = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let requestNumber = incrementRequestCount()
        if requestNumber <= failuresBeforeSuccess {
            throw DownloadCoreError.httpStatus(503)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("ok".utf8))
            continuation.finish()
        }
        return HTTPTransportResponse(statusCode: 200, headers: ["Content-Length": "2"], body: stream)
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func incrementRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        return requests
    }
}

private final class RangeTransport: HTTPTransport, @unchecked Sendable {
    private let content: Data
    private let lock = NSLock()
    private(set) var rangeRequests = 0

    init(content: Data) {
        self.content = content
    }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let stream: AsyncThrowingStream<Data, Error>
        if request.httpMethod == "HEAD" {
            stream = AsyncThrowingStream { continuation in
                continuation.finish()
            }
            return HTTPTransportResponse(
                statusCode: 200,
                headers: [
                    "Content-Length": String(content.count),
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\""
                ],
                body: stream
            )
        }

        guard let rangeHeader = request.value(forHTTPHeaderField: "Range"),
              let (start, end) = parseRange(rangeHeader),
              start >= 0,
              end >= start,
              end < Int64(content.count) else {
            throw DownloadCoreError.responseMismatch("RangeTransport requires a valid range")
        }
        lock.withLock {
            rangeRequests += 1
        }
        let bytes = Data(content[Int(start)...Int(end)])
        stream = AsyncThrowingStream { continuation in
            continuation.yield(bytes)
            continuation.finish()
        }
        return HTTPTransportResponse(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes \(start)-\(end)/\(content.count)",
                "Content-Length": String(bytes.count),
                "ETag": "\"v1\""
            ],
            body: stream
        )
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rangeRequests
    }

    private func parseRange(_ value: String) -> (Int64, Int64)? {
        let raw = value.replacingOccurrences(of: "bytes=", with: "")
        let bounds = raw.split(separator: "-", maxSplits: 1).compactMap { Int64($0) }
        guard bounds.count == 2 else { return nil }
        return (bounds[0], bounds[1])
    }
}
