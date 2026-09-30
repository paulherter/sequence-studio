import Foundation
import SSCore
import SSMedia
import SSPlayback
import Synchronization

public enum MediaResolveError: Error, Equatable, Sendable {
    /// The project has no media item with this ID.
    case unknownMedia(UUID)
    /// Nothing is at the stored path (the clip shows the offline placeholder).
    case offline(UUID, path: String)
    /// The file could not be opened as video.
    case unreadable(UUID)
    /// The file has no usable audio track.
    case noAudio(UUID)
}

/// Resolves a `Clip.media` ID to a demuxer / audio source from the project's media refs (`MediaRef.path`).
/// `SSPlayback.MediaResolver` for the engine: synchronous and called off the main actor. Opened demuxers and audio
/// sources are cached; `prepare` opens them ahead of time in the background (the session calls it for new media),
/// and a lookup that finds nothing cached opens the file itself and blocks until it is loaded (never on the main
/// actor: the engine calls from decode queues). A missing file is `.offline`, never a crash. Safe from any thread.
public final class ProjectMediaResolver: MediaResolver, @unchecked Sendable {
    public typealias DemuxerFactory = @Sendable (URL) async throws -> any Demuxing
    public typealias AudioFactory = @Sendable (URL, Int) async throws -> any AudioSource

    private struct State {
        var refs: [UUID: MediaRef] = [:]
        var demuxers: [UUID: any Demuxing] = [:]
        var audio: [UUID: any AudioSource] = [:]
        /// Media without a usable audio track (or whose audio failed): not retried.
        var noAudio: Set<UUID> = []
        var sampleRate = 48_000
        /// One open in flight per media, shared by `prepare` and the blocking lookups (never two live demuxers).
        var videoOpen: [UUID: (path: String, task: Task<(any Demuxing)?, Never>)] = [:]
        var audioOpen: [UUID: (path: String, rate: Int, task: Task<(any AudioSource)?, Never>)] = [:]
    }
    private let state = Mutex(State())
    private let makeDemuxer: DemuxerFactory
    private let makeAudio: AudioFactory
    private let fileExists: @Sendable (String) -> Bool

    public init(demuxer: @escaping DemuxerFactory = { try await AVDemuxer(url: $0) },
                audio: @escaping AudioFactory = { try await AssetAudioSource.open(url: $0, sampleRate: $1) },
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        makeDemuxer = demuxer; makeAudio = audio; self.fileExists = fileExists
    }

    /// Replaces the known media. Cached and in-flight sources of items whose path changed (relink) or that are gone
    /// are dropped; a sample-rate change drops all audio. An open that finishes for an old path or rate is discarded.
    public func update(_ media: [MediaRef], sampleRate: Int? = nil) {
        state.withLock { s in
            let new = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
            for id in Set(s.refs.keys).union(s.demuxers.keys).union(s.videoOpen.keys).union(s.audioOpen.keys)
            where new[id] == nil || new[id]?.path != s.refs[id]?.path {
                s.demuxers[id] = nil; s.audio[id] = nil; s.noAudio.remove(id)
                s.videoOpen[id] = nil; s.audioOpen[id] = nil
            }
            s.refs = new
            if let sampleRate, sampleRate != s.sampleRate {
                s.sampleRate = sampleRate; s.audio = [:]; s.noAudio = []; s.audioOpen = [:]
            }
        }
    }

    /// Sample rate audio sources are opened with (the active sequence's).
    public var sampleRate: Int { state.withLock { $0.sampleRate } }

    public func isOffline(_ id: UUID) -> Bool {
        guard let ref = state.withLock({ $0.refs[id] }) else { return true }
        return !fileExists(ref.path)
    }

    // MARK: Shared opens

    /// The open in flight for `id` (started if none), with the path it opens. Nil for unknown media.
    private func videoOpen(_ id: UUID) -> (path: String, task: Task<(any Demuxing)?, Never>)? {
        state.withLock { s in
            guard let ref = s.refs[id] else { return nil }
            if let o = s.videoOpen[id], o.path == ref.path { return o }
            let make = makeDemuxer, url = URL(fileURLWithPath: ref.path)
            let o = (path: ref.path, task: Task.detached { try? await make(url) })
            s.videoOpen[id] = o
            return o
        }
    }

    private func audioOpen(_ id: UUID) -> (path: String, rate: Int, task: Task<(any AudioSource)?, Never>)? {
        state.withLock { s in
            guard let ref = s.refs[id] else { return nil }
            if let o = s.audioOpen[id], o.path == ref.path, o.rate == s.sampleRate { return o }
            let make = makeAudio, url = URL(fileURLWithPath: ref.path), rate = s.sampleRate
            let o = (path: ref.path, rate: rate, task: Task.detached { try? await make(url, rate) })
            s.audioOpen[id] = o
            return o
        }
    }

    /// Caches a finished open only if the media still has the path (and rate) it was opened for.
    /// Returns the cached object, or nil when the result is stale or failed.
    private func finishVideo(_ id: UUID, path: String, _ result: (any Demuxing)?) -> (any Demuxing)? {
        state.withLock { s in
            guard s.refs[id]?.path == path else { return nil }
            if s.videoOpen[id]?.path == path { s.videoOpen[id] = nil }
            if let cached = s.demuxers[id] { return cached }
            guard let result else { return nil }
            s.demuxers[id] = result
            return result
        }
    }

    private func finishAudio(_ id: UUID, path: String, rate: Int, _ result: (any AudioSource)?) -> (any AudioSource)? {
        state.withLock { s in
            guard s.refs[id]?.path == path, s.sampleRate == rate else { return nil }
            if s.audioOpen[id]?.path == path, s.audioOpen[id]?.rate == rate { s.audioOpen[id] = nil }
            if let cached = s.audio[id] { return cached }
            guard let result else { s.noAudio.insert(id); return nil }
            s.audio[id] = result
            return result
        }
    }

    private func cachedVideo(_ id: UUID) -> (any Demuxing)? { state.withLock { $0.demuxers[id] } }
    private func cachedAudio(_ id: UUID) -> (any AudioSource)? { state.withLock { $0.audio[id] } }

    /// Loads the demuxer and audio source of each item (concurrently) into the cache. Offline or unreadable items
    /// are skipped; a later lookup reports why. Returns the IDs that are ready for video.
    @discardableResult
    public func prepare(_ ids: [UUID]) async -> Set<UUID> {
        await withTaskGroup(of: UUID?.self) { group in
            for id in ids {
                group.addTask { [self] in
                    guard let ref = state.withLock({ $0.refs[id] }), fileExists(ref.path) else { return nil }
                    var ready = cachedVideo(id) != nil
                    if !ready, let o = videoOpen(id) {
                        ready = finishVideo(id, path: o.path, await o.task.value) != nil
                    }
                    let skipAudio = state.withLock { $0.audio[id] != nil || $0.noAudio.contains(id) }
                    if !skipAudio, let o = audioOpen(id) {
                        _ = finishAudio(id, path: o.path, rate: o.rate, await o.task.value)
                    }
                    return ready ? id : nil
                }
            }
            var out = Set<UUID>()
            for await id in group { if let id { out.insert(id) } }
            return out
        }
    }

    // MARK: MediaResolver (sync, off the main actor)

    public func demuxer(for media: UUID) throws -> any Demuxing {
        for _ in 0..<3 {
            let ref = state.withLock { $0.refs[media] }
            guard let ref else { throw MediaResolveError.unknownMedia(media) }
            guard fileExists(ref.path) else { throw MediaResolveError.offline(media, path: ref.path) }
            if let d = cachedVideo(media) { return d }
            guard let o = videoOpen(media) else { throw MediaResolveError.unknownMedia(media) }
            let result = Self.blocking { await o.task.value }
            if let d = finishVideo(media, path: o.path, result ?? nil) { return d }
            if state.withLock({ $0.refs[media]?.path }) == o.path { throw MediaResolveError.unreadable(media) }
        }
        throw MediaResolveError.unreadable(media)
    }

    public func audio(for media: UUID) throws -> any AudioSource {
        for _ in 0..<3 {
            let (ref, none) = state.withLock { ($0.refs[media], $0.noAudio.contains(media)) }
            guard let ref else { throw MediaResolveError.unknownMedia(media) }
            guard fileExists(ref.path) else { throw MediaResolveError.offline(media, path: ref.path) }
            if let a = cachedAudio(media) { return a }
            if none { throw MediaResolveError.noAudio(media) }
            guard let o = audioOpen(media) else { throw MediaResolveError.unknownMedia(media) }
            let result = Self.blocking { await o.task.value }
            if let a = finishAudio(media, path: o.path, rate: o.rate, result ?? nil) { return a }
            if state.withLock({ $0.refs[media]?.path == o.path && $0.sampleRate == o.rate }) { throw MediaResolveError.noAudio(media) }
        }
        throw MediaResolveError.noAudio(media)
    }

    /// Waits for an async result on the calling (non-main) thread.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T? {
        let box = Mutex<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached { let r = await work(); box.withLock { $0 = r }; done.signal() }
        done.wait()
        return box.withLock { $0 }
    }
}
