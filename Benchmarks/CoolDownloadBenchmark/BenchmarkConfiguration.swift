import CoolDownloadCore
import Foundation

struct BenchmarkConfiguration: Codable, Sendable {
    var sizeBytes: Int64 = 64 * 1024 * 1024
    /// Set only when the caller explicitly supplies `--size-mib`. External
    /// runs can otherwise learn the size from the completed record.
    var expectedSizeBytes: Int64?
    /// Raw URL used only inside an isolated child process. Reports redact its
    /// path, query, fragment and credentials.
    var sourceURL: String?
    /// Optional SHA-256 used for external-source verification. Fixture runs
    /// always verify their deterministic byte pattern instead.
    var expectedSHA256: String?
    var connections: [Int] = [1, 2, 4, 8]
    var repetitions = 3
    var warmups = 1
    var taskCount = 1
    var globalConnections = 16
    var maxOpenFileDescriptors = 128
    var minimumPartSizeBytes: Int64 = 16 * 1024 * 1024
    var perConnectionBytesPerSecond: Int64 = 0
    var firstByteDelayMilliseconds = 0
    var failFirstDataRequests = 0
    var retryAttempts = 1
    var retryDelayMilliseconds = 1_000
    var timeoutSeconds = 300
    /// Optional HTTP(S) proxy for external-source runs. Credentials are never
    /// written to the report.
    var proxyURL: String?
    /// Optional mounted directory used as the parent of per-run directories.
    var downloadsRootPath: String?
    var keepFiles = false
    var outputPath: String?

    static func parse(arguments: [String]) throws -> Self {
        var configuration = Self()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                throw BenchmarkCLIError.helpRequested
            }

            func nextValue() throws -> String {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw BenchmarkCLIError.missingValue(argument)
                }
                index = valueIndex
                return arguments[valueIndex]
            }

            switch argument {
            case "--url":
                let raw = try nextValue()
                guard let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      let host = url.host,
                      !host.isEmpty else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.sourceURL = raw
            case "--sha256":
                let raw = try nextValue().lowercased()
                guard raw.count == 64, raw.allSatisfy(\.isHexDigit) else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.expectedSHA256 = raw
            case "--size-mib":
                let value = try mibValue(nextValue(), option: argument)
                configuration.sizeBytes = value
                configuration.expectedSizeBytes = value
            case "--connections":
                let raw = try nextValue()
                let values = raw.split(separator: ",").compactMap { Int($0) }
                guard !values.isEmpty,
                      values.allSatisfy({ (1...64).contains($0) }),
                      values.count == raw.split(separator: ",").count else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.connections = Array(Set(values)).sorted()
            case "--repetitions":
                configuration.repetitions = try positiveInt(nextValue(), option: argument)
            case "--warmups":
                let raw = try nextValue()
                guard let value = Int(raw), value >= 0 else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.warmups = value
            case "--tasks":
                configuration.taskCount = try positiveInt(nextValue(), option: argument)
            case "--global-connections":
                configuration.globalConnections = try positiveInt(nextValue(), option: argument)
            case "--max-open-fds":
                let raw = try nextValue()
                guard let value = Int(raw), value >= 2 else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.maxOpenFileDescriptors = value
            case "--minimum-part-mib":
                configuration.minimumPartSizeBytes = try mibValue(nextValue(), option: argument)
            case "--per-connection-mibps":
                let raw = try nextValue()
                guard let value = Double(raw), value >= 0 else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.perConnectionBytesPerSecond = Int64(value * 1024 * 1024)
            case "--first-byte-ms":
                let raw = try nextValue()
                guard let value = Int(raw), value >= 0 else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.firstByteDelayMilliseconds = value
            case "--fail-first-data-requests":
                let raw = try nextValue()
                guard let value = Int(raw), value >= 0 else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.failFirstDataRequests = value
            case "--retry-attempts":
                configuration.retryAttempts = try positiveInt(nextValue(), option: argument)
            case "--retry-delay-ms":
                let raw = try nextValue()
                guard let value = Int(raw), value >= 0 else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.retryDelayMilliseconds = value
            case "--proxy-url":
                let raw = try nextValue()
                guard let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      let host = url.host,
                      !host.isEmpty,
                      url.port.map({ (1...65_535).contains($0) }) ?? true else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.proxyURL = raw
            case "--downloads-root":
                let raw = try nextValue()
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BenchmarkCLIError.invalidValue(argument, raw)
                }
                configuration.downloadsRootPath = raw
            case "--keep-files":
                configuration.keepFiles = true
            case "--timeout-seconds":
                configuration.timeoutSeconds = try positiveInt(nextValue(), option: argument)
            case "--output":
                configuration.outputPath = try nextValue()
            default:
                throw BenchmarkCLIError.unknownOption(argument)
            }
            index += 1
        }

        if configuration.sourceURL == nil || configuration.expectedSizeBytes != nil {
            guard configuration.minimumPartSizeBytes <= configuration.sizeBytes else {
                throw BenchmarkCLIError.invalidCombination(
                    "--minimum-part-mib must not exceed --size-mib"
                )
            }
        }
        if configuration.proxyURL != nil, configuration.sourceURL == nil {
            throw BenchmarkCLIError.invalidCombination("--proxy-url requires --url")
        }
        if configuration.expectedSHA256 != nil, configuration.sourceURL == nil {
            throw BenchmarkCLIError.invalidCombination("--sha256 requires --url")
        }
        if configuration.sourceURL != nil,
           configuration.perConnectionBytesPerSecond > 0
            || configuration.firstByteDelayMilliseconds > 0
            || configuration.failFirstDataRequests > 0 {
            throw BenchmarkCLIError.invalidCombination(
                "--per-connection-mibps, --first-byte-ms and --fail-first-data-requests are local-fixture options"
            )
        }
        return configuration
    }

    /// Redacts values that could identify a local machine or carry credentials
    /// before this configuration is embedded in a JSON report.
    func redactedForReport() -> Self {
        var copy = self
        if let sourceURL,
           let url = URL(string: sourceURL),
           let scheme = url.scheme,
           let host = url.host {
            var redacted = "\(scheme.lowercased())://\(host.lowercased())"
            if let port = url.port {
                redacted += ":\(port)"
            }
            copy.sourceURL = redacted
        }
        if proxyURL != nil {
            copy.proxyURL = "<redacted>"
        }
        if downloadsRootPath != nil {
            copy.downloadsRootPath = "<redacted>"
        }
        copy.outputPath = nil
        return copy
    }

    func networkConfiguration() throws -> HTTPNetworkConfiguration {
        guard let proxyURL else { return .default }
        guard let url = URL(string: proxyURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty else {
            throw BenchmarkCLIError.invalidValue("--proxy-url", proxyURL)
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return HTTPNetworkConfiguration(
            proxyMode: .manual,
            proxyHost: host,
            proxyPort: port,
            proxyUsername: url.user?.removingPercentEncoding ?? "",
            proxyPassword: url.password?.removingPercentEncoding ?? ""
        )
    }

    static let usage = """
    Usage: swift run CoolDownloadBenchmark [options]

      --size-mib N                 Bytes per task (default: 64)
      --url URL                    External HTTP(S) source instead of the local fixture
      --sha256 HEX                 Expected SHA-256 for an external source
      --connections 1,2,4,8        Per-task connection matrix
      --repetitions N              Measured runs per connection value (default: 3)
      --warmups N                  Unreported warmup runs (default: 1)
      --tasks N                    Concurrent download tasks per run (default: 1)
      --global-connections N       Global Range lease limit (default: 16)
      --max-open-fds N              Download FD reservation budget (default: 128)
      --minimum-part-mib N         Minimum persisted Range size (default: 16)
      --per-connection-mibps N     Per-stream server throttle; 0 is unlimited
      --first-byte-ms N            Delay before response headers (default: 0)
      --fail-first-data-requests N Deterministically fail the first N data requests (default: 0)
      --retry-attempts N           Maximum attempts per task (default: 1)
      --retry-delay-ms N            Retry backoff in milliseconds (default: 1000)
      --proxy-url URL               HTTP(S) proxy for --url; credentials stay local
      --downloads-root PATH         Store each run below a mounted path
      --keep-files                  Keep isolated run directories under --downloads-root
      --timeout-seconds N          Per-run timeout (default: 300)
      --output PATH                Also write the JSON report to PATH
      --help                       Show this help

    Progress is written to stderr. The final machine-readable report is written
    to stdout, so it can be redirected without filtering human-readable output.
    """

    private static func positiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw BenchmarkCLIError.invalidValue(option, raw)
        }
        return value
    }

    private static func mibValue(_ raw: String, option: String) throws -> Int64 {
        guard let value = Double(raw), value > 0 else {
            throw BenchmarkCLIError.invalidValue(option, raw)
        }
        let bytes = value * 1024 * 1024
        guard bytes <= Double(Int64.max) else {
            throw BenchmarkCLIError.invalidValue(option, raw)
        }
        return Int64(bytes)
    }
}

enum BenchmarkCLIError: Error, LocalizedError {
    case helpRequested
    case missingValue(String)
    case invalidValue(String, String)
    case invalidCombination(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .missingValue(let option):
            return "Missing value for \(option)"
        case .invalidValue(let option, let value):
            return "Invalid value for \(option): \(value)"
        case .invalidCombination(let message):
            return message
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        }
    }
}
