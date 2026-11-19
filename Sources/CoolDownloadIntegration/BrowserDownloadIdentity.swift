import Foundation
import CoolDownloadCore

/// Compares browser submissions without discarding URL queries or merging
/// unrelated same-name files. GitHub's two redirect forms require a shared
/// release page as additional evidence; this is a short-window defense, not a
/// replacement for an extension-provided operation ID.
public struct BrowserDownloadIdentity: Sendable, Equatable {
    private struct Header: Sendable, Equatable {
        let name: String
        let value: String
    }

    private struct GitHubAsset: Sendable, Equatable {
        let page: String
        let name: String
        let redirected: Bool
    }

    private let kind: DownloadKind
    private let link: String
    private let headers: [Header]
    private let page: String?
    private let githubAsset: GitHubAsset?

    public init(_ item: IntegrationDownloadCredential) {
        kind = item.type
        link = Self.normalizedURL(item.link)
        headers = (item.headers ?? [:]).map { name, value in
            Header(name: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), value: value)
        }.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        let normalizedPage = item.downloadPage.map(Self.normalizedURL)
        page = normalizedPage?.isEmpty == false ? normalizedPage : nil
        githubAsset = Self.githubAsset(link: link, page: page)
    }

    public func isCompatible(with other: Self) -> Bool {
        guard kind == other.kind else { return false }
        if link == other.link { return isSameRequest(as: other) }
        guard kind == .http,
              let lhs = githubAsset, let rhs = other.githubAsset,
              lhs.redirected != rhs.redirected,
              lhs.page == rhs.page, lhs.name == rhs.name else { return false }
        // Redirects change navigation headers and host-scoped cookies. A
        // conflicting explicit Authorization header must never be merged.
        let lhsAuthorization = headers.first { $0.name == "authorization" }?.value
        let rhsAuthorization = other.headers.first { $0.name == "authorization" }?.value
        return lhsAuthorization == nil || rhsAuthorization == nil || lhsAuthorization == rhsAuthorization
    }

    func isSameRequest(as other: Self) -> Bool {
        kind == other.kind && link == other.link
            && (headers.isEmpty || other.headers.isEmpty || headers == other.headers)
            && (page == nil || other.page == nil || page == other.page)
    }

    static func sameResolvedFile(_ lhs: BrowserDownloadResolution, _ rhs: BrowserDownloadResolution) -> Bool {
        let lhsSource = lhs.preview.source
        let rhsSource = rhs.preview.source
        guard lhs.verified, rhs.verified, normalizedURL(lhsSource.link) == normalizedURL(rhsSource.link) else {
            return false
        }
        if let left = lhs.preview.totalBytes, let right = rhs.preview.totalBytes, left != right { return false }
        if let left = lhs.etag, let right = rhs.etag, left != right { return false }

        func representationHeaders(_ source: DownloadSource) -> [String: String] {
            (source.headers ?? [:]).reduce(into: [:]) { result, pair in
                let name = pair.key.lowercased()
                // Browser navigation diagnostics do not supply credentials.
                if !name.hasPrefix("sec-fetch-"), !name.hasPrefix("sec-ch-"),
                   !["host", "range", "if-range", "priority"].contains(name) {
                    result[name] = pair.value
                }
            }
        }
        var left = representationHeaders(lhsSource)
        var right = representationHeaders(rhsSource)
        if left == right { return true }

        // The browser's direct capture and a replayed cross-origin redirect
        // can send different navigation headers and only one can carry cookies.
        // Relax their comparison only after the origin confirms the same bytes.
        guard let tag = lhs.etag, tag == rhs.etag, tag.hasPrefix("\""), tag.hasSuffix("\""), tag.count >= 2,
              let size = lhs.preview.totalBytes, size == rhs.preview.totalBytes else { return false }
        if let cookie = left["cookie"], let other = right["cookie"], cookie != other { return false }
        for name in ["accept", "accept-language", "accept-encoding", "cookie", "referer", "upgrade-insecure-requests"] {
            left.removeValue(forKey: name)
            right.removeValue(forKey: name)
        }
        return left == right
    }

    private static func normalizedURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? trimmed
    }

    private static func githubAsset(link: String, page: String?) -> GitHubAsset? {
        guard let page,
              let release = URLComponents(string: page),
              release.scheme == "https", release.host == "github.com",
              release.user == nil, release.password == nil,
              release.port == nil || release.port == 443,
              let asset = URLComponents(string: link), asset.scheme == "https",
              asset.user == nil, asset.password == nil,
              asset.port == nil || asset.port == 443 else { return nil }
        let releasePath = release.path.split(separator: "/").map(String.init)
        guard releasePath.count == 5, releasePath[2] == "releases", releasePath[3] == "tag" else { return nil }
        let assetPath = asset.path.split(separator: "/").map(String.init)
        if asset.host == "github.com" {
            guard assetPath.count == 6, assetPath[0] == releasePath[0], assetPath[1] == releasePath[1],
                  assetPath[2] == "releases", assetPath[3] == "download", assetPath[4] == releasePath[4] else { return nil }
            return GitHubAsset(page: page, name: assetPath[5], redirected: false)
        }
        guard asset.host == "release-assets.githubusercontent.com", assetPath.count == 3,
              assetPath[0] == "github-production-release-asset",
              asset.queryItems?.contains(where: { $0.name == "rscd" }) == true,
              let name = DownloadFileNameResolver.fromURLQuery(link) else { return nil }
        return GitHubAsset(page: page, name: name, redirected: true)
    }
}
