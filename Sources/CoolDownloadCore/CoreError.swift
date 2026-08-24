import Foundation

public enum DownloadCoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case invalidFolder(String)
    case invalidName(String)
    case duplicateDestination(String)
    case notFound(DownloadID)
    case invalidState(DownloadID, DownloadStatus)
    case storageLocked(URL)
    case corruptRecord(URL, String)
    case unsupportedLegacyRecordType(String)
    case httpStatus(Int)
    case resumeNotSupported
    case resourceChanged
    case responseMismatch(String)
    case unsupportedHLS(String)
    case noSpace
    case permissionDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid download URL: \(value)"
        case .invalidFolder(let value):
            return "Invalid download folder: \(value)"
        case .invalidName(let value):
            return "Invalid download name: \(value)"
        case .duplicateDestination(let value):
            return "A download already uses this destination: \(value)"
        case .notFound(let id):
            return "Download \(id) was not found"
        case .invalidState(let id, let status):
            return "Download \(id) cannot be changed from state \(status.rawValue)"
        case .storageLocked(let url):
            return "The data directory is already in use: \(url.path)"
        case .corruptRecord(let url, let reason):
            return "Cannot read download record \(url.path): \(reason)"
        case .unsupportedLegacyRecordType(let type):
            return "Unsupported legacy download type: \(type)"
        case .httpStatus(let status):
            return "The server returned HTTP \(status)"
        case .resumeNotSupported:
            return "The server did not support resuming this download"
        case .resourceChanged:
            return "The remote file changed while the download was being resumed"
        case .responseMismatch(let reason):
            return "The server response did not match the download: \(reason)"
        case .unsupportedHLS(let reason):
            return "Unsupported HLS playlist: \(reason)"
        case .noSpace:
            return "There is not enough free disk space"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .cancelled:
            return "The download was cancelled"
        }
    }
}
