import Foundation
import Testing
@testable import SQEditorSession

/// Stabilizer bug (2026-10-07): the Analyze row stayed at "0 %" with a Cancel that did nothing. The run lifecycle
/// (start, progress, cancel, failure) is tested here with injected work, no media or analyzer needed.
@MainActor @Suite struct AnalysisJobTests {
    @MainActor final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() { opened = true; waiting?.resume(); waiting = nil }
        var isWaiting: Bool { waiting != nil }
    }

    @MainActor final class Log {
        var progress: [Double] = []
        var endings: [String] = []
        func ended(_ e: AnalysisJobEnding<Int>) {
            switch e {
            case .done(let v): endings.append("done \(v)")
            case .cancelled: endings.append("cancelled")
            case .failed(let why): endings.append("failed \(why)")
            }
        }
    }

    private func until(_ ok: () -> Bool) async throws {
        for _ in 0..<500 where !ok() { try await Task.sleep(for: .milliseconds(2)) }
        #expect(ok())
    }

    @Test func runReportsProgressInWholePercentsThenTheOutcome() async throws {
        let job = AnalysisJob<Int>(), log = Log()
        let started = job.start({ progress in
            for p in [0.0, 0.001, 0.1, 0.104, 0.5, 1.0] {
                progress(p)
                try await Task.sleep(for: .milliseconds(5))
            }
            return 7
        }, progress: { log.progress.append($0) }, ended: log.ended)
        #expect(started && job.isRunning)
        // A second start while running does nothing.
        let second = job.start({ _ in 1 }, progress: { _ in }, ended: { _ in Issue.record("second run") })
        #expect(!second)
        try await until { !log.endings.isEmpty }
        #expect(log.endings == ["done 7"])
        #expect(log.progress == [0, 0.1, 0.5, 1])
        #expect(!job.isRunning)
    }

    @Test func cancelEndsTheRunAtOnceEvenWhenTheWorkIgnoresIt() async throws {
        let job = AnalysisJob<Int>(), log = Log(), gate = Gate()
        var lateProgress: (@Sendable (Double) -> Void)?
        job.start({ progress in
            lateProgress = progress
            await gate.wait()          // stuck work (e.g. a blocking read before its first frame)
            return 1
        }, progress: { log.progress.append($0) }, ended: log.ended)
        try await until { gate.isWaiting }
        job.cancel()
        #expect(log.endings == ["cancelled"])
        #expect(!job.isRunning)

        // A new run starts right away; the old run's late progress and result never reach it.
        let log2 = Log(), gate2 = Gate()
        let restarted = job.start({ progress in
            progress(0.3)
            await gate2.wait()
            return 2
        }, progress: { log2.progress.append($0) }, ended: log2.ended)
        #expect(restarted)
        lateProgress?(0.9)
        gate.open()
        try await until { log2.progress == [0.3] }
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.endings == ["cancelled"] && log.progress.isEmpty)
        #expect(log2.endings.isEmpty && log2.progress == [0.3] && job.isRunning)
        gate2.open()
        try await until { !log2.endings.isEmpty }
        #expect(log2.endings == ["done 2"])
        job.cancel()                   // idle: nothing
        #expect(log2.endings == ["done 2"])
    }

    @Test func aFailureIsReportedAsAFailureNotAsCancelled() async throws {
        struct Unreadable: LocalizedError { var errorDescription: String? { "The file could not be read." } }
        let job = AnalysisJob<Int>(), log = Log()
        job.start({ _ in throw Unreadable() }, progress: { _ in }, ended: log.ended)
        try await until { !log.endings.isEmpty }
        #expect(log.endings == ["failed The file could not be read."])
        #expect(!job.isRunning)
    }

    @Test func workThatStopsOnItsOwnCancellationEndsCancelledOnce() async throws {
        let job = AnalysisJob<Int>(), log = Log()
        job.start({ _ in
            try await Task.sleep(for: .seconds(30))
            return 1
        }, progress: { _ in }, ended: log.ended)
        try await Task.sleep(for: .milliseconds(10))
        job.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.endings == ["cancelled"])
    }
}
