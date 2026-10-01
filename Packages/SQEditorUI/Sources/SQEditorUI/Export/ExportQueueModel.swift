import AppKit
import Observation
import SQExport

/// Mirrors `ExportQueue` for the UI (docs/UX.md 4.6: progress ring + popover list).
@MainActor @Observable
public final class ExportQueueModel {
    /// UI copy of `ExportJobStatus` (whose initializer is internal to SQExport).
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var state: ExportJobState
        public var progress: Double
        public var outputURL: URL
        public init(id: UUID, name: String, state: ExportJobState, progress: Double, outputURL: URL) {
            self.id = id; self.name = name; self.state = state; self.progress = progress; self.outputURL = outputURL
        }
        init(_ s: ExportJobStatus) { self.init(id: s.id, name: s.name, state: s.state, progress: s.progress, outputURL: s.outputURL) }
    }

    public private(set) var jobs: [Row] = []
    @ObservationIgnored private let queue: ExportQueue
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let revealHandler: @MainActor (URL) -> Void

    public init(queue: ExportQueue,
                reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.queue = queue
        self.revealHandler = reveal
    }

    public func start() {
        guard task == nil else { return }
        let queue = self.queue
        task = Task { [weak self] in
            let stream = await queue.updates()
            for s in await queue.allStatuses() { self?.applyIfNew(Row(s)) }
            for await u in stream { self?.apply(Row(u)) }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    func apply(_ s: Row) {
        if let i = jobs.firstIndex(where: { $0.id == s.id }) { jobs[i] = s } else { jobs.append(s) }
    }
    private func applyIfNew(_ s: Row) {
        if !jobs.contains(where: { $0.id == s.id }) { jobs.append(s) }
    }

    // MARK: Derived

    static func isActive(_ s: ExportJobState) -> Bool { s == .waiting || s == .running }
    static func isFinished(_ s: ExportJobState) -> Bool { !isActive(s) }

    public var activeCount: Int { jobs.filter { Self.isActive($0.state) }.count }
    public var hasActiveJobs: Bool { activeCount > 0 }

    /// 0...1 over all jobs that can still finish or did (stopped and failed jobs are left out).
    public var overallProgress: Double {
        let relevant = jobs.filter { s in
            switch s.state { case .cancelled, .failed: false; default: true }
        }
        guard !relevant.isEmpty else { return 0 }
        let sum = relevant.reduce(0.0) { acc, s in
            if case .done = s.state { acc + 1 } else { acc + s.progress }
        }
        return sum / Double(relevant.count)
    }

    public static func stateText(_ s: ExportJobState) -> String {
        switch s {
        case .waiting: "Waiting"
        case .running: "Exporting"
        case .done: "Done"
        case .cancelled: "Stopped"
        case .failed(let m): "Failed: \(m)"
        }
    }

    // MARK: Actions

    public func cancel(_ id: UUID) { let q = queue; Task { await q.cancel(id) } }
    public func reveal(_ s: Row) {
        if case .done(let url) = s.state { revealHandler(url) }
    }
    public func clearFinished() { jobs.removeAll { Self.isFinished($0.state) } }
}
