import Foundation
import SQCore
import SQMedia
import SQPlayback

// The services the session talks to, as small protocols (the Windows port plan, seam 5). On the Mac the session keeps
// the concrete types (no existential, no behavior change); elsewhere it holds the protocol, and a platform engine plugs in.

/// What the session asks of the media resolver: which files the project has and when they changed.
public protocol SessionMediaResolving: AnyObject, MediaResolver {
    func setProjectFolder(_ folder: URL?)
    func info(of id: UUID) -> MediaInfo?
    func update(_ media: [MediaRef], sampleRate: Int?)
    func invalidate(_ ids: Set<UUID>)
    @discardableResult
    func prepare(_ ids: [UUID]) async -> Set<UUID>
}

/// The preview render cache as the session uses it (cached segments playback reads instead of the clips).
@MainActor
public protocol SessionRenderCaching: AnyObject {
    var onSpansChanged: (() -> Void)? { get set }
    var seedFrames: (([DecodedFrame]) -> Void)? { get set }
    func spans(for timeline: Timeline, sequences: [Timeline.ID: Timeline]) -> [RenderCacheSpan]
    func mediaChanged()
}

/// Background proxies (W9.9 AutoProxy) as the session uses them.
@MainActor
public protocol SessionProxyServing: AnyObject {
    var projectID: UUID? { get }
    func sync(_ media: [MediaRef], projectID: UUID?, activeTimeline: Timeline?)
    func addEngine(_ e: any ProgramEngine)
}

#if os(macOS)
public typealias SessionMediaResolver = ProjectMediaResolver
public typealias SessionRenderCache = RenderCacheController
public typealias SessionProxyService = AutoProxyService

extension ProjectMediaResolver: SessionMediaResolving {}
extension RenderCacheController: SessionRenderCaching {}
extension AutoProxyService: SessionProxyServing {}
#else
public typealias SessionMediaResolver = RefOnlyMediaResolver
public typealias SessionRenderCache = any SessionRenderCaching
public typealias SessionProxyService = any SessionProxyServing

extension SessionProxyServing {
    public func sync(_ media: [MediaRef], projectID: UUID?) { sync(media, projectID: projectID, activeTimeline: nil) }
}

/// shortcut: keeps the project's media list and nothing else (opens no file, `prepare` reports nothing ready);
/// upgrade with an FFmpeg resolver (SQMediaFFmpeg demuxer and audio source) when the Windows monitor plays.
public final class RefOnlyMediaResolver: SessionMediaResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [UUID: MediaRef] = [:]
    private var folder: URL?

    public init() {}

    public func setProjectFolder(_ folder: URL?) { lock.withLock { self.folder = folder } }
    public func info(of id: UUID) -> MediaInfo? { lock.withLock { refs[id]?.info } }
    public func path(of id: UUID) -> String? { lock.withLock { refs[id]?.path } }
    public func update(_ media: [MediaRef], sampleRate: Int? = nil) {
        lock.withLock { refs = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }) }
    }
    public func invalidate(_ ids: Set<UUID>) {}
    @discardableResult
    public func prepare(_ ids: [UUID]) async -> Set<UUID> { [] }
    public func demuxer(for media: UUID) throws -> any Demuxing { throw MediaResolverError.unknownMedia(media) }
    public func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
    public func fileURL(for media: UUID) -> URL? { path(of: media).map { URL(fileURLWithPath: $0) } }
}
#endif
