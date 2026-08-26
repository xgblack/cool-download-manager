import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("CoolDownloadCore")
struct CoreTests {
    @Test("checksum calculator hashes files incrementally")
    func checksumCalculator() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("checksum.txt")
        try Data("hello world".utf8).write(to: file)
        let checksum = try FileChecksumCalculator().calculate(fileURL: file, algorithm: .sha256)
        #expect(checksum.description == "SHA-256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        #expect(FileChecksum(string: checksum.description) == checksum)
        #expect(FileChecksum(string: "SHA-256:not-hex") == nil)
    }

    @Test("checksum calculator reports missing files")
    func checksumMissingFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        do {
            _ = try FileChecksumCalculator().calculate(fileURL: missing, algorithm: .md5)
            Issue.record("missing checksum file should fail")
        } catch let error as ChecksumError {
            #expect(error == .fileNotFound(missing))
        }
    }

    @Test("per-host settings round trip and wildcard precedence")
    func perHostSettings() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PerHostSettingsStore(dataRoot: root)
        let exact = PerHostSettingsItem(host: "cdn.example.test", threadCount: 4)
        let wildcard = PerHostSettingsItem(host: "*.example.test", threadCount: 2, speedLimit: 10)
        _ = try await store.save([exact, wildcard])
        #expect(try await store.matching(host: "cdn.example.test") == exact)
        #expect(try await store.matching(host: "img.example.test") == wildcard)
        let reopened = try PerHostSettingsStore(dataRoot: root)
        #expect(try await reopened.load() == [exact, wildcard])
    }

    @Test("per-host settings reject duplicate and malformed hosts")
    func perHostSettingsValidation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PerHostSettingsStore(dataRoot: root)
        do {
            _ = try await store.save([
                PerHostSettingsItem(host: "example.test"),
                PerHostSettingsItem(host: "EXAMPLE.TEST")
            ])
            Issue.record("duplicate normalized hosts should be rejected")
        } catch let error as PerHostSettingsError {
            #expect(error == .invalid("主机设置不能重复：example.test"))
        }
        do {
            _ = try await store.save([PerHostSettingsItem(host: "https://example.test/path")])
            Issue.record("host paths should be rejected")
        } catch let error as PerHostSettingsError {
            #expect(error == .invalid("主机设置不能包含路径"))
        }
    }

    @Test("task settings persist and validate independently of global settings")
    func taskSettingsRoundTrip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(
            store: store,
            defaultFolder: root,
            schedulerConfiguration: DownloadSchedulerConfiguration(
                maxConcurrentDownloads: 2,
                maxConnectionsPerDownload: 8,
                speedLimit: 4096
            )
        )
        try await service.boot()
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/task.bin"),
            folder: root.path
        ))
        let settings = DownloadTaskSettings(
            threadCount: 2,
            speedLimit: 128,
            completionAction: .lock,
            showCompletionDialog: false,
            showPartInfo: true
        )
        _ = try await service.updateTaskSettings(id: id, settings: settings)
        #expect(await service.snapshot().downloads.first?.taskSettings == settings)

        do {
            _ = try await service.updateTaskSettings(
                id: id,
                settings: DownloadTaskSettings(threadCount: 65)
            )
            Issue.record("thread counts above the supported range should fail")
        } catch let error as DownloadCoreError {
            #expect(error == .invalidTaskSettings("任务线程数必须在 1 到 64 之间"))
        }
    }

    @Test("per-host headers and credentials override global request defaults")
    func perHostRequestOverrides() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HeaderCaptureTransport(body: Data("ok".utf8))
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root,
            schedulerConfiguration: DownloadSchedulerConfiguration(userAgent: "GlobalAgent")
        )
        try await service.boot()
        await service.updatePerHostSettings([
            PerHostSettingsItem(
                host: "downloads.example.test",
                username: "alice",
                password: "secret",
                userAgent: "HostAgent"
            )
        ])
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(
                kind: .http,
                link: "https://downloads.example.test/file.bin",
                downloadPage: "https://downloads.example.test/page"
            ),
            folder: root.path,
            start: true
        ))

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await service.snapshot().downloads.first(where: { $0.id == id })?.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.snapshot().downloads.first(where: { $0.id == id })?.status == .completed)
        let request = try #require(transport.lastRequest())
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "HostAgent")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://downloads.example.test/page")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
    }

    @Test("batch expansion matches the legacy padding rules")
    func batchExpansion() throws {
        let expander = BatchDownloadExpander()
        #expect(try expander.expand(
            pattern: "https://example.test/photo-*.jpg",
            start: 8,
            end: 10
        ) == [
            "https://example.test/photo-08.jpg",
            "https://example.test/photo-09.jpg",
            "https://example.test/photo-10.jpg"
        ])
        #expect(try expander.expand(
            pattern: "https://example.test/*-*.bin",
            start: 1,
            end: 2,
            wildcardLength: .unspecified
        ) == [
            "https://example.test/1-1.bin",
            "https://example.test/2-2.bin"
        ])
        #expect(try expander.expand(
            pattern: "https://example.test/*.bin",
            start: 1,
            end: 2,
            wildcardLength: .custom(4)
        ).first == "https://example.test/0001.bin")
    }

    @Test("batch expansion rejects invalid and oversized ranges")
    func batchExpansionValidation() throws {
        let expander = BatchDownloadExpander()
        #expect(throws: BatchDownloadError.missingWildcard) {
            try expander.expand(pattern: "https://example.test/file.bin", start: 1, end: 2)
        }
        #expect(throws: BatchDownloadError.invalidRange) {
            try expander.expand(pattern: "https://example.test/*.bin", start: 2, end: 1)
        }
        #expect(throws: BatchDownloadError.tooManyItems(maximum: 1000)) {
            try expander.expand(pattern: "https://example.test/*.bin", start: 0, end: 1000)
        }
    }

    @Test("queue store migrates legacy fields and preserves unknown fields")
    func queueStoreRoundTrip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("config/download_db/queues", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":12,"name":"Archive","maxConcurrent":4,"queueItems":[3,8],"futureField":{"keep":true}}"#.utf8)
            .write(to: directory.appendingPathComponent("12.json"))

        let store = try QueueStore(dataRoot: root)
        let loaded = try await store.load()
        #expect(loaded == [DownloadQueueModel(
            id: 12,
            name: "Archive",
            maxConcurrent: 4,
            queueItems: [3, 8]
        )])
        var changed = try await store.model(id: 12)
        changed.stopQueueOnEmpty = true
        _ = try await store.save(changed)
        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("12.json"))
            ) as? [String: Any]
        )
        #expect((object["futureField"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(object["stopQueueOnEmpty"] as? Bool == true)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "tmp" }.isEmpty
        )
    }

    @Test("queue store reads Kotlin weekday enum names")
    func queueStoreReadsLegacyWeekdayNames() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("config/download_db/queues", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyQueue = #"""
        {
          "id": 0,
          "name": "Main",
          "maxConcurrent": 2,
          "queueItems": [],
          "scheduledTimes": {
            "daysOfWeek": ["MONDAY", "WEDNESDAY", "SUNDAY"],
            "startTime": "02:30",
            "endTime": "07:30",
            "enabledStartTime": false,
            "enabledEndTime": false
          },
          "stopQueueOnEmpty": false
        }
        """#
        try Data(legacyQueue.utf8).write(to: directory.appendingPathComponent("0.json"))

        let store = try QueueStore(dataRoot: root)
        let loaded = try await store.load()
        #expect(loaded.first?.id == 0)
        #expect(loaded.first?.scheduledTimes.daysOfWeek == [1, 3, 7])
    }

    @Test("queue store creates, edits and protects the main queue")
    func queueStoreCRUD() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(dataRoot: root)
        #expect(try await store.load().first?.id == 0)
        let created = try await store.create(name: "Nightly")
        #expect(created.id > 10)
        var edited = created
        edited.name = "Nightly 2"
        edited.queueItems = [4, 5]
        _ = try await store.save(edited)
        #expect(try await store.model(id: created.id) == edited)
        let second = try await store.create(name: "Later")
        try await store.assignItems([4, 5], to: second.id)
        #expect(try await store.model(id: created.id).queueItems == [])
        #expect(try await store.model(id: second.id).queueItems == [4, 5])
        try await store.assignItems([4], to: nil)
        #expect(try await store.model(id: second.id).queueItems == [5])
        try await store.remove(id: created.id)
        do {
            _ = try await store.model(id: created.id)
            Issue.record("removed queue should not be readable")
        } catch let error as QueueStoreError {
            #expect(error == .notFound(created.id))
        }
        do {
            try await store.remove(id: 0)
            Issue.record("the main queue should not be removable")
        } catch let error as QueueStoreError {
            #expect(error == .cannotDeleteMainQueue)
        }
    }

    @Test("category store loads defaults, preserves fields and moves items")
    func categoryStoreCRUD() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultFolder = root.appendingPathComponent("Downloads", isDirectory: true)
        let store = try CategoryStore(dataRoot: root, defaultFolder: defaultFolder)

        let defaults = try await store.load()
        #expect(defaults.count == 6)
        #expect(defaults.first?.name == "Compressed")
        #expect(defaults.first?.acceptedFileTypes.contains("zip") == true)

        let custom = try await store.create(
            name: "Fixtures",
            path: root.appendingPathComponent("Fixtures", isDirectory: true).path,
            acceptedFileTypes: ["bin"]
        )
        var edited = custom
        edited.acceptedURLPatterns = ["example.test/*"]
        _ = try await store.save(edited)
        try await store.assignItems([7, 8], to: custom.id)
        #expect(try await store.model(id: custom.id).items == [7, 8])
        #expect(try await store.matchingCategory(fileName: "file.bin", url: "https://example.test/a")?.id == custom.id)

        let raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.categoriesURL)) as? [[String: Any]]
        )
        #expect(raw.contains { ($0["id"] as? Int) == Int(custom.id) })

        try await store.assignItems([7], to: nil)
        #expect(try await store.model(id: custom.id).items == [8])
    }

    @Test("queue schedule evaluates weekdays and overnight windows")
    func queueScheduleEvaluation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let mondayMorning = calendar.date(from: DateComponents(
            calendar: calendar, year: 2026, month: 8, day: 24, hour: 3, minute: 0
        ))!
        let mondayMidday = calendar.date(from: DateComponents(
            calendar: calendar, year: 2026, month: 8, day: 24, hour: 12, minute: 0
        ))!
        let mondayLate = calendar.date(from: DateComponents(
            calendar: calendar, year: 2026, month: 8, day: 24, hour: 23, minute: 0
        ))!
        let overnight = QueueSchedule(
            daysOfWeek: [1],
            startTime: "22:00",
            endTime: "06:00",
            enabledStartTime: true,
            enabledEndTime: true
        )
        #expect(overnight.isActive(at: mondayMorning, calendar: calendar))
        #expect(!overnight.isActive(at: mondayMidday, calendar: calendar))
        #expect(overnight.isActive(at: mondayLate, calendar: calendar))
        #expect(QueueSchedule.default.isActive(at: mondayLate, calendar: calendar))
    }

    @Test("settings use defaults when the file is absent")
    func settingsDefaults() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SettingsStore(dataRoot: root)
        let settings = try await store.load()
        #expect(settings.threadCount == 8)
        #expect(settings.maxConcurrentDownloads == 3)
        #expect(settings.defaultDownloadFolder.hasSuffix("Downloads/ABDM"))
        #expect(!FileManager.default.fileExists(atPath: store.settingsURL.path))
    }

    @Test("settings save round trips and preserves unknown fields")
    func settingsRoundTrip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"futureSetting":{"keep":true},"threadCount":12,"defaultDarkTheme":"dark","defaultLightTheme":"light","language":"zh-CN","font":"Helvetica","useNativeMenuBar":false,"useSystemTray":false,"dnsServers":["1.1.1.1"]}"#.utf8)
            .write(to: config.appendingPathComponent("appSettings.json"))

        let store = try SettingsStore(dataRoot: root)
        var settings = try await store.load()
        #expect(settings.threadCount == 12)
        settings.apiPort = 16200
        settings.proxyPassword = "secret-value"
        let saved = try await store.save(settings)
        #expect(saved == settings)

        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: config.appendingPathComponent("appSettings.json"))
            ) as? [String: Any]
        )
        #expect((object["futureSetting"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(object["apiPort"] as? Int == 16200)
        #expect(object["proxyPassword"] as? String == "secret-value")
        #expect(object["defaultDarkTheme"] == nil)
        #expect(object["defaultLightTheme"] == nil)
        #expect(object["language"] == nil)
        #expect(object["font"] == nil)
        #expect(object["useNativeMenuBar"] == nil)
        #expect(object["useSystemTray"] == nil)
        #expect(object["dnsServers"] == nil)

        let reopened = try SettingsStore(dataRoot: root)
        #expect(try await reopened.load() == settings)
    }

    @Test("settings reject invalid ranges without exposing secrets")
    func settingsValidation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(dataRoot: root)
        var settings = try await store.load()
        settings.apiPort = 0
        settings.apiAuthKey = "do-not-leak"

        do {
            _ = try await store.save(settings)
            Issue.record("invalid API port should be rejected")
        } catch let error as SettingsStoreError {
            #expect(error == .invalid("API 端口必须在 1 到 65535 之间"))
            #expect(!error.localizedDescription.contains("do-not-leak"))
        }
    }

    @Test("corrupt settings are not cached as defaults")
    func corruptSettingsNotCached() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(dataRoot: root)
        let settingsURL = store.settingsURL
        try Data("[]".utf8).write(to: settingsURL)
        do {
            _ = try await store.load()
            Issue.record("a non-object settings root should be rejected")
        } catch let error as SettingsStoreError {
            #expect(error == .corrupt(settingsURL, "根值不是 JSON 对象"))
        }
        try Data(#"{"threadCount":4}"#.utf8).write(to: settingsURL)
        #expect(try await store.load().threadCount == 4)
    }

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

    @Test("automatic filename comes from signed URL content disposition")
    func signedURLFilename() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DownloadService(store: try DownloadStore(rootURL: root), defaultFolder: root)
        try await service.boot()

        let link = "https://cdn.example.test/3299e15a-323c-4a57-82d3-1591ea65f709?response-content-disposition=attachment%3B+filename%3DABDownloadManager_1.10.2_linux_x64.tar.gz"
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: link),
            folder: root.path
        ))

        #expect(await service.snapshot().downloads.first(where: { $0.id == id })?.name == "ABDownloadManager_1.10.2_linux_x64.tar.gz")
    }

    @Test("HTTP response exposes Content-Disposition filename")
    func httpResponseFilename() async throws {
        let transport = MemoryTransport()
        transport.handler = { request in
            let body = request.httpMethod == "HEAD" ? Data() : Data("body".utf8)
            return MemoryTransport.reply(
                status: 200,
                headers: [
                    "Content-Length": request.httpMethod == "HEAD" ? "4" : "4",
                    "Content-Disposition": "attachment; filename*=UTF-8''report%20%E4%B8%AD%E6%96%87.zip"
                ],
                body: body
            )
        }
        let downloader = HTTPDownloader(transport: transport)
        let source = DownloadSource(kind: .http, link: "https://fixture.invalid/download")
        let metadata = try await downloader.probe(source: source)
        #expect(metadata.fileName == "report 中文.zip")

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try PartFileWriter(record: makeRecord(id: 30, folder: root, source: source))
        let result = try await downloader.download(source: source, offset: 0, writer: writer)
        #expect(result.fileName == metadata.fileName)
    }

    @Test("download service finishes an automatic task with the server filename")
    func serviceAdoptsHTTPFilename() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(
                status: 200,
                headers: [
                    "Content-Length": "4",
                    "Content-Disposition": "attachment; filename=server-name.bin"
                ],
                body: Data("body".utf8)
            )
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root
        )
        try await service.boot()
        let automaticLink = "https://fixture.invalid/3299e15a-323c-4a57-82d3-1591ea65f709"
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: automaticLink),
            folder: root.path,
            start: true
        ))

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await service.snapshot().downloads.first(where: { $0.id == id })?.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let completed = try #require(await service.snapshot().downloads.first(where: { $0.id == id }))
        #expect(completed.status == .completed)
        #expect(completed.name == "server-name.bin")
        #expect(try Data(contentsOf: completed.destinationURL) == Data("body".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("3299e15a-323c-4a57-82d3-1591ea65f709").path))

        let manualID = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/another-download"),
            folder: root.path,
            name: "manual-name.bin",
            start: true
        ))
        while ContinuousClock.now < deadline + .seconds(2) {
            if await service.snapshot().downloads.first(where: { $0.id == manualID })?.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let manual = try #require(await service.snapshot().downloads.first(where: { $0.id == manualID }))
        #expect(manual.status == .completed)
        #expect(manual.name == "manual-name.bin")
        #expect(try Data(contentsOf: manual.destinationURL) == Data("body".utf8))
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

    @Test("started queues emit one completion event and honor their policy")
    func queueCompletionEvent() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: ["Content-Length": "2"], body: Data("ok".utf8))
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DownloadService(
            store: try DownloadStore(rootURL: root),
            downloader: HTTPDownloader(transport: transport),
            defaultFolder: root
        )
        try await service.boot()
        await service.updateQueuePolicies([
            7: DownloadQueuePolicy(
                maxConcurrent: 1,
                stopQueueOnEmpty: true,
                completionAction: .lock
            )
        ])
        let id = try await service.add(AddDownloadRequest(
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/queue-event", suggestedName: "event.bin"),
            queueID: 7
        ))
        let stream = await service.queueEvents()
        let eventTask = Task<DownloadQueueEvent?, Never> {
            for await event in stream {
                return event
            }
            return nil
        }
        try await Task.sleep(for: .milliseconds(1))
        try await service.startQueue(id: 7)

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              await service.snapshot().downloads.first(where: { $0.id == id })?.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.snapshot().downloads.first(where: { $0.id == id })?.status == .completed)
        let event = await eventTask.value
        #expect(event == .becameEmpty(queueID: 7, completionAction: .lock))
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

    @Test("completed downloads can be explicitly redownloaded")
    func serviceRedownloadsCompletedFile() async throws {
        let transport = MemoryTransport()
        transport.handler = { _ in
            MemoryTransport.reply(status: 200, headers: ["Content-Length": "2"], body: Data("ok".utf8))
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
            source: DownloadSource(kind: .http, link: "https://fixture.invalid/redownload", suggestedName: "same.bin"),
            start: true
        ))
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              await service.snapshot().downloads.first(where: { $0.id == id })?.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(await service.snapshot().downloads.first(where: { $0.id == id }))
        #expect(first.status == .completed)
        try await service.redownload(ids: [id])
        while ContinuousClock.now < deadline,
              await service.snapshot().downloads.first(where: { $0.id == id })?.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = try #require(await service.snapshot().downloads.first(where: { $0.id == id }))
        #expect(second.status == .completed)
        #expect(try Data(contentsOf: second.destinationURL) == Data("ok".utf8))
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

    @Test("part file preparation preserves resume bytes while extending allocation")
    func partFilePreparationPreservesResumeBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = makeRecord(id: 22, folder: root)
        let writer = try PartFileWriter(record: record)
        try await writer.append(Data("resume".utf8))
        try await writer.prepare(length: 10, sparse: false)
        #expect(try await writer.length() == 10)
        let bytes = try Data(contentsOf: record.incompleteURL)
        #expect(bytes.prefix(6) == Data("resume".utf8))
        #expect(bytes.suffix(4) == Data(repeating: 0, count: 4))
    }

    @Test("deleted completed files can be reconciled without removing present files")
    func reconcileDeletedCompletedFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadStore(rootURL: root)
        var missing = makeRecord(id: 23, folder: root)
        missing.status = .completed
        var present = makeRecord(id: 24, folder: root)
        present.status = .completed
        try Data("kept".utf8).write(to: present.destinationURL)
        try await store.save(missing)
        try await store.save(present)

        let service = DownloadService(store: store, defaultFolder: root)
        try await service.boot()
        #expect(try await service.removeCompletedDownloadsMissingFiles() == [23])
        #expect(Set(await service.snapshot().downloads.map(\.id)) == [24])
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
          "preferredConnectionCount": 4,
          "speedLimit": 1024,
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
        #expect(decoded.record.taskSettings?.threadCount == 4)
        #expect(decoded.record.taskSettings?.speedLimit == 1024)

        var changed = decoded.record
        changed.status = .completed
        let encoded = try LegacyJSONCodec.encodeRecord(changed, preserving: decoded.rawObject)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect((object?["futureField"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(object?["status"] as? String == "Completed")
        #expect(object?["preferredConnectionCount"] as? Int == 4)
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

private final class HeaderCaptureTransport: HTTPTransport, @unchecked Sendable {
    private let body: Data
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(body: Data) {
        self.body = body
    }

    func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        lock.withLock { requests.append(request) }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(body)
            continuation.finish()
        }
        return HTTPTransportResponse(
            statusCode: 200,
            headers: ["Content-Length": String(body.count)],
            body: stream
        )
    }

    func lastRequest() -> URLRequest? {
        lock.withLock { requests.last }
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
