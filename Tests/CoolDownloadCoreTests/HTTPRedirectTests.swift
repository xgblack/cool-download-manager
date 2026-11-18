import Foundation
import Network
import Testing
@testable import CoolDownloadCore

@Suite("HTTP redirect request ownership", .serialized)
struct HTTPRedirectTests {
    @Test("real URLSession redirect replaces Host, strips cross-origin credentials and retains Range")
    func crossOrigin() async throws {
        let server = try RedirectHTTPFixture()
        defer { server.stop() }
        let source = DownloadSource(kind: .http, link: server.url("entry"), headers: [
            "hOsT": "127.0.0.1:\(server.port)", "Authorization": "Bearer fixture", "Cookie": "fixture=value",
            "Connection": "X-Hop", "X-Hop": "must-not-forward"
        ])
        let metadata = try await HTTPDownloader().probe(source: source)
        #expect(metadata.totalBytes == 6)
        #expect(metadata.effectiveRequest?.url?.host == "localhost")
        let requests = server.requests()
        try #require(requests.count == 2)
        #expect(requests[0].headers["authorization"] == "Bearer fixture")
        #expect(requests[0].headers["x-hop"] == nil)
        #expect(requests[1].headers["host"] == "localhost:\(server.port)")
        #expect(requests[1].headers["authorization"] == nil)
        #expect(requests[1].headers["cookie"] == nil)
        #expect(requests[1].headers["range"] == "bytes=0-0")
    }

    @Test("same-origin redirect retains authentication and genuine loops still fail")
    func sameOriginAndLoop() async throws {
        let server = try RedirectHTTPFixture()
        defer { server.stop() }
        _ = try await HTTPDownloader().probe(source: .init(kind: .http, link: server.url("same-entry"),
            headers: ["Authorization": "Bearer fixture", "Cookie": "fixture=value"]))
        #expect(server.requests().last?.headers["authorization"] == "Bearer fixture")
        #expect(server.requests().last?.headers["cookie"] == "fixture=value")
        do {
            _ = try await HTTPDownloader().probe(source: .init(kind: .http, link: server.url("loop")))
            Issue.record("A real redirect loop must not be treated as a file")
        } catch let error as URLError { #expect(error.code == .httpTooManyRedirects) }
    }
}

/// Small HTTP fixture for the real URL loading system, not a mock transport.
private final class RedirectHTTPFixture: @unchecked Sendable {
    struct Request: Sendable { let path: String; let headers: [String: String] }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cooldm.test.redirect")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            receive(connection, data: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port > 0 else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }
    func requests() -> [Request] { lock.withLock { recorded } }
    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            var data = data
            data.append(bytes ?? Data())
            guard data.count <= 32 * 1024 else { connection.cancel(); return }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                let lines = text.components(separatedBy: "\r\n")
                let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
                lock.withLock { recorded.append(.init(path: path, headers: headers)) }
                let location: String?
                switch path {
                case "/entry": location = "http://localhost:\(port)/file"
                case "/same-entry": location = "/same-file"
                case "/loop": location = "/loop"
                case "/file" where headers["host"] == "127.0.0.1:\(port)": location = "http://localhost:\(port)/file"
                default: location = nil
                }
                let response: String
                if let location { response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
                else { response = "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes 0-0/6\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx" }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if done || error != nil { connection.cancel() }
            else { receive(connection, data: data) }
        }
    }
}
