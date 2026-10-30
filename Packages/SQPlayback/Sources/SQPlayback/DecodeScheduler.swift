import Foundation
import Synchronization
import SQCore
import SQMedia

/// Runs `PrefetchPlanner.Job`s on up to `lanesPerMedia` decoders per media (a decoder is never called concurrently; each
/// lane has its own decoder and serial queue), at most `maxConcurrent` jobs in total. A run of adjacent GOPs (forward or
/// reverse play through one clip) stays on one lane, in priority order, and its next GOP goes to the decoder that decoded
/// the previous one; a second lane only takes a GOP that is not connected (through queued GOPs) to a running one: another
/// clip of the same file at a different source position (never next to a canceled job: a seek within one clip reuses its
/// decoder), and is released `spareLaneLinger` after its media has only one run left. `submit` replaces the pending queue and cancels in-flight jobs
/// that are not in the new queue (a seek). A job that throws is reported through `onError` once and not retried by the
/// scheduler; the same job is ignored by later `submit`s until `resetFailures()`. A running job marked
/// `finishesWhenDropped` (scrub keyframe) is never canceled by `submit`; its result is stored. Decoders hand frames over
/// one by one (`decode(_:deliver:)`): the sink sees them as they are decoded, and once more at the end only those that
/// were not delivered early.
///
/// Deviation from ARCHITECTURE §6: the decoder factory, the result sink and the error callback are init parameters
/// (no FrameCache dependency here; the engine's sink inserts into the cache).
public actor DecodeScheduler {
    public typealias DecoderFactory = @Sendable (UUID) throws -> any VideoDecoding
    public typealias Sink = @Sendable (PrefetchPlanner.Job, [DecodedFrame]) -> Void
    public typealias ErrorHandler = @Sendable (PrefetchPlanner.Job, any Error) -> Void

    /// One decoder of a media.
    struct Lane: Hashable { var media: UUID; var index: Int }

    private struct Flight {
        var job: PrefetchPlanner.Job
        var task: Task<Void, Never>
        let gate: DeliveryGate
        var cancelled = false
        /// The media was forgotten (relinked) while this job ran: its decoder and frames are discarded.
        var forgotten = false
        mutating func cancel() { cancelled = true; gate.close(); task.cancel() }
    }

    /// A lane's decoder (nil while the first job creates it) and serial queue: decoder creation and `decode` (blocking
    /// AVFoundation/VideoToolbox work) run there, never on the cooperative thread pool.
    private struct Slot {
        var decoder: (any VideoDecoding)?
        let executor: QueueTaskExecutor
        /// Frames of the last job that completed on it: the next GOP continues there without a reseek.
        var last: ClosedRange<Int>?
        var lastUse: UInt64 = 0
        /// Since when this lane is a spare: its media is wanted but has fewer runs than lanes (released after the linger).
        var spareSince: ContinuousClock.Instant?
    }

    /// The queued and running GOPs of each media, grouped into runs (GOPs that touch, through queued ones). Built once
    /// per pump/trim: linear in the queue after sorting (all-intra media queues one job per frame).
    private struct Runs {
        /// Run of each queued job.
        var run: [PrefetchPlanner.JobKey: Int] = [:]
        /// Runs that contain a running (not canceled) GOP: their queued GOPs continue on that GOP's lane.
        var busy: Set<Int> = []
        /// Number of runs per media.
        var count: [UUID: Int] = [:]
        /// First frames of the queued GOPs per media.
        var starts: [UUID: Set<Int>] = [:]
    }

    /// Early deliveries of one job: closed on cancel. Checking and sinking happen under its lock, so once `close()`
    /// returned no frame of the job reaches the sink any more (a relink cleans the cache right after `forget`).
    final class DeliveryGate: Sendable {
        private let state = Mutex<(open: Bool, delivered: Set<Time>)>((true, []))
        func deliver(_ f: DecodedFrame, _ sink: () -> Void) {
            state.withLock { s in
                guard s.open else { return }
                s.delivered.insert(f.pts)
                sink()
            }
        }
        func close() { state.withLock { $0.open = false } }
        var delivered: Set<Time> { state.withLock { $0.delivered } }
    }

    private let maxConcurrent: Int
    private let lanesPerMedia: Int
    private let makeDecoder: DecoderFactory
    private let sink: Sink
    private let onError: ErrorHandler?
    private var slots: [Lane: Slot] = [:]
    private var pending: [PrefetchPlanner.Job] = []
    private var flights: [Lane: Flight] = [:]      // stays until the task has really finished
    private var failed: Set<PrefetchPlanner.JobKey> = []
    /// Decoders hold a VideoToolbox session each (hardware sessions are limited): the ones the current queue does not
    /// need are kept most-recently-used first, at most `idleDecoders` of them, the rest are invalidated.
    private let idleDecoders: Int
    /// Live software (non-hardware) decoders at most (`WorkLimits.softwareDecoderSessions`; weak Macs): idle ones beyond it
    /// are evicted least recently used first, wanted ones last. An idle decoder whose run continues with a queued GOP is
    /// spared (no new session and reseek per GOP), but only up to `softwareDecoderCeiling(cap:)` (one session over the
    /// cap): beyond that the least recently used continuing ones are closed too, so a stack of software layers wider than
    /// the cap reopens a session per GOP for the extra layers instead of holding one session each (memory first on the
    /// weak Macs the cap exists for). Running ones are never closed (at most `maxConcurrent` of them).
    private let maxSoftwareDecoders: Int
    /// How long a wanted media keeps a decoder it has no run for (another clip of the file between two of its GOPs).
    private let spareLaneLinger: Duration
    private var spareCheck: Task<Void, Never>?
    /// Media of the last submitted queue (running or already done): their decoders are never trimmed, however few jobs
    /// are still pending, so a window with 3+ alternating media does not recreate a decoder per job.
    private var lastWanted: Set<UUID> = []
    private var useClock: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Jobs decoding now and not canceled, readable off the actor (the planner keeps them listed).
    private let runningKeys = Mutex<Set<PrefetchPlanner.JobKey>>([])

    /// True while `frames` of `media` are being decoded (not canceled). Thread-safe snapshot.
    public nonisolated func isRunning(media: UUID, frames: ClosedRange<Int>) -> Bool {
        runningKeys.withLock { $0.contains(PrefetchPlanner.JobKey(media: media, frames: frames)) }
    }

    private func publishRunning() {
        let keys = Set(flights.values.filter { !$0.cancelled }.map(\.job.key))
        runningKeys.withLock { $0 = keys }
    }

    /// `lanesPerMedia`: decoders one media may use at once (each is a VideoToolbox session with its own reference
    /// frames; 1 = strictly serial per media).
    /// `spareLaneLinger`: a wanted media keeps more decoders than it has runs (queued or running) for this long.
    public init(maxConcurrent: Int = 4, lanesPerMedia: Int = 1, idleDecoders: Int = 2, maxSoftwareDecoders: Int = .max,
                spareLaneLinger: Duration = .seconds(1), decoder makeDecoder: @escaping DecoderFactory, sink: @escaping Sink, onError: ErrorHandler? = nil) {
        self.maxConcurrent = max(1, maxConcurrent); self.lanesPerMedia = max(1, lanesPerMedia)
        self.idleDecoders = max(0, idleDecoders); self.maxSoftwareDecoders = max(1, maxSoftwareDecoders)
        self.spareLaneLinger = spareLaneLinger
        self.makeDecoder = makeDecoder; self.sink = sink; self.onError = onError
    }

    /// Replaces the pending queue (ordered by `priority`, stable) and cancels in-flight jobs not in `jobs`.
    public func submit(_ jobs: [PrefetchPlanner.Job]) {
        let sorted = jobs.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority < $1.element.priority : $0.offset < $1.offset
        }.map(\.element)
        var seen = Set<PrefetchPlanner.JobKey>()
        let wanted = sorted.filter { !failed.contains($0.key) && seen.insert($0.key).inserted }
        let wantedByKey = Dictionary(wanted.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (lane, var f) in flights where !f.cancelled && !f.job.finishesWhenDropped {
            // Not wanted any more, or wanted from an earlier frame than the running seek decodes (it skips frames before
            // its `neededFrom`): restart it with the wider job.
            if let w = wantedByKey[f.job.key], !Self.widens(w.neededFrom, f.job.neededFrom) { continue }
            f.cancel(); flights[lane] = f
        }
        let live = Set(flights.values.filter { !$0.cancelled }.map(\.job.key))
        pending = wanted.filter { !live.contains($0.key) }
        lastWanted = Set(wanted.map(\.media))
        trimDecoders(keeping: lastWanted)
        pump()
    }

    /// True when a job needing frames from `new` on needs frames a job running from `running` on skips (nil = all).
    static func widens(_ new: Int?, _ running: Int?) -> Bool {
        guard let running else { return false }
        guard let new else { return true }
        return new < running
    }

    /// Releases the decoders (and their queues) of media that are neither wanted nor running, beyond the MRU `idleDecoders`.
    private func trimDecoders(keeping wanted: Set<UUID>) {
        let idle = slots.keys.filter { !wanted.contains($0.media) && flights[$0] == nil }
            .sorted { (slots[$0]?.lastUse ?? 0) > (slots[$1]?.lastUse ?? 0) }
        for lane in idle.dropFirst(idleDecoders) { release(lane) }
        trimSpareLanes(runs())
        trimSoftwareDecoders(keeping: wanted)
    }

    /// Software decoders kept at most while their runs continue (`maxSoftwareDecoders` plus one): the hard bound.
    static func softwareDecoderCeiling(cap: Int) -> Int { cap == .max ? .max : cap + 1 }

    /// Over `maxSoftwareDecoders`: closes idle software decoders, unwanted media first, then the least recently used. An
    /// idle decoder whose next GOP is queued is spared (it continues without a reseek; closing it only made the next GOP
    /// open a new session) while the total stays within `softwareDecoderCeiling`; beyond it the least recently used
    /// continuing ones go as well.
    private func trimSoftwareDecoders(keeping wanted: Set<UUID>) {
        guard maxSoftwareDecoders < .max else { return }
        let software = slots.filter { $0.value.decoder.map { !$0.isHardware } ?? false }
        var over = software.count - maxSoftwareDecoders
        guard over > 0 else { return }
        var queuedStarts: [UUID: Set<Int>] = [:]
        for j in pending { queuedStarts[j.media, default: []].insert(j.frames.lowerBound) }
        func continues(_ l: Lane) -> Bool {
            guard let next = slots[l]?.last.map({ $0.upperBound + 1 }) else { return false }
            return queuedStarts[l.media]?.contains(next) ?? false
        }
        func lru(_ a: Lane, _ b: Lane) -> Bool { (slots[a]?.lastUse ?? 0) < (slots[b]?.lastUse ?? 0) }
        let idle = software.keys.filter { flights[$0] == nil }
        let victims = idle.filter { !continues($0) }.sorted {
            let (a, b) = (wanted.contains($0.media), wanted.contains($1.media))
            return a != b ? !a : lru($0, $1)
        }
        var live = software.count
        for lane in victims where over > 0 { release(lane); over -= 1; live -= 1 }
        // Continuing runs may hold one session over the cap, never more.
        var beyond = live - Self.softwareDecoderCeiling(cap: maxSoftwareDecoders)
        for lane in idle.filter(continues).sorted(by: lru) where beyond > 0 { release(lane); beyond -= 1 }
    }

    /// A media keeps one decoder per run it has queued or running (at least one): each decoder is a VideoToolbox session
    /// (100-500 MB for 4K, hardware sessions are limited). A lane beyond that (the second clip of the file has no GOP
    /// queued now) is released once it has been spare for `spareLaneLinger`; a running lane is never released.
    private func trimSpareLanes(_ runs: Runs) {
        guard lanesPerMedia > 1 else { return }
        let now = ContinuousClock.now
        var recheck: ContinuousClock.Instant?
        var byMedia: [UUID: [Lane]] = [:]
        for lane in slots.keys { byMedia[lane.media, default: []].append(lane) }
        for (media, lanes) in byMedia {
            let keep = max(1, runs.count[media] ?? 0)
            let starts = runs.starts[media] ?? []
            // Running lanes first, then one whose run continues with a queued GOP, then the most recently used.
            func score(_ l: Lane) -> (Int, Int, UInt64) {
                let s = slots[l]
                return (flights[l] != nil ? 1 : 0, starts.contains((s?.last?.upperBound ?? -2) + 1) ? 1 : 0, s?.lastUse ?? 0)
            }
            let ranked = lanes.sorted { score($0) > score($1) }
            for l in ranked.prefix(keep) { slots[l]?.spareSince = nil }
            for l in ranked.dropFirst(keep) where flights[l] == nil {
                let since = slots[l]?.spareSince ?? now
                if now - since >= spareLaneLinger { release(l); continue }
                slots[l]?.spareSince = since
                recheck = min(recheck ?? since + spareLaneLinger, since + spareLaneLinger)
            }
        }
        if let recheck, spareCheck == nil {
            spareCheck = Task { [weak self] in
                try? await Task.sleep(until: recheck, clock: .continuous)
                await self?.checkSpareLanes()
            }
        }
    }

    private func checkSpareLanes() {
        spareCheck = nil
        trimSpareLanes(runs())
    }

    private func runs() -> Runs {
        var r = Runs()
        guard lanesPerMedia > 1 else { return r }
        var byMedia: [UUID: [(frames: ClosedRange<Int>, key: PrefetchPlanner.JobKey?)]] = [:]
        for f in flights.values where !f.cancelled { byMedia[f.job.media, default: []].append((f.job.frames, nil)) }
        for j in pending {
            byMedia[j.media, default: []].append((j.frames, j.key))
            r.starts[j.media, default: []].insert(j.frames.lowerBound)
        }
        var id = 0
        for (media, items) in byMedia {
            var upper = 0, n = 0
            for item in items.sorted(by: { $0.frames.lowerBound < $1.frames.lowerBound }) {
                // Sorted by first frame, a GOP touches the run so far exactly when it starts at most one past its end.
                if n == 0 || item.frames.lowerBound > upper + 1 { id += 1; n += 1; upper = item.frames.upperBound }
                else { upper = max(upper, item.frames.upperBound) }
                if let key = item.key { r.run[key] = id } else { r.busy.insert(id) }
            }
            r.count[media] = n
        }
        return r
    }

    /// Only called for a lane without a running job (callers check `flights`, or the job has just finished), and always on
    /// this actor, so `invalidate()` never races a `decode` of the same decoder: a decoder is used by one job at a time.
    private func release(_ lane: Lane) {
        slots.removeValue(forKey: lane)?.decoder?.invalidate()
    }

    /// Drops everything known about `media` (it was relinked to another file): queued jobs, the failure memory, the
    /// decoders; running jobs are canceled and their results and decoders are discarded.
    public func forget(_ media: Set<UUID>) {
        pending.removeAll { media.contains($0.media) }
        failed = failed.filter { !media.contains($0.media) }
        for lane in slots.keys where media.contains(lane.media) {
            if var f = flights[lane] { f.cancel(); f.forgotten = true; flights[lane] = f }
            else { release(lane) }
        }
        publishRunning()
    }

    /// Decoders that currently exist (tests).
    var decoderCount: Int { slots.values.filter { $0.decoder != nil }.count }

    public func cancelAll() {
        pending = []
        for (lane, var f) in flights where !f.cancelled { f.cancel(); flights[lane] = f }
        publishRunning()
    }

    /// Pause: forgets the jobs still waiting for a slot (prefetch ahead of a playhead that stopped); jobs already
    /// decoding finish, a paused frame may need them. The caller clears its last-posted plan so the paused plan is sent.
    public func dropQueued() {
        pending = []
    }

    public func resetFailures() { failed = [] }

    /// Jobs queued or running (canceled ones still winding down count until they return).
    public var isIdle: Bool { pending.isEmpty && flights.isEmpty }

    /// Suspends until nothing is queued or running.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The lane `job` may start on now, or nil: every lane of its media is busy, or the job continues (through queued
    /// GOPs of the same media) a run that a lane is decoding, so it waits for that lane. `rank`: the job's place among
    /// the wanted jobs now (running ones first, then its place in the queue).
    private func lane(for job: PrefetchPlanner.Job, rank: Int, runs: Runs) -> Lane? {
        var busy = 0, live = false
        for i in 0..<lanesPerMedia {
            if let f = flights[Lane(media: job.media, index: i)] { busy += 1; if !f.cancelled { live = true } }
        }
        guard busy < lanesPerMedia else { return nil }
        if lanesPerMedia > 1, let run = runs.run[job.key], runs.busy.contains(run) { return nil }
        if busy > 0 {
            // A second decoder (a new session, competing for the hardware) only for a GOP not connected to the running
            // one (another clip of the file), among the nearest `maxConcurrent`: after a seek, far GOPs opening sessions
            // slowed the GOP under the playhead. Next to a canceled job only (a seek within one clip) the job waits:
            // that decoder returns at once and is reused.
            guard live, rank < maxConcurrent else { return nil }
        }
        let free = (0..<lanesPerMedia).map { Lane(media: job.media, index: $0) }.filter { flights[$0] == nil }
        // The lane that decoded the GOP right before (continues without a reseek); else an existing decoder whose own
        // continuation is not queued; else any existing decoder; else a new one.
        let queuedStarts = runs.starts[job.media] ?? []
        func next(_ l: Lane) -> Int? { slots[l]?.last.map { $0.upperBound + 1 } }
        return free.first { next($0) == job.frames.lowerBound }
            ?? free.first { slots[$0] != nil && !queuedStarts.contains(next($0) ?? -1) }
            ?? free.first { slots[$0] != nil }
            ?? free.first
    }

    private func pump() {
        var runs = flights.count < maxConcurrent && !pending.isEmpty ? self.runs() : Runs()
        while flights.count < maxConcurrent {
            let live = flights.values.reduce(0) { $0 + ($1.cancelled ? 0 : 1) }
            var pick: (Int, Lane)?
            for (i, job) in pending.enumerated() {
                if let l = lane(for: job, rank: live + i, runs: runs) { pick = (i, l); break }
            }
            guard let (i, lane) = pick else { break }
            let job = pending.remove(at: i)
            if let run = runs.run[job.key] { runs.busy.insert(run) }
            runs.starts[job.media]?.remove(job.frames.lowerBound)
            let factory = makeDecoder, sink = self.sink
            let gate = DeliveryGate()
            let slot = slots[lane] ?? Slot(decoder: nil, executor: QueueTaskExecutor(
                label: "SQPlayback.decode.\(job.media.uuidString.prefix(8)).\(lane.index)"))
            slots[lane] = slot
            let known = slot.decoder
            let task = Task(executorPreference: slot.executor) { [weak self] in
                var decoder: (any VideoDecoding)?
                let result: Result<[DecodedFrame], any Error>
                do {
                    let d = try known ?? factory(job.media)
                    decoder = d
                    try Task.checkCancellation()
                    result = .success(try await d.decode(job.frames, neededFrom: job.neededFrom, deliver: { f in gate.deliver(f) { sink(job, [f]) } }))
                } catch { result = .failure(error) }
                await self?.finished(job, on: lane, decoder, result)
            }
            flights[lane] = Flight(job: job, task: task, gate: gate)
        }
        publishRunning()
        if isIdle { let w = idleWaiters; idleWaiters = []; w.forEach { $0.resume() } }
    }

    private func finished(_ job: PrefetchPlanner.Job, on lane: Lane, _ decoder: (any VideoDecoding)?,
                          _ result: Result<[DecodedFrame], any Error>) {
        let flight = flights.removeValue(forKey: lane)
        let cancelled = flight?.cancelled ?? true
        // A decoder survives a failed `decode` (it resets its own session state); only a media that was forgotten drops it.
        if let decoder {
            if flight?.forgotten == true { decoder.invalidate(); release(lane) }
            else if var slot = slots[lane] {
                useClock += 1
                slot.decoder = decoder; slot.lastUse = useClock
                if case .success = result, !cancelled { slot.last = job.frames } else { slot.last = nil }
                slots[lane] = slot
            } else { decoder.invalidate() }
        }
        switch result {
        case .success(let frames):
            if !cancelled, let gate = flight?.gate {
                let early = gate.delivered
                let rest = early.isEmpty ? frames : frames.filter { !early.contains($0.pts) }
                if !rest.isEmpty || early.isEmpty { sink(job, rest) }
            }
        case .failure(let error):
            if !(error is CancellationError) && !cancelled {
                failed.insert(job.key)
                onError?(job, error)
            }
        }
        if slots[lane]?.decoder == nil { slots[lane] = nil }
        // Pump first: the lane that just finished takes its run's next GOP (running lanes are never trimmed), so the
        // trim below cannot close a decoder the queue is about to continue on.
        pump()
        trimDecoders(keeping: lastWanted.union(pending.map(\.media)))
    }
}

/// Task executor over a private serial `DispatchQueue` (dedicated thread per queue while it has work).
final class QueueTaskExecutor: TaskExecutor, Sendable {
    let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

