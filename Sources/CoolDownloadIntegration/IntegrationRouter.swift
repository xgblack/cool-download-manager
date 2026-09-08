import Foundation
import CoolDownloadCore

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func text(_ statusCode: Int, _ value: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(value.utf8)
        )
    }
}

public actor IntegrationRouter {
    public static let defaultPort: UInt16 = 15151

    private let handler: any DownloadIntegrationHandler
    private let apiKey: String?
    private let allowAnonymous: Bool
    nonisolated let canStartHTTP: Bool
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(handler: any DownloadIntegrationHandler, apiKey: String? = nil, allowAnonymous: Bool = false) {
        self.handler = handler
        self.apiKey = apiKey
        self.allowAnonymous = allowAnonymous
        self.canStartHTTP = apiKey.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? allowAnonymous
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func handle(_ request: HTTPRequest, port: UInt16 = defaultPort) async -> HTTPResponse {
        guard !Task.isCancelled else { return .text(503, "Service stopped") }
        let authorities: Set<String> = ["localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"]
        let permittedHosts = port == 80 ? authorities.union(["localhost", "127.0.0.1", "[::1]"]) : authorities
        if let host = request.header("Host"), !permittedHosts.contains(host.lowercased()) {
            return .text(403, "Forbidden host")
        }
        if let origin = request.header("Origin"), !permittedHosts.contains(String(origin.lowercased().dropFirst(7))) || !origin.lowercased().hasPrefix("http://") {
            return .text(403, "Forbidden origin")
        }
        // Supplying an empty key is never equivalent to opting into anonymous mode.
        if let apiKey {
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  request.header("X-Api-Key") == apiKey else { return .text(401, "Unauthorized") }
        } else if !allowAnonymous {
            return .text(401, "Unauthorized")
        }

        do {
            switch (request.method.uppercased(), request.path) {
            case ("POST", "/ping"):
                return .text(200, "pong")
            case ("GET", "/queues"):
                let queues = try await handler.listQueues()
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: try encoder.encode(queues)
                )
            case ("POST", "/add"):
                let request = try decodeAddRequest(request.body)
                try await handler.addFromBrowser(request)
                return .text(200, "OK")
            case ("POST", "/start-headless-download"):
                let headless = try decoder.decode(HeadlessDownloadRequest.self, from: request.body)
                _ = try await handler.addHeadless(headless)
                return .text(200, "OK")
            default:
                if request.method.uppercased() == "PATCH",
                   let id = sourcePatchDownloadID(from: request.path) {
                    let patch = try decoder.decode(DownloadSourcePatch.self, from: request.body)
                    try DownloadSourceSecurity.validate(
                        DownloadSource(kind: .http, link: patch.link, headers: patch.headers)
                    )
                    let result = try await handler.patchSource(id: id, patch: patch)
                    return HTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/json; charset=utf-8"],
                        body: try encoder.encode(result)
                    )
                }
                return .text(404, "Not Found")
            }
        } catch let error as DecodingError {
            _ = error
            return .text(400, "Invalid request")
        } catch let error as DownloadCoreError {
            switch error {
            case .notFound:
                return .text(404, "Not Found")
            case .invalidURL, .invalidSourcePatch:
                return .text(400, "Invalid request")
            case .invalidState, .resourceChanged, .resumeNotSupported,
                 .sourceRefreshRequired:
                return .text(409, "Source update conflict")
            default:
                return .text(500, "Request failed")
            }
        } catch {
            return .text(500, "Request failed")
        }
    }

    private func decodeAddRequest(_ data: Data) throws -> AddDownloadsRequest {
        if let request = try? decoder.decode(AddDownloadsRequest.self, from: data) {
            return request
        }
        let items = try decoder.decode([IntegrationDownloadCredential].self, from: data)
        return AddDownloadsRequest(items: items)
    }

    private func sourcePatchDownloadID(from path: String) -> DownloadID? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0].isEmpty,
              components[1] == "downloads",
              components[3] == "source",
              let id = DownloadID(components[2]),
              id > 0 else {
            return nil
        }
        return id
    }
}
