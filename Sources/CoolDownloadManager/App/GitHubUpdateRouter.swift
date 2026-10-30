import CryptoKit
import Foundation

struct GitHubUpdateRoute: Equatable, Hashable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let prefix: String?

    static let official = GitHubUpdateRoute(id: "github", title: "GitHub 官方", prefix: nil)
    static let builtIns: [Self] = [
        .official,
        .init(id: "gh-proxy", title: "GitHub 加速 1", prefix: "https://gh-proxy.com/"),
        .init(id: "ghfast", title: "GitHub 加速 2", prefix: "https://ghfast.top/"),
        .init(id: "ghproxy", title: "GitHub 加速 3", prefix: "https://ghproxy.net/")
    ]

    func rewriting(_ url: URL) -> URL? {
        guard Self.supports(url) else { return nil }
        return prefix.flatMap { URL(string: $0 + url.absoluteString) } ?? url
    }

    static func supports(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        let path = url.path
        let releases = "/xgblack/cool-download-manager/releases/"
        return path == releases + "latest/download/appcast.xml"
            || (path.hasPrefix(releases + "download/") && path.lowercased().hasSuffix(".zip"))
    }

    static func ordered(ids: [String]) -> [Self] {
        var seen = Set<String>()
        return (ids.compactMap { id in builtIns.first { $0.id == id } } + builtIns)
            .filter { seen.insert($0.id).inserted }
    }
}

struct VerifiedUpdateFeed: Sendable, Equatable {
    let build: Int
    let archiveURL: URL
    let archiveLength: Int

    /// Sparkle 2.9 signs the bytes preceding its final signature comment.
    /// Verify these exact bytes before using a mirror's version for routing.
    static func decode(_ data: Data, publicKey: Data) throws -> Self {
        let prefix = Data("<!-- sparkle-signatures:\n".utf8)
        guard let signatureRange = data.range(of: prefix, options: .backwards),
              let suffixRange = data.range(of: Data("-->".utf8), in: signatureRange.upperBound..<data.endIndex),
              let block = String(data: data[signatureRange.upperBound..<suffixRange.lowerBound], encoding: .utf8),
              data[suffixRange.upperBound...].allSatisfy({ [9, 10, 13, 32].contains($0) }) else {
            throw UpdateRoutingError.invalidFeed
        }
        let fields = block.split(separator: "\n").reduce(into: [String: String]()) { fields, line in
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                fields[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let content = Data(data[..<signatureRange.lowerBound])
        guard let lengthString = fields["length"], Int(lengthString) == content.count,
              let signatureString = fields["edSignature"], let signature = Data(base64Encoded: signatureString),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: content) else {
            throw UpdateRoutingError.invalidSignature
        }
        // Update XML is public metadata, but external entities must never be resolved.
        guard let xml = String(data: content, encoding: .utf8),
              !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else {
            throw UpdateRoutingError.invalidFeed
        }
        let delegate = UpdateFeedXMLDelegate()
        let parser = XMLParser(data: content)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isRSS,
              let result = delegate.entries.max(by: { $0.build < $1.build }) else {
            throw UpdateRoutingError.invalidFeed
        }
        return result
    }
}

private final class UpdateFeedXMLDelegate: NSObject, XMLParserDelegate {
    var isRSS = false
    var entries: [VerifiedUpdateFeed] = []
    private var insideItem = false
    private var element = ""
    private var build = ""
    private var channel = ""
    private var hardware = ""
    private var archive: URL?
    private var length: Int?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "rss" { isRSS = true }
        if name == "item" {
            insideItem = true
            build = ""; channel = ""; hardware = ""; archive = nil; length = nil
        }
        if insideItem, name == "enclosure", let value = attributes["url"], let url = URL(string: value),
           GitHubUpdateRoute.supports(url), let signature = attributes["sparkle:edSignature"],
           Data(base64Encoded: signature)?.count == 64 {
            archive = url
            length = attributes["length"].flatMap(Int.init)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch element {
        case "sparkle:version": build += string
        case "sparkle:channel": channel += string
        case "sparkle:hardwareRequirements": hardware += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" {
            if let number = Int(build.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0,
               channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               hardware.isEmpty || hardware.contains("arm64"),
               let archive, let length, length > 0 {
                entries.append(.init(build: number, archiveURL: archive, archiveLength: length))
            }
            insideItem = false
        }
        element = ""
    }
}

enum UpdateRoutingError: Error, LocalizedError {
    case invalidFeed, invalidSignature, invalidResponse, responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFeed: "更新信息格式无效。"
        case .invalidSignature: "更新信息的签名验证失败。"
        case .invalidResponse: "更新线路返回了无效响应。"
        case .responseTooLarge: "更新线路的探测响应超出大小限制。"
        }
    }
}

struct UpdateProbeResponse: Sendable {
    let data: Data
    let status: Int
    let contentRange: String?
}

typealias UpdateProbeTransport = @Sendable (URLRequest, Int) async throws -> UpdateProbeResponse

private final class UpdateHTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url?.scheme?.lowercased() == "https"
            && request.url?.user == nil && request.url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

struct UpdateFeedProbe: Sendable {
    let route: GitHubUpdateRoute
    let feed: VerifiedUpdateFeed
    let milliseconds: Double
}

struct UpdateArchiveProbe: Sendable {
    let route: GitHubUpdateRoute
    let bytesPerSecond: Double
}

struct UpdateRouteSelection: Sendable {
    var feedRoutes: [GitHubUpdateRoute] = GitHubUpdateRoute.builtIns
    var downloadRoutes: [GitHubUpdateRoute] = GitHubUpdateRoute.builtIns
    var latestBuild: Int = 0
}

@MainActor
final class GitHubUpdateRouter {
    nonisolated static let archiveProbeBytes = 256 * 1_024
    nonisolated static let maximumFeedBytes = 256 * 1_024
    private let defaults: UserDefaults
    private let transport: UpdateProbeTransport

    init(defaults: UserDefaults = .standard, transport: @escaping UpdateProbeTransport = GitHubUpdateRouter.fetch) {
        self.defaults = defaults
        self.transport = transport
    }

    func cachedSelection() -> UpdateRouteSelection {
        .init(
            feedRoutes: GitHubUpdateRoute.ordered(ids: defaults.stringArray(forKey: "updateFeedRouteOrder") ?? []),
            downloadRoutes: GitHubUpdateRoute.ordered(ids: defaults.stringArray(forKey: "updateDownloadRouteOrder") ?? []),
            latestBuild: defaults.integer(forKey: "highestVerifiedUpdateBuild")
        )
    }

    func refresh(feedURL: URL, publicKey: Data, currentBuild: Int) async throws -> UpdateRouteSelection {
        let cached = cachedSelection()
        let transport = self.transport
        let feeds: [UpdateFeedProbe] = await Self.probeInPairs(cached.feedRoutes) { route in
            do {
                guard let url = route.rewriting(feedURL) else { return nil }
                let start = ContinuousClock.now
                let response = try await transport(Self.request(url: url), Self.maximumFeedBytes)
                guard response.status == 200, response.data.count <= Self.maximumFeedBytes else { return nil }
                let feed = try VerifiedUpdateFeed.decode(response.data, publicKey: publicKey)
                return UpdateFeedProbe(route: route, feed: feed, milliseconds: start.duration(to: .now).updateMilliseconds)
            } catch {
                return nil
            }
        }
        try Task.checkCancellation()
        var selection = cached
        selection.feedRoutes = Self.rankFeeds(feeds, fallback: cached.feedRoutes)
        if let newest = feeds.map(\.feed).max(by: { $0.build < $1.build }) {
            selection.latestBuild = max(cached.latestBuild, newest.build)
            // Only a real newer version needs archive probes. Reuse recent samples
            // for the same immutable archive rather than measuring on every launch.
            let recent = Date().timeIntervalSince1970 - defaults.double(forKey: "updateArchiveProbeDate") < 6 * 3_600
            if newest.build > currentBuild,
               !(recent && defaults.integer(forKey: "updateArchiveProbeBuild") == newest.build) {
                let probes: [UpdateArchiveProbe] = await Self.probeInPairs(cached.downloadRoutes) { route in
                    do {
                        guard let url = route.rewriting(newest.archiveURL) else { return nil }
                        let count = min(Self.archiveProbeBytes, newest.archiveLength)
                        let request = Self.request(url: url, rangeBytes: count)
                        let start = ContinuousClock.now
                        let response = try await transport(request, count)
                        guard Self.validArchiveSample(response, expectedLength: newest.archiveLength, requestedBytes: count) else { return nil }
                        let seconds = start.duration(to: .now).updateMilliseconds / 1_000
                        return UpdateArchiveProbe(route: route, bytesPerSecond: Double(response.data.count) / max(seconds, 0.001))
                    } catch {
                        return nil
                    }
                }
                try Task.checkCancellation()
                if !probes.isEmpty {
                    selection.downloadRoutes = Self.rankArchives(probes, fallback: cached.downloadRoutes)
                    defaults.set(Date().timeIntervalSince1970, forKey: "updateArchiveProbeDate")
                    defaults.set(newest.build, forKey: "updateArchiveProbeBuild")
                }
            }
        }
        defaults.set(selection.latestBuild, forKey: "highestVerifiedUpdateBuild")
        defaults.set(selection.feedRoutes.map(\.id), forKey: "updateFeedRouteOrder")
        defaults.set(selection.downloadRoutes.map(\.id), forKey: "updateDownloadRouteOrder")
        return selection
    }

    nonisolated static func rankFeeds(_ probes: [UpdateFeedProbe], fallback: [GitHubUpdateRoute]) -> [GitHubUpdateRoute] {
        let ranked = probes.sorted {
            if $0.feed.build != $1.feed.build { return $0.feed.build > $1.feed.build }
            if $0.milliseconds != $1.milliseconds { return $0.milliseconds < $1.milliseconds }
            return $0.route.id < $1.route.id
        }.map(\.route.id)
        return GitHubUpdateRoute.ordered(ids: ranked + fallback.map(\.id))
    }

    nonisolated static func rankArchives(_ probes: [UpdateArchiveProbe], fallback: [GitHubUpdateRoute]) -> [GitHubUpdateRoute] {
        let ranked = probes.sorted {
            if $0.bytesPerSecond != $1.bytesPerSecond { return $0.bytesPerSecond > $1.bytesPerSecond }
            return $0.route.id < $1.route.id
        }.map(\.route.id)
        return GitHubUpdateRoute.ordered(ids: ranked + fallback.map(\.id))
    }

    nonisolated static func validArchiveSample(_ response: UpdateProbeResponse, expectedLength: Int, requestedBytes: Int) -> Bool {
        response.status == 206 && response.contentRange == "bytes 0-\(requestedBytes - 1)/\(expectedLength)"
            && response.data.count == requestedBytes && response.data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    nonisolated private static func probeInPairs<Result: Sendable>(
        _ routes: [GitHubUpdateRoute], operation: @escaping @Sendable (GitHubUpdateRoute) async -> Result?
    ) async -> [Result] {
        await withTaskGroup(of: Result?.self) { group in
            var iterator = routes.makeIterator()
            for _ in 0..<2 {
                if let route = iterator.next() { group.addTask { await operation(route) } }
            }
            var results: [Result] = []
            for await result in group {
                if let result { results.append(result) }
                if !Task.isCancelled, let route = iterator.next() { group.addTask { await operation(route) } }
            }
            return results
        }
    }

    nonisolated private static func request(url: URL, rangeBytes: Int? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("CoolDownloadManager-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let rangeBytes {
            request.setValue("bytes=0-\(rangeBytes - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        return request
    }

    nonisolated static func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateProbeResponse {
        try await fetch(request, maximumBytes: maximumBytes, configuration: .ephemeral)
    }

    nonisolated static func fetch(_ request: URLRequest, maximumBytes: Int, configuration: URLSessionConfiguration) async throws -> UpdateProbeResponse {
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: UpdateHTTPSRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...206).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else { throw UpdateRoutingError.invalidResponse }
        if request.value(forHTTPHeaderField: "Range") != nil, response.statusCode != 206 {
            throw UpdateRoutingError.invalidResponse
        }
        guard response.expectedContentLength <= maximumBytes else { throw UpdateRoutingError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw UpdateRoutingError.responseTooLarge }
            data.append(byte)
        }
        guard !data.isEmpty else { throw UpdateRoutingError.invalidResponse }
        return .init(data: data, status: response.statusCode, contentRange: response.value(forHTTPHeaderField: "Content-Range"))
    }
}

private extension Duration {
    var updateMilliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
