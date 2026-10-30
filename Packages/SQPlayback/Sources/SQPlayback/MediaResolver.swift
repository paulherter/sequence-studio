#if canImport(CoreVideo)
import CoreVideo
#endif
import Foundation
// Only the Mac build links SQAnalysis's Gyroflow part; elsewhere canImport can be true just because another target of
// the same build compiled SQAnalysis (SwiftPM shares one module folder), without GyroFrameWarper in it.
#if canImport(SQAnalysis) && os(macOS)
import SQAnalysis
#endif
import SQCore
import SQFrame
import SQFrameCoreVideo
import SQMedia
#if canImport(SQRender)
import SQRender
#endif

/// A decoded still image (upright BGRA8 frame, decoded once) and its track info (the compositor's color hint).
public struct StillFrame: Sendable {
    public var frame: SQFrame
    public var info: VideoTrackInfo
    public init(frame: SQFrame, info: VideoTrackInfo) { self.frame = frame; self.info = info }
}

#if canImport(CoreVideo)
public extension StillFrame {
    /// The wrapped CVPixelBuffer (no copy).
    var buffer: CVPixelBuffer { frame.pixelBuffer }
    init(buffer: CVPixelBuffer, info: VideoTrackInfo) { self.init(frame: SQFrame(pixelBuffer: buffer), info: info) }
}
#endif

/// Gives the engine access to a media's demuxer (video) and audio source. Called off the main actor; implementations
/// should hand out already opened objects (opening an asset may block).
public protocol MediaResolver: Sendable {
    func demuxer(for media: UUID) throws -> any Demuxing
    func audio(for media: UUID) throws -> any AudioSource
    #if canImport(SQRender)
    /// Per-layer color pipelines (S-Log3 etc.). nil = every layer is treated as plain Rec.709.
    var colorResolver: LayerColorResolver? { get }
    #endif
    /// The picture of a still-image media (decoded once, cached by the implementation). nil = not a still: the media is
    /// resolved through `demuxer(for:)`. Throws when it is a still that cannot be read (offline / damaged).
    func stillFrame(for media: UUID) throws -> StillFrame?
    /// A ready proxy of the media (W9.9), opened, for the monitor only: decoded while scrubbing (and while playing when
    /// `PlaybackEngine.proxyUse.playback` is on), never for paused frames. Export never asks for it. nil = no proxy (yet).
    /// It must have the original's frame times (same count and presentation times); color is always interpreted from the
    /// original (its media info), so the proxy's own tags never matter beyond decoding its pixels.
    func proxyDemuxer(for media: UUID) throws -> (any Demuxing)?
    #if canImport(SQAnalysis) && os(macOS)
    /// Gyroflow Stabilizer frames (playback and export warp through it). nil = Gyroflow layers show unwarped.
    var gyroWarper: GyroFrameWarper? { get }
    #endif
    /// The original file of a video media (subject mattes are precomputed from it in the background). nil = unknown,
    /// offline or a still: subject masks then segment the shown frame live.
    func fileURL(for media: UUID) -> URL?
}

public extension MediaResolver {
    #if canImport(SQRender)
    var colorResolver: LayerColorResolver? { nil }
    #endif
    func stillFrame(for media: UUID) throws -> StillFrame? { nil }
    func proxyDemuxer(for media: UUID) throws -> (any Demuxing)? { nil }
    #if canImport(SQAnalysis) && os(macOS)
    var gyroWarper: GyroFrameWarper? { nil }
    #endif
    func fileURL(for media: UUID) -> URL? { nil }
}

public enum MediaResolverError: Error, Sendable, Equatable { case unknownMedia(UUID) }

/// Fixed table of opened media (tests, bench, video-only callers). Unknown IDs throw `.unknownMedia` (offline).
public struct StaticMediaResolver: MediaResolver {
    public var demuxers: [UUID: any Demuxing]
    public var audioSources: [UUID: any AudioSource]
    public var stills: [UUID: StillFrame]
    /// Ready proxies (bench, tests).
    public var proxies: [UUID: any Demuxing]
    /// Original files (tests: subject matte precompute).
    public var fileURLs: [UUID: URL] = [:]

    public init(demuxers: [UUID: any Demuxing] = [:], audio: [UUID: any AudioSource] = [:], stills: [UUID: StillFrame] = [:],
                proxies: [UUID: any Demuxing] = [:]) {
        self.demuxers = demuxers; self.audioSources = audio; self.stills = stills; self.proxies = proxies
    }

    public func proxyDemuxer(for media: UUID) throws -> (any Demuxing)? { proxies[media] }

    public func fileURL(for media: UUID) -> URL? { fileURLs[media] }

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
