import Foundation
import SQCore
import Synchronization

/// Turns a layer's `ClipColor` + its media into the `ColorPipeline` the compositor needs. Shared by playback and export.
///
/// Returns nil (identity fast path) when the layer is plain Rec.709 with no correction and no LUT: the compositor then
/// takes its cheap inverse-OETF path and never allocates the color intermediate.
///
/// Two levels, so a keyframed grade (a new `ClipColor` every frame) neither lags behind the playhead nor floods a cache:
/// - The LUTs a grade references (the static part: Input LUTs, look LUTs, the automatic camera LUT) are loaded once per
///   distinct LUT set and media, and cached. Loading reads and parses files, so it never happens on the render thread:
///   `pipeline(for:media:owner:)` schedules it in the background on a miss and serves the owner's previous pipeline
///   until `onWarmed` fires (the engine answers with a redraw). `warm(_:)` (timeline push) re-checks file LUT stamps,
///   so an edited `.cube` is reloaded, and retries LUTs that failed. `pipelineBlocking` (export) loads inline.
/// - The pipeline itself (the numbers: sliders, wheels, curves, vignette; uploaded as uniforms) is assembled from those
///   cached LUTs without I/O whenever the grade changes, and remembered per owner so an unchanged grade costs one
///   comparison.
public final class LayerColorResolver: Sendable {
    public typealias MediaInfoLookup = @Sendable (UUID) -> MediaInfo?

    /// The static part of a layer's color: which LUTs it needs, for which media.
    private struct LUTKey: Hashable {
        var refs: Set<LUTRef>   // a set: Step order does not change what is cached
        var media: UUID
        var embeddedLUT: String?
    }

    private struct LUTEntry {
        var luts: [LUTRef: CubeLUT]
        /// Stamps of the file LUTs the entry was loaded from.
        var stamps: [LUTRef: LUTStamp]
        /// Set when a referenced LUT failed to load: the entry is degraded and is reloaded after this date or on the next warm.
        var retryAfter: Date?
        /// New on every load, so a pipeline assembled from an older load is rebuilt.
        var generation: Int
    }

    /// The pipeline last served for an owner, with what it was assembled from.
    private struct Served {
        var color: ClipColor
        var media: UUID
        var space: ColorSpaceID?
        var generation: Int
        var pipeline: ColorPipeline?
        /// `State.clock` when last served or assembled (eviction drops the least recently used owners first).
        var lastUse = 0

        func matches(_ c: ClipColor, _ m: UUID, _ info: MediaInfo?, _ gen: Int) -> Bool {
            generation == gen && media == m && space == info?.detectedColorSpace && color == c
        }
    }

    private struct State {
        var entries: [LUTKey: LUTEntry] = [:]
        var inflight: Set<LUTKey> = []
        /// Last served pipeline per owner (the clip, else the media): reused while the grade is unchanged and drawn
        /// while the LUTs of a changed grade are still loading.
        var served: [UUID: Served] = [:]
        var clock = 0
        /// Keys in load order (oldest first) for eviction.
        var order: [LUTKey] = []
        var generation = 0
        var onWarmed: (@Sendable () -> Void)?

        mutating func touch(_ slot: UUID) {
            guard served[slot] != nil else { return }
            clock += 1
            served[slot]?.lastUse = clock
        }
    }

    private let lutProvider: (any LUTProvider)?
    private let mediaInfo: MediaInfoLookup
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "LayerColorResolver.warm", qos: .userInitiated)
    private static let cacheLimit = 256
    /// Owners whose last pipeline is remembered.
    static let servedLimit = 4 * cacheLimit
    private static let failureRetry: TimeInterval = 2
    /// `SQ_COLOR_LOG=1`: logs each LUT load (diagnostics).
    private static let logging = ProcessInfo.processInfo.environment["SQ_COLOR_LOG"] == "1"

    public init(lutProvider: (any LUTProvider)?, mediaInfo: @escaping MediaInfoLookup) {
        self.lutProvider = lutProvider; self.mediaInfo = mediaInfo
    }

    /// The project's info of `media` (the lookup this resolver was built with): the engines read the item's pixel aspect
    /// from it (F7.3). Never does I/O.
    public func info(of media: UUID) -> MediaInfo? { mediaInfo(media) }

    /// Called (on a background queue) after a background load finished; the engine redraws.
    public func setOnWarmed(_ f: (@Sendable () -> Void)?) { state.withLock { $0.onWarmed = f } }

    // MARK: Lookup (render thread)

    private enum Lookup {
        case served(ColorPipeline?)
        case entry(LUTEntry)
        case miss(previous: ColorPipeline?)
    }

    /// nil = identity Rec.709 (use the fast path). Never does I/O. While the LUTs of a changed grade are still loading,
    /// the pipeline last served for the same `owner` (the clip; the media when nil) keeps drawing: with `owner` a clip
    /// never shows another clip's grade of the same media.
    public func pipeline(for color: ClipColor, media: UUID, owner: UUID? = nil) -> ColorPipeline? {
        let info = mediaInfo(media)
        guard let key = Self.lutKey(color, media, info) else { return nil }
        let slot = owner ?? media
        // No LUTs: nothing to read from disk, so the grade is assembled on the spot (never a frame behind).
        if key.refs.isEmpty { return pipelineBlocking(for: color, media: media, owner: owner) }
        let (found, due): (Lookup, Bool) = state.withLock { s in
            guard let e = s.entries[key] else { s.touch(slot); return (.miss(previous: s.served[slot]?.pipeline), true) }
            let due = e.retryAfter.map { $0 <= Date() } ?? false
            if let p = s.served[slot], p.matches(color, media, info, e.generation) {
                s.touch(slot)
                return (.served(p.pipeline), due)
            }
            return (.entry(e), due)
        }
        if due { schedule(key, media: media, force: false) }
        switch found {
        case .served(let p): return p
        case .entry(let e): return assemble(color, media: media, info: info, entry: e, slot: slot)
        case .miss(let previous): return previous
        }
    }

    /// Loads inline and caches (export, tests). Never returns a stale entry for edited LUT files.
    public func pipelineBlocking(for color: ClipColor, media: UUID, owner: UUID? = nil) -> ColorPipeline? {
        let info = mediaInfo(media)
        guard let key = Self.lutKey(color, media, info) else { return nil }
        let entry = load(key, media: media, force: false)
        let slot = owner ?? media
        let hit = state.withLock { s -> Served? in
            guard let p = s.served[slot], p.matches(color, media, info, entry.generation) else { return nil }
            s.touch(slot)
            return p
        }
        if let hit { return hit.pipeline }
        return assemble(color, media: media, info: info, entry: entry, slot: slot)
    }

    /// Schedules background LUT loads for the given layers (timeline push / color change).
    public func warm(_ layers: [(color: ClipColor, media: UUID)]) {
        var seen = Set<LUTKey>()
        for l in layers {
            guard let key = Self.lutKey(l.color, l.media, mediaInfo(l.media)), seen.insert(key).inserted else { continue }
            schedule(key, media: l.media, force: true)
        }
    }

    /// Drops cached LUTs (media relinked, project opened). The last served pipelines stay as fallbacks.
    public func invalidate() {
        state.withLock { $0.entries.removeAll(); $0.order.removeAll() }
    }

    /// Waits for running background loads (tests).
    public func waitUntilIdle() async {
        while state.withLock({ !$0.inflight.isEmpty }) { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// Cached LUT sets (tests).
    var cachedCount: Int { state.withLock { $0.entries.count } }
    /// Owners with a remembered pipeline (tests).
    var servedCount: Int { state.withLock { $0.served.count } }

    // MARK: Building

    /// nil when the layer needs no pipeline. Otherwise the LUTs its enabled sections reference (the automatic Input LUT
    /// resolved to the media's embedded LUT where `ColorPipeline.from` would use it), independent of every number.
    private static func lutKey(_ color: ClipColor, _ media: UUID, _ info: MediaInfo?) -> LUTKey? {
        let source = color.effectiveSource(mediaSpace: info?.colorSpace)
        // Default settings on Rec.709 media: nothing to do (automatic embedded LUT applies to S-Log3 only).
        if color.isIdentity(rec709Source: source == .rec709) { return nil }
        var refs: Set<LUTRef> = []
        func add(_ r: LUTRef) { refs.insert(r) }
        for (n, e) in color.effects.enumerated() {
            if e.isEnabled(.basicCorrection), n > 0 || color.usesInputLUT, let ref = e.inputLUT {
                switch ref {
                case .file, .embedded: add(ref)
                case .automatic:
                    if n == 0, color.useEmbeddedLUT, info?.embeddedLUTName != nil, source == .sLog3SGamut3Cine {
                        add(.embedded(media))
                    }
                }
            }
            if e.isEnabled(.creative), let ref = e.creative.look, ref != .automatic, color.graph == nil { add(ref) }
        }
        if let g = color.graph {
            for s in g.steps where s.enabled { if let ref = s.lut, ref != .automatic { add(ref) } }
            if let ref = g.outputLUT, ref != .automatic { add(ref) }
        }
        return LUTKey(refs: refs, media: media, embeddedLUT: info?.embeddedLUTName)
    }

    /// Builds the pipeline from loaded LUTs (no I/O) and remembers it for `slot`.
    private func assemble(_ color: ClipColor, media: UUID, info: MediaInfo?, entry: LUTEntry, slot: UUID) -> ColorPipeline? {
        let built = ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: info,
                                       lutProvider: LoadedLUTs(luts: entry.luts))
        let result: ColorPipeline? = built.isIdentity ? nil : built
        state.withLock { s in
            s.clock += 1
            s.served[slot] = Served(color: color, media: media, space: info?.detectedColorSpace,
                                    generation: entry.generation, pipeline: result, lastUse: s.clock)
            // Full: drop the least recently used quarter, never everything (every visible layer would lose the fallback
            // it draws while a changed grade's LUTs load, and flash ungraded).
            if s.served.count > Self.servedLimit {
                let old = s.served.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(Self.servedLimit / 4)
                for (k, _) in old { s.served[k] = nil }
            }
        }
        return result
    }

    private func schedule(_ key: LUTKey, media: UUID, force: Bool) {
        let start = state.withLock { $0.inflight.insert(key).inserted }
        guard start else { return }
        queue.async { [self] in
            _ = load(key, media: media, force: force)
            let notify = state.withLock { $0.onWarmed }
            notify?()
            state.withLock { _ = $0.inflight.remove(key) }
        }
    }

    /// `force`: re-check file stamps and retry failed LUTs even when an entry exists.
    private func load(_ key: LUTKey, media: UUID, force: Bool) -> LUTEntry {
        let stamps = fileStamps(key.refs)
        if let e = state.withLock({ $0.entries[key] }), e.stamps == stamps,
           e.retryAfter == nil || (!force && e.retryAfter! > Date()) {
            return e
        }
        var luts: [LUTRef: CubeLUT] = [:]
        var failed = false
        for ref in key.refs {
            if let l = lutProvider?.lut(for: ref) { luts[ref] = l } else { failed = true }
        }
        if Self.logging {
            NSLog("COLOR: media=\(media) luts=\(luts.count)/\(key.refs.count)\(failed ? " (LUT failed)" : "")")
        }
        return state.withLock { s in
            // Full: drop the oldest quarter, not everything (every visible layer would otherwise miss at once).
            if s.entries.count >= Self.cacheLimit {
                let drop = s.order.prefix(Self.cacheLimit / 4)
                for k in drop { s.entries[k] = nil }
                s.order.removeFirst(drop.count)
            }
            if s.entries[key] == nil { s.order.append(key) }
            s.generation += 1
            let e = LUTEntry(luts: luts, stamps: stamps,
                             retryAfter: failed ? Date().addingTimeInterval(Self.failureRetry) : nil,
                             generation: s.generation)
            s.entries[key] = e
            return e
        }
    }

    private func fileStamps(_ refs: Set<LUTRef>) -> [LUTRef: LUTStamp] {
        var out: [LUTRef: LUTStamp] = [:]
        for ref in refs { if case .file = ref, let st = lutProvider?.stamp(for: ref) { out[ref] = st } }
        return out
    }

    static func isIdentity(_ p: ColorPipeline) -> Bool {
        p.isIdentity
    }
}

/// Serves already loaded LUTs (no I/O); a missing one is treated as absent, like a failed load.
private struct LoadedLUTs: LUTProvider {
    let luts: [LUTRef: CubeLUT]
    func lut(for ref: LUTRef) -> CubeLUT? { luts[ref] }
}
