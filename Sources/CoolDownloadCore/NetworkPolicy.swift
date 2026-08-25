import Foundation

/// The proxy modes exposed by the historical desktop settings. `system`
/// deliberately leaves URLSession's configuration untouched so macOS can
/// apply the user's current proxy and PAC configuration.
public enum HTTPProxyMode: String, Sendable, Equatable {
    case system
    case direct
    case manual
    case pac
}

/// Network policy used when the core creates a URLSession transport.
///
/// URLSession can apply proxy and TLS policy directly. DNS server overrides
/// are retained here for settings compatibility, but URLSession has no public
/// per-session DNS resolver on macOS; callers must not treat `dnsServers` as
/// active routing until a resolver-backed transport is added.
public struct HTTPNetworkConfiguration: Sendable, Equatable {
    public var proxyMode: HTTPProxyMode
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String
    public var proxyPassword: String
    public var proxyPACURL: String
    public var dnsServers: [String]
    public var ignoreSSLCertificates: Bool

    public init(
        proxyMode: HTTPProxyMode = .system,
        proxyHost: String = "",
        proxyPort: Int = 8080,
        proxyUsername: String = "",
        proxyPassword: String = "",
        proxyPACURL: String = "",
        dnsServers: [String] = [],
        ignoreSSLCertificates: Bool = false
    ) {
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.proxyPACURL = proxyPACURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dnsServers = dnsServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.ignoreSSLCertificates = ignoreSSLCertificates
    }

    public static let `default` = Self()
}

/// URLSession delegate for the two authentication cases that cannot be
/// represented by request headers: proxy credentials and server trust.
private final class URLSessionDelegateProxy: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: HTTPNetworkConfiguration

    init(configuration: HTTPNetworkConfiguration) {
        self.configuration = configuration
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(
        to challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let method = protectionSpace.authenticationMethod

        let isProxyAuthentication = protectionSpace.isProxy()
            || method == "NSURLAuthenticationMethodHTTPProxy"
            || method == "NSURLAuthenticationMethodHTTPSProxy"
        if isProxyAuthentication,
           !configuration.proxyUsername.isEmpty,
           challenge.previousFailureCount == 0 {
            completionHandler(
                .useCredential,
                URLCredential(
                    user: configuration.proxyUsername,
                    password: configuration.proxyPassword,
                    persistence: .none
                )
            )
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
           configuration.ignoreSSLCertificates,
           let trust = protectionSpace.serverTrust,
           challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}

/// Builds URLSession requests while applying the configured macOS network
/// policy. The delegate is retained separately because URLSession does not
/// retain its delegate strongly for the lifetime of the session on all SDKs.
final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: URLSessionDelegateProxy

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        networkConfiguration: HTTPNetworkConfiguration = .default
    ) {
        let networkConfiguration = networkConfiguration
        let sessionConfiguration = configuration
        Self.applyProxy(networkConfiguration, to: sessionConfiguration)
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.waitsForConnectivity = false
        let delegate = URLSessionDelegateProxy(configuration: networkConfiguration)
        self.delegate = delegate
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func response(for request: URLRequest) async throws -> HTTPTransportResponse {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw DownloadCoreError.responseMismatch("response was not HTTP")
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(64 * 1024)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 64 * 1024 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return HTTPTransportResponse(
            statusCode: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            },
            body: body
        )
    }

    private static func applyProxy(
        _ configuration: HTTPNetworkConfiguration,
        to sessionConfiguration: URLSessionConfiguration
    ) {
        switch configuration.proxyMode {
        case .system:
            // An untouched URLSession configuration follows macOS system
            // proxy and PAC settings.
            break
        case .direct:
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "FTPEnable": 0,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0
            ]
        case .manual:
            guard !configuration.proxyHost.isEmpty else { return }
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": configuration.proxyHost,
                "HTTPPort": configuration.proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": configuration.proxyHost,
                "HTTPSPort": configuration.proxyPort,
                "ProxyAutoConfigEnable": 0
            ]
        case .pac:
            guard !configuration.proxyPACURL.isEmpty else { return }
            sessionConfiguration.connectionProxyDictionary = [
                "ProxyAutoConfigEnable": 1,
                "ProxyAutoConfigURLString": configuration.proxyPACURL
            ]
        }
    }
}

enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
