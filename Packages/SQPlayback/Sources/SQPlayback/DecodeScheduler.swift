import Foundation
import SQCore
import SQMedia

/// Runs `PrefetchPlanner.Job`s: one job in flight per media (decoders must not be called concurrently), at most
/// `maxConcurrent` in total. `submit` replaces the pending queue and cancels in-flight jobs that are not in the new
/// queue (a seek). A job that throws is reported through `onError` once and not retried by the scheduler; the same
/// job is ignored by later `submit`s until `resetFailures()`.
///
/// Deviation from ARCHITECTURE §6: the decoder factory, the result sink and the error callback are init parameters
/// (no FrameCache dependency here; the engine's sink inserts into the cache).
public actor DecodeScheduler {
    public typealias DecoderFactory = @Sendable (UUID) throws -> any VideoDecoding
    public typealias Sink = @Sendable (PrefetchPlanner.Job, [DecodedFrame]) -> Void
    public typealias ErrorHandler = @Sendable (PrefetchPlanner.Job, any Error) -> Void

    private struct Flight {
        var job: PrefetchPlanner.Job
        var task: Task<Void, Never>
        var cancelled = false
    }

    private let maxConcurrent: Int
    private let makeDecoder: DecoderFactory
    private let sink: Sink
    private let onError: ErrorHandler?
    private var decoders: [UUID: any VideoDecoding] = [:]
    /// One serial queue per media: decoder creation and `decode` (blocking AVFoundation/VideoToolbox work) run
    /// there, never on the cooperative thread pool.
    private var executors: [UUID: QueueTaskExecutor] = [:]
    private var pending: [PrefetchPlanner.Job] = []
    private var flights: [UUID: Flight] = [:]      // by media; stays until the task has really finished
    private var failed: Set<PrefetchPlanner.JobKey> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 4, decoder makeDecoder: @escaping DecoderFactory, sink: @escaping Sink,
                onError: ErrorHandler? = nil) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.makeDecoder = makeDecoder; self.sink = sink; self.onError = onError
    }

    /// Replaces the pending queue (ordered by `priority`, stable) and cancels in-flight jobs not in `jobs`.
    public func submit(_ jobs: [PrefetchPlanner.Job]) {
        let sorted = jobs.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority < $1.element.priority : $0.offset < $1.offset
        }.map(\.element)
        var seen = Set<PrefetchPlanner.JobKey>()
        let wanted = sorted.filter { !failed.contains($0.key) && seen.insert($0.key).inserted }
        let wantedKeys = Set(wanted.map(\.key))
        for (media, var f) in flights where !wantedKeys.contains(f.job.key) && !f.cancelled {
            f.cancelled = true; f.task.cancel(); flights[media] = f
        }
        pending = wanted.filter { job in flights[job.media].map { $0.job.key != job.key || $0.cancelled } ?? true }
        pump()
    }

    public func cancelAll() {
        pending = []
        for (media, var f) in flights where !f.cancelled { f.cancelled = true; f.task.cancel(); flights[media] = f }
    }

    public func resetFailures() { failed = [] }

    /// Jobs queued or running (cancelled ones still winding down count until they return).
    public var isIdle: Bool { pending.isEmpty && flights.isEmpty }

    /// Suspends until nothing is queued or running.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func pump() {
        while flights.count < maxConcurrent, let i = pending.firstIndex(where: { flights[$0.media] == nil }) {
            let job = pending.remove(at: i)
            let factory = makeDecoder
            let known = decoders[job.media]
            let executor = executors[job.media] ?? QueueTaskExecutor(label: "SQPlayback.decode.\(job.media.uuidString.prefix(8))")
            executors[job.media] = executor
            let task = Task(executorPreference: executor) { [weak self] in
                let result: Result<(any VideoDecoding, [DecodedFrame]), any Error>
                do {
                    let d = try known ?? factory(job.media)
                    try Task.checkCancellation()
                    result = .success((d, try await d.decode(job.frames)))
                } catch { result = .failure(error) }
                await self?.finished(job, result)
            }
            flights[job.media] = Flight(job: job, task: task)
        }
        if isIdle { let w = idleWaiters; idleWaiters = []; w.forEach { $0.resume() } }
    }

    private func finished(_ job: PrefetchPlanner.Job, _ result: Result<(any VideoDecoding, [DecodedFrame]), any Error>) {
        let cancelled = flights.removeValue(forKey: job.media)?.cancelled ?? true
        switch result {
        case .success(let (decoder, frames)):
            decoders[job.media] = decoder
            if !cancelled { sink(job, frames) }
        case .failure(let error):
            if !(error is CancellationError) && !cancelled {
                failed.insert(job.key)
                onError?(job, error)
            }
        }
        pump()
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
