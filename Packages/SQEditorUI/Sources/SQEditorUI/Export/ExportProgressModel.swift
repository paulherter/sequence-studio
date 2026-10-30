import Foundation
import SQExport

/// State of one export progress window. Pure (no AppKit): the view reads it, the controller feeds it job rows and a clock.
public struct ExportProgressModel: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case running
        case confirmingCancel
        /// Stop confirmed, waiting for the job to wind down: no buttons, cannot flip back.
        case stopping
        case done(URL)
        case failed(String)
        case cancelled
    }

    public let jobID: UUID
    public let name: String
    public private(set) var outputURL: URL
    public private(set) var stage: Stage = .running
    public private(set) var tracker = ExportProgressTracker()
    public private(set) var isRunning = false
    private var startTime: Double?
    private var now: Double = 0
    private var finishedAt: Double?

    /// Seconds the "Done" state stays before the window closes itself (the maintainer's default: 1 s).
    public static let autoCloseDelay = 1.0

    public init(jobID: UUID, name: String, outputURL: URL) {
        self.jobID = jobID; self.name = name; self.outputURL = outputURL
    }

    /// Feeds one snapshot of the job and the current time (seconds, monotonic).
    public mutating func update(state: ExportJobState, progress: Double, outputURL: URL, now t: Double) {
        now = t
        self.outputURL = outputURL
        if startTime == nil { startTime = t }
        switch state {
        case .waiting: isRunning = false
        case .running:
            isRunning = true
            tracker.record(progress: progress, at: t)
        case .done(let url):
            tracker.record(progress: 1, at: t)
            setFinal(.done(url), at: t)
        case .failed(let m): setFinal(.failed(m), at: t)
        case .cancelled: setFinal(.cancelled, at: t)
        }
    }

    private mutating func setFinal(_ s: Stage, at t: Double) {
        if finishedAt == nil { finishedAt = t }
        stage = s
    }

    /// Clock tick without new job data (elapsed time keeps counting).
    public mutating func tick(now t: Double) { now = t }

    // MARK: Derived

    public var isFinished: Bool {
        switch stage { case .done, .failed, .cancelled: true; default: false }
    }
    public var fraction: Double { tracker.progress }
    public var percentText: String { "\(Int((fraction * 100).rounded(.down)))%" }
    public var phase: ExportProgressTracker.Phase { ExportProgressTracker.phase(progress: fraction, running: isRunning) }
    public var phaseText: String {
        switch stage {
        case .done: SQL10n.string("Done")
        case .failed: SQL10n.string("Export failed")
        case .cancelled: SQL10n.string("Export stopped")
        case .stopping: SQL10n.string("Stopping…")
        default: SQL10n.string(phase.title)
        }
    }
    public var elapsed: Double { max((finishedAt ?? now) - (startTime ?? now), 0) }
    public var elapsedText: String { SQL10n.format("%@ elapsed", ExportProgressTracker.format(seconds: elapsed)) }
    public var remainingText: String {
        isFinished ? "" : SQL10n.localized(ExportProgressTracker.remainingText(isRunning ? tracker.remaining : nil))
    }
    public var errorText: String? { if case .failed(let m) = stage { SQL10n.localized(m) } else { nil } }
    public var title: String { SQL10n.string("Exporting") }
    public var dockFraction: Double { fraction }

    /// A successful export closes the window by itself after `autoCloseDelay`; a failure or stop stays until closed.
    public func shouldAutoClose(now t: Double) -> Bool {
        guard case .done = stage, let f = finishedAt else { return false }
        return t - f >= Self.autoCloseDelay
    }

    // MARK: Cancel flow (inline confirmation, no system alert)

    public mutating func requestCancel() { if stage == .running { stage = .confirmingCancel } }
    public mutating func confirmCancel() { if stage == .confirmingCancel { stage = .stopping } }
    public mutating func keepExporting() { if stage == .confirmingCancel { stage = .running } }
    public var cancelPrompt: String { SQL10n.string("Stop the export? The partial file is deleted.") }
}
