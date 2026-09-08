import Foundation
import CoreData
import Testing
@testable import CoolDownloadCore

@Suite("商用一致性")
struct CommercialReadinessTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-consistency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("并发新增保留每条记录并独立预留同名文件", arguments: 0..<10)
    func concurrentAdds(round: Int) async throws {
        let root = try root()
        let store = try DownloadStore(rootURL: root)
        let service = DownloadService(store: store, defaultFolder: root,
            schedulerConfiguration: .init(appendExtensionToIncompleteDownloads: true))
        try await service.boot()
        let ids = try await withThrowingTaskGroup(of: DownloadID.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await service.add(.init(source: .init(kind: .http,
                        link: "https://example.test/\(round)/\(index)"), name: "same.bin"))
                }
            }
            var result: [DownloadID] = []
            for try await id in group { result.append(id) }
            return result
        }
        let snapshot = await service.snapshot().downloads
        let reopened = try DownloadStore(rootURL: root)
        let persisted = try await reopened.load()
        #expect(Set(ids).count == 100)
        #expect(snapshot.count == 100)
        #expect(persisted.count == 100)
        #expect(Set(persisted.map(\.name)).count == 100)
        #expect(Set(persisted.map(\.incompleteURL)).count == 100)
        #expect(Set(persisted.map(\.source.link)).count == 100)
        await service.shutdown()
    }
    @Test("编号预留跨失败与重开保持唯一并拒绝整数溢出")
    func identifierBoundary() async throws {
        let root = try root()
        let store = try DownloadStore(rootURL: root)
        #expect(try await store.reserveNextID() == 1)
        #expect(try await store.reserveNextID() == 2)
        let record = DownloadRecord(id: 100, source: .init(kind: .http, link: "https://example.test/a"), folder: root.path, name: "a")
        try await store.save(record)
        #expect(try await store.reserveNextID() == 101)
        let reopened = try DownloadStore(rootURL: root)
        #expect(try await reopened.reserveNextID() == 101)
        let maximum = DownloadRecord(id: Int64.max, source: record.source, folder: root.path, name: "max")
        try await store.save(maximum)
        await #expect(throws: DownloadCoreError.identifierExhausted) {
            try await store.reserveNextID()
        }
    }

    @Test("保存失败不发布新任务且释放同名预留")
    func failedAddReleasesName() async throws {
        let root = try root()
        let database = try MetadataDatabase(rootURL: root)
        let store = try DownloadStore(rootURL: root, database: database)
        let service = DownloadService(store: store, defaultFolder: root)
        try await service.boot()
        // An invalid pending managed object forces a real Core Data save failure.
        database.perform { context in
            _ = NSEntityDescription.insertNewObject(forEntityName: "DownloadQueue", into: context)
        }
        await #expect(throws: (any Error).self) {
            try await service.add(.init(source: .init(kind: .http, link: "https://example.test/a"), name: "same.bin"))
        }
        #expect(await service.snapshot().downloads.isEmpty)
        let id = try await service.add(.init(source: .init(kind: .http, link: "https://example.test/b"), name: "same.bin"))
        #expect(id == 2)
        #expect(await service.snapshot().downloads.first?.name == "same.bin")
        #expect(try await store.load().count == 1)
        await service.shutdown()
    }

    @Test("完成时出现外部同名文件不会被替换")
    func finishPreservesExternalFile() async throws {
        let root = try root()
        let record = DownloadRecord(id: 1, source: .init(kind: .http, link: "https://example.test/a"), folder: root.path, name: "a")
        let writer = try PartFileWriter(record: record)
        try await writer.append(Data("download".utf8))
        try Data("external".utf8).write(to: record.destinationURL)
        await #expect(throws: (any Error).self) { try await writer.finish() }
        #expect(try Data(contentsOf: record.destinationURL) == Data("external".utf8))
        #expect(try Data(contentsOf: record.incompleteURL) == Data("download".utf8))
    }

}
