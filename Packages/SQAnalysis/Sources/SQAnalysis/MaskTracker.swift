import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import SQCore
import SQMedia
import Synchronization
import Vision

// Mask tracking (Track Forward / Backward on a mask). Position / +Scale: Vision's object tracker follows the mask's
// bounding box. +Rotation / Perspective: `MaskPointTracker` fits the motion of the points inside the outline from optical
// flow. Frames are read upright and shrunk like the Stabilizer's (size from `WorkLimits`, smaller on 8 GB Macs);
// backward runs read short chunks forward and walk each chunk in reverse, so memory stays small. SQCore turns the
// motions into path keys.

public struct VisionMaskTracker: MaskTracking {
    public let url: URL
    public let maxDimension: Int
    /// Length of one backward read chunk.
    public let chunkSeconds: Double
    /// Below this confidence the object counts as lost (tracking stops there).
    public static let minConfidence: Float = 0.3
    /// The media item's `VideoTrackInfo.deinterlaceFieldOrder`: frames are tracked deinterlaced (nil = as stored).
    public let deinterlace: FieldOrder?

    public init(url: URL, limits: WorkLimits = .current, deinterlace: FieldOrder? = nil) {
        self.init(url: url, maxDimension: limits.maskTrackDimension, chunkSeconds: limits.maskTrackChunkSeconds,
                  deinterlace: deinterlace)
    }

    public init(url: URL, maxDimension: Int, chunkSeconds: Double = 1, deinterlace: FieldOrder? = nil) {
        self.url = url; self.maxDimension = maxDimension; self.chunkSeconds = chunkSeconds; self.deinterlace = deinterlace
    }

    public func track(region: [Vec2], mode: MaskTrackMode, sourceTimes: [Time],
                      progress: (@Sendable (Double) -> Void)?) async throws -> [MaskMotion?] {
        guard let first = sourceTimes.first, let last = sourceTimes.last else { return [] }
        let forward = last >= first
        let lo = sec(min(first, last)), hi = sec(max(first, last))
        let start = MaskTrackBox(bounding: region)
        guard let startRect = Self.visionRect(start) else { return sourceTimes.map { _ in nil } }

        let handler = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: startRect)
        var points = MaskPointTracker(region: region, mode: mode)
        var lost = false
        var results: [(pts: Double, motion: MaskMotion?)] = []
        let expected = max(Double(sourceTimes.count), 1)
        /// The object tracker's box on this frame, as a motion from the start box; nil (and lost) below the confidence.
        func boxStep(_ pb: CVPixelBuffer) -> MaskMotion? {
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            guard (try? handler.perform([request], on: pb, orientation: .up)) != nil,
                  let o = request.results?.first as? VNDetectedObjectObservation, o.confidence >= Self.minConfidence else { return nil }
            observation = o
            return MaskMotion(from: start, to: Self.box(o.boundingBox), scale: mode == .scale)
        }
        /// One frame in tracking order: the first one is the start, every later one asks Vision.
        func step(_ pb: CVPixelBuffer, _ pts: Double) {
            var motion: MaskMotion?
            if mode.usesPoints {
                motion = points.step(pb)
            } else if results.isEmpty {
                motion = .identity
            } else if !lost {
                motion = boxStep(pb)
            }
            if motion == nil { lost = true }
            results.append((pts, motion))
            progress?(min(Double(results.count) / expected, 1))
        }

        let reader = FrameReader(url: url, maxDimension: maxDimension, deinterlace: deinterlace)
        if forward {
            try await reader.forEach(from: lo, to: hi) { pb, pts in step(pb, pts); return !lost }
        } else {
            var end = hi
            var chunkEnd = hi + 1e-3     // frames at or after this were tracked in the previous chunk
            while !lost {
                let a = max(lo, end - chunkSeconds)
                var frames: [(CVPixelBuffer, Double)] = []
                try await reader.forEach(from: a, to: end) { pb, pts in
                    if pts < chunkEnd - 1e-6 { frames.append((pb, pts)) }
                    return true
                }
                // Vision per frame blocks: on the frame lane like the read, not on the cooperative pool.
                try await reader.work {
                    for (pb, pts) in frames.reversed() where !lost {
                        try reader.stop.check()
                        step(pb, pts)
                    }
                }
                guard let earliest = frames.first?.1, a > lo else { break }
                chunkEnd = earliest
                end = a
            }
        }
        try Task.checkCancellation()
        progress?(1)
        return Self.motions(at: sourceTimes.map(sec), from: results.sorted { $0.pts < $1.pts })
    }

    func sec(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }

    /// The motion for each requested instant: the frame shown then (latest pts at or before it, else the earliest frame).
    static func motions(at times: [Double], from frames: [(pts: Double, motion: MaskMotion?)]) -> [MaskMotion?] {
        guard !frames.isEmpty else { return times.map { _ in nil } }
        return times.map { t in
            var lo = 0, hi = frames.count - 1, pick = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if frames[mid].pts <= t + 1e-4 { pick = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return frames[pick].motion
        }
    }

    /// Our box (y down) as Vision's normalized rect (origin bottom left), clipped to the frame; nil when nothing is left.
    static func visionRect(_ b: MaskTrackBox) -> CGRect? {
        let r = CGRect(x: b.center.x - b.size.x / 2, y: 1 - (b.center.y + b.size.y / 2), width: b.size.x, height: b.size.y)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.002, r.height > 0.002 else { return nil }
        return r
    }

    static func box(_ r: CGRect) -> MaskTrackBox {
        MaskTrackBox(center: Vec2(Double(r.midX), 1 - Double(r.midY)), size: Vec2(Double(r.width), Double(r.height)))
    }
}

/// Upright, shrunk BGRA frames of a time range of one file, in pts order. Times are the app's source times (SQMedia's
/// `SampleIndex`: 0 = the first presented frame), not AVAssetReader's: a file whose first frame starts after 0 (no edit
/// list, or an empty edit at the start) would otherwise put picks, tracked mattes and precomputed mattes a few frames off
/// the frame the monitor shows, and find no frame at all at the clip start.
struct FrameReader {
    let url: URL
    let maxDimension: Int
    /// Field order of interlaced media whose frames are handed out deinterlaced (`AnalysisFields`); nil = as stored.
    var deinterlace: FieldOrder?
    /// Shape of the stored pixels: frames are handed out as shown (squeezed pixels made square). Positions in frame
    /// fractions are the same either way.
    var pixelAspect: PixelAspect = .square
    /// Ends this reader's reads from outside (`ReadStop`); bodies running on the lane ask it instead of `Task`.
    let stop = ReadStop()
    /// Seconds without a frame decoded or segmented after which lane work counts as hung (`onLane`).
    var stallAfter: Double = WorkLimits.frameWorkStallSeconds

    /// The blocking reads of tracking, matte precompute and people search run here (`forEach`), never on the cooperative
    /// pool: a few reads that hang there leave no thread for any other task of the app (2026-10-09: "dead in the whole
    /// program" while the UI still drew). Its own lane: a whole Stabilizer analysis must not hold a mask track back.
    static let lane = BlockingLane(label: "sq.lane.frames", width: max(3, ProcessInfo.processInfo.activeProcessorCount / 2),
                                   qos: .userInitiated)

    /// AVAssetReader time of the first presented frame, per file (read once). Only a value that was really read is
    /// kept: a read that failed or was canceled leaves nothing behind (2026-10-09: a wrong value stored here would put
    /// every later request of the app run on the wrong frames).
    private static let origins = Mutex<[URL: Double]>([:])
    /// Tests: runs inside `origin` before the file is read (a request canceled right there).
    @TaskLocal static var onOrigin: (@Sendable () -> Void)?
    /// Tests: runs on the reading thread once a read has started, before its first frame (a decoder that hangs).
    @TaskLocal static var onReader: (@Sendable (AVAssetReader) -> Void)?

    /// The test hooks of the calling task (task locals do not reach the lane's threads).
    struct Hooks: Sendable {
        var onOrigin: (@Sendable () -> Void)?
        var onReader: (@Sendable (AVAssetReader) -> Void)?
        static var current: Hooks { Hooks(onOrigin: FrameReader.onOrigin, onReader: FrameReader.onReader) }
    }

    /// What reading a file needs, loaded once: the asynchronous part. Reading itself (`read`) is synchronous, so a
    /// caller can run it on a thread of its own.
    struct Plan: @unchecked Sendable {
        let url: URL
        let asset: AVURLAsset
        let track: AVAssetTrack
        /// AVAssetReader time (s) at which the first non-empty edit starts.
        let editStart: Double
        /// Media time (s) that edit shows first, nil without an edit list. Compressed samples carry media time.
        let editMedia: Double?
        let orientation: CGImagePropertyOrientation
        /// The size the decoder scales to (long side `maxDimension`), nil = as stored (already small). A 4K frame is
        /// never made as full-size BGRA (as the Stabilizer, `VisionStabilizationAnalyzer.decodeSize`).
        let size: (width: Int, height: Int)?
    }

    /// WebM: read by its own decoder (`forEach`), no `plan` / `read`.
    var isWebM: Bool { WebMFile.isWebM(url) }

    func plan() async throws -> Plan {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StabilizationError.noVideoTrack }
        var edit = 0.0, media: Double?
        if let first = try await track.load(.segments).first(where: { !$0.isEmpty }) {
            let t = first.timeMapping.target.start, s = first.timeMapping.source.start
            if t.isNumeric { edit = max(edit, t.seconds) }
            if s.isNumeric { media = s.seconds }
        }
        let preferred = try await track.load(.preferredTransform)
        let quarter = Int((atan2(Double(preferred.b), Double(preferred.a)) * 2 / .pi).rounded())
        let size = VisionStabilizationAnalyzer.decodeSize(natural: try await track.load(.naturalSize), maxDimension: maxDimension)
        try stop.check()
        return Plan(url: url, asset: asset, track: track, editStart: edit, editMedia: media,
                    orientation: PersonSegmenter.orientation(quarterTurns: quarter), size: size)
    }

    /// AVAssetReader time (s) of source time 0: the later of the first non-empty edit's start and the first decoded
    /// frame's pts (an empty edit at the start yields a filler frame before it). The compressed samples read here carry
    /// media time, the decoded frames presentation time (edit list applied): a camera or ffmpeg B-frame file shows media
    /// from the reorder delay on at 0 (elst media time 1001/30000), so the first pts is mapped through that edit first
    /// (unmapped it was one frame late, every matte drawn a frame early: feedback 2026-10-19, the mask ran ahead). Throws when the file cannot be read or
    /// the read is stopped; nothing is remembered then.
    static func origin(_ plan: Plan, stop: ReadStop = ReadStop(), hooks: Hooks = .current) throws -> Double {
        if let o = origins.withLock({ $0[plan.url] }) { return o }
        hooks.onOrigin?()
        try stop.check()
        var o = plan.editStart
        let reader = try AVAssetReader(asset: plan.asset)
        let out = AVAssetReaderTrackOutput(track: plan.track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw StabilizationError.unreadable }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? StabilizationError.unreadable }
        stop.attach(reader)
        defer { stop.release(reader) }
        // Compressed samples come in decode order: the earliest pts of the first few is the first shown (open-GOP
        // leading frames are decoded after their key frame).
        var firstPTS: Double?, seen = 0
        while seen < 16, let s = stop.copy(out) {
            if stop.isStopped { break }
            guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
            seen += 1
            let p = CMSampleBufferGetPresentationTimeStamp(s)
            if p.isNumeric { firstPTS = min(firstPTS ?? p.seconds, p.seconds) }
        }
        let failure: (any Error)? = reader.status == .failed ? (reader.error ?? StabilizationError.unreadable) : nil
        stop.release(reader)
        try stop.check()
        if let failure { throw failure }
        if let firstPTS { o = max(o, plan.editMedia.map { plan.editStart + firstPTS - $0 } ?? firstPTS) }
        origins.withLock { $0[plan.url] = o }
        return o
    }

    private static func context() -> CIContext { CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]) }

    /// The frame as analysis reads it: deinterlaced, upright, long side at most `maxDimension`.
    private func small(_ pb: CVPixelBuffer, _ o: CGImagePropertyOrientation, fields: FieldOrder?, context: CIContext) -> CVPixelBuffer? {
        VisionStabilizationAnalyzer.shrink(AnalysisFields.progressive(pb, fields), orientation: o, maxDimension: maxDimension,
                                           pixelAspect: pixelAspect, context: context)
    }

    /// Calls `body` per frame with pts in [from, to] (seconds); `body` returns false to stop. `body` runs on the frame
    /// lane's thread while the caller waits (never both at once): the read and the Vision work in it block, and must
    /// not hold a thread of the cooperative pool. There `Task.isCancelled` says nothing: `body` asks `stop.check()`.
    /// Canceling the calling task ends a read that hangs in the decoder (`ReadStop`). `urgent`: one frame the user
    /// waits for goes ahead of waiting long reads.
    func forEach(from: Double, to: Double, urgent: Bool = false,
                 _ body: @escaping (CVPixelBuffer, Double) throws -> Bool) async throws {
        if WebMFile.isWebM(url) {
            nonisolated(unsafe) let context = Self.context()
            let start = CMTime(seconds: from, preferredTimescale: 600_000)
            let duration = CMTime(seconds: max(to - from, 0) + 1e-3, preferredTimescale: 600_000)
            let range = TimeRange(start: Time(start.value, Int64(start.timescale)), duration: Time(duration.value, Int64(duration.timescale)))
            var go = true
            let me = self
            nonisolated(unsafe) let body = body
            try await WebMReadback.forEachFrame(url: url, range: range) { frame in
                guard go else { return }
                try stop.check()
                let pts = Double(frame.pts.value) / Double(max(frame.pts.timescale, 1))
                guard pts <= to + 1e-4, pts >= from - 1e-4 else { return }
                // The WebM decoder hands out its own frames (no shift, no fields) from its own path; shrinking and
                // `body` (Vision) block, so each frame's share runs on the lane.
                nonisolated(unsafe) let pb = frame.pixelBuffer
                go = try await onLane(urgent: urgent) {
                    guard let small = me.small(pb, .up, fields: nil, context: context) else { return true }
                    return try body(small, pts)
                }
            }
            return
        }
        let plan = try await plan()
        let hooks = Hooks.current
        let me = self
        // The caller waits until the lane's thread is done with `body`: one user at a time.
        nonisolated(unsafe) let body = body
        try await onLane(urgent: urgent) { try me.read(plan, from: from, to: to, hooks: hooks, body) }
    }

    /// Blocking work on frames already read (Vision on the frames of a backward chunk, on the last frame of a forward
    /// run), on the frame lane's thread while the caller waits: never on the cooperative pool. `body` asks
    /// `stop.check()` per frame (its cancellation and its sign of life). `urgent`: one frame the user waits for.
    func work<T: Sendable>(urgent: Bool = false, _ body: @escaping () throws -> T) async throws -> T {
        nonisolated(unsafe) let body = body
        return try await onLane(urgent: urgent) { try body() }
    }

    /// `body` on the lane. Canceling the caller stops the reader. Work without a `stop.check()` for `stallAfter` seconds
    /// (a decoder or Vision call that never returns) is given up: the caller gets `BlockingLane.Stalled`, the lane's
    /// slot is free again, the reader is stopped (the thread, should it ever come back, writes nothing more).
    private func onLane<T: Sendable>(urgent: Bool, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let stop = stop, limit = stallAfter, name = url.lastPathComponent
        return try await withTaskCancellationHandler {
            try await BlockingLane.$urgent.withValue(urgent) {
                do {
                    return try await Self.lane.run(stallAfter: limit) { _, beat in
                        stop.watch(beat)
                        return try body()
                    }
                } catch let stalled as BlockingLane.Stalled {
                    stop.stop()
                    NSLog("[Frames] %@: no frame decoded or segmented for %.0f s, the call is given up (its thread stays with it)", name, limit)
                    throw stalled
                }
            }
        } onCancel: { stop.stop() }
    }

    /// How far back the frame shown at a time is looked for, in seconds, one after the other: a quarter second covers
    /// ordinary footage; a frame held longer (variable frame rate, a screen recording, a timelapse) is found by the
    /// wider reads, which only run when the narrower one found nothing.
    static let shownReach: [Double] = [0.25, 1, 4, 16]
    /// A frame counts as shown at `t` when its pts is at most this far after it (rounding of the playhead's time only:
    /// the monitor shows the frame with pts <= t < next pts, `SampleIndex.frame(at:)`).
    static let shownSlack = 1e-5

    /// The frame the monitor shows at `seconds` (the latest with pts <= seconds), shrunk, with its pts; nil when the
    /// file has none within `shownReach`. Read on the frame lane, ahead of waiting long reads.
    func shownFrame(at seconds: Double) async throws -> (CVPixelBuffer, Double)? {
        if isWebM { return try await shownWebM(at: seconds) }
        let plan = try await plan()
        let hooks = Hooks.current
        let me = self
        struct Frame: @unchecked Sendable { let pb: CVPixelBuffer; let pts: Double }
        let f: Frame? = try await onLane(urgent: true) {
            try me.shown(plan, at: seconds, hooks: hooks).map { Frame(pb: $0.0, pts: $0.1) }
        }
        return f.map { ($0.pb, $0.pts) }
    }

    /// `shownFrame` of a WebM file (its decoder's own path).
    func shownWebM(at seconds: Double) async throws -> (CVPixelBuffer, Double)? {
        for reach in Self.shownReach {
            let from = max(seconds - reach, 0)
            var held: (CVPixelBuffer, Double)?
            try await forEach(from: from, to: seconds) { pb, pts in
                if pts <= seconds + Self.shownSlack { held = (pb, pts) }
                return true
            }
            if held != nil || from == 0 { return held }
        }
        return nil
    }

    /// The synchronous part of `shownFrame` for a file AVFoundation reads. AVAssetReader hands out the frame that is on
    /// screen at the start of its time range with the range's start as pts, not its own: a frame found only there
    /// started earlier, so the read is made again from further back until the frame's real pts is inside the range.
    func shown(_ plan: Plan, at seconds: Double, hooks: Hooks = .current) throws -> (CVPixelBuffer, Double)? {
        for reach in Self.shownReach {
            let from = max(seconds - reach, 0)
            if let f = try last(plan, from: from, to: seconds, hooks: hooks), from == 0 || f.1 > from + 2e-4 { return f }
            if from == 0 { return nil }
        }
        return nil
    }

    /// The synchronous part of `forEach` for a file AVFoundation reads (not WebM): blocks its thread while frames decode.
    func read(_ plan: Plan, from: Double, to: Double, hooks: Hooks = .current, _ body: (CVPixelBuffer, Double) throws -> Bool) throws {
        let context = Self.context()
        try scan(plan, from: from, to: to, hooks: hooks) { pb, pts in
            guard let small = small(pb, plan.orientation, fields: deinterlace, context: context) else { return true }
            return try body(small, pts)
        }
    }

    /// The latest frame with pts in [from, to] (never one after `to`: the read itself lets frames a tenth of a
    /// millisecond late through). Only the frame that is used is shrunk (a hover reads a quarter second of frames to find
    /// the one shown).
    func last(_ plan: Plan, from: Double, to: Double, hooks: Hooks = .current) throws -> (CVPixelBuffer, Double)? {
        var held: (CVPixelBuffer, Double)?
        try scan(plan, from: from, to: to, hooks: hooks) { pb, pts in
            if pts <= to + Self.shownSlack, pts >= (held?.1 ?? -.infinity) { held = (pb, pts) }
            return true
        }
        guard let (pb, pts) = held, let small = small(pb, plan.orientation, fields: deinterlace, context: Self.context()) else { return nil }
        return (small, pts)
    }

    /// The frame whose pts is nearest to `seconds` among those at most `window` away from it (the earlier of two equally
    /// near), shrunk, with its pts; nil when there is none. The read ends at the first frame further away than the one
    /// before it; only the frame that is used is deinterlaced and shrunk.
    func nearest(_ plan: Plan, to seconds: Double, within window: Double, hooks: Hooks = .current) throws -> (CVPixelBuffer, Double)? {
        var held: (CVPixelBuffer, Double)?
        try scan(plan, from: max(seconds - window, 0), to: seconds + window, hooks: hooks) { pb, pts in
            if let h = held, abs(h.1 - seconds) <= abs(pts - seconds) + 1e-6 { return pts <= seconds }
            held = (pb, pts)
            return true
        }
        guard let (pb, pts) = held, let small = small(pb, plan.orientation, fields: deinterlace, context: Self.context()) else { return nil }
        return (small, pts)
    }

    /// The decoded frames with source time in [from, to], as the decoder made them (scaled to `plan.size`, not upright).
    private func scan(_ plan: Plan, from: Double, to: Double, hooks: Hooks, _ body: (CVPixelBuffer, Double) throws -> Bool) throws {
        let shift = try Self.origin(plan, stop: stop, hooks: hooks)
        let start = CMTime(seconds: from + shift, preferredTimescale: 600_000)
        let duration = CMTime(seconds: max(to - from, 0) + 1e-3, preferredTimescale: 600_000)
        let (reader, output) = try AnalysisFields.start(asset: plan.asset, track: plan.track, order: deinterlace, size: plan.size,
                                                        timeRange: CMTimeRange(start: start, duration: duration))
        stop.attach(reader)
        defer { stop.release(reader) }
        hooks.onReader?(reader)
        while let sample = stop.copy(output) {
            try stop.check()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let raw = CMSampleBufferGetPresentationTimeStamp(sample)
            guard raw.isNumeric else { continue }
            let pts = raw.seconds - shift
            guard pts <= to + 1e-4, pts >= from - 1e-4 else { continue }
            if try !body(pb, pts) { return }
        }
        try stop.check()
        if reader.status == .failed { throw reader.error ?? StabilizationError.unreadable }
    }
}

/// Ends a file read from outside its thread. A read that hangs inside `copyNextSampleBuffer` never reaches a
/// cancellation check of its own (2026-10-09): the one who gives it up (a canceled task, the mask tool's deadline, Stop)
/// cancels the reader itself, which makes the blocked call return. Also the cancellation flag of work that runs on a
/// lane thread, where `Task.isCancelled` says nothing.
final class ReadStop: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var stopped = false
    private var beat: (@Sendable () -> Void)?

    var isStopped: Bool { lock.withLock { stopped } }
    /// Throws when the read was stopped or the current task (if any) is canceled. Also the work's sign of life: the
    /// lane's stall deadline starts over (`watch`).
    func check() throws {
        let (gone, beat) = lock.withLock { (stopped, self.beat) }
        if gone || Task.isCancelled { throw CancellationError() }
        beat?()
    }
    /// The stall deadline of the lane job this read now runs in.
    func watch(_ beat: @escaping @Sendable () -> Void) { lock.withLock { self.beat = beat } }

    private var copying = false
    /// Test seam: runs inside the copy window (after `copying` is set, before the decoder is asked).
    var duringCopy: (@Sendable () -> Void)?

    /// The reader now reading; one that starts after the stop is canceled at once.
    func attach(_ r: AVAssetReader) {
        let late = lock.withLock { reader = r; return stopped }
        if late { cancel(r) }
    }
    func detach() { lock.withLock { reader = nil } }
    /// The owner is done: detaches and cancels under the same lock a stop cancels under, so two `cancelReading` calls
    /// (owner and stopper) never run on one reader at once.
    func release(_ r: AVAssetReader) {
        lock.withLock {
            reader = nil
            if r.status == .reading { r.cancelReading() }
        }
    }

    /// `copyNextSampleBuffer` of the attached reader. `cancelReading` while a copy runs on another thread crashes inside
    /// MediaToolbox (EXC_BAD_ACCESS, 2026-10-17 and again 2026-10-18 under a loaded full run, where a copy simply took
    /// more than the old 2 s grace and the stopper canceled under it). So a stop never cancels during a copy, however
    /// long it takes: the copy returns first and the read ends at its next check.
    /// shortcut: a copy that never returns keeps its thread and reader; `BlockingLane.Stalled` frees the lane slot. Upgrade
    /// when a real decoder hang is seen (cancel only after proving the hang, never by timer alone).
    func copy(_ output: AVAssetReaderOutput) -> CMSampleBuffer? {
        let go = lock.withLock { () -> Bool in
            if stopped { return false }
            copying = true
            return true
        }
        if !go { return nil }
        defer { lock.withLock { copying = false } }
        duringCopy?()
        return output.copyNextSampleBuffer()
    }

    /// Cancels under the lock, so it never runs between the start of a copy and the copy itself.
    private func cancel(_ r: AVAssetReader) {
        lock.withLock { if !copying, r.status == .reading { r.cancelReading() } }
    }

    func stop() {
        let r = lock.withLock { stopped = true; return reader }
        if let r { cancel(r) }
    }
}

/// One thread for the subject mask tool's frame of the moment (file read and Vision request, both blocking calls): a
/// call that hangs holds this thread, never one of the cooperative pool's, and later requests wait in line behind it.
actor SubjectFrameWorker {
    private static let current = Mutex(SubjectFrameWorker())
    static var shared: SubjectFrameWorker { current.withLock { $0 } }
    /// Goes on with a fresh thread (a click after a request that never came back): the old one stays with its call.
    static func replace() { current.withLock { $0 = SubjectFrameWorker() } }
    static let label = "sq.subject.frame"
    private let queue = DispatchSerialQueue(label: SubjectFrameWorker.label, qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func run<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T { try work() }
}
