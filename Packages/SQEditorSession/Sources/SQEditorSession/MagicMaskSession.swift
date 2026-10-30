import Accelerate
import AppKit
import SQAnalysis
import SQCore
import SQUIKit
import Synchronization

/// Magic mode on the Program monitor: segments the shown source frame (in the background), then hover is a label lookup
/// (the object under the pointer) and a click's pick is stored at once (`MagicMatteStore`) so the picture shows it before
/// any Track. Never runs during playback: the host prepares only for a parked playhead. Every new frame (seek, scrub, step)
/// is segmented again; a newer frame cancels the stale request.
///
/// Nothing a request leaves behind can switch the session off (2026-10-09, "works once, then never again"):
/// - a frame that really shows nothing is remembered, so the host does not run it on every redraw; a click runs it again;
/// - a request that threw is logged with its error and not remembered as "nothing here": the next hover (after
///   `retryDelay`) or click runs it again;
/// - a request that does not come back within `timeout` is given up, so the next one can start; its late result is
///   ignored. Only a click runs that frame again (never hover or a redraw: a call that hangs would be started again
///   every few seconds), and the click moves the frame work on to a fresh thread (`onRestart`);
/// - soft mattes for the hover highlight and for a pick are made off the main thread on one queue with the same
///   deadline (`DeadlineQueue`): the main thread never waits for Vision.
@MainActor
public final class MagicMaskSession {
    /// Segments the frame at source seconds of a file: the objects and that frame's pts.
    public typealias Segment = @Sendable (URL, Double) async throws -> (InstanceFrame, Double)?

    /// Why the last request for a frame gave no objects although the frame may have some.
    public enum Problem: Equatable, Sendable {
        /// The read or the segmentation threw (the error's text).
        case failed(String)
        /// No answer within the deadline (seconds).
        case timedOut(Double)
    }

    private enum Outcome: Sendable {
        case ready(InstanceFrame, Double)
        case empty
        case failed(String)
        case timedOut
    }

    private struct Pending {
        var media: UUID
        var sourceTime: Time
        var id: Int
        var work: Task<Void, Never>
        var watchdog: Task<Void, Never>
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// The same with the shape of the file's stored pixels and the field order its frames are deinterlaced with.
    public typealias ShapedSegment = @Sendable (URL, Double, PixelAspect, FieldOrder?) async throws -> (InstanceFrame, Double)?

    private let segment: ShapedSegment
    /// Shape of a file's stored pixels (`VideoTrackInfo.displayPixelAspect`), set by the host: hover and a pick see the
    /// frame as it is shown, like Track does (`MagicMaskTracker.pixelAspect`), so the pick's matte and the tracked
    /// ones have one shape. A point is a fraction of the upright shown picture (origin top left), whatever the file's
    /// rotation or pixel shape.
    public var pixelAspect: (URL) -> PixelAspect = { _ in .square }
    /// Field order a file's frames are deinterlaced with (`VideoTrackInfo.deinterlaceFieldOrder`: nil for progressive
    /// media and an item with Deinterlace off), set by the host: hover and a pick see the frames the monitor shows.
    public var deinterlace: (URL) -> FieldOrder? = { _ in nil }
    private let timeout: Double
    private let retryDelay: Double
    private var shown: (media: UUID, sourceTime: Time, frame: InstanceFrame, pts: Double)?
    private var pending: Pending?
    /// The frame that was segmented and shows no object.
    private var empty: (media: UUID, sourceTime: Time)?
    private var problem: (media: UUID, sourceTime: Time, what: Problem, at: ContinuousClock.Instant)?
    private var nextID = 0
    private var hoverCache: [UInt8: SubjectMatte] = [:]
    /// Soft mattes: one at a time off the main thread; only the label asked for last is computed (`softWanted`).
    private let softQueue = DeadlineQueue(label: "sq.magic.soft")
    /// Called when a click runs a frame again whose request timed out: the frame work moves to a fresh thread.
    private let onRestart: @Sendable () -> Void
    private let softWanted = Counter()
    /// Moves on with every new frame and reset: a soft matte of an older frame is not kept.
    private var frameGeneration = 0

    private final class Counter: Sendable {
        private let value = Mutex(0)
        var current: Int { value.withLock { $0 } }
        func next() -> Int { value.withLock { $0 += 1; return $0 } }
    }

    /// `timeout`: seconds one request may take (`WorkLimits.subjectFrameDeadline`). `retryDelay`: seconds before a frame
    /// whose request threw is run again without a click (one that timed out: only by a click).
    public init(timeout: Double = WorkLimits.subjectFrameDeadline, retryDelay: Double = 1,
                segment: Segment? = nil, shaped: ShapedSegment? = nil,
                onRestart: @escaping @Sendable () -> Void = { MagicMaskTracker.abandonStuckFrameWork() }) {
        if let shaped {
            self.segment = shaped
        } else if let segment {
            self.segment = { @Sendable url, s, _, _ in try await segment(url, s) }
        } else {
            self.segment = { @Sendable url, s, aspect, fields in
                try await MagicMaskTracker(url: url, pixelAspect: aspect, deinterlace: fields).segment(at: s)
                    .map { ($0.frame, $0.pts) }
            }
        }
        self.onRestart = onRestart
        self.timeout = timeout
        self.retryDelay = retryDelay
    }

    /// True when the objects of this frame are known (hover and picks work).
    public func isReady(media: UUID, sourceTime: Time) -> Bool {
        shown.map { $0.media == media && $0.sourceTime == sourceTime } ?? false
    }

    /// True when this frame was segmented and shows no object: `prepare` does not run it again without `retry`.
    /// A request that threw or timed out is not this (`problem`).
    public func hasFailed(media: UUID, sourceTime: Time) -> Bool {
        empty.map { $0.media == media && $0.sourceTime == sourceTime } ?? false
    }

    /// Why the last request for this frame gave nothing although it may show objects (read error, timeout); nil otherwise.
    public func problem(media: UUID, sourceTime: Time) -> Problem? {
        problem.flatMap { $0.media == media && $0.sourceTime == sourceTime ? $0.what : nil }
    }

    /// True while this frame's request runs.
    public func isPending(media: UUID, sourceTime: Time) -> Bool {
        pending.map { $0.media == media && $0.sourceTime == sourceTime } ?? false
    }

    /// True when `prepare` (without `retry`) would start a request for this frame now: not ready, not on its way, not
    /// known to be empty, not failed within the last `retryDelay` seconds and not timed out.
    public func wantsPrepare(media: UUID, sourceTime: Time) -> Bool {
        if isReady(media: media, sourceTime: sourceTime) || isPending(media: media, sourceTime: sourceTime) { return false }
        if hasFailed(media: media, sourceTime: sourceTime) { return false }
        return !waitsForAClick(media: media, sourceTime: sourceTime)
    }

    /// A frame whose request timed out (until a click), or threw within the last `retryDelay` seconds.
    private func waitsForAClick(media: UUID, sourceTime: Time) -> Bool {
        guard let p = problem, p.media == media, p.sourceTime == sourceTime else { return false }
        if case .timedOut = p.what { return true }
        return ContinuousClock.now - p.at < .seconds(retryDelay)
    }

    /// Segments the frame at `sourceTime` unless it is already known, known to be empty or on its way (then waits for
    /// that request, also when this caller's own request for the frame was replaced meanwhile: F, G, F again). A newer
    /// frame cancels the older request. `retry` (a click) runs a frame again that gave nothing or failed before: nothing
    /// one request did switches a frame off for the rest of the app run. Returns whether the frame is ready afterwards.
    @discardableResult
    public func prepare(media: UUID, url: URL, sourceTime: Time, retry: Bool = false) async -> Bool {
        var started = false, joined = false
        while true {
            if isReady(media: media, sourceTime: sourceTime) { return true }
            if isPending(media: media, sourceTime: sourceTime) {
                await withCheckedContinuation { pending?.waiters.append($0) }
                joined = true
                continue
            }
            // A caller that joined a request which threw or timed out reports that failure; it does not start the retry
            // itself (with a short `retryDelay` the waiters would race: the one that retried first would leave the others
            // waiting for the retry, and nobody would tell the failure).
            if joined, !started, !retry, problem(media: media, sourceTime: sourceTime) != nil { return false }
            // This call's own request ended without a frame (empty, failed, timed out, replaced by another frame).
            if started { return false }
            if hasFailed(media: media, sourceTime: sourceTime) {
                guard retry else { return false }
                empty = nil
            }
            if !retry, waitsForAClick(media: media, sourceTime: sourceTime) { return false }
            if retry, case .timedOut? = problem(media: media, sourceTime: sourceTime) { onRestart() }
            start(media: media, url: url, sourceTime: sourceTime)
            started = true
        }
    }

    private func start(media: UUID, url: URL, sourceTime: Time) {
        if let old = pending {
            NSLog("[Magic] request %d replaced by a newer frame", old.id)
            drop(old)
        }
        nextID += 1
        let id = nextID
        let s = Double(sourceTime.value) / Double(max(sourceTime.timescale, 1))
        let run = segment
        let aspect = pixelAspect(url), fields = deinterlace(url)
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Outcome
            do {
                if let r = try await run(url, s, aspect, fields) { outcome = .ready(r.0, r.1) } else { outcome = .empty }
            } catch {
                outcome = .failed(Self.describe(error))
            }
            await self?.finish(id, seconds: s, outcome)
        }
        let limit = timeout
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            self?.finish(id, seconds: s, .timedOut)
        }
        pending = Pending(media: media, sourceTime: sourceTime, id: id, work: work, watchdog: watchdog)
    }

    /// Ends a request that is no longer wanted: its work is canceled, its callers go on (and find the state as it is).
    private func drop(_ p: Pending) {
        pending = nil
        p.work.cancel()
        p.watchdog.cancel()
        for w in p.waiters { w.resume() }
    }

    /// Applies the result of request `id` once. A result of a request that was replaced, reset or given up is ignored.
    private func finish(_ id: Int, seconds s: Double, _ outcome: Outcome) {
        guard let p = pending, p.id == id else {
            switch outcome {
            case .ready, .empty: NSLog("[Magic] late result of request %d ignored (frame %.3f s)", id, s)
            case .failed, .timedOut: break      // a canceled request ends by throwing
            }
            return
        }
        hoverCache = [:]
        frameGeneration += 1
        _ = softWanted.next()
        switch outcome {
        case .ready(let frame, let pts):
            shown = (p.media, p.sourceTime, frame, pts)
            empty = nil; problem = nil
            NSLog("[Magic] ready: frame %.3f s (pts %.3f, %d objects)", s, pts, Set(frame.labels.labels).subtracting([0]).count)
        case .empty:
            shown = nil; problem = nil
            empty = (p.media, p.sourceTime)
            NSLog("[Magic] frame %.3f s: nothing segmented", s)
        case .failed(let why):
            shown = nil; empty = nil
            problem = (p.media, p.sourceTime, .failed(why), .now)
            NSLog("[Magic] segment failed: %@ (frame %.3f s)", why, s)
        case .timedOut:
            shown = nil; empty = nil
            problem = (p.media, p.sourceTime, .timedOut(timeout), .now)
            NSLog("[Magic] timeout: frame %.3f s gave no answer in %.1f s, request %d given up", s, timeout, id)
        }
        drop(p)
    }

    /// Type, domain, code and text of an error (log and status line).
    nonisolated static func describe(_ error: any Error) -> String {
        if error is CancellationError { return "canceled" }
        let e = error as NSError
        return "\(type(of: error)) \(e.domain) \(e.code): \(SQL10n.errorText(error))"
    }

    /// Forgets the shown frame (other clip, playback started) and stops a running request.
    public func reset() {
        if let p = pending { drop(p) }
        shown = nil; empty = nil; problem = nil; hoverCache = [:]
        frameGeneration += 1
        _ = softWanted.next()
    }

    /// The object under frame fraction `p` of the prepared frame: its label and matte; nil over the background. Never
    /// runs the segmenter: `matte` is the soft matte when it was made before (`soft`), else the hard labels; `softMatte`
    /// makes the soft one off the main thread.
    public func hover(at p: Vec2) -> (label: UInt8, matte: SubjectMatte, soft: Bool)? {
        guard let f = shown?.frame else { return nil }
        let l = f.labels.label(at: p)
        guard l != 0 else { return nil }
        if let m = hoverCache[l] { return (l, m, true) }
        return (l, f.labels.matte(of: [l]), false)
    }

    /// The soft matte of object `label` of the prepared frame, made off the main thread. nil when the frame changed or
    /// another label was asked for meanwhile (latest wins: a stale request is skipped before it runs).
    public func softMatte(_ label: UInt8) async -> SubjectMatte? {
        guard let s = shown, label != 0 else { return nil }
        if let m = hoverCache[label] { return m }
        let token = softWanted.next()
        let generation = frameGeneration
        let frame = s.frame
        let wanted = softWanted
        // A highlight never moves a stuck queue on (no `restart`): hover shows the hard labels then.
        let m: SubjectMatte? = await softQueue.run(deadline: timeout) {
            wanted.current == token ? frame.soft([label]) : nil
        }
        guard let m, generation == frameGeneration else { return nil }      // a new frame or a reset meanwhile
        hoverCache[label] = m
        return m
    }

    /// The prepared frame's pts (seconds): where its matte is stored.
    public var shownPTS: Double? { shown?.pts }

    /// How a pick ended.
    public enum PickResult: Equatable, Sendable {
        /// The matte is stored.
        case stored
        /// The points leave nothing (blank matte): nothing was stored.
        case nothing
        /// Nothing to work on: no frame is prepared, the points belong to another frame, or the frame changed meanwhile.
        case refused
        /// The matte was not made within the deadline (seconds): nothing was stored.
        case gaveUp(Double)
    }

    private enum PickAnswer: Sendable {
        case matte(SubjectMatte)
        case nothing
    }

    /// Stores the matte of `points` on the prepared frame under `key` (the mask's cache key). On the pick's own frame the
    /// points pick; on another frame `start` (the tracked matte there before the correction) is corrected by the points
    /// made on it. The matte is made off the main thread (soft mattes are Vision calls) within `timeout`, and stored
    /// when it arrives.
    public func pick(points: [MagicPoint], key: String, start: SubjectMatte? = nil, store: MagicMatteStore = .shared) async -> PickResult {
        guard let s = shown, let anchor = points.first?.sourceTime, anchor == s.sourceTime || start != nil else {
            NSLog("[Magic] pick refused: %@", shown == nil ? "no frame is prepared" : "the points belong to another frame")
            return .refused
        }
        // Points are stored at the playhead's source time; the decoded frame lies at or up to one file frame before it.
        let here = Double(s.sourceTime.value) / Double(max(s.sourceTime.timescale, 1))
        let frame = s.frame, pts = s.pts
        let from = anchor == s.sourceTime ? nil : start
        let span = max(here - pts, 0) + 2 * MagicFollower.pointTolerance
        let generation = frameGeneration
        // A click moves a stuck queue on (`restart`).
        let answer: PickAnswer? = await softQueue.run(deadline: timeout, restart: true) {
            MagicMaskTracker.pickMatte(frame, pts: pts, points: points, start: from, span: span).map { .matte($0) } ?? .nothing
        }
        guard let answer else {
            NSLog("[Magic] pick at pts %.3f given up: no matte within %.1f s", pts, timeout)
            return .gaveUp(timeout)
        }
        guard generation == frameGeneration else {
            NSLog("[Magic] pick at pts %.3f dropped: the frame changed meanwhile", pts)
            return .refused
        }
        switch answer {
        case .matte(let m):
            store.put(m, key: key, pts: pts)
            // Queued behind the other saves: the pick answers on the main thread, the write is the whole matte list.
            store.saveLater(key: key)
            NSLog("[Magic] pick at pts %.3f: stored", pts)
            return .stored
        case .nothing:
            NSLog("[Magic] pick at pts %.3f: nothing found", pts)
            return .nothing
        }
    }
}

/// Draws a matte as a tinted see-through image (Magic hover / pick highlight on the monitor).
public enum MagicHighlight {
    /// Accent-colored image, alpha = matte * `alpha` (premultiplied RGBA, row 0 at the top).
    public static func image(_ m: SubjectMatte, color: NSColor = Theme.Colors.accent, alpha: CGFloat = 0.45) -> CGImage? {
        let c = color.usingColorSpace(.sRGB) ?? .white
        let n = m.width * m.height
        // Accelerate, not a per-pixel Swift loop: that one took ~390 ms for a full-HD matte in Debug, per scrubbed frame.
        // a = clamp(matte, 0, 1) * alpha * 255; each color plane = tint * a (premultiplied); planes interleave to RGBA.
        var a = [Float](repeating: 0, count: n)
        var lo: Float = 0, hi: Float = 1, k = Float(alpha) * 255
        m.values.withUnsafeBufferPointer { src in
            vDSP_vclip(src.baseAddress!, 1, &lo, &hi, &a, 1, vDSP_Length(n))
        }
        vDSP_vsmul(a, 1, &k, &a, 1, vDSP_Length(n))
        var pr = [UInt8](repeating: 0, count: n), pg = pr, pb = pr, pa = pr
        var tmp = [Float](repeating: 0, count: n)
        let tint: [Float] = [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
        for ch in 0..<4 {
            var s: Float = ch == 3 ? 1 : tint[ch]
            vDSP_vsmul(a, 1, &s, &tmp, 1, vDSP_Length(n))
            switch ch {
            case 0: vDSP_vfixu8(tmp, 1, &pr, 1, vDSP_Length(n))
            case 1: vDSP_vfixu8(tmp, 1, &pg, 1, vDSP_Length(n))
            case 2: vDSP_vfixu8(tmp, 1, &pb, 1, vDSP_Length(n))
            default: vDSP_vfixu8(tmp, 1, &pa, 1, vDSP_Length(n))
            }      // truncates like the old UInt8() conversion
        }
        var px = [UInt8](repeating: 0, count: n * 4)
        pr.withUnsafeMutableBytes { r in pg.withUnsafeMutableBytes { g in
            pb.withUnsafeMutableBytes { b in pa.withUnsafeMutableBytes { al in
                px.withUnsafeMutableBytes { out in
                    func buf(_ p: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                        vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(m.height), width: vImagePixelCount(m.width), rowBytes: m.width)
                    }
                    var rb = buf(r), gb = buf(g), bb = buf(b), ab = buf(al)
                    var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(m.height), width: vImagePixelCount(m.width), rowBytes: m.width * 4)
                    // ARGB8888 order of the call = first buffer first in memory: R, G, B, A.
                    vImageConvert_Planar8toARGB8888(&rb, &gb, &bb, &ab, &dst, vImage_Flags(kvImageNoFlags))
                }
            } }
        } }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: m.width, height: m.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: m.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
