import CoreVideo
import Foundation
import SQAnalysis
import SQCore
import SQMedia
import SQPlayback
import SQRender
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
/// `SQPlayback.MediaResolver` for the engine: synchronous and called off the main actor. Opened demuxers and audio
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
        /// Decoded still images (path they were read from), decoded once.
        var stills: [UUID: (path: String, frame: StillFrame)] = [:]
        /// Order the stills were decoded in (oldest first), for the byte budget.
        var stillOrder: [UUID] = []
        /// One open in flight per media, shared by `prepare` and the blocking lookups (never two live demuxers).
        var videoOpen: [UUID: (path: String, task: Task<(any Demuxing)?, Never>)] = [:]
        var audioOpen: [UUID: (path: String, rate: Int, map: AudioChannelMap?, task: Task<(any AudioSource)?, Never>)] = [:]
        /// Opened proxies (W9.9), with the proxy file they were opened from.
        var proxies: [UUID: (url: URL, demuxer: any Demuxing)] = [:]
        /// Bumped by `dropProxies`: an open that began before must not store its (old file's) demuxer.
        var proxyEpochs: [UUID: Int] = [:]
        /// Preview render cache files by fake media ID, with their opened demuxers.
        var renderCacheFiles: [UUID: URL] = [:]
        var renderCacheDemuxers: [UUID: any Demuxing] = [:]
    }
    private let state = Mutex(State())
    /// Where a media's ready proxy is (W9.9 AutoProxy): (media ID, source path) -> proxy file, nil = none.
    public typealias ProxyURLLookup = @Sendable (_ media: UUID, _ path: String) -> URL?
    /// Nominal box: a closure stored straight in `Mutex<Optional<closure>>` is reabstracted (thunk pair) on every
    /// store and read, and a read-modify-write cycle stacked thousands of them (stack overflow, 2026-10-29 crash).
    private final class LookupBox: Sendable {
        let call: ProxyURLLookup
        init(_ call: @escaping ProxyURLLookup) { self.call = call }
    }
    private let proxyLookup = Mutex<LookupBox?>(nil)
    private let makeDemuxer: DemuxerFactory
    /// Opens preview render cache files: `UncachedFileDemuxer` (F_NOCACHE reads), or the injected factory in tests.
    private let makeCacheDemuxer: DemuxerFactory
    /// Opens a file's audio with the media item's channel map (F7.10; nil = the file's layout).
    private let makeAudio: @Sendable (URL, Int, AudioChannelMap?, Int?) async throws -> any AudioSource
    private let fileExists: @Sendable (String) -> Bool
    /// Decoded stills (up to 8192 px, ~270 MB each) are kept up to this many bytes; the oldest go first.
    private let stillBudget: Int
    private let lutProvider: CachingLUTProvider
    /// Per-layer color pipelines for playback and export: S-Log3 / HLG conversion, the clip's correction and LUTs.
    /// Media infos and the embedded LUT (read from the clip file, cached) come from this resolver's refs.
    public let colorResolver: LayerColorResolver?
    /// Gyroflow Stabilizer frames for playback and export: the engine plus this resolver's media paths.
    public let gyroWarper: GyroFrameWarper?

    public static func openDemuxer(_ url: URL) async throws -> any Demuxing {
        if let probed = DemuxerHandoff.take(url) { return probed }     // just imported: the probe's sample-table walk
        if WebMFile.isWebM(url) { return try await WebMDemuxer(url: url) }
        if MXFFile.isMXF(url) { return try await MXFDemuxer(url: url) }
        return try await AVDemuxer(url: url)
    }
    public static func openAudio(_ url: URL, _ sampleRate: Int) async throws -> any AudioSource {
        if WebMFile.isWebM(url) { return try await WebMAudioSource.open(url: url, sampleRate: sampleRate) }
        if MXFFile.isMXF(url) { return try await MXFAudioSource.open(url: url, sampleRate: sampleRate) }
        return try await AssetAudioSource.open(url: url, sampleRate: sampleRate)
    }

    /// Factories default to the AVFoundation ones. They default to nil (resolved here) rather than to a closure or
    /// function value: an async throwing function as a default-argument expression miscompiles, and the process then
    /// aborts with "freed pointer was not the last allocation" as soon as that factory throws (e.g. an unreadable file).
    public init(demuxer: DemuxerFactory? = nil, audio: AudioFactory? = nil,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                stillCacheBytes: Int = 512 * 1024 * 1024,
                gyroEngine: (any GyroStabilizationEngine)? = GyroflowEngine.shared) {
        stillBudget = stillCacheBytes
        makeDemuxer = demuxer ?? { try await Self.openDemuxer($0) }
        makeCacheDemuxer = demuxer ?? { try await UncachedFileDemuxer(url: $0) }
        if let audio {      // an injected source delivers two sides: the map picks from those
            makeAudio = { url, rate, map, _ in ChannelMappedSource.wrap(try await audio(url, rate), map: map) }
        } else {
            makeAudio = { try await AudioSources.open(url: $0, sampleRate: $1, channelMap: $2, expectedChannels: $3) }
        }
        self.fileExists = fileExists
        let owner = WeakOwner()
        let provider = CachingLUTProvider(file: { MediaManagement.resolveStoredPath($0, projectFolder: owner.folder).flatMap { FileManager.default.contents(atPath: $0) } },
                                          embedded: { id in
            guard let path = owner.value?.path(of: id) else { return nil }
            return (try? EmbeddedMeta.lut(inClip: URL(fileURLWithPath: path)))?.data
        }, stamp: { MediaManagement.resolveStoredPath($0, projectFolder: owner.folder).flatMap { LUTStamp.ofFile($0) } })
        lutProvider = provider
        colorResolver = LayerColorResolver(lutProvider: provider) { owner.value?.info(of: $0) }
        gyroWarper = gyroEngine.map { GyroFrameWarper(engine: $0, path: { owner.value?.path(of: $0) }) }
        self.owner = owner
        owner.value = self
    }

    private final class WeakOwner: @unchecked Sendable {
        weak var value: ProjectMediaResolver?
        private let lock = NSLock()
        private var _folder: URL?
        var folder: URL? { get { lock.lock(); defer { lock.unlock() }; return _folder } set { lock.lock(); _folder = newValue; lock.unlock() } }
    }
    private let owner: WeakOwner

    /// The folder a project-relative LUT path (`Files/Library/x.cube`) is read from; nil for a loose project file.
    public func setProjectFolder(_ folder: URL?) {
        guard owner.folder != folder else { return }
        owner.folder = folder
        lutProvider.removeAll(); colorResolver?.invalidate()
    }

    /// Number of decoded stills held (tests).
    var cachedStillCount: Int { state.withLock { $0.stills.count } }

    public func path(of id: UUID) -> String? { state.withLock { $0.refs[id]?.path } }
    public func info(of id: UUID) -> MediaInfo? { state.withLock { $0.refs[id]?.info } }

    /// Replaces the known media. Cached and in-flight sources of items whose path changed (relink) or that are gone
    /// are dropped; a sample-rate change drops all audio. An open that finishes for an old path or rate is discarded.
    public func update(_ media: [MediaRef], sampleRate: Int? = nil) {
        state.withLock { s in
            let new = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
            for id in Set(s.refs.keys).union(s.demuxers.keys).union(s.videoOpen.keys).union(s.audioOpen.keys)
            where new[id] == nil || new[id]?.path != s.refs[id]?.path {
                s.demuxers[id] = nil; s.audio[id] = nil; s.noAudio.remove(id); s.stills[id] = nil; s.stillOrder.removeAll { $0 == id }
                s.videoOpen[id] = nil; s.audioOpen[id] = nil; s.proxies[id] = nil
            }
            if new.contains(where: { id, ref in s.refs[id].map { $0.path != ref.path } ?? false }) {   // a path change, not a new item
                lutProvider.removeAll(); colorResolver?.invalidate()
            }
            // F7.10: other audio channels chosen for an item: its audio source is opened again, the picture stays.
            for (id, ref) in new where s.refs[id] != nil && s.refs[id]?.info?.audio?.channelMap != ref.info?.audio?.channelMap {
                s.audio[id] = nil; s.noAudio.remove(id); s.audioOpen[id] = nil
            }
            s.refs = new
            if let sampleRate, sampleRate != s.sampleRate {
                s.sampleRate = sampleRate; s.audio = [:]; s.noAudio = []; s.audioOpen = [:]
            }
        }
    }

    /// The files of these items changed on disk (overwritten, gone, back): every cached or in-flight source is dropped, so
    /// the next use opens the file as it is now. Proxies stay; the engine's `mediaChanged` decides about them.
    public func invalidate(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        state.withLock { s in
            for id in ids {
                s.demuxers[id] = nil; s.audio[id] = nil; s.noAudio.remove(id); s.stills[id] = nil
                s.stillOrder.removeAll { $0 == id }
                s.videoOpen[id] = nil; s.audioOpen[id] = nil; s.proxies[id] = nil; s.proxyEpochs[id, default: 0] += 1
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

    private func audioOpen(_ id: UUID) -> (path: String, rate: Int, map: AudioChannelMap?, task: Task<(any AudioSource)?, Never>)? {
        state.withLock { s in
            guard let ref = s.refs[id] else { return nil }
            let map = ref.info?.audio?.channelMap
            if let o = s.audioOpen[id], o.path == ref.path, o.rate == s.sampleRate, o.map == map { return o }
            let make = makeAudio, url = URL(fileURLWithPath: ref.path), rate = s.sampleRate
            // A map chosen against another channel count (the file's tracks changed since the probe) is not routed.
            let channels = map == nil ? nil : ref.info?.audio?.channels
            let o = (path: ref.path, rate: rate, map: map, task: Task.detached { try? await make(url, rate, map, channels) })
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

    private func finishAudio(_ id: UUID, path: String, rate: Int, map: AudioChannelMap?,
                             _ result: (any AudioSource)?) -> (any AudioSource)? {
        state.withLock { s in
            guard let ref = s.refs[id], ref.path == path, s.sampleRate == rate, ref.info?.audio?.channelMap == map else { return nil }
            if let o = s.audioOpen[id], o.path == path, o.rate == rate, o.map == map { s.audioOpen[id] = nil }
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
                    if ref.info?.isStill == true { return (try? stillFrame(for: id)) != nil ? id : nil }
                    var ready = cachedVideo(id) != nil
                    if !ready, let o = videoOpen(id) {
                        ready = finishVideo(id, path: o.path, await o.task.value) != nil
                    }
                    let skipAudio = state.withLock { $0.audio[id] != nil || $0.noAudio.contains(id) }
                    if !skipAudio, let o = audioOpen(id) {
                        _ = finishAudio(id, path: o.path, rate: o.rate, map: o.map, await o.task.value)
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

    public func fileURL(for media: UUID) -> URL? {
        guard let ref = state.withLock({ $0.refs[media] }), ref.info?.isStill != true, fileExists(ref.path) else { return nil }
        return URL(fileURLWithPath: ref.path)
    }

    /// Preview render cache: the fake media ID of a cached segment (`RenderCacheMedia.id(forKey:)`) is served from this
    /// .mov. Registered when the segment is rendered; the file is opened on the first lookup (a decode queue).
    public func setRenderCacheFile(media: UUID, url: URL) {
        state.withLock { s in
            if s.renderCacheFiles[media] != url { s.renderCacheDemuxers[media] = nil }
            s.renderCacheFiles[media] = url
        }
    }

    public func removeRenderCacheFile(media: UUID) {
        state.withLock { s in s.renderCacheFiles[media] = nil; s.renderCacheDemuxers[media] = nil }
    }

    public func demuxer(for media: UUID) throws -> any Demuxing {
        if let url = state.withLock({ $0.renderCacheFiles[media] }) {
            if let d = state.withLock({ $0.renderCacheDemuxers[media] }) { return d }
            guard fileExists(url.path) else { throw MediaResolveError.offline(media, path: url.path) }
            let make = makeCacheDemuxer
            guard let opened = Self.blocking({ try? await make(url) }), let d = opened else { throw MediaResolveError.unreadable(media) }
            return state.withLock { s in
                guard s.renderCacheFiles[media] == url else { return d }
                if let c = s.renderCacheDemuxers[media] { return c }
                s.renderCacheDemuxers[media] = d
                return d
            }
        }
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

    /// The original's demuxer, opened without blocking (shared with `prepare` and the engine's lookups). nil when offline,
    /// unknown or unreadable.
    public func openedDemuxer(for media: UUID) async -> (any Demuxing)? {
        guard let ref = state.withLock({ $0.refs[media] }), fileExists(ref.path) else { return nil }
        if let d = cachedVideo(media) { return d }
        guard let o = videoOpen(media) else { return nil }
        return finishVideo(media, path: o.path, await o.task.value)
    }

    /// Forgets the opened proxies of these media: the proxy file was replaced or removed (W9.9), so the next
    /// `proxyDemuxer` opens it again, even under the same file name.
    public func dropProxies(_ ids: Set<UUID>) {
        state.withLock { s in for id in ids { s.proxies[id] = nil; s.proxyEpochs[id, default: 0] += 1 } }
    }

    /// Installs (or with nil removes) the proxy lookup; opened proxies are dropped.
    public func setProxyLookup(_ lookup: ProxyURLLookup?) {
        let box = lookup.map(LookupBox.init)
        proxyLookup.withLock { $0 = box }
        state.withLock { $0.proxies = [:] }
    }

    /// The installed proxy lookup (nil when none). Re-setting it must not grow the call chain.
    public var currentProxyLookup: ProxyURLLookup? { proxyLookup.withLock { $0 }?.call }

    /// The media's ready proxy, for the monitors only (scrub and optionally playback). Export and every other reader
    /// use `demuxer(for:)`, which always opens the original. nil when there is no ready proxy or it cannot be opened.
    public func proxyDemuxer(for media: UUID) throws -> (any Demuxing)? {
        guard let ref = state.withLock({ $0.refs[media] }), ref.info?.isStill != true,
              let lookup = proxyLookup.withLock({ $0 })?.call, let url = lookup(media, ref.path) else { return nil }
        let (cached, epoch) = state.withLock { ($0.proxies[media], $0.proxyEpochs[media] ?? 0) }
        if let c = cached, c.url == url { return c.demuxer }
        let make = makeDemuxer
        guard let opened = Self.blocking({ try? await make(url) }), let d = opened else { return nil }
        return state.withLock { s in
            guard s.refs[media]?.path == ref.path else { return nil }
            guard (s.proxyEpochs[media] ?? 0) == epoch else { return nil }      // replaced meanwhile (a proxiesChanged follows)
            if let c = s.proxies[media], c.url == url { return c.demuxer }
            s.proxies[media] = (url, d)
            return d
        }
    }

    /// The decoded picture of a still-image item (ImageIO, once per path). nil = not a still.
    public func stillFrame(for media: UUID) throws -> StillFrame? {
        let ref = state.withLock { $0.refs[media] }
        guard let ref, ref.info?.isStill == true else { return nil }
        guard fileExists(ref.path) else { throw MediaResolveError.offline(media, path: ref.path) }
        if let c = state.withLock({ $0.stills[media] }), c.path == ref.path { return c.frame }
        guard let buffer = try? StillImage.load(URL(fileURLWithPath: ref.path)) else { throw MediaResolveError.unreadable(media) }
        // The picture counts with its real size (the buffer is capped at 8192 px), so Scale 1 is one file pixel.
        let size = ref.info?.video.map { ($0.width, $0.height) } ?? (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        let frame = StillFrame(buffer: buffer, info: StillImage.trackInfo(width: size.0, height: size.1))
        return state.withLock { s in
            guard s.refs[media]?.path == ref.path else { return frame }
            if let c = s.stills[media], c.path == ref.path { return c.frame }
            s.stills[media] = (ref.path, frame)
            s.stillOrder.removeAll { $0 == media }; s.stillOrder.append(media)
            var total = s.stills.values.reduce(0) { $0 + CVPixelBufferGetDataSize($1.frame.buffer) }
            while total > stillBudget, s.stillOrder.count > 1 {         // the one just decoded always stays
                let old = s.stillOrder.removeFirst()
                if let f = s.stills.removeValue(forKey: old) { total -= CVPixelBufferGetDataSize(f.frame.buffer) }
            }
            return frame
        }
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
            if let a = finishAudio(media, path: o.path, rate: o.rate, map: o.map, result ?? nil) { return a }
            if state.withLock({ $0.refs[media]?.path == o.path && $0.sampleRate == o.rate && $0.refs[media]?.info?.audio?.channelMap == o.map }) { throw MediaResolveError.noAudio(media) }
        }
        throw MediaResolveError.noAudio(media)
    }

    /// Waits for an async result on the calling thread. The work runs detached, so waiting never deadlocks the pool,
    /// but a caller on the main thread freezes the UI for the open: that is a bug in the caller (the render loop and
    /// the audio feeder call from their own queues), so it is logged once instead of crashing a shipping build.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T? {
        if Thread.isMainThread { noteMainThreadWait() }
        let box = Mutex<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached { let r = await work(); box.withLock { $0 = r }; done.signal() }
        done.wait()
        return box.withLock { $0 }
    }

    private static let warnedMainWait = Mutex<Bool>(false)
    private static func noteMainThreadWait() {
        let first = warnedMainWait.withLock { w -> Bool in defer { w = true }; return !w }
        if first { NSLog("ProjectMediaResolver: a media open blocked the main thread (call it from a background queue)") }
    }
}
