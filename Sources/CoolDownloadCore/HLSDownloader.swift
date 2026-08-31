import Foundation

public struct HLSDownloadResult: Sendable {
    public let totalBytes: Int64
    public let segmentCount: Int
    public let fingerprint: HLSManifestFingerprint?
    public let renditions: [HLSRendition]
    public let completedSegmentSequence: Int64?

    public init(
        totalBytes: Int64,
        segmentCount: Int,
        fingerprint: HLSManifestFingerprint? = nil,
        renditions: [HLSRendition] = [],
        completedSegmentSequence: Int64? = nil
    ) {
        self.totalBytes = totalBytes
        self.segmentCount = segmentCount
        self.fingerprint = fingerprint
        self.renditions = renditions
        self.completedSegmentSequence = completedSegmentSequence
    }
}

/// Compatibility facade retained for DownloadService and external callers.
/// Parsing and body execution live in separate types so HLS semantics can be
/// tested without driving the entire task scheduler.
public final class HLSDownloader: @unchecked Sendable {
    private let executor: HLSExecutor

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        networkConfiguration: HTTPNetworkConfiguration = .default,
        parser: HLSParser = HLSParser()
    ) {
        executor = HLSExecutor(
            transport: URLSessionHTTPTransport(
                configuration: configuration,
                networkConfiguration: networkConfiguration
            ),
            parser: parser
        )
    }

    public init(
        transport: any HTTPTransport,
        parser: HLSParser = HLSParser()
    ) {
        executor = HLSExecutor(transport: transport, parser: parser)
    }

    public func resolvePlaylist(
        source: DownloadSource,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        downloadID: DownloadID? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HLSResolvedPlaylist {
        guard let url = URL(string: source.link),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            throw DownloadCoreError.invalidURL(source.link)
        }
        return try await executor.resolvePlaylist(
            at: url,
            headers: source.headers,
            fileDescriptorBudget: fileDescriptorBudget,
            downloadID: downloadID,
            activity: activity
        )
    }

    public func download(
        source: DownloadSource,
        writer: PartFileWriter,
        resumeSnapshot: HLSResumeSnapshot? = nil,
        completedSegments: Set<Int> = [],
        completedPartMetadata: [DownloadPart] = [],
        progress: (@Sendable (Int64, Int, Int, Int64) async -> Void)? = nil,
        checkpoint: HLSCheckpointHandler? = nil,
        manifestResolved: HLSManifestResolvedHandler? = nil,
        rateLimiter: DownloadRateLimiter? = nil,
        fileDescriptorBudget: HTTPFileDescriptorBudget? = nil,
        downloadID: DownloadID? = nil,
        activity: HTTPRequestActivityHandler? = nil
    ) async throws -> HLSDownloadResult {
        try await executor.download(
            source: source,
            writer: writer,
            resumeSnapshot: resumeSnapshot,
            completedSegments: completedSegments,
            completedPartMetadata: completedPartMetadata,
            progress: progress,
            checkpoint: checkpoint,
            manifestResolved: manifestResolved,
            rateLimiter: rateLimiter,
            fileDescriptorBudget: fileDescriptorBudget,
            downloadID: downloadID,
            activity: activity
        )
    }
}
