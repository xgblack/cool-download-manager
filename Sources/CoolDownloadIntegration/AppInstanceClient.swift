import Foundation
import Darwin

/// Startup probes are safe to repeat. The caller sends its actual add request
/// once, after this returns, so an ambiguous write response is never replayed.
public struct AppInstanceClient: Sendable {
    private let client: PrivateSocketClient

    public init(socketURL: URL) { client = PrivateSocketClient(socketURL: socketURL) }

    public func waitUntilReady(timeout: TimeInterval = 10, launch: (() throws -> Void)? = nil) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var launched = false
        repeat {
            do {
                let reply = try client.send(.init(requestId: UUID().uuidString, action: "status"),
                                            timeout: min(0.25, remaining(deadline)))
                if reply.isError {
                    // Older installed versions only implement private ping/add.
                    let ping = try client.send(.init(requestId: UUID().uuidString, action: "ping"),
                                               timeout: min(0.25, remaining(deadline)))
                    if !ping.isError, ping.payload == "true" { return }
                    throw AppInstanceError.unavailable("主应用未能确认就绪")
                }
                let status = try JSONDecoder().decode(AppInstanceStatus.self, from: Data(reply.payload.utf8))
                switch status.state {
                case .ready: return
                case .failed: throw AppInstanceError.startupFailed(status.message ?? "下载核心不可用")
                case .stopping: throw AppInstanceError.stopping
                case .starting: break
                }
            } catch let error as PrivateSocketClientError {
                switch error {
                case .system(ENOENT), .system(ECONNREFUSED):
                    if !launched, let launch { try launch(); launched = true }
                case .system(EAGAIN), .system(ETIMEDOUT), .closed:
                    break // An existing, busy instance is not evidence that it stopped.
                default: throw error
                }
            }
            if ContinuousClock.now >= deadline { break }
            Thread.sleep(forTimeInterval: min(0.05, remaining(deadline)))
        } while ContinuousClock.now < deadline
        throw AppInstanceError.timedOut
    }

    public func showMainWindow(timeout: TimeInterval = 10) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            do {
                let reply = try client.send(.init(requestId: UUID().uuidString, action: "show-main"),
                                            timeout: min(0.25, remaining(deadline)))
                guard !reply.isError else { throw AppInstanceError.unavailable("原实例无法打开窗口") }
                return
            } catch let error as PrivateSocketClientError {
                switch error {
                case .system(ENOENT), .system(ECONNREFUSED), .system(EAGAIN), .system(ETIMEDOUT), .closed: break
                default: throw error
                }
            }
            Thread.sleep(forTimeInterval: min(0.05, remaining(deadline)))
        } while ContinuousClock.now < deadline
        throw AppInstanceError.timedOut
    }

    private func remaining(_ deadline: ContinuousClock.Instant) -> TimeInterval {
        let value = ContinuousClock.now.duration(to: deadline).components
        return max(0.001, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }
}
