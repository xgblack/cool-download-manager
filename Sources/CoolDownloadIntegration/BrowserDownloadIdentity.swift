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
        if link == other.link {
            // One transport can omit optional metadata. Explicit conflicts
            // still describe distinct download sources.
            return (headers.isEmpty || other.headers.isEmpty || headers == other.headers)
                && (page == nil || other.page == nil || page == other.page)
        }
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
