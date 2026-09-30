import Foundation
import SSMedia

/// Gives the engine access to a media's demuxer (video) and audio source. Called off the main actor; implementations
/// should hand out already opened objects (opening an asset may block).
public protocol MediaResolver: Sendable {
    func demuxer(for media: UUID) throws -> any Demuxing
    func audio(for media: UUID) throws -> any AudioSource
}

public enum MediaResolverError: Error, Sendable, Equatable { case unknownMedia(UUID) }

/// Fixed table of opened media (tests, bench, video-only callers). Unknown IDs throw `.unknownMedia` (offline).
public struct StaticMediaResolver: MediaResolver {
    public var demuxers: [UUID: any Demuxing]
    public var audioSources: [UUID: any AudioSource]

    public init(demuxers: [UUID: any Demuxing] = [:], audio: [UUID: any AudioSource] = [:]) {
        self.demuxers = demuxers; self.audioSources = audio
    }

    public func demuxer(for media: UUID) throws -> any Demuxing {
        guard let d = demuxers[media] else { throw MediaResolverError.unknownMedia(media) }
        return d
    }

    public func audio(for media: UUID) throws -> any AudioSource {
        guard let a = audioSources[media] else { throw MediaResolverError.unknownMedia(media) }
        return a
    }
}
