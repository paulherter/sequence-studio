import CoreVideo
import Foundation
import SQCore
import Synchronization

/// Person mattes for the Program monitor without ever running Vision on the caller's thread (W9.8 review #3).
///
/// `matte(for:...)` returns at once: the smoothed matte of that frame when it was already made (`exact`), otherwise the
/// last good matte of the same clip and source while the frame is segmented on the scheduler's own serial queue (newest
/// request per clip wins; older pending frames of that clip are dropped). `onReady` fires after each requested frame lands
/// so the render loop redraws. One tracker per quality: fast while playing or scrubbing, balanced for a settled frame.
/// State is keyed by clip and decoded source (original or proxy, #7) and released by `retain(clips:)` and `forget(sources:)`.
public final class SubjectMatteScheduler: Sendable {
    public struct Key: Hashable, Sendable {
        public var clip: UUID
        /// The media actually decoded: the original or its proxy (their frames differ, so their mattes never mix).
        public var source: UUID
        public init(clip: UUID, source: UUID) { self.clip = clip; self.source = source }

        /// The tracker's key: clip and source folded into one id (export keys its own tracker the same way).
        public var trackerKey: UUID {
            var a = clip.uuid, b = source.uuid
            withUnsafeMutableBytes(of: &a) { pa in withUnsafeBytes(of: &b) { pb in for i in 0..<16 { pa[i] ^= pb[i] &+ UInt8(i) } } }
            return UUID(uuid: a)
        }
    }

    public struct Result: Sendable {
        public var matte: SubjectMatte?
        /// The matte belongs to the requested frame (false: a stand-in from an earlier frame, or nil while none exists).
        public var exact: Bool
    }

    private struct Job: @unchecked Sendable {
        let key: Key
        let frame: CVPixelBuffer
        let rotation: Int
        let frameIndex: Int
        let quality: PersonSegmenter.Quality
        /// A look-ahead frame (playing): its result is cached, but it is not the frame shown, so no redraw and no stand-in.
        let ahead: Bool
    }

    private struct State {
        var pending: [Key: [Job]] = [:]
        var order: [Key] = []
        var running = false
        var known: Set<Key> = []
        var latest: [Key: SubjectMatte] = [:]
        var timings: [Double] = []
        var segmentations = 0
        /// Frames Vision gave no mask for (error): answered as exact with no matte, so a settled frame is not retried forever.
        var failed: Set<Failed> = []
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct Failed: Hashable { let key: Key; let frame: Int; let fast: Bool }

    private let fast: SubjectMatteTracker
    private let balanced: SubjectMatteTracker
    private let state = Mutex(State())
    private let onReadyBox = CallbackSlot()
    private let queue = DispatchQueue(label: "sq.subject-matte", qos: .userInitiated)

    public init(capacity: Int = 8) {
        fast = SubjectMatteTracker(capacity: capacity)
        balanced = SubjectMatteTracker(capacity: capacity)
    }

    /// Called on the scheduler's queue after a shown frame's matte landed.
    public func setOnReady(_ f: (@Sendable () -> Void)?) { onReadyBox.set(f) }

    private func tracker(_ q: PersonSegmenter.Quality) -> SubjectMatteTracker { q == .fast ? fast : balanced }

    /// The matte to draw now for `frameIndex` of `key`; never blocks on Vision. `ahead` frames (decoded, about to be shown)
    /// are segmented after it so playback finds them ready.
    public func matte(for frame: CVPixelBuffer, rotationDegrees: Int, key: Key, frameIndex: Int,
                      quality: PersonSegmenter.Quality, ahead: [(CVPixelBuffer, Int)] = []) -> Result {
        let t = tracker(quality)
        let tk = key.trackerKey
        let later = ahead.filter { t.cached(key: tk, frameIndex: $0.1) == nil }
            .map { Job(key: key, frame: $0.0, rotation: rotationDegrees, frameIndex: $0.1, quality: quality, ahead: true) }
        if let m = t.cached(key: tk, frameIndex: frameIndex) {
            state.withLock { $0.latest[key] = m }
            if !later.isEmpty { enqueue(key, later) }
            return Result(matte: m, exact: true)
        }
        if state.withLock({ $0.failed.contains(Failed(key: key, frame: frameIndex, fast: quality == .fast)) }) {
            return Result(matte: nil, exact: true)
        }
        enqueue(key, [Job(key: key, frame: frame, rotation: rotationDegrees, frameIndex: frameIndex, quality: quality, ahead: false)] + later)
        return Result(matte: state.withLock { $0.latest[key] }, exact: false)
    }

    /// The smoothed matte of a frame if it was made at `quality` (tests, HUD).
    public func cached(key: Key, frameIndex: Int, quality: PersonSegmenter.Quality) -> SubjectMatte? {
        tracker(quality).cached(key: key.trackerKey, frameIndex: frameIndex)
    }

    private func enqueue(_ key: Key, _ jobs: [Job]) {
        let start = state.withLock { s -> Bool in
            s.known.insert(key)
            s.pending[key] = jobs                     // replaces older pending frames of this clip
            if !s.order.contains(key) { s.order.append(key) }
            defer { s.running = true }
            return !s.running
        }
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while let job = next() {
            let t = tracker(job.quality)
            let tk = job.key.trackerKey
            var m = t.cached(key: tk, frameIndex: job.frameIndex)
            if m == nil {
                let start = ContinuousClock.now
                m = t.layerMatte(for: job.frame, rotationDegrees: job.rotation, key: tk, frameIndex: job.frameIndex, quality: job.quality)
                let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
                let failedRun = m == nil
                state.withLock { s in
                    s.segmentations += 1
                    if failedRun {
                        if s.failed.count > 512 { s.failed = [] }
                        s.failed.insert(Failed(key: job.key, frame: job.frameIndex, fast: job.quality == .fast))
                    }
                    s.timings.append(ms); if s.timings.count > 120 { s.timings.removeFirst(s.timings.count - 120) }
                }
            }
            let shown = state.withLock { s -> Bool in
                // Released while it ran (clip gone, relinked): drop the result and its tracker state.
                guard s.known.contains(job.key) else { return false }
                if !job.ahead, let m { s.latest[job.key] = m }
                return !job.ahead
            }
            if !state.withLock({ $0.known.contains(job.key) }) { t.reset(key: tk) }
            if shown { onReadyBox.call() }
        }
    }

    private func next() -> Job? {
        let (job, waiters) = state.withLock { s -> (Job?, [CheckedContinuation<Void, Never>]) in
            guard let k = s.order.first, var list = s.pending[k], !list.isEmpty else {
                s.running = false
                defer { s.idleWaiters = [] }
                return (nil, s.idleWaiters)
            }
            let j = list.removeFirst()
            s.order.removeFirst()
            if list.isEmpty { s.pending[k] = nil } else { s.pending[k] = list; s.order.append(k) }
            return (j, [])
        }
        for w in waiters { w.resume() }
        return job
    }

    /// Releases every clip not in `clips` (left the timeline or lost its subject mask).
    public func retain(clips: Set<UUID>) { release { !clips.contains($0.clip) } }

    /// Releases every key decoded from these media (relinked, proxy replaced).
    public func forget(sources: Set<UUID>) { release { sources.contains($0.source) } }

    public func resetAll() { release { _ in true } }

    private func release(_ drop: (Key) -> Bool) {
        let gone = state.withLock { s -> [Key] in
            let g = s.known.filter(drop)
            for k in g { s.known.remove(k); s.latest[k] = nil; s.pending[k] = nil }
            s.failed = s.failed.filter { !g.contains($0.key) }
            s.order.removeAll { g.contains($0) }
            return Array(g)
        }
        for k in gone { fast.reset(key: k.trackerKey); balanced.reset(key: k.trackerKey) }
    }

    /// Clips and sources with state (tests).
    public var keys: Set<Key> { state.withLock { $0.known } }
    /// Vision runs so far.
    public var segmentations: Int { state.withLock { $0.segmentations } }
    /// Wall time of the last Vision runs in ms (newest last, at most 120).
    public var timings: [Double] { state.withLock { $0.timings } }

    /// Suspends until nothing is pending or running (tests, frame capture).
    public func waitUntilIdle() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { s -> Bool in
                if !s.running { return true }
                s.idleWaiters.append(c); return false
            }
            if idle { c.resume() }
        }
    }
}
