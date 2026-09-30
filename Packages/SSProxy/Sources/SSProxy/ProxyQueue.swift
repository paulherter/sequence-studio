import Foundation
import SSCore

public struct ProxyJobID: Sendable, Hashable, Codable { public let raw: UUID; public init() { raw = UUID() } }

public enum ProxyJobState: Sendable, Equatable {
    case queued, running
    case done(ProxyRecord)
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self { case .queued, .running: false; default: true }
    }
}

/// Scheduling priority of a job: decides start order and the priority of the transcode task.
public enum ProxyJobPriority: Int, Sendable, Hashable, Comparable, Codable {
    /// Automatic generation after import.
    case background = 0
    /// Explicitly requested by the user.
    case utility = 1
    case userInitiated = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var taskPriority: TaskPriority {
        switch self { case .background: .background; case .utility: .utility; case .userInitiated: .userInitiated }
    }
}

public struct ProxyJobInfo: Sendable, Equatable, Identifiable {
    public var id: ProxyJobID
    public var source: URL
    public var kind: ProxyKind
    public var priority: ProxyJobPriority = .utility
    public var state: ProxyJobState
    /// 0...1
    public var progress: Double
    public var isDone: Bool { if case .done = state { true } else { false } }
}

/// Sequential (or N-way) proxy generation with dedupe. Completed proxies are registered in the `ProxyCache`.
public actor ProxyQueue {
    public typealias Fingerprinter = @Sendable (URL) throws -> SourceFingerprint

    private struct Job {
        var info: ProxyJobInfo
        var fingerprint: SourceFingerprint
        var task: Task<Void, Never>?
        var cancelRequested = false
    }

    private let cache: ProxyCache
    private let transcoder: any ProxyTranscoding
    private let fingerprinter: Fingerprinter
    public private(set) var concurrency: Int
    private var jobs: [ProxyJobID: Job] = [:]
    private var order: [ProxyJobID] = []
    private var listeners: [UUID: (job: ProxyJobID?, cont: AsyncStream<ProxyJobInfo>.Continuation)] = [:]

    public init(cache: ProxyCache, transcoder: any ProxyTranscoding, concurrency: Int = 1,
                fingerprinter: @escaping Fingerprinter = { try SourceFingerprint.compute(for: $0) }) {
        self.cache = cache; self.transcoder = transcoder
        self.concurrency = max(1, concurrency); self.fingerprinter = fingerprinter
    }

    /// Call once at launch: removes stale partials (no job can be running yet) and enforces the cache cap.
    public func start() {
        // Partials of jobs that already started (enqueue before start()) are kept.
        let running = Set(jobs.values.filter { $0.info.state == .running }.map {
            cache.partialURL(fingerprint: $0.fingerprint, kind: $0.info.kind)
        })
        cache.purgePartials(except: running)
        cache.enforceCap()
        startNext()
    }

    public func setConcurrency(_ n: Int) { concurrency = max(1, n); startNext() }

    /// Queues a proxy of the whole file (no partial ranges: the cache key is (fingerprint, kind)). Returns the
    /// existing job if the same (fingerprint, kind) is queued, running (not being cancelled) or already cached. Throws if the source cannot be fingerprinted.
    public func enqueue(_ source: URL, kind: ProxyKind,
                        priority: ProxyJobPriority = .utility) async throws -> ProxyJobID {
        let fp = try fingerprinter(source)
        if let existing = order.first(where: {
            guard let j = jobs[$0] else { return false }
            guard j.fingerprint == fp, j.info.kind == kind else { return false }
            switch j.info.state {
            case .queued: return true
            case .running: return !j.cancelRequested
            case .done(let r): return cache.lookup(fingerprint: r.fingerprint, kind: r.kind) != nil
            default: return false
            }
        }) { return existing }
        let id = ProxyJobID()
        var info = ProxyJobInfo(id: id, source: source, kind: kind, priority: priority, state: .queued, progress: 0)
        if let rec = cache.lookup(fingerprint: fp, kind: kind) {
            info.state = .done(rec); info.progress = 1
            jobs[id] = Job(info: info, fingerprint: fp); order.append(id)
            publish(id)
            return id
        }
        jobs[id] = Job(info: info, fingerprint: fp); order.append(id)
        publish(id)
        startNext()
        return id
    }

    public func info(_ id: ProxyJobID) -> ProxyJobInfo? { jobs[id]?.info }
    public func allJobs() -> [ProxyJobInfo] { order.compactMap { jobs[$0]?.info } }

    /// Mean progress of all non-cancelled jobs (0 if none).
    public func overallProgress() -> Double {
        let infos = allJobs().filter { $0.state != .cancelled }
        guard !infos.isEmpty else { return 0 }
        return infos.reduce(0) { $0 + $1.progress } / Double(infos.count)
    }

    public func cancel(_ id: ProxyJobID) {
        guard var j = jobs[id] else { return }
        switch j.info.state {
        case .queued:
            j.info.state = .cancelled
            jobs[id] = j; publish(id)
        case .running:
            j.cancelRequested = true
            jobs[id] = j
            j.task?.cancel()
        default: break
        }
    }

    public func cancelAll() { for id in order { cancel(id) } }

    /// Updates for one job (current state first); finishes when the job reaches a terminal state.
    public func updates(for id: ProxyJobID) -> AsyncStream<ProxyJobInfo> {
        let (stream, cont) = AsyncStream.makeStream(of: ProxyJobInfo.self, bufferingPolicy: .bufferingNewest(64))
        guard let j = jobs[id] else { cont.finish(); return stream }
        cont.yield(j.info)
        if j.info.state.isTerminal { cont.finish(); return stream }
        addListener(job: id, cont)
        return stream
    }

    /// Updates for every job.
    public func updates() -> AsyncStream<ProxyJobInfo> {
        let (stream, cont) = AsyncStream.makeStream(of: ProxyJobInfo.self, bufferingPolicy: .bufferingNewest(256))
        addListener(job: nil, cont)
        return stream
    }

    private func addListener(job: ProxyJobID?, _ cont: AsyncStream<ProxyJobInfo>.Continuation) {
        let lid = UUID()
        listeners[lid] = (job, cont)
        cont.onTermination = { [weak self] _ in Task { await self?.removeListener(lid) } }
    }
    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func publish(_ id: ProxyJobID) {
        guard let info = jobs[id]?.info else { return }
        for (lid, l) in listeners where l.job == nil || l.job == id {
            l.cont.yield(info)
            if l.job == id, info.state.isTerminal { l.cont.finish(); listeners[lid] = nil }
        }
    }

    private func startNext() {
        var running = jobs.values.filter { $0.info.state == .running }.count
        // Higher priority first; stable within a priority (FIFO).
        let candidates = order.enumerated().sorted {
            let (a, b) = (jobs[$0.element]?.info.priority ?? .background, jobs[$1.element]?.info.priority ?? .background)
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        for id in candidates where running < concurrency {
            guard var j = jobs[id], j.info.state == .queued else { continue }
            j.info.state = .running
            let (source, kind, fp) = (j.info.source, j.info.kind, j.fingerprint)
            j.task = Task(priority: j.info.priority.taskPriority) { [weak self] in await self?.run(id, source: source, kind: kind, fingerprint: fp) }
            jobs[id] = j
            publish(id)
            running += 1
        }
    }

    private func setProgress(_ id: ProxyJobID, _ p: Double) {
        guard var j = jobs[id], j.info.state == .running else { return }
        j.info.progress = min(1, max(j.info.progress, p))
        jobs[id] = j; publish(id)
    }

    private func run(_ id: ProxyJobID, source: URL, kind: ProxyKind, fingerprint: SourceFingerprint) async {
        let partial = cache.partialURL(fingerprint: fingerprint, kind: kind)
        try? FileManager.default.removeItem(at: partial)
        let result: Result<ProxyRecord, any Error>
        do {
            let out = try await transcoder.transcode(source: source, kind: kind, destination: partial, timeRange: nil) { [weak self] p in
                Task { await self?.setProgress(id, p) }
            }
            try Task.checkCancellation()
            if jobs[id]?.cancelRequested == true { throw CancellationError() }
            let rec = ProxyRecord(fingerprint: fingerprint, kind: kind,
                                  fileName: ProxyCache.fileName(for: fingerprint, kind: kind),
                                  dimensions: out.dimensions, createdAt: Date(), sourceDuration: out.sourceDuration)
            try cache.commit(partial: partial, record: rec)
            result = .success(rec)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            result = .failure(error)
        }
        guard var j = jobs[id] else { return }
        j.task = nil
        switch result {
        case .success(let rec):
            j.info.state = .done(rec); j.info.progress = 1
            cache.enforceCap(protecting: [ProxyRecordID(rec)])
        case .failure(let e):
            j.info.state = (e is CancellationError || j.cancelRequested) ? .cancelled : .failed("\(e)")
        }
        jobs[id] = j
        publish(id)
        startNext()
    }
}
