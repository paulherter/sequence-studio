import CoreVideo
import Foundation
import SSCore
import SSMedia
import SSRender

/// A decoded still image (upright BGRA8 buffer, decoded once) and its track info (the compositor's colour hint).
public struct StillFrame: @unchecked Sendable {
    public var buffer: CVPixelBuffer
    public var info: VideoTrackInfo
    public init(buffer: CVPixelBuffer, info: VideoTrackInfo) { self.buffer = buffer; self.info = info }
}

/// Gives the engine access to a media's demuxer (video) and audio source. Called off the main actor; implementations
/// should hand out already opened objects (opening an asset may block).
public protocol MediaResolver: Sendable {
    func demuxer(for media: UUID) throws -> any Demuxing
    func audio(for media: UUID) throws -> any AudioSource
    /// Per-layer colour pipelines (S-Log3 etc.). nil = every layer is treated as plain Rec.709.
    var colorResolver: LayerColorResolver? { get }
    /// The picture of a still-image media (decoded once, cached by the implementation). nil = not a still: the media is
    /// resolved through `demuxer(for:)`. Throws when it is a still that cannot be read (offline / damaged).
    func stillFrame(for media: UUID) throws -> StillFrame?
}

public extension MediaResolver {
    var colorResolver: LayerColorResolver? { nil }
    func stillFrame(for media: UUID) throws -> StillFrame? { nil }
}

public enum MediaResolverError: Error, Sendable, Equatable { case unknownMedia(UUID) }

/// Fixed table of opened media (tests, bench, video-only callers). Unknown IDs throw `.unknownMedia` (offline).
public struct StaticMediaResolver: MediaResolver {
    public var demuxers: [UUID: any Demuxing]
    public var audioSources: [UUID: any AudioSource]
    public var stills: [UUID: StillFrame]

    public init(demuxers: [UUID: any Demuxing] = [:], audio: [UUID: any AudioSource] = [:], stills: [UUID: StillFrame] = [:]) {
        self.demuxers = demuxers; self.audioSources = audio; self.stills = stills
    }

    public func stillFrame(for media: UUID) throws -> StillFrame? { stills[media] }

    public func demuxer(for media: UUID) throws -> any Demuxing {
        guard let d = demuxers[media] else { throw MediaResolverError.unknownMedia(media) }
        return d
    }

    public func audio(for media: UUID) throws -> any AudioSource {
        guard let a = audioSources[media] else { throw MediaResolverError.unknownMedia(media) }
        return a
    }
}
