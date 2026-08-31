import Foundation

public enum HLSPlaylistKind: String, Codable, Sendable, Equatable {
    case master
    case media
}

public struct HLSByteRange: Codable, Sendable, Equatable, Hashable {
    public let length: Int64
    public let offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }

    public var end: Int64 { offset + length - 1 }

    public var headerValue: String { "bytes=\(offset)-\(end)" }
}

public struct HLSMap: Codable, Sendable, Equatable, Hashable {
    public let uri: URL
    public let byteRange: HLSByteRange?

    public init(uri: URL, byteRange: HLSByteRange? = nil) {
        self.uri = uri
        self.byteRange = byteRange
    }
}

public struct HLSSegment: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let uri: URL
    public let duration: Double
    public let byteRange: HLSByteRange?
    public let map: HLSMap?
    public let discontinuityGroup: Int

    public init(
        sequence: Int64,
        uri: URL,
        duration: Double,
        byteRange: HLSByteRange? = nil,
        map: HLSMap? = nil,
        discontinuityGroup: Int = 0
    ) {
        self.sequence = sequence
        self.uri = uri
        self.duration = duration
        self.byteRange = byteRange
        self.map = map
        self.discontinuityGroup = discontinuityGroup
    }
}

public struct HLSVariant: Codable, Sendable, Equatable {
    public let uri: URL
    public let bandwidth: Int
    public let codecs: String?
    public let resolution: String?
    public let audioGroup: String?
    public let subtitlesGroup: String?

    public init(
        uri: URL,
        bandwidth: Int,
        codecs: String? = nil,
        resolution: String? = nil,
        audioGroup: String? = nil,
        subtitlesGroup: String? = nil
    ) {
        self.uri = uri
        self.bandwidth = bandwidth
        self.codecs = codecs
        self.resolution = resolution
        self.audioGroup = audioGroup
        self.subtitlesGroup = subtitlesGroup
    }
}

public enum HLSRenditionType: String, Codable, Sendable, Equatable {
    case audio
    case subtitles
    case closedCaptions
    case video
}

public struct HLSRendition: Codable, Sendable, Equatable {
    public let type: HLSRenditionType
    public let groupID: String
    public let name: String
    public let language: String?
    public let isDefault: Bool
    public let autoselect: Bool
    public let uri: URL?

    public init(
        type: HLSRenditionType,
        groupID: String,
        name: String,
        language: String? = nil,
        isDefault: Bool = false,
        autoselect: Bool = false,
        uri: URL? = nil
    ) {
        self.type = type
        self.groupID = groupID
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.autoselect = autoselect
        self.uri = uri
    }
}

public struct HLSPlaylist: Codable, Sendable, Equatable {
    public let kind: HLSPlaylistKind
    public let baseURL: URL
    public let mediaSequence: Int64
    public let endList: Bool
    public let variants: [HLSVariant]
    public let renditions: [HLSRendition]
    public let segments: [HLSSegment]

    public init(
        kind: HLSPlaylistKind,
        baseURL: URL,
        mediaSequence: Int64 = 0,
        endList: Bool = false,
        variants: [HLSVariant] = [],
        renditions: [HLSRendition] = [],
        segments: [HLSSegment] = []
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.mediaSequence = mediaSequence
        self.endList = endList
        self.variants = variants
        self.renditions = renditions
        self.segments = segments
    }
}

public struct HLSManifestFingerprint: Codable, Sendable, Equatable {
    public let canonicalPlaylist: String
    public let mediaSequence: Int64
    public let segmentIdentities: [String]

    public init(
        canonicalPlaylist: String,
        mediaSequence: Int64,
        segmentIdentities: [String]
    ) {
        self.canonicalPlaylist = canonicalPlaylist
        self.mediaSequence = mediaSequence
        self.segmentIdentities = segmentIdentities
    }
}

public struct HLSResumeSnapshot: Codable, Sendable, Equatable {
    public let fingerprint: HLSManifestFingerprint
    public let completedSegmentSequence: Int64?
    public let outputByteBoundary: Int64

    public init(
        fingerprint: HLSManifestFingerprint,
        completedSegmentSequence: Int64?,
        outputByteBoundary: Int64
    ) {
        self.fingerprint = fingerprint
        self.completedSegmentSequence = completedSegmentSequence
        self.outputByteBoundary = outputByteBoundary
    }
}

public struct HLSResolvedPlaylist: Sendable, Equatable {
    public let playlist: HLSPlaylist
    public let selectedVariant: HLSVariant?
    public let renditions: [HLSRendition]
    public let fingerprint: HLSManifestFingerprint

    public init(
        playlist: HLSPlaylist,
        selectedVariant: HLSVariant? = nil,
        renditions: [HLSRendition] = [],
        fingerprint: HLSManifestFingerprint
    ) {
        self.playlist = playlist
        self.selectedVariant = selectedVariant
        self.renditions = renditions
        self.fingerprint = fingerprint
    }
}
