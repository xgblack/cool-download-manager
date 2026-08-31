import CryptoKit
import Foundation

public struct HLSParser: Sendable {
    public static let defaultMaximumManifestBytes = 4 * 1024 * 1024

    public let maximumManifestBytes: Int

    public init(maximumManifestBytes: Int = Self.defaultMaximumManifestBytes) {
        self.maximumManifestBytes = max(1, maximumManifestBytes)
    }

    public func parse(_ data: Data, baseURL: URL) throws -> HLSPlaylist {
        guard data.count <= maximumManifestBytes else {
            throw DownloadCoreError.unsupportedHLS("播放列表超过大小限制")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadCoreError.unsupportedHLS("播放列表不是 UTF-8 文本")
        }
        return try parse(text, baseURL: baseURL)
    }

    public func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        guard text.utf8.count <= maximumManifestBytes else {
            throw DownloadCoreError.unsupportedHLS("播放列表超过大小限制")
        }
        try validateHTTPURL(baseURL, reason: "播放列表地址无效")

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else {
            throw DownloadCoreError.unsupportedHLS("缺少 #EXTM3U 标头")
        }

        var mediaSequence: Int64 = 0
        var mediaSequenceSeen = false
        var endList = false
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var segments: [HLSSegment] = []
        var pendingVariantAttributes: [String: String]?
        var pendingDuration: Double?
        var pendingByteRange: ParsedByteRange?
        var previousByteRangeURI: URL?
        var previousByteRangeEnd: Int64?
        var currentMap: HLSMap?
        var discontinuityGroup = 0

        for line in lines.dropFirst() {
            if !line.hasPrefix("#") {
                let uri = try resolveHTTPURL(line, relativeTo: baseURL, reason: "媒体 URI 无效")
                if let attributes = pendingVariantAttributes {
                    variants.append(try variant(uri: uri, attributes: attributes))
                    pendingVariantAttributes = nil
                    continue
                }
                guard let duration = pendingDuration else {
                    throw DownloadCoreError.unsupportedHLS("分片 URI 前缺少 EXTINF")
                }
                let byteRange: HLSByteRange?
                if let pendingByteRange {
                    let offset: Int64
                    if let explicitOffset = pendingByteRange.offset {
                        offset = explicitOffset
                    } else {
                        guard previousByteRangeURI == uri,
                              let previousByteRangeEnd,
                              previousByteRangeEnd < Int64.max else {
                            throw DownloadCoreError.unsupportedHLS(
                                "BYTERANGE 省略偏移时必须连续使用同一 URI"
                            )
                        }
                        offset = previousByteRangeEnd + 1
                    }
                    byteRange = try makeByteRange(length: pendingByteRange.length, offset: offset)
                    previousByteRangeURI = uri
                    previousByteRangeEnd = byteRange?.end
                } else {
                    byteRange = nil
                    previousByteRangeURI = nil
                    previousByteRangeEnd = nil
                }
                guard mediaSequence <= Int64.max - Int64(segments.count) else {
                    throw DownloadCoreError.unsupportedHLS("媒体序列号溢出")
                }
                segments.append(HLSSegment(
                    sequence: mediaSequence + Int64(segments.count),
                    uri: uri,
                    duration: duration,
                    byteRange: byteRange,
                    map: currentMap,
                    discontinuityGroup: discontinuityGroup
                ))
                pendingDuration = nil
                pendingByteRange = nil
                continue
            }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard pendingVariantAttributes == nil, pendingDuration == nil else {
                    throw DownloadCoreError.unsupportedHLS("播放列表标签顺序无效")
                }
                pendingVariantAttributes = try parseAttributeList(value(afterColonIn: line))
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                renditions.append(try rendition(
                    attributes: parseAttributeList(value(afterColonIn: line)),
                    baseURL: baseURL
                ))
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                guard pendingDuration == nil, pendingVariantAttributes == nil else {
                    throw DownloadCoreError.unsupportedHLS("EXTINF 后缺少分片 URI")
                }
                let raw = value(afterColonIn: line).split(
                    separator: ",",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).first.map(String.init) ?? ""
                guard let duration = Double(raw), duration.isFinite, duration >= 0 else {
                    throw DownloadCoreError.unsupportedHLS("EXTINF 时长无效")
                }
                pendingDuration = duration
                continue
            }
            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard pendingByteRange == nil else {
                    throw DownloadCoreError.unsupportedHLS("分片包含重复 BYTERANGE")
                }
                pendingByteRange = try parseByteRange(value(afterColonIn: line))
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = try parseAttributeList(value(afterColonIn: line))
                guard let rawURI = attributes["URI"] else {
                    throw DownloadCoreError.unsupportedHLS("初始化分片缺少 URI")
                }
                let uri = try resolveHTTPURL(rawURI, relativeTo: baseURL, reason: "初始化分片 URI 无效")
                let byteRange: HLSByteRange?
                if let rawRange = attributes["BYTERANGE"] {
                    let parsed = try parseByteRange(rawRange)
                    guard let offset = parsed.offset else {
                        throw DownloadCoreError.unsupportedHLS("MAP BYTERANGE 必须包含显式偏移")
                    }
                    byteRange = try makeByteRange(length: parsed.length, offset: offset)
                } else {
                    byteRange = nil
                }
                currentMap = HLSMap(uri: uri, byteRange: byteRange)
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard !mediaSequenceSeen, segments.isEmpty,
                      let value = Int64(value(afterColonIn: line)), value >= 0 else {
                    throw DownloadCoreError.unsupportedHLS("媒体序列号无效")
                }
                mediaSequence = value
                mediaSequenceSeen = true
                continue
            }
            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = try parseAttributeList(value(afterColonIn: line))
                guard attributes["METHOD"]?.uppercased() == "NONE" else {
                    throw DownloadCoreError.unsupportedHLS("加密 HLS 需要密钥提供方")
                }
                continue
            }
            if line == "#EXT-X-DISCONTINUITY" {
                guard discontinuityGroup < Int.max else {
                    throw DownloadCoreError.unsupportedHLS("断点组数量溢出")
                }
                discontinuityGroup += 1
                continue
            }
            if line == "#EXT-X-ENDLIST" {
                endList = true
                continue
            }
        }

        guard pendingVariantAttributes == nil else {
            throw DownloadCoreError.unsupportedHLS("STREAM-INF 后缺少 variant URI")
        }
        guard pendingDuration == nil, pendingByteRange == nil else {
            throw DownloadCoreError.unsupportedHLS("播放列表结尾缺少分片 URI")
        }
        guard variants.isEmpty || segments.isEmpty else {
            throw DownloadCoreError.unsupportedHLS("播放列表不能同时包含 variant 和媒体分片")
        }

        let kind: HLSPlaylistKind = variants.isEmpty ? .media : .master
        if kind == .media, !segments.isEmpty, !endList {
            throw DownloadCoreError.unsupportedHLS("Live 播放列表缺少 #EXT-X-ENDLIST")
        }
        return HLSPlaylist(
            kind: kind,
            baseURL: baseURL,
            mediaSequence: mediaSequence,
            endList: endList,
            variants: variants,
            renditions: renditions,
            segments: segments
        )
    }

    public func selectHighestBandwidthVariant(from playlist: HLSPlaylist) -> HLSVariant? {
        playlist.variants.max {
            if $0.bandwidth != $1.bandwidth { return $0.bandwidth < $1.bandwidth }
            return $0.uri.absoluteString > $1.uri.absoluteString
        }
    }

    public func fingerprint(for playlist: HLSPlaylist) -> HLSManifestFingerprint {
        HLSManifestFingerprint(
            canonicalPlaylist: canonicalIdentity(for: playlist.baseURL),
            mediaSequence: playlist.mediaSequence,
            segmentIdentities: playlist.segments.map { segment in
                let range = segment.byteRange.map { "\($0.offset):\($0.length)" } ?? "full"
                let map = segment.map.map { value in
                    let mapRange = value.byteRange.map { "\($0.offset):\($0.length)" } ?? "full"
                    return "\(canonicalIdentity(for: value.uri))@\(mapRange)"
                } ?? "none"
                return [
                    String(segment.sequence),
                    canonicalIdentity(for: segment.uri),
                    range,
                    map,
                    String(segment.discontinuityGroup),
                    String(segment.duration.bitPattern)
                ].joined(separator: "|")
            }
        )
    }

    public func parseAttributeList(_ rawValue: String) throws -> [String: String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for character in rawValue {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == ",", !quoted {
                fields.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }
        guard !quoted else {
            throw DownloadCoreError.unsupportedHLS("属性列表包含未闭合引号")
        }
        fields.append(current)

        var result: [String: String] = [:]
        for field in fields {
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else {
                throw DownloadCoreError.unsupportedHLS("属性列表格式无效")
            }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces).uppercased()
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, result[name] == nil else {
                throw DownloadCoreError.unsupportedHLS("属性列表名称无效或重复")
            }
            if value.hasPrefix("\"") || value.hasSuffix("\"") {
                guard value.count >= 2, value.first == "\"", value.last == "\"" else {
                    throw DownloadCoreError.unsupportedHLS("属性引号格式无效")
                }
                value.removeFirst()
                value.removeLast()
                guard !value.contains("\"") else {
                    throw DownloadCoreError.unsupportedHLS("属性值包含无效引号")
                }
            }
            result[name] = value
        }
        return result
    }

    private struct ParsedByteRange {
        let length: Int64
        let offset: Int64?
    }

    private func parseByteRange(_ raw: String) throws -> ParsedByteRange {
        let components = raw.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let length = Int64(components[0]), length > 0 else {
            throw DownloadCoreError.unsupportedHLS("BYTERANGE 长度无效")
        }
        let offset: Int64?
        if components.count == 2 {
            guard let value = Int64(components[1]), value >= 0 else {
                throw DownloadCoreError.unsupportedHLS("BYTERANGE 偏移无效")
            }
            offset = value
        } else {
            offset = nil
        }
        return ParsedByteRange(length: length, offset: offset)
    }

    private func makeByteRange(length: Int64, offset: Int64) throws -> HLSByteRange {
        guard length > 0, offset >= 0, offset <= Int64.max - (length - 1) else {
            throw DownloadCoreError.unsupportedHLS("BYTERANGE 范围溢出")
        }
        return HLSByteRange(length: length, offset: offset)
    }

    private func variant(uri: URL, attributes: [String: String]) throws -> HLSVariant {
        guard let rawBandwidth = attributes["BANDWIDTH"],
              let bandwidth = Int(rawBandwidth), bandwidth > 0 else {
            throw DownloadCoreError.unsupportedHLS("variant 缺少有效 BANDWIDTH")
        }
        return HLSVariant(
            uri: uri,
            bandwidth: bandwidth,
            codecs: attributes["CODECS"],
            resolution: attributes["RESOLUTION"],
            audioGroup: attributes["AUDIO"],
            subtitlesGroup: attributes["SUBTITLES"]
        )
    }

    private func rendition(
        attributes: [String: String],
        baseURL: URL
    ) throws -> HLSRendition {
        guard let rawType = attributes["TYPE"],
              let type = HLSRenditionType(attributeValue: rawType),
              let groupID = attributes["GROUP-ID"], !groupID.isEmpty,
              let name = attributes["NAME"], !name.isEmpty else {
            throw DownloadCoreError.unsupportedHLS("rendition 属性不完整")
        }
        let uri = try attributes["URI"].map {
            try resolveHTTPURL($0, relativeTo: baseURL, reason: "rendition URI 无效")
        }
        return HLSRendition(
            type: type,
            groupID: groupID,
            name: name,
            language: attributes["LANGUAGE"],
            isDefault: try yesNo(attributes["DEFAULT"]),
            autoselect: try yesNo(attributes["AUTOSELECT"]),
            uri: uri
        )
    }

    private func yesNo(_ raw: String?) throws -> Bool {
        guard let raw else { return false }
        switch raw.uppercased() {
        case "YES": return true
        case "NO": return false
        default: throw DownloadCoreError.unsupportedHLS("YES/NO 属性值无效")
        }
    }

    private func value(afterColonIn line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
    }

    private func resolveHTTPURL(
        _ raw: String,
        relativeTo baseURL: URL,
        reason: String
    ) throws -> URL {
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            throw DownloadCoreError.unsupportedHLS(reason)
        }
        try validateHTTPURL(url, reason: reason)
        return url
    }

    private func validateHTTPURL(_ url: URL, reason: String) throws {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw DownloadCoreError.unsupportedHLS(reason)
        }
    }

    private func canonicalIdentity(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return digest(url.absoluteString)
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        let query = components.queryItems ?? []
        components.query = nil
        let base = components.string ?? ""
        guard !query.isEmpty else { return base }
        let normalized = query.map { item -> String in
            let name = item.name.lowercased()
            if Self.rotatingSignatureNames.contains(name)
                || name.hasPrefix("x-amz-")
                || name.hasPrefix("x-goog-") {
                return "\(name)=*"
            }
            return "\(name)=sha256:\(digest(item.value ?? ""))"
        }.sorted()
        return base + "?" + normalized.joined(separator: "&")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let rotatingSignatureNames: Set<String> = [
        "auth", "authorization", "e", "exp", "expires", "hdnea", "hmac",
        "key-pair-id", "policy", "sig", "signature", "st", "token"
    ]
}

private extension HLSRenditionType {
    init?(attributeValue: String) {
        switch attributeValue.uppercased() {
        case "AUDIO": self = .audio
        case "SUBTITLES": self = .subtitles
        case "CLOSED-CAPTIONS": self = .closedCaptions
        case "VIDEO": self = .video
        default: return nil
        }
    }
}
