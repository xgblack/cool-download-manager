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
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(handler: any DownloadIntegrationHandler, apiKey: String? = nil) {
        self.handler = handler
        self.apiKey = apiKey
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let apiKey, request.header("X-Api-Key") != apiKey {
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
                    _ = try DownloadSourceSecurity.prepare(
                        DownloadSource(kind: .http, link: patch.link, headers: patch.headers),
                        reference: "integration.validation"
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
