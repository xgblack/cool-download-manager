import Foundation

public actor LegacyQueueStore {
    private let queuesURL: URL

    public init(dataRoot: URL) throws {
        self.queuesURL = dataRoot
            .standardizedFileURL
            .appendingPathComponent("config/download_db/queues", isDirectory: true)
        try FileManager.default.createDirectory(at: queuesURL, withIntermediateDirectories: true)
    }

    public func load() throws -> [IntegrationQueue] {
        let files = try FileManager.default.contentsOfDirectory(
            at: queuesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var queues: [IntegrationQueue] = []
        for file in files where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.int64Value,
                  let name = object["name"] as? String else {
                throw LegacyQueueStoreError.corrupt(file)
            }
            queues.append(IntegrationQueue(id: id, name: name))
        }
        if queues.isEmpty {
            return [IntegrationQueue(id: 0, name: "主队列")]
        }
        return queues.sorted { $0.id < $1.id }
    }
}

public enum LegacyQueueStoreError: Error, LocalizedError, Sendable, Equatable {
    case corrupt(URL)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url): return "无法读取队列记录：\(url.path)"
        }
    }
}
