import CoreVideo
import Foundation
import SQCore
import Synchronization

/// Person segmentation of one upright frame (Vision in the app, a fake in tests).
public protocol PersonSegmenting: Sendable {
    func segment(_ frame: CVPixelBuffer) throws -> SubjectMatte?
}

/// Vision person segmentation at the balanced quality (the same matte a settled frame shows).
public struct VisionPersonSegmenter: PersonSegmenting {
    public init() {}
    public func segment(_ frame: CVPixelBuffer) throws -> SubjectMatte? {
        try PersonSegmenter.matte(in: frame, orientation: .up, quality: .balanced)
    }
}

/// Subject masks precomputed like Magic mattes: the person matte of every source frame of a media range is segmented in
/// the background (one file read, frames in order, temporally smoothed) and stored in a `MagicMatteStore` under
/// `cacheKey(media:path:)`. Playback reads the store and only falls back to `SubjectMatteScheduler` (live Vision) for
/// frames not done yet. One job at a time at utility priority, so playback and editing stay responsive. Thread-safe.
public final class SubjectMattePrecompute: Sendable {
    private struct Job: Sendable {
        let media: UUID
        let url: URL
        let key: String
        let from: Double
        let to: Double
        let generation: Int
        let deinterlace: FieldOrder?
    }

    private struct State {
        var queue: [Job] = []
        /// Ranges asked for per key this session (a request inside one is a no-op).
        var requested: [String: [ClosedRange<Double>]] = [:]
        /// Bumped by `retain`/`forget`: a running job of an older generation stops at its next frame.
        var generations: [UUID: Int] = [:]
        var running = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var segmentations = 0
        /// The read of the job now running: `retain` / `forget` of its media stop it at once (a read that hangs in the
        /// decoder never reaches the generation check of its next frame).
        var reading: (media: UUID, stop: ReadStop)?
    }

    /// The stop of the running job's read (tests).
    var runningStop: ReadStop? { state.withLock { $0.reading?.stop } }

    public let store: MagicMatteStore
    private let segmenter: any PersonSegmenting
    private let maxDimension: Int
    private let state = Mutex(State())
    private let onProgressBox = CallbackSlot()
    /// Frames between redraw notices (and between file saves x 10).
    static let progressEvery = 12

    /// The app's store: `~/Library/Caches/<bundle>/SubjectMattes` (kept apart from Magic mattes, which are swept per pick).
    public static let sharedStore: MagicMatteStore = {
        let dir = AnalysisCacheLocation.directory("SubjectMattes") { AnalysisCacheLocation.legacyBundleDirectory("SubjectMattes") }
        return MagicMatteStore(directory: dir)
    }()

    public init(store: MagicMatteStore = SubjectMattePrecompute.sharedStore, segmenter: any PersonSegmenting = VisionPersonSegmenter(),
                maxDimension: Int = WorkLimits.current.maskTrackDimension) {
        self.store = store; self.segmenter = segmenter; self.maxDimension = maxDimension
    }

    /// Stable across launches (FNV-1a over the media id and its file path, so a relink gets new mattes), hex.
    /// `deinterlace`: the field order the frames are deinterlaced with (`request`); nil keeps the key progressive media
    /// always had, so a changed Deinterlace switch segments again and nothing else does.
    public static func cacheKey(media: UUID, path: String, quality: PersonSegmenter.Quality = .balanced,
                                deinterlace: FieldOrder? = nil) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ bytes: some Sequence<UInt8>) { for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        mix(withUnsafeBytes(of: media.uuid) { Array($0) })
        mix(Array(path.utf8))
        // Mattes of different qualities never share a key: export (accurate) must not read a balanced matte as its own.
        let tag = switch quality { case .fast: "person1f-"; case .balanced: "person1-"; case .accurate: "person1a-" }
        return tag + String(h, radix: 16) + (deinterlace.map { "-fields-\($0.rawValue)" } ?? "")
    }

    /// Called (on the worker) after every few stored frames and when a job ends: the render loop redraws.
    public func setOnProgress(_ f: (@Sendable () -> Void)?) { onProgressBox.set(f) }

    /// Vision runs so far (tests, HUD).
    public var segmentations: Int { state.withLock { $0.segmentations } }

    /// Asks for the person mattes of source seconds `from`...`to` of `media` (file `url`), starting at `start` (the shown
    /// frame: forward to `to`, then `from` up to `start`). Cheap and non-blocking (render thread). false = already asked.
    /// `deinterlace`: the media item's `VideoTrackInfo.deinterlaceFieldOrder`; the mattes are made of deinterlaced
    /// frames and stored under `cacheKey(media:path:deinterlace:)`.
    @discardableResult
    public func request(media: UUID, url: URL, from: Double, to: Double, start: Double, deinterlace: FieldOrder? = nil) -> Bool {
        let lo = max(0, min(from, to)), hi = max(from, to)
        let s = min(max(start, lo), hi)
        let key = Self.cacheKey(media: media, path: url.path, deinterlace: deinterlace)
        let launch = state.withLock { st -> Bool? in
            let tol = 1e-3
            if st.requested[key, default: []].contains(where: { $0.lowerBound <= lo + tol && $0.upperBound >= hi - tol }) { return nil }
            st.requested[key, default: []].append(lo...hi)
            let g = st.generations[media, default: 0]
            st.queue.append(Job(media: media, url: url, key: key, from: s, to: hi, generation: g, deinterlace: deinterlace))
            if s > lo + tol { st.queue.append(Job(media: media, url: url, key: key, from: lo, to: s, generation: g, deinterlace: deinterlace)) }
            defer { st.running = true }
            return !st.running
        }
        guard let launch else { return false }
        if launch { Task.detached(priority: .utility) { [self] in await drain() } }
        return true
    }

    /// Stops and forgets the work of every media not in `media` (their clips left the timeline or lost the subject mask).
    public func retain(media: Set<UUID>) { drop { !media.contains($0) } }

    /// Stops the work of these media (relinked): their next request starts over (under the new file's key).
    public func forget(media: Set<UUID>) { drop { media.contains($0) } }

    private func drop(_ gone: (UUID) -> Bool) {
        let stop = state.withLock { s -> ReadStop? in
            let ids = Set(s.queue.map(\.media)).union(s.generations.keys).union(s.reading.map { [$0.media] } ?? []).filter(gone)
            guard !ids.isEmpty else { return nil }
            for id in ids { s.generations[id, default: 0] += 1 }
            let keys = Set(s.queue.filter { ids.contains($0.media) }.map(\.key))
            s.queue.removeAll { ids.contains($0.media) }
            for k in keys { s.requested[k] = nil }
            // Keys of a running job: found through the generation bump; its requested ranges go when it stops.
            return s.reading.flatMap { ids.contains($0.media) ? $0.stop : nil }
        }
        stop?.stop()
    }

    private func live(_ j: Job) -> Bool { state.withLock { $0.generations[j.media, default: 0] == j.generation } }

    private func drain() async {
        while let job = next() {
            await run(job)
        }
    }

    private func next() -> Job? {
        let (job, waiters) = state.withLock { s -> (Job?, [CheckedContinuation<Void, Never>]) in
            guard !s.queue.isEmpty else {
                s.running = false
                defer { s.waiters = [] }
                return (nil, s.waiters)
            }
            return (s.queue.removeFirst(), [])
        }
        for w in waiters { w.resume() }
        return job
    }

    private func run(_ job: Job) async {
        defer {
            // Stopped (`retain` / `forget`): the range may be asked for again.
            if !live(job) { state.withLock { s in if s.queue.allSatisfy({ $0.key != job.key }) { s.requested[job.key] = nil } } }
        }
        guard live(job) else { return }
        store.preload(job.key)
        let have = store.times(key: job.key)
        func stored(_ pts: Double) -> Bool {
            var lo = 0, hi = have.count
            while lo < hi { let m = (lo + hi) / 2; if have[m] < pts - 1e-4 { lo = m + 1 } else { hi = m } }
            return lo < have.count && abs(have[lo] - pts) <= 1e-4
        }
        if Self.covers(have, from: job.from, to: job.to) { return }      // done in an earlier session: nothing to decode
        var smoother = SubjectMatteSmoother()
        var index = 0, done = 0
        let reader = FrameReader(url: job.url, maxDimension: maxDimension, deinterlace: job.deinterlace)
        state.withLock { $0.reading = (job.media, reader.stop) }
        defer { state.withLock { $0.reading = nil } }
        guard live(job) else { return }          // dropped just before its read was known
        do {
            try await reader.forEach(from: job.from, to: job.to) { pb, pts in
                guard self.live(job) else { return false }
                defer { index += 1 }
                if stored(pts) { return true }           // done before (earlier session or overlapping job)
                let raw: SubjectMatte?
                do { raw = try self.segmenter.segment(pb) } catch {
                    // Vision failed (busy Neural Engine): not "no person". Nothing stored; the live path segments it.
                    self.state.withLock { $0.segmentations += 1 }
                    return true
                }
                self.state.withLock { $0.segmentations += 1 }
                // No mask from Vision: an empty matte, so playback does not run Vision there either.
                let m = raw.map { smoother.push($0, frameIndex: index) } ?? SubjectMatte(width: 1, height: 1, values: [0])
                self.store.put(m, key: job.key, pts: pts)
                done += 1
                if done % Self.progressEvery == 0 { self.onProgressBox.call() }
                if done % (Self.progressEvery * 10) == 0 { self.store.save(key: job.key) }
                return true
            }
        } catch {}
        if done > 0 {
            store.save(key: job.key)
            onProgressBox.call()
        }
    }

    /// Stored times `have` (sorted) cover `from`...`to` without a hole: they reach both ends (within 0.1 s) and no gap is
    /// longer than 1.5 x the typical (median) frame spacing.
    public static func covers(_ have: [Double], from: Double, to: Double) -> Bool {
        guard have.count >= 2, let first = have.first, let last = have.last, first <= from + 0.1, last >= to - 0.1 else { return false }
        let i0 = max(0, (have.firstIndex { $0 >= from } ?? 0) - 1)
        let i1 = min(have.count - 1, (have.lastIndex { $0 <= to } ?? have.count - 1) + 1)
        guard i1 > i0 else { return false }
        let gaps = (i0..<i1).map { have[$0 + 1] - have[$0] }.sorted()
        let median = gaps[gaps.count / 2]
        return gaps.last! <= median * 1.5 + 1e-6
    }

    /// Suspends until nothing is queued or running (tests).
    public func waitUntilIdle() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { s -> Bool in
                if !s.running { return true }
                s.waiters.append(c); return false
            }
            if idle { c.resume() }
        }
    }
}
