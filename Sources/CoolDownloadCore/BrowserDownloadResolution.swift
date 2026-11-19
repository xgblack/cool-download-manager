import Foundation

public struct PendingBrowserDownload: Sendable {
    public let id: DownloadID
    public let source: DownloadSource
    public let start: Bool
}

public struct BrowserDownloadResolution: Sendable {
    public let preview: DownloadPreview
    public let verified: Bool
    public let isPage: Bool
    public let isNoContent: Bool
    public let etag: String?
}
