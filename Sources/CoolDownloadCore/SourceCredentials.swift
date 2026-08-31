import Foundation

/// Request material that must never be encoded into ordinary task metadata.
/// Keychain-backed stores serialize it internally, but the type deliberately
/// does not conform to Codable so it cannot be embedded in DownloadRecord.
public struct DownloadSecureSource: Sendable, Equatable {
    public let link: String
    public let headers: [String: String]?
    public let downloadPage: String?

    public init(
        link: String,
        headers: [String: String]? = nil,
        downloadPage: String? = nil
    ) {
        self.link = link
        self.headers = headers
        self.downloadPage = downloadPage
    }
}

public protocol DownloadCredentialStore: Sendable {
    func read(reference: String) throws -> DownloadSecureSource?
    func write(_ source: DownloadSecureSource, reference: String) throws
    func remove(reference: String) throws
}

public final class KeychainDownloadCredentialStore: @unchecked Sendable, DownloadCredentialStore {
    private let keychain: KeychainStore

    public init(
        keychain: KeychainStore = KeychainStore(
            service: "\(AppPaths.bundleIdentifier).download-sources"
        )
    ) {
        self.keychain = keychain
    }

    public func read(reference: String) throws -> DownloadSecureSource? {
        guard let value = try keychain.read(account: reference),
              let data = value.data(using: .utf8) else {
            return nil
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let link = dictionary["link"] as? String else {
            throw DownloadCoreError.corruptRecord(
                URL(fileURLWithPath: "Keychain/\(reference)"),
                "下载来源凭据格式无效"
            )
        }
        let headers = dictionary["headers"] as? [String: String]
        return DownloadSecureSource(
            link: link,
            headers: headers,
            downloadPage: dictionary["downloadPage"] as? String
        )
    }

    public func write(_ source: DownloadSecureSource, reference: String) throws {
        var object: [String: Any] = ["link": source.link]
        if let headers = source.headers {
            object["headers"] = headers
        }
        if let downloadPage = source.downloadPage {
            object["downloadPage"] = downloadPage
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw DownloadCoreError.invalidSourcePatch("下载来源凭据无法编码")
        }
        try keychain.write(value, account: reference)
    }

    public func remove(reference: String) throws {
        try keychain.write(nil, account: reference)
    }
}

public final class InMemoryDownloadCredentialStore: @unchecked Sendable, DownloadCredentialStore {
    private let lock = NSLock()
    private var values: [String: DownloadSecureSource] = [:]

    public init() {}

    public func read(reference: String) throws -> DownloadSecureSource? {
        lock.withLock { values[reference] }
    }

    public func write(_ source: DownloadSecureSource, reference: String) throws {
        lock.withLock { values[reference] = source }
    }

    public func remove(reference: String) throws {
        lock.withLock { values[reference] = nil }
    }
}

public struct PreparedDownloadSource: Sendable, Equatable {
    public let projection: DownloadSource
    public let secureSource: DownloadSecureSource?

    public init(projection: DownloadSource, secureSource: DownloadSecureSource?) {
        self.projection = projection
        self.secureSource = secureSource
    }
}

public enum DownloadSourceSecurity {
    private static let publicHeaderNames: Set<String> = [
        "accept", "accept-encoding", "accept-language", "cache-control", "user-agent"
    ]

    public static func credentialReference(for id: DownloadID) -> String {
        "download.source.\(id)"
    }

    public static func prepare(
        _ source: DownloadSource,
        reference: String
    ) throws -> PreparedDownloadSource {
        let url = try validatedURL(source.link)
        try validateHeaders(source.headers)

        let publicHeaders = source.headers?.filter {
            publicHeaderNames.contains($0.key.lowercased())
        }
        let hasPrivateHeaders = (source.headers?.count ?? 0) != (publicHeaders?.count ?? 0)
        let projectedLink = publicURL(from: url).absoluteString
        let hasPrivateURLData = projectedLink != source.link
        let normalizedDownloadPage = try validatedDownloadPage(source.downloadPage)
        let projectedDownloadPage = normalizedDownloadPage.map {
            publicURL(from: $0).absoluteString
        }
        let hasPrivateDownloadPage = projectedDownloadPage != normalizedDownloadPage?.absoluteString
        let needsSecureSource = hasPrivateHeaders || hasPrivateURLData || hasPrivateDownloadPage

        var projection = source
        projection.link = projectedLink
        projection.headers = publicHeaders?.isEmpty == false ? publicHeaders : nil
        projection.downloadPage = projectedDownloadPage
        projection.credentialReference = needsSecureSource ? reference : nil
        let secureSource = needsSecureSource
            ? DownloadSecureSource(
                link: source.link,
                headers: source.headers,
                downloadPage: normalizedDownloadPage?.absoluteString
            )
            : nil
        return PreparedDownloadSource(projection: projection, secureSource: secureSource)
    }

    public static func containsRestrictedData(_ source: DownloadSource) -> Bool {
        guard let prepared = try? prepare(
            source,
            reference: source.credentialReference ?? "validation"
        ) else {
            return true
        }
        return prepared.secureSource != nil
    }

    public static func validateHeaders(_ headers: [String: String]?) throws {
        guard let headers else { return }
        guard headers.count <= 64 else {
            throw DownloadCoreError.invalidSourcePatch("请求头数量不能超过 64 个")
        }
        let tokenCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var normalizedNames: Set<String> = []
        for (name, value) in headers {
            guard !name.isEmpty,
                  name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
                throw DownloadCoreError.invalidSourcePatch("请求头名称无效")
            }
            guard normalizedNames.insert(name.lowercased()).inserted else {
                throw DownloadCoreError.invalidSourcePatch("请求头名称不能重复")
            }
            guard value.utf8.count <= 8_192,
                  !value.unicodeScalars.contains(where: {
                      $0.value == 0 || $0.value == 10 || $0.value == 13
                  }) else {
                throw DownloadCoreError.invalidSourcePatch("请求头值无效")
            }
        }
    }

    private static func validatedURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 8_192,
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw DownloadCoreError.invalidURL("下载地址格式无效")
        }
        return url
    }

    private static func validatedDownloadPage(_ raw: String?) throws -> URL? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= 8_192,
              !normalized.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw DownloadCoreError.invalidSourcePatch("下载页面地址格式无效")
        }
        return url
    }

    private static func publicURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}
