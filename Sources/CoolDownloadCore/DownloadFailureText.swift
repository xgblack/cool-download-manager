import Foundation

/// User-facing failure text stored in the existing error field. Classification
/// happens while the typed error is available, never by parsing an old message.
public enum DownloadFailureText {
    public static func message(for error: Error) -> String {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: failure.code)
            let summary: String
            let recovery: String
            switch code {
            case .appTransportSecurityRequiresSecureConnection:
                summary = "系统安全策略阻止了此 HTTP 连接。"
                recovery = "请更新客户端，或更新为服务器提供的可用 HTTPS 地址后重试。"
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                summary = "无法验证服务器的 HTTPS 证书。"
                recovery = "请检查系统日期，并联系网站修复证书，或更新为可信的下载地址后重试。"
            case .secureConnectionFailed:
                summary = "无法与服务器建立安全连接。"
                recovery = "请检查代理和服务器的 TLS 配置，处理后重试。"
            case .clientCertificateRejected, .clientCertificateRequired:
                summary = "服务器要求有效的客户端证书。"
                recovery = "请联系网站确认访问要求，或更新为可访问的下载来源。"
            case .timedOut:
                summary = "连接服务器超时。"
                recovery = "请检查网络和代理设置，稍后重试。"
            case .notConnectedToInternet, .networkConnectionLost:
                summary = "网络未连接或连接已中断。"
                recovery = "请恢复网络连接后重试，已有下载进度会保留。"
            case .cannotFindHost, .dnsLookupFailed:
                summary = "无法解析下载服务器地址。"
                recovery = "请检查下载地址、网络和 DNS 设置后重试。"
            case .cannotConnectToHost:
                summary = "无法连接下载服务器。"
                recovery = "请检查网络、代理和服务器状态后重试。"
            case .badURL, .unsupportedURL:
                summary = "下载地址无效或不受支持。"
                recovery = "请更新为有效的 HTTP 或 HTTPS 下载地址。"
            case .httpTooManyRedirects:
                summary = "下载地址发生了过多次重定向。"
                recovery = "请重新获取有效的下载地址并更新来源。"
            default:
                summary = "下载请求未能完成。"
                recovery = "请检查网络和下载来源后重试。"
            }
            // NSError descriptions and userInfo can contain signed URLs or
            // credentials. Only include the domain and code in diagnostics.
            return "\(summary)\n\(recovery)\n错误码：\(NSURLErrorDomain) / \(failure.code)"
        }
        if let coreError = error as? DownloadCoreError {
            let recovery: String
            switch coreError {
            case .httpStatus(let status):
                if status == 401 || status == 403 {
                    recovery = "下载来源需要认证或访问被拒绝，请更新下载地址及所需请求头。"
                } else if status == 404 || status == 410 {
                    recovery = "资源不存在、已移除或链接已失效，请检查并更新下载来源。"
                } else if status == 408 || status == 425 || status == 429 || status >= 500 {
                    recovery = "服务器暂时无法处理请求，请稍后重试。"
                } else {
                    recovery = "请检查下载来源及网站的访问要求后重试。"
                }
            case .sourceRefreshRequired:
                recovery = "请更新下载地址及所需请求头后继续。"
            case .noSpace:
                recovery = "请释放下载磁盘的可用空间后重试。"
            case .permissionDenied, .invalidFolder:
                recovery = "请检查保存目录是否存在、磁盘是否可写及应用的文件访问权限后重试。"
            case .resourceChanged:
                recovery = "请核对下载来源；原有字节不能与不同文件拼接。"
            case .resumeNotSupported:
                recovery = "当前来源无法安全续传，请重新获取支持续传的同一资源，或新建下载。"
            default:
                return coreError.localizedDescription
            }
            return "\(coreError.localizedDescription)\n\(recovery)"
        }
        if failure.domain == NSCocoaErrorDomain {
            switch failure.code {
            case NSFileWriteOutOfSpaceError:
                return message(for: DownloadCoreError.noSpace)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "没有权限访问下载文件。\n请检查保存目录和应用的文件访问权限后重试。"
            default:
                break
            }
        }
        return "下载未能完成。\n请检查下载来源和保存目录后重试。\n错误码：\(failure.domain) / \(failure.code)"
    }

    /// A short excerpt for list rows and notifications, including old records.
    public static func summary(_ message: String?) -> String? {
        message?.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
