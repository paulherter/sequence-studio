import Foundation
import SSCore
import Synchronization

/// Turns a layer's `ClipColor` + its media into the `ColorPipeline` the compositor needs, once per distinct
/// (clip colour, media, detected properties) and cached. Shared by playback and export.
///
/// Returns nil (identity fast path) when the layer is plain Rec.709 with no correction and no LUT: the compositor then
/// takes its cheap inverse-OETF path and never allocates the colour intermediate.
///
/// Building a pipeline can read and parse LUT files, so it never happens on the render thread:
/// - `pipeline(for:media:)` (playback) is a cache lookup. On a miss it schedules a background build and returns the
///   previous pipeline of that media (or identity) until `onWarmed` fires, which the engine answers with a redraw.
/// - `warm(_:)` is called when a timeline is pushed: builds what is missing and re-checks file LUT stamps (an edited
///   `.cube` is reloaded) and retries LUTs that failed to load.
/// - `pipelineBlocking(for:media:)` (export) builds inline.
public final class LayerColorResolver: Sendable {
    public typealias MediaInfoLookup = @Sendable (UUID) -> MediaInfo?

    private struct Key: Hashable {
        var color: ClipColor
        var media: UUID
        var space: ColorSpaceID?
        var embeddedLUT: String?
    }

    private struct Entry {
        var pipeline: ColorPipeline?
        /// Stamps of the file LUTs the pipeline was built from.
        var stamps: [LUTRef: LUTStamp]
        /// Set when a referenced LUT failed to load: the pipeline is degraded and is rebuilt after this date or on the next warm.
        var retryAfter: Date?
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var inflight: Set<Key> = []
        /// Last built pipeline per media: served while a new one is still being built.
        var previous: [UUID: ColorPipeline?] = [:]
        var onWarmed: (@Sendable () -> Void)?
    }

    private let lutProvider: (any LUTProvider)?
    private let mediaInfo: MediaInfoLookup
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "LayerColorResolver.warm", qos: .userInitiated)
    private static let cacheLimit = 256
    private static let failureRetry: TimeInterval = 2
    /// `SS_COLOR_LOG=1`: logs each newly built pipeline (diagnostics).
    private static let logging = ProcessInfo.processInfo.environment["SS_COLOR_LOG"] == "1"

    public init(lutProvider: (any LUTProvider)?, mediaInfo: @escaping MediaInfoLookup) {
        self.lutProvider = lutProvider; self.mediaInfo = mediaInfo
    }

    /// Called (on a background queue) after a background build finished; the engine redraws.
    public func setOnWarmed(_ f: (@Sendable () -> Void)?) { state.withLock { $0.onWarmed = f } }

    // MARK: Lookup (render thread)

    /// nil = identity Rec.709 (use the fast path). Never does I/O.
    public func pipeline(for color: ClipColor, media: UUID) -> ColorPipeline? {
        guard let (key, _) = Self.needsPipeline(color, media, mediaInfo(media)) else { return nil }
        let (hit, previous, due): (Entry?, ColorPipeline??, Bool) = state.withLock { s in
            let e = s.entries[key]
            return (e, s.previous[media], e == nil || (e?.retryAfter.map { $0 <= Date() } ?? false))
        }
        if due { schedule(key, color: color, media: media, force: false) }
        if let hit { return hit.pipeline }
        return previous ?? nil
    }

    /// Builds inline and caches (export, tests). Never returns a stale entry for edited LUT files.
    public func pipelineBlocking(for color: ClipColor, media: UUID) -> ColorPipeline? {
        let info = mediaInfo(media)
        guard let (key, _) = Self.needsPipeline(color, media, info) else { return nil }
        return build(key, color: color, media: media, info: info, force: false)
    }

    /// Schedules background builds for the given layers (timeline push / colour change).
    public func warm(_ layers: [(color: ClipColor, media: UUID)]) {
        for l in layers {
            guard let (key, _) = Self.needsPipeline(l.color, l.media, mediaInfo(l.media)) else { continue }
            schedule(key, color: l.color, media: l.media, force: true)
        }
    }

    /// Drops cached pipelines (media relinked, project opened). The last served pipelines stay as fallbacks.
    public func invalidate() {
        state.withLock { $0.entries.removeAll() }
    }

    /// Waits for running background builds (tests).
    public func waitUntilIdle() async {
        while state.withLock({ !$0.inflight.isEmpty }) { try? await Task.sleep(for: .milliseconds(2)) }
    }

    var cachedCount: Int { state.withLock { $0.entries.count } }

    // MARK: Building

    private static func needsPipeline(_ color: ClipColor, _ media: UUID, _ info: MediaInfo?) -> (Key, MediaInfo?)? {
        // Default settings on Rec.709 media: nothing to do (automatic embedded LUT applies to S-Log3 only).
        if color.isDefault, (info?.colorSpace ?? .rec709) == .rec709 { return nil }
        return (Key(color: color, media: media, space: info?.detectedColorSpace, embeddedLUT: info?.embeddedLUTName), info)
    }

    private func schedule(_ key: Key, color: ClipColor, media: UUID, force: Bool) {
        let start = state.withLock { $0.inflight.insert(key).inserted }
        guard start else { return }
        queue.async { [self] in
            let info = mediaInfo(media)
            _ = build(key, color: color, media: media, info: info, force: force)
            let notify = state.withLock { $0.onWarmed }
            notify?()
            state.withLock { _ = $0.inflight.remove(key) }
        }
    }

    /// `force`: re-check file stamps and retry failed LUTs even when an entry exists.
    private func build(_ key: Key, color: ClipColor, media: UUID, info: MediaInfo?, force: Bool) -> ColorPipeline? {
        let stamps = fileStamps(color)
        if let e = state.withLock({ $0.entries[key] }), e.stamps == stamps,
           e.retryAfter == nil || (!force && e.retryAfter! > Date()) {
            return e.pipeline
        }
        let recorder = RecordingProvider(base: lutProvider)
        let built = ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: info, lutProvider: recorder)
        let result: ColorPipeline? = Self.isIdentity(built) ? nil : built
        if Self.logging {
            let what = result.map { "\($0.source) conversionLUT=\($0.conversionLUT?.title ?? "none") creative=\($0.creativeLUT?.title ?? "none")" }
            NSLog("COLOR: media=\(media) pipeline=\(what ?? "identity")\(recorder.failed ? " (LUT failed)" : "")")
        }
        state.withLock { s in
            if s.entries.count >= Self.cacheLimit { s.entries.removeAll() }
            s.entries[key] = Entry(pipeline: result, stamps: stamps,
                                   retryAfter: recorder.failed ? Date().addingTimeInterval(Self.failureRetry) : nil)
            s.previous[media] = .some(result)
        }
        return result
    }

    private func fileStamps(_ c: ClipColor) -> [LUTRef: LUTStamp] {
        var out: [LUTRef: LUTStamp] = [:]
        for ref in [c.conversionLUT, c.creativeLUT] {
            if let ref, case .file = ref, let st = lutProvider?.stamp(for: ref) { out[ref] = st }
        }
        return out
    }

    static func isIdentity(_ p: ColorPipeline) -> Bool {
        p.source == .rec709 && p.correction.isNeutral && p.conversionLUT == nil
            && (p.creativeLUT == nil || p.creativeIntensity <= 0)
    }
}

/// Forwards to the real provider and notes whether any requested LUT could not be loaded.
private final class RecordingProvider: LUTProvider, @unchecked Sendable {
    let base: (any LUTProvider)?
    private let lock = NSLock()
    private var didFail = false
    init(base: (any LUTProvider)?) { self.base = base }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return didFail }
    func lut(for ref: LUTRef) -> CubeLUT? {
        let l = base?.lut(for: ref)
        if l == nil { lock.lock(); didFail = true; lock.unlock() }
        return l
    }
    func stamp(for ref: LUTRef) -> LUTStamp? { base?.stamp(for: ref) }
}
