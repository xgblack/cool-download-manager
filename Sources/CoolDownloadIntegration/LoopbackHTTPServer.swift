import Foundation
import Network

public final class LoopbackHTTPServer: @unchecked Sendable {
    public let port: UInt16

    private let listeners: [NWListener]
    private let router: IntegrationRouter
    private let queue = DispatchQueue(label: "com.cooldownloadmanager.integration.http")
    private let maximumRequestBytes = 4 * 1024 * 1024

    public init(port: UInt16 = IntegrationRouter.defaultPort, router: IntegrationRouter) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw IntegrationServerError.invalidPort(port)
        }
        self.port = port
        self.router = router
        let hosts = ["127.0.0.1", "::1"]
        var createdListeners: [NWListener] = []
        createdListeners.reserveCapacity(hosts.count)
        for host in hosts {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(host),
                port: endpointPort
            )
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("CoolDownloadIntegration listener failed: \(error)\n", stderr)
                }
            }
            createdListeners.append(listener)
        }
        self.listeners = createdListeners
        for listener in self.listeners {
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
        }
    }

    public func start() {
        listeners.forEach { $0.start(queue: queue) }
    }

    public func stop() {
        listeners.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                fputs("CoolDownloadIntegration connection failed: \(error)\n", stderr)
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if nextBuffer.count > self.maximumRequestBytes {
                self.send(HTTPResponse.text(413, "Request too large"), on: connection)
                return
            }
            if let request = Self.parseRequest(nextBuffer) {
                Task {
                    let response = await self.router.handle(request)
                    self.send(response, on: connection)
                }
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: nextBuffer)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var payload = Data()
        let reason = Self.reasonPhrase(response.statusCode)
        payload.append(Data("HTTP/1.1 \(response.statusCode) \(reason)\r\n".utf8))
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "text/plain; charset=utf-8"
        }
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            payload.append(Data("\(key): \(value)\r\n".utf8))
        }
        payload.append(Data("\r\n".utf8))
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: separator) else {
            return nil
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }?.value ?? "0") ?? 0
        guard contentLength >= 0, data.count >= bodyStart + contentLength else {
            return nil
        }
        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestParts[1],
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + contentLength)])
        )
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

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "本机回环端口无效：\(port)"
        }
    }
}
