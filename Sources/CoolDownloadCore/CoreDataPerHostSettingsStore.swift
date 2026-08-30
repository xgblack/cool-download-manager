import Foundation
import CoreData

/// Persists non-sensitive host overrides in Core Data and keeps usernames and
/// passwords in Keychain. The public value type remains unchanged for the UI
/// and downloader, but SQLite only contains the credential account names.
public actor PerHostSettingsStore {
    public nonisolated let settingsURL: URL
    public nonisolated let metadataURL: URL
    private let database: MetadataDatabase
    private let keychain: KeychainStore
    private var values: [PerHostSettingsItem] = []
    private var loaded = false

    public init(dataRoot: URL) throws {
        try self.init(
            dataRoot: dataRoot,
            database: MetadataDatabase.shared(rootURL: dataRoot),
            keychain: .shared
        )
    }

    public init(dataRoot: URL, database: MetadataDatabase, keychain: KeychainStore = .shared) throws {
        settingsURL = dataRoot.standardizedFileURL
        self.database = database
        metadataURL = database.storeURL
        self.keychain = keychain
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    public func load() throws -> [PerHostSettingsItem] {
        if loaded { return values }
        do {
            let decoded: [PerHostSettingsItem] = try database.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "PerHostSettings")
                request.sortDescriptors = [
                    NSSortDescriptor(key: "sortOrder", ascending: true),
                    NSSortDescriptor(key: "host", ascending: true)
                ]
                return try context.fetch(request).map { object in
                    let host = (object.value(forKey: "host") as? String) ?? ""
                    let usernameKey = object.value(forKey: "usernameKey") as? String
                    let passwordKey = object.value(forKey: "passwordKey") as? String
                    let username = try usernameKey.flatMap { try keychain.read(account: $0) }
                    let password = try passwordKey.flatMap { try keychain.read(account: $0) }
                    let threadCount = (object.value(forKey: "threadCount") as? NSNumber).map { Int($0.int64Value) }
                    return try PerHostSettingsItem(
                        host: host,
                        username: username,
                        password: password,
                        userAgent: object.value(forKey: "userAgent") as? String,
                        threadCount: threadCount,
                        speedLimit: (object.value(forKey: "speedLimit") as? NSNumber)?.int64Value
                    ).validated()
                }
            }
            values = decoded
            loaded = true
            return values
        } catch let error as PerHostSettingsError {
            throw error
        } catch {
            throw PerHostSettingsError.corrupt(metadataURL, error.localizedDescription)
        }
    }

    @discardableResult
    public func save(_ items: [PerHostSettingsItem]) throws -> [PerHostSettingsItem] {
        let normalized = try normalize(items)
        do {
            try database.perform { context in
                let existing = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "PerHostSettings"))
                let incomingHosts = Set(normalized.map(\.host))
                for object in existing {
                    guard let host = object.value(forKey: "host") as? String,
                          !incomingHosts.contains(host) else { continue }
                    try deleteCredential(for: object, key: "usernameKey")
                    try deleteCredential(for: object, key: "passwordKey")
                    context.delete(object)
                }
                for (index, value) in normalized.enumerated() {
                    let request = NSFetchRequest<NSManagedObject>(entityName: "PerHostSettings")
                    request.predicate = NSPredicate(format: "host == %@", value.host)
                    request.fetchLimit = 1
                    let object = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(
                        forEntityName: "PerHostSettings",
                        into: context
                    )
                    object.setValue(value.host, forKey: "host")
                    object.setValue(value.userAgent, forKey: "userAgent")
                    object.setValue(value.threadCount, forKey: "threadCount")
                    object.setValue(value.speedLimit, forKey: "speedLimit")
                    object.setValue(Int64(index), forKey: "sortOrder")
                    let usernameKey = credentialAccount(host: value.host, kind: "username")
                    let passwordKey = credentialAccount(host: value.host, kind: "password")
                    try keychain.write(value.username, account: usernameKey)
                    try keychain.write(value.password, account: passwordKey)
                    object.setValue(value.username == nil ? nil : usernameKey, forKey: "usernameKey")
                    object.setValue(value.password == nil ? nil : passwordKey, forKey: "passwordKey")
                }
                try context.save()
            }
            values = normalized
            loaded = true
            return values
        } catch let error as PerHostSettingsError {
            throw error
        } catch {
            throw PerHostSettingsError.writeFailed(metadataURL, error.localizedDescription)
        }
    }

    public func matching(host: String) throws -> PerHostSettingsItem? {
        let candidate = host.lowercased()
        return try load()
            .filter { $0.matches(host: candidate) }
            .sorted {
                let lhsWildcards = $0.host.filter { $0 == "*" }.count
                let rhsWildcards = $1.host.filter { $0 == "*" }.count
                if lhsWildcards != rhsWildcards { return lhsWildcards < rhsWildcards }
                if $0.host.count != $1.host.count { return $0.host.count > $1.host.count }
                return $0.host < $1.host
            }
            .first
    }

    private func normalize(_ items: [PerHostSettingsItem]) throws -> [PerHostSettingsItem] {
        var seen = Set<String>()
        var result: [PerHostSettingsItem] = []
        for value in items {
            let valid = try value.validated()
            guard seen.insert(valid.host).inserted else {
                throw PerHostSettingsError.invalid("主机设置不能重复：\(valid.host)")
            }
            result.append(valid)
        }
        return result
    }

    private func credentialAccount(host: String, kind: String) -> String {
        "per-host/\(host)/\(kind)"
    }

    private func deleteCredential(for object: NSManagedObject, key: String) throws {
        guard let account = object.value(forKey: key) as? String else { return }
        try keychain.write(nil, account: account)
    }
}
