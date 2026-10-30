import AppKit
import Observation
import SQCore
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
        public var loudness: LoudnessReport?
        public init(id: UUID, name: String, state: ExportJobState, progress: Double, outputURL: URL,
                    loudness: LoudnessReport? = nil) {
            self.id = id; self.name = name; self.state = state; self.progress = progress; self.outputURL = outputURL
            self.loudness = loudness
        }
        init(_ s: ExportJobStatus) {
            self.init(id: s.id, name: s.name, state: s.state, progress: s.progress, outputURL: s.outputURL, loudness: s.loudness)
        }
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
        let before = jobs.first(where: { $0.id == s.id })?.state
        if before != s.state {
            switch s.state {
            case .waiting: SQLog.info("export queued: \(s.name)")
            case .running: SQLog.info("export start: \(s.name) -> \(s.outputURL.path)")
            case .done(let url): SQLog.info("export ok: \(s.name) -> \(url.path)")
            case .failed(let m): SQLog.error("export failed: \(s.name): \(m)")
            case .cancelled: SQLog.info("export canceled: \(s.name)")
            }
        }
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

    /// Result line for a finished export that normalized loudness; nil otherwise.
    public static func loudnessText(_ r: LoudnessReport?) -> String? {
        guard let r else { return nil }
        guard r.measuredLUFS.isFinite else { return SQL10n.string("Audio is silent, loudness unchanged") }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let gain = (r.gainDB >= 0 ? "+" : "") + f(r.gainDB)
        var s = SQL10n.format("%@ LUFS, %@ dBTP (gain %@ dB", f(r.outputLUFS), f(r.outputTruePeakDB), gain)
        if r.limiterUsed { s += SQL10n.format(", peak limiter at %@ dBTP ceiling)", f(r.ceilingDB)) }
        else { s += r.limitedByCeiling ? SQL10n.format(", limited by %@ dBTP ceiling)", f(r.ceilingDB)) : ")" }
        if let v = r.verified, v.integratedLUFS.isFinite {
            s += SQL10n.format("; in the file %@ LUFS, %@ dBTP", f(v.integratedLUFS), f(v.truePeakDB))
            if let o = r.overshootDB { s += SQL10n.format(", %@ dB above the ceiling", f(o)) }
        }
        return s
    }

    public static func stateText(_ s: ExportJobState) -> String {
        switch s {
        case .waiting: SQL10n.string("Waiting")
        case .running: SQL10n.string("Exporting")
        case .done: SQL10n.string("Done")
        case .cancelled: SQL10n.string("Stopped")
        case .failed(let m): SQL10n.format("Failed: %@", SQL10n.localized(m))
        }
    }

    // MARK: Actions

    public func cancel(_ id: UUID) { let q = queue; Task { await q.cancel(id) } }
    public func reveal(_ s: Row) {
        if case .done(let url) = s.state { revealHandler(url) }
    }
    public func clearFinished() { jobs.removeAll { Self.isFinished($0.state) } }
}
