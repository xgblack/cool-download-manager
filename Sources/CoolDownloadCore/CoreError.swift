import Foundation

public enum DownloadCoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case invalidFolder(String)
    case invalidName(String)
    case invalidTaskSettings(String)
    case duplicateDestination(String)
    case notFound(DownloadID)
    case invalidState(DownloadID, DownloadStatus)
    case storageLocked(URL)
    case corruptRecord(URL, String)
    case unsupportedLegacyRecordType(String)
    case httpStatus(Int)
    case resumeNotSupported
    case resourceChanged
    case sourceRefreshRequired(DownloadSourceRefreshReason)
    case invalidSourcePatch(String)
    case responseMismatch(String)
    case unsupportedHLS(String)
    case noSpace
    case permissionDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "下载地址无效"
        case .invalidFolder(let value):
            return "下载目录无效：\(value)"
        case .invalidName(let value):
            return "文件名无效：\(value)"
        case .invalidTaskSettings(let reason):
            return reason
        case .duplicateDestination(let value):
            return "已有下载使用此保存位置：\(value)"
        case .notFound(let id):
            return "找不到下载任务 \(id)"
        case .invalidState(let id, let status):
            let statusName: String
            switch status {
            case .added: statusName = "已添加"
            case .preparing: statusName = "准备中"
            case .downloading: statusName = "下载中"
            case .paused: statusName = "已暂停"
            case .retrying: statusName = "重试中"
            case .waitingForSourceRefresh: statusName = "等待更新来源"
            case .completed: statusName = "已完成"
            case .failed: statusName = "失败"
            case .cancelled: statusName = "已取消"
            }
            return "下载任务 \(id) 无法从“\(statusName)”状态执行此操作"
        case .storageLocked(let url):
            return "数据目录已被其他实例占用：\(url.path)"
        case .corruptRecord(let url, let reason):
            return "无法读取下载记录 \(url.path)：\(reason)"
        case .unsupportedLegacyRecordType(let type):
            return "不支持的旧版下载类型：\(type)"
        case .httpStatus(let status):
            return "服务器返回 HTTP \(status)"
        case .resumeNotSupported:
            return "服务器不支持续传此下载"
        case .resourceChanged:
            return "续传下载时远程文件已发生变化"
        case .sourceRefreshRequired(let reason):
            switch reason {
            case .authenticationRequired:
                return "下载来源认证已失效，需要更新来源"
            case .credentialsUnavailable:
                return "下载来源凭据暂不可用，需要更新来源"
            }
        case .invalidSourcePatch(let reason):
            return reason
        case .responseMismatch(let reason):
            return "服务器响应与下载内容不匹配：\(reason)"
        case .unsupportedHLS(let reason):
            return "不支持的 HLS 播放列表：\(reason)"
        case .noSpace:
            return "磁盘可用空间不足"
        case .permissionDenied(let path):
            return "没有权限访问：\(path)"
        case .cancelled:
            return "下载已取消"
        }
    }
}
