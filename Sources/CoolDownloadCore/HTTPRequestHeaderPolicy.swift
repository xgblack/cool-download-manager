import Foundation

/// Browser headers describe one request, not every host in its redirect chain.
/// Apply this at the transport boundary, including for sources saved by older builds.
public enum HTTPRequestHeaderPolicy {
    private static let connectionHeaders: Set<String> = [
        "host", "connection", "proxy-connection", "keep-alive", "content-length",
        "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization"
    ]
    private static let crossOriginHeaders: Set<String> = [
        "accept", "accept-encoding", "accept-language", "user-agent", "range", "if-range",
        "if-match", "if-unmodified-since", "if-none-match", "if-modified-since"
    ]

    public static func prepare(_ request: URLRequest) -> URLRequest {
        var result = request
        let headers = request.allHTTPHeaderFields ?? [:]
        let nominated = headers.first { $0.key.lowercased() == "connection" }?.value
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        let removed = connectionHeaders.union(nominated)
        for key in headers.keys where removed.contains(key.lowercased()) {
            result.setValue(nil, forHTTPHeaderField: key)
        }
        return result
    }

    static func redirect(_ request: URLRequest, from previousURL: URL?, previousRequest: URLRequest?) -> URLRequest {
        var result = prepare(request)
        if sameOrigin(previousURL, request.url), sameOrigin(previousRequest?.url, previousURL) {
            // URLSession may remove explicit Authorization even on a same-origin
            // redirect. Restore from the preceding hop, not the original URL.
            for key in ["Authorization", "Cookie"] where result.value(forHTTPHeaderField: key) == nil {
                result.setValue(previousRequest?.value(forHTTPHeaderField: key), forHTTPHeaderField: key)
            }
        } else if !sameOrigin(previousURL, request.url) {
            for key in (result.allHTTPHeaderFields ?? [:]).keys
                where !crossOriginHeaders.contains(key.lowercased()) {
                result.setValue(nil, forHTTPHeaderField: key)
            }
        }
        return result
    }

    public static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs, let scheme = lhs.scheme?.lowercased(),
              ["http", "https"].contains(scheme), scheme == rhs.scheme?.lowercased(),
              let host = lhs.host?.lowercased(), host == rhs.host?.lowercased() else { return false }
        let port = scheme == "https" ? 443 : 80
        return (lhs.port ?? port) == (rhs.port ?? port)
    }
}
