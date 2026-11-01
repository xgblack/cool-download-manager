import Foundation
import CoolDownloadCore
import CoolDownloadIntegration

/// Both preflight and submission must build exactly the same validated source.
enum DownloadSourceDraft {
    static func links(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func source(link: String, name: String?, original: IntegrationDownloadCredential?) throws -> DownloadSource {
        let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var source: DownloadSource
        if let original, sameOrigin(link, original.link) {
            source = original.asCoreSource()
            source.link = link
        } else {
            source = DownloadSource(
                kind: URL(string: link)?.path.lowercased().hasSuffix(".m3u8") == true ? .hls : .http,
                link: link
            )
        }
        if let explicitName, !explicitName.isEmpty { source.suggestedName = explicitName }
        return try DownloadSourceSecurity.validatedForPersistence(source)
    }

    static func sources(link: String, name: String?, originals: [IntegrationDownloadCredential] = []) throws -> [DownloadSource] {
        let links = links(link)
        guard !links.isEmpty else { return [] }
        return try links.enumerated().map { index, link in
            try source(link: link, name: links.count == 1 ? name : nil,
                original: originals.indices.contains(index) ? originals[index] : nil)
        }
    }

    static func sameOrigin(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = URLComponents(string: lhs), let b = URLComponents(string: rhs),
              let aHost = a.host, let bHost = b.host, let scheme = a.scheme?.lowercased(),
              ["http", "https"].contains(scheme), scheme == b.scheme?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return aHost.lowercased() == bHost.lowercased() && (a.port ?? defaultPort) == (b.port ?? defaultPort)
    }
}
