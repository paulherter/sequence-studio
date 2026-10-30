import Foundation
import Observation
import SQProxy

/// One running background job as the task popover shows it.
public struct BackgroundJob: Identifiable, Sendable {
    public enum Kind: Sendable { case export, proxy, transcription, other }
    public let id: String
    public let kind: Kind
    public var title: String
    /// 0...1, nil while unknown.
    public var progress: Double?
    public let cancel: @MainActor @Sendable () -> Void
    public init(id: String, kind: Kind, title: String, progress: Double?, cancel: @escaping @MainActor @Sendable () -> Void) {
        self.id = id; self.kind = kind; self.title = title; self.progress = progress; self.cancel = cancel
    }
}

/// Anything that runs work in the background (stabilizer, reframe and mask tracking plug in through this).
@MainActor
public protocol BackgroundJobSource: AnyObject {
    /// The jobs that are queued or running right now.
    func currentJobs() async -> [BackgroundJob]
}

/// Lists the running background jobs of all sources (exports, proxies, transcription, ...), Premiere-like.
@MainActor
@Observable
public final class JobCenter {
    public private(set) var jobs: [BackgroundJob] = []
    @ObservationIgnored private var sources: [any BackgroundJobSource] = []
    @ObservationIgnored private var poll: Task<Void, Never>?

    public init() {}

    public func register(_ source: any BackgroundJobSource) { sources.append(source) }

    public var hasActiveJobs: Bool { !jobs.isEmpty }
    /// Jobs that are not exports (exports have their own list with Reveal and Clear Finished).
    public var otherJobs: [BackgroundJob] { jobs.filter { $0.kind != .export } }

    /// Mean progress over the jobs that report one (0 while none does); nil when nothing runs.
    public var overallProgress: Double? {
        guard !jobs.isEmpty else { return nil }
        let known = jobs.compactMap(\.progress)
        return known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
    }

    public func refresh() async {
        var all: [BackgroundJob] = []
        for s in sources { all += await s.currentJobs() }
        let same = all.map(\.id) == jobs.map(\.id) && all.map(\.progress) == jobs.map(\.progress) && all.map(\.title) == jobs.map(\.title)
        if !same { jobs = all }
    }

    public func cancel(_ id: String) {
        jobs.first { $0.id == id }?.cancel()
    }

    /// Polls while started (the status ring is showing); stops with `stopPolling`.
    public func startPolling(interval: Duration = .seconds(1)) {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() { poll?.cancel(); poll = nil }
}

/// Proxy and optimized-media jobs of the `ProxyQueue`.
@MainActor
public final class ProxyJobSource: BackgroundJobSource {
    private let queue: ProxyQueue
    public init(queue: ProxyQueue) { self.queue = queue }

    public func currentJobs() async -> [BackgroundJob] {
        let q = queue
        return await q.allJobs().compactMap { info in
            switch info.state {
            case .queued, .running: break
            default: return nil
            }
            let what = info.kind == .optimized ? "Optimized media" : "Proxy"
            let id = info.id
            return BackgroundJob(id: "proxy-\(id)", kind: .proxy,
                                 title: SQL10n.format("%@: %@", SQL10n.string(what), info.source.lastPathComponent),
                                 progress: info.state == .running ? info.progress : 0,
                                 cancel: { Task { await q.cancel(id) } })
        }
    }
}

/// Exports from the export queue (waiting and running).
@MainActor
public final class ExportJobSource: BackgroundJobSource {
    private let model: ExportQueueModel
    public init(model: ExportQueueModel) { self.model = model }

    public func currentJobs() async -> [BackgroundJob] {
        let m = model
        return m.jobs.compactMap { row in
            switch row.state {
            case .waiting, .running: break
            default: return nil
            }
            let id = row.id
            return BackgroundJob(id: "export-\(id)", kind: .export, title: SQL10n.format("Export: %@", row.name),
                                 progress: row.state == .running ? row.progress : 0,
                                 cancel: { m.cancel(id) })
        }
    }
}

/// The auto-caption transcription of the open sequence.
@MainActor
public final class TranscriptionJobSource: BackgroundJobSource {
    private let model: @MainActor () -> CaptionsPanelModel?
    public init(model: @escaping @MainActor () -> CaptionsPanelModel?) { self.model = model }

    public func currentJobs() async -> [BackgroundJob] {
        guard let m = model(), case .transcribing(let p) = m.state else { return [] }
        return [BackgroundJob(id: "transcription", kind: .transcription, title: SQL10n.string("Transcribing speech"),
                              progress: p, cancel: { [weak m] in m?.cancelTranscription() })]
    }
}

/// Conform to Constant Frame Rate runs of the Project panel.
@MainActor
public final class ConformJobSource: BackgroundJobSource {
    private let runner: ConformRunner
    public init(runner: ConformRunner) { self.runner = runner }

    public func currentJobs() async -> [BackgroundJob] {
        let r = runner
        return r.runs.map { run in
            let id = run.id
            return BackgroundJob(id: "conform-\(id)", kind: .other, title: run.title, progress: run.progress,
                                 cancel: { r.cancel(id) })
        }
    }
}
