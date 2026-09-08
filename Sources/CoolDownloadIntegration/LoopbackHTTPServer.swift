import Foundation
import Network

public final class LoopbackHTTPServer: @unchecked Sendable {
    public let port: UInt16
    private let listeners: [NWListener]
    private let router: IntegrationRouter
    private let queue = DispatchQueue(label: "com.cooldownloadmanager.integration.http")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let maximumConnections: Int
    private let connectionTimeout: TimeInterval
    private let onFailure: @Sendable (String) -> Void
    private var started = false
    private var stopped = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var deadlines: [ObjectIdentifier: DispatchWorkItem] = [:]
    static let maximumRequestBytes = 4 * 1024 * 1024
    static let maximumHeaderBytes = 16 * 1024

    public init(
        port: UInt16 = IntegrationRouter.defaultPort,
        router: IntegrationRouter,
        maximumConnections: Int = 32,
        connectionTimeout: TimeInterval = 10,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw IntegrationServerError.invalidPort(port)
        }
        guard router.canStartHTTP else { throw IntegrationServerError.authenticationRequired }
        self.port = port
        self.router = router
        self.maximumConnections = max(1, maximumConnections)
        self.connectionTimeout = connectionTimeout.isFinite ? max(0.01, connectionTimeout) : 10
        self.onFailure = onFailure
        var created: [NWListener] = []
        for host in ["127.0.0.1", "::1"] {
            let parameters = NWParameters.tcp
            // Separate loopback listeners must not compete for a dual-stack bind.
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = host == "127.0.0.1" ? .v4 : .v6
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
            // Permit the IPv4 and IPv6 listeners to share the numeric port.
            parameters.allowLocalEndpointReuse = true
            created.append(try NWListener(using: parameters))
        }
        listeners = created
        queue.setSpecific(key: queueKey, value: 1)
        for listener in listeners {
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                if case .failed = state {
                    self.stopOnQueue()
                    self.onFailure("HTTP 监听失败，请检查端口占用和本机网络配置；Native Messaging 可独立使用。")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
    }

    public func start() {
        onQueue {
            guard !started, !stopped else { return }
            started = true
            listeners.forEach { $0.start(queue: queue) }
        }
    }

    /// Cancels accepted connections and the request tasks owned by this instance.
    /// Handlers must cooperate with task cancellation; already committed commands are not undone.
    public func stop() { onQueue { stopOnQueue() } }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() }
        else { queue.sync(execute: body) }
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listeners.forEach { $0.cancel() }
        for id in Array(connections.keys) { close(id) }
    }

    private func close(_ id: ObjectIdentifier) {
        deadlines.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < maximumConnections else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(id) }
            if case .cancelled = state { self?.close(id) }
        }
        let deadline = DispatchWorkItem { [weak self] in self?.close(id) }
        deadlines[id] = deadline
        queue.asyncAfter(deadline: .now() + connectionTimeout, execute: deadline)
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        let id = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connections[id] != nil else { connection.cancel(); return }
            guard error == nil else { self.close(id); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try Self.parseRequest(buffer) {
                    self.requests[id] = Task { [weak self, router = self.router, port = self.port] in
                        guard !Task.isCancelled else { return }
                        let response = await router.handle(request, port: port)
                        guard !Task.isCancelled else { return }
                        self?.queue.async { [weak self] in
                            self?.send(response, on: connection)
                        }
                    }
                } else if isComplete {
                    self.send(.text(400, "Incomplete request"), on: connection)
                } else {
                    self.receive(connection, buffer: buffer)
                }
            } catch let error as RequestParseError {
                self.send(.text(error.status, "Invalid request"), on: connection)
            } catch {
                self.send(.text(400, "Invalid request"), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard connections[id] != nil, !stopped else { return }
        var payload = Data("HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(response.statusCode))\r\n".utf8)
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            payload.append(Data("\(key): \(value)\r\n".utf8))
        }
        payload.append(Data("\r\n".utf8))
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    enum RequestParseError: Error, Equatable {
        case invalid, tooLarge
        var status: Int { self == .tooLarge ? 413 : 400 }
    }

    /// nil means a bounded, syntactically valid prefix still needs bytes.
    static func parseRequest(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= maximumRequestBytes else { throw RequestParseError.tooLarge }
        guard let range = data.range(of: Data([13, 10, 13, 10])) else {
            guard data.count <= maximumHeaderBytes else { throw RequestParseError.tooLarge }
            return nil
        }
        guard range.upperBound <= maximumHeaderBytes else { throw RequestParseError.tooLarge }
        guard let text = String(data: data[..<range.lowerBound], encoding: .utf8) else { throw RequestParseError.invalid }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1", parts[1].hasPrefix("/"),
              !parts[1].hasPrefix("//"), parts[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !parts[0].isEmpty, parts[0].utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            throw RequestParseError.invalid
        }
        var headers: [String: String] = [:]
        let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RequestParseError.invalid }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ token.contains($0) }), headers[name] == nil,
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { throw RequestParseError.invalid }
            headers[name] = value
        }
        guard let host = headers["host"], !host.isEmpty, headers["transfer-encoding"] == nil else { throw RequestParseError.invalid }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw RequestParseError.invalid }
        guard let length = Int(rawLength), length <= maximumRequestBytes - range.upperBound else { throw RequestParseError.tooLarge }
        // Subtract first: untrusted Content-Length never participates in unchecked addition.
        guard data.count - range.upperBound >= length else { return nil }
        guard data.count - range.upperBound == length else { throw RequestParseError.invalid }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1].split(separator: "?", maxSplits: 1)[0]), headers: headers, body: Data(data[range.upperBound...]))
    }

    private static func reasonPhrase(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        default: return statusCode >= 500 ? "Internal Server Error" : "Response"
        }
    }
}

public enum IntegrationServerError: Error, LocalizedError, Sendable, Equatable {
    case invalidPort(UInt16)
    case authenticationRequired

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "HTTP 需要非空认证密钥，或明确启用匿名兼容模式"
        case .invalidPort(let port): return "本机回环端口无效：\(port)"
        }
    }
}
