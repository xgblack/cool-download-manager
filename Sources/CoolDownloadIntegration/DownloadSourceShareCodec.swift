import Foundation
import CoolDownloadCore

public enum DownloadSourceShareError: Error, LocalizedError, Equatable {
    case empty
    case invalidFormat
    case invalidSource
    case unsupportedType
    case tooLarge
    case credentialsUnavailable

    public var errorDescription: String? {
        switch self {
        case .empty: return "没有可导入的下载来源"
        case .invalidFormat: return "二维码内容不是有效的下载链接或来源 JSON"
        case .invalidSource: return "下载来源包含无效的地址或请求信息"
        case .unsupportedType: return "仅支持 HTTP、HTTPS 和 HLS 下载来源"
        case .tooLarge: return "下载来源内容过大，请减少来源数量或请求信息"
        case .credentialsUnavailable: return "此任务的来源需要更新，暂时无法分享完整来源"
        }
    }
}

/// The portable task source format shared with upstream QR codes. Credentials
/// are supplied by the selected task; this type never reads host or proxy settings.
public enum DownloadSourceShareCodec {
    public static func encode(_ sources: [DownloadSource]) throws -> String {
        guard !sources.isEmpty else { throw DownloadSourceShareError.empty }
        let values = try sources.map { source -> SharedSource in
            guard source.credentialReference == nil else {
                throw DownloadSourceShareError.credentialsUnavailable
            }
            let validated = try validate(source)
            return SharedSource(source: validated)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        if values.count == 1 {
            data = try encoder.encode(values[0])
        } else {
            data = try encoder.encode(values)
        }
        guard data.count <= LoopbackHTTPServer.maximumRequestBytes else {
            throw DownloadSourceShareError.tooLarge
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> [DownloadSource] {
        guard text.utf8.count <= LoopbackHTTPServer.maximumRequestBytes else {
            throw DownloadSourceShareError.tooLarge
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DownloadSourceShareError.empty }
        guard text.first == "{" || text.first == "[" else {
            let links = text.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return try links.map { link in
                let kind: DownloadKind = URL(string: link)?.path.lowercased().hasSuffix(".m3u8") == true ? .hls : .http
                return try validate(DownloadSource(kind: kind, link: link))
            }
        }
        let values: [SharedSource]
        do {
            let data = Data(text.utf8)
            let decoder = JSONDecoder()
            values = text.first == "["
                ? try decoder.decode([SharedSource].self, from: data)
                : [try decoder.decode(SharedSource.self, from: data)]
        } catch {
            throw DownloadSourceShareError.invalidFormat
        }
        guard !values.isEmpty else { throw DownloadSourceShareError.empty }
        return try values.map { try $0.source() }
    }

    private static func validate(_ source: DownloadSource) throws -> DownloadSource {
        do {
            return try DownloadSourceSecurity.validatedForPersistence(source)
        } catch {
            // Decoder and validation diagnostics may contain the original input.
            throw DownloadSourceShareError.invalidSource
        }
    }

    private struct SharedSource: Codable {
        let type: String?
        let link: String
        let headers: [String: String]?
        let username: String?
        let password: String?
        let userAgent: String?
        let downloadPage: String?
        let suggestedName: String?

        init(source: DownloadSource) {
            type = source.kind.rawValue
            link = source.link
            headers = source.headers?.isEmpty == false ? source.headers : nil
            username = nil
            password = nil
            userAgent = nil
            downloadPage = source.downloadPage
            suggestedName = source.suggestedName
        }

        func source() throws -> DownloadSource {
            let kind: DownloadKind
            if let type {
                guard let decoded = DownloadKind(rawValue: type.lowercased()) else {
                    throw DownloadSourceShareError.unsupportedType
                }
                kind = decoded
            } else {
                kind = URL(string: link)?.path.lowercased().hasSuffix(".m3u8") == true ? .hls : .http
            }
            var headers = headers ?? [:]
            if let userAgent, !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
                headers["User-Agent"] = userAgent
            }
            if let username, !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                let credentials = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
                headers["Authorization"] = "Basic \(credentials)"
            }
            return try validate(DownloadSource(
                kind: kind,
                link: link,
                headers: headers.isEmpty ? nil : headers,
                downloadPage: downloadPage,
                suggestedName: suggestedName
            ))
        }
    }
}
