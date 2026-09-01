import Foundation

public enum DownloadSourceSecurity {
    public static func validate(_ source: DownloadSource) throws {
        _ = try validatedURL(source.link)
        try validateHeaders(source.headers)
        _ = try validatedDownloadPage(source.downloadPage)
    }

    public static func validatedForPersistence(_ source: DownloadSource) throws -> DownloadSource {
        try validate(source)
        var source = source
        source.downloadPage = try validatedDownloadPage(source.downloadPage)?.absoluteString
        source.credentialReference = nil
        return source
    }

    public static func validateHeaders(_ headers: [String: String]?) throws {
        guard let headers else { return }
        guard headers.count <= 64 else {
            throw DownloadCoreError.invalidSourcePatch("请求头数量不能超过 64 个")
        }
        let tokenCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var normalizedNames: Set<String> = []
        for (name, value) in headers {
            guard !name.isEmpty,
                  name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
                throw DownloadCoreError.invalidSourcePatch("请求头名称无效")
            }
            guard normalizedNames.insert(name.lowercased()).inserted else {
                throw DownloadCoreError.invalidSourcePatch("请求头名称不能重复")
            }
            guard value.utf8.count <= 8_192,
                  !value.unicodeScalars.contains(where: {
                      $0.value == 0 || $0.value == 10 || $0.value == 13
                  }) else {
                throw DownloadCoreError.invalidSourcePatch("请求头值无效")
            }
        }
    }

    private static func validatedURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 8_192,
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw DownloadCoreError.invalidURL("下载地址格式无效")
        }
        return url
    }

    private static func validatedDownloadPage(_ raw: String?) throws -> URL? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= 8_192,
              !normalized.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw DownloadCoreError.invalidSourcePatch("下载页面地址格式无效")
        }
        return url
    }
}
