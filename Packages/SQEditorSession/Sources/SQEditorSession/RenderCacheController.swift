import Foundation
import SQCore
import SQExport
import SQMedia
import SQPlayback
import SQRender
import SQUIKit

/// Preview render cache, wiring (the design notes "Preview render cache"): keeps the disk index, renders the next heavy
/// segment in the background when the editor is idle, and gives the session the spans playback reads instead of the clips.
/// The session feeds it the un-substituted sequence on every push (`spans(for:sequences:)`); a 1 s tick asks the
/// scheduler for work. Nothing here touches the project file.
@MainActor
public final class RenderCacheController {
    public struct Stats: Equatable, Sendable {
        public var rendered = 0
        public var failed = 0
        /// Segments playback reads from the cache right now.
        public var spansInUse = 0
        public var bytes: Int64 = 0
    }

    /// What the host tells the controller (closures, so the session and tests share one path).
    public struct Inputs {
        public var playhead: () -> Time
        public var isPlaying: () -> Bool
        /// Cumulative dropped frames of the playback engine.
        public var droppedFrames: () -> Int
        /// Another heavy job (export, auto proxy) runs: the cache waits.
        public var isBusy: () -> Bool
        public var now: () -> Date
        public init(playhead: @escaping () -> Time, isPlaying: @escaping () -> Bool, droppedFrames: @escaping () -> Int,
                    isBusy: @escaping () -> Bool = { false }, now: @escaping () -> Date = Date.init) {
            self.playhead = playhead; self.isPlaying = isPlaying; self.droppedFrames = droppedFrames
            self.isBusy = isBusy; self.now = now
        }
    }

    /// Renders one segment to the URL; the last argument is the pending-writes tier the renderer fills with the frames it
    /// encodes (`RenderCacheSegmentWriter.write(..., pending:)`).
    public typealias Renderer = @Sendable (RenderCacheSegment, Timeline, [Timeline.ID: Timeline], URL,
                                           RenderCachePendingFrames) async throws -> Void

    /// Changes whenever the renderer's output changes. shortcut: bumped by hand with a shader or effect change; the app
    /// build number is part of the key too, so a new build never reads an old picture.
    static let rendererRevision = "r1"

    public private(set) var stats = Stats()
    /// Set by the session: spans changed after a render finished, push the sequence again.
    public var onSpansChanged: (() -> Void)?
    /// Set by the session: hands the pending-writes frames of a segment that just went live to playback
    /// (`PlaybackEngine.seedFrames`).
    public var seedFrames: (([DecodedFrame]) -> Void)?
    /// Powered by `PowerPolicy.pausesBackgroundJobs`.
    public var held = false
    /// The display view: playback reads spans only in the SDR view (`PlaybackEngine`), so a change pushes again.
    var displayView: () -> DisplayView = { DisplayView.current }
    private var lastDisplayView: DisplayView?

    private var store: RenderCacheStore
    private var index: RenderCacheIndex
    private let media: ProjectMediaResolver
    private let inputs: Inputs
    private let render: Renderer
    private let idleDelay: TimeInterval
    private var enabled = false
    private var source: (timeline: Timeline, sequences: [Timeline.ID: Timeline])?
    private var segments: [RenderCacheSegment] = []
    private var segmentsStale = true
    private var lastEdit: Date
    private var dropTimes: [Time] = []
    private var lastDropped = 0
    private var job: (key: String, task: Task<Void, Never>)?
    private var timer: Timer?

    public init(directory: URL, byteCap: Int64, media: ProjectMediaResolver, inputs: Inputs,
                idleDelay: TimeInterval = RenderCacheScheduler.defaultIdleDelay,
                render: Renderer? = nil) {
        store = RenderCacheStore(directory: directory, byteCap: byteCap)
        index = RenderCacheIndex()
        self.media = media; self.inputs = inputs; self.idleDelay = idleDelay
        self.render = render ?? { segment, timeline, sequences, url, pending in
            try await RenderCacheSegmentWriter.write(segment: segment, timeline: timeline, sequences: sequences,
                                                     resolver: media, to: url, pending: pending)
        }
        lastEdit = inputs.now()
    }

    // MARK: Settings

    /// On/off and the size cap (Settings). Turning it off keeps the files (they are valid again when it is turned on) but
    /// playback stops reading them; a smaller cap evicts at the next commit.
    public func configure(enabled: Bool, directory: URL, byteCap: Int64) {
        let moved = directory != store.directory
        if moved { cancelJob(); unregisterAll() }
        store = RenderCacheStore(directory: directory, byteCap: byteCap)
        if enabled != self.enabled || moved {
            self.enabled = enabled
            if enabled {
                index = store.load()
                registerAll()
                startTimer()
            } else {
                cancelJob(); stopTimer(); unregisterAll(); index = RenderCacheIndex()
            }
            segmentsStale = true
            publishStats(spans: 0)
            onSpansChanged?()
        }
    }

    public var isEnabled: Bool { enabled }

    // MARK: Read path

    /// The spans playback should read for this sequence (empty when the cache is off, empty or nothing matches). Also the
    /// session's note that the sequence was pushed: a changed sequence counts as an edit (the renderer waits).
    public func spans(for timeline: Timeline, sequences: [Timeline.ID: Timeline]) -> [RenderCacheSpan] {
        guard enabled else { source = nil; return [] }
        if source?.timeline != timeline || source?.sequences != sequences {
            source = (timeline, sequences)
            lastEdit = inputs.now()
            segmentsStale = true
        }
        guard !index.entries.isEmpty else { return [] }
        let spans = plan().filter { $0.isHeavy && index.contains($0.key) }
            .map { RenderCacheSpan(range: $0.range, media: RenderCacheMedia.id(forKey: $0.key)) }
        if spans.count != stats.spansInUse {
            publishStats(spans: spans.count)
            if !spans.isEmpty { SQLog.info("render cache: playback reads \(spans.count) cached segment(s)") }
        }
        return spans
    }

    /// The spans an export of this sequence may read (the same keys and files playback reads); no side effects: the
    /// export's sequence is not an edit and does not replace the pushed one. `ExportSourceBuilder` uses them only when
    /// the export settings give the cached picture (`RenderCacheSegmentWriter.mayReuse`).
    public func exportSpans(for timeline: Timeline, sequences: [Timeline.ID: Timeline]) -> [RenderCacheSpan] {
        guard enabled, !index.entries.isEmpty else { return [] }
        let segs = source?.timeline == timeline && source?.sequences == sequences ? plan()
            : Self.segments(of: timeline, sequences: sequences, media: media)
        return segs.filter { $0.isHeavy && index.contains($0.key) }
            .map { RenderCacheSpan(range: $0.range, media: RenderCacheMedia.id(forKey: $0.key)) }
    }

    /// A media file changed on disk: the stamps in the keys changed, so spans are recomputed.
    public func mediaChanged() {
        segmentsStale = true
        if enabled { onSpansChanged?() }
    }

    // MARK: Plan

    private func plan() -> [RenderCacheSegment] {
        guard let source else { return [] }
        if !segmentsStale { return segments }
        segments = Self.segments(of: source.timeline, sequences: source.sequences, media: media)
        segmentsStale = false
        return segments
    }

    static func segments(of timeline: Timeline, sequences: [Timeline.ID: Timeline],
                         media: ProjectMediaResolver) -> [RenderCacheSegment] {
        let context = RenderCacheContext(rendererID: Self.rendererID, workingSpace: RenderCacheSegmentWriter.workingSpace(for: timeline),
                                         mediaStamp: { mediaStamp(media, $0) })
        return RenderCachePlan.segments(of: timeline, resolver: { sequences[$0] }, context: context)
    }

    /// What of a media file the picture depends on besides the clip itself: size and modification date of the file, and
    /// its color interpretation (`MediaInfo`: input color space, transfer, LUT, HDR handling of the media item).
    nonisolated static func mediaStamp(_ media: ProjectMediaResolver, _ id: UUID) -> String {
        var stamp = ""
        if let path = media.path(of: id), let a = try? FileManager.default.attributesOfItem(atPath: path) {
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            stamp = "\(size)-\(mtime)"
        }
        if let info = media.info(of: id) {
            let e = JSONEncoder(); e.outputFormatting = .sortedKeys
            if let d = try? e.encode(info) { stamp += "|" + String(decoding: d, as: UTF8.self) }
        }
        return stamp
    }

    private static var rendererID: String {
        rendererRevision + "-" + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev")
    }

    // MARK: Background render

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// One scheduler step (called by the 1 s timer; tests call it directly).
    public func tick() {
        guard enabled, source != nil else { return }
        // shortcut: the display view is polled once a second, so a switch to or from SDR reads the cache (or the clips)
        // within a second; becomes a direct notification when the monitor's view change reaches the session.
        let view = displayView()
        if let last = lastDisplayView, last != view, !index.entries.isEmpty { onSpansChanged?() }
        lastDisplayView = view
        let dropped = inputs.droppedFrames()
        if inputs.isPlaying(), dropped > lastDropped {
            dropTimes.append(inputs.playhead())
            if dropTimes.count > 50 { dropTimes.removeFirst(dropTimes.count - 50) }
        }
        lastDropped = dropped
        let current = plan()
        if let job, !current.contains(where: { $0.key == job.key }) { cancelJob() }
        guard job == nil, let source else { return }
        guard let next = RenderCacheScheduler.nextJob(
            segments: current, index: index, playhead: inputs.playhead(), droppedFrames: dropTimes,
            playing: inputs.isPlaying(), throttled: held || inputs.isBusy(), lastEdit: lastEdit, now: inputs.now(),
            idleDelay: idleDelay) else { return }
        start(next, source: source)
    }

    private func start(_ segment: RenderCacheSegment, source: (timeline: Timeline, sequences: [Timeline.ID: Timeline])) {
        // ProRes 422 LT at 1080p30 is about 12 MB/s; the estimate only has to keep the disk floor.
        let estimate = Int64(max(1, Self.secs(segment.range.duration)) * 20_000_000)
        guard store.mayWrite(bytes: estimate) else { return }
        let url = store.fileURL(for: segment.key)
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let render = self.render
        let started = inputs.now()
        // The frames nearest the playhead stay in RAM while they are encoded: the parked frame and the start of a play
        // show from them the moment the segment goes live.
        let local = inputs.playhead() - segment.range.start
        let anchor = local < .zero ? Time.zero : min(local, segment.range.duration)
        let pending = RenderCachePendingFrames(media: RenderCacheMedia.id(forKey: segment.key), anchor: anchor)
        SQLog.info("render cache: rendering \(Self.secs(segment.range.start))s +\(Self.secs(segment.range.duration))s")
        let task = Task.detached(priority: .utility) { [weak self] in
            var failure: Error?
            do { try await render(segment, source.timeline, source.sequences, url, pending) } catch { failure = error }
            let error = failure
            await self?.finish(segment, started: started, error: error, pending: pending)
        }
        job = (segment.key, task)
    }

    private func finish(_ segment: RenderCacheSegment, started: Date, error: Error?, pending: RenderCachePendingFrames) {
        let frames = pending.take()
        guard job?.key == segment.key else {                  // canceled: the writer already removed a partial file
            try? FileManager.default.removeItem(at: store.fileURL(for: segment.key))
            return
        }
        job = nil
        let live = Set(plan().map(\.key))
        guard error == nil, live.contains(segment.key) else {
            if error != nil && !(error is CancellationError) {
                stats.failed += 1
                SQLog.error("render cache: segment failed: \(error!)")
            }
            try? FileManager.default.removeItem(at: store.fileURL(for: segment.key))
            publishStats(spans: stats.spansInUse)
            return
        }
        let before = Set(index.entries.keys)
        do {
            try store.commit(key: segment.key, duration: segment.range.duration, to: &index, protecting: live, now: inputs.now())
        } catch {
            stats.failed += 1
            SQLog.error("render cache: commit failed: \(error)")
            try? FileManager.default.removeItem(at: store.fileURL(for: segment.key))
            return
        }
        for gone in before.subtracting(index.entries.keys) { media.removeRenderCacheFile(media: RenderCacheMedia.id(forKey: gone)) }
        media.setRenderCacheFile(media: RenderCacheMedia.id(forKey: segment.key), url: store.fileURL(for: segment.key))
        stats.rendered += 1
        let took = inputs.now().timeIntervalSince(started)
        publishStats(spans: stats.spansInUse)
        SQLog.info("render cache: segment \(stats.rendered) done in \(String(format: "%.1f", took)) s, cache \(index.entries.count) file(s), \(stats.bytes / 1_000_000) MB")
        if !frames.isEmpty { seedFrames?(frames) }       // before the push: the first tick on the span finds them
        onSpansChanged?()
    }

    private func publishStats(spans: Int) {
        stats.spansInUse = spans
        stats.bytes = index.totalBytes
    }

    private func registerAll() {
        for key in index.entries.keys {
            media.setRenderCacheFile(media: RenderCacheMedia.id(forKey: key), url: store.fileURL(for: key))
        }
    }

    private func unregisterAll() {
        for key in index.entries.keys { media.removeRenderCacheFile(media: RenderCacheMedia.id(forKey: key)) }
    }

    private func cancelJob() { job?.task.cancel(); job = nil }

    /// Tests: waits for the running job to finish.
    func waitForJob() async {
        if let j = job { await j.task.value }
    }

    private static func secs(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
}
