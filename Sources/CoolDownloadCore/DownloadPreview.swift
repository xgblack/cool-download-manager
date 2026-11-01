import Foundation

/// A short-lived description of a source, before a task or destination exists.
/// The normalized source is retained so edits cannot reuse another URL's result.
public struct DownloadPreview: Sendable, Equatable {
    public let source: DownloadSource
    public let fileName: String?
    public let totalBytes: Int64?
    public let supportsResume: Bool?
    public let hlsSegmentCount: Int?
    public let hlsDuration: Double?

    public init(
        source: DownloadSource,
        fileName: String? = nil,
        totalBytes: Int64? = nil,
        supportsResume: Bool? = nil,
        hlsSegmentCount: Int? = nil,
        hlsDuration: Double? = nil
    ) {
        self.source = source
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.supportsResume = supportsResume
        self.hlsSegmentCount = hlsSegmentCount
        self.hlsDuration = hlsDuration
    }
}
