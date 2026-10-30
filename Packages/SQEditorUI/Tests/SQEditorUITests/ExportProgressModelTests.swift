import Foundation
import Testing
import SQExport
@testable import SQEditorUI
@testable import SQInspectorUI

@Suite struct ExportProgressModelTests {
    let url = URL(fileURLWithPath: "/tmp/out.mp4")
    func make() -> ExportProgressModel { ExportProgressModel(jobID: UUID(), name: "out", outputURL: url) }

    @Test func waitingIsPreparing() {
        var m = make()
        m.update(state: .waiting, progress: 0, outputURL: url, now: 0)
        #expect(m.phaseText == "Preparing")
        #expect(m.remainingText == "Calculating…")
        #expect(m.percentText == "0%")
    }

    @Test func runningShowsPercentElapsedAndEta() {
        var m = make()
        for s in 0...30 { m.update(state: .running, progress: Double(s) / 100, outputURL: url, now: Double(s)) }
        #expect(m.percentText == "30%")
        #expect(m.elapsedText == "0:30 elapsed")
        #expect(m.remainingText == "1:10 left")
        #expect(m.phaseText == "Rendering and encoding")
    }

    @Test func elapsedKeepsCountingOnTick() {
        var m = make()
        m.update(state: .running, progress: 0, outputURL: url, now: 5)
        m.tick(now: 12)
        #expect(m.elapsedText == "0:07 elapsed")
    }

    @Test func successAutoClosesAfterOneSecond() {
        var m = make()
        m.update(state: .running, progress: 0.5, outputURL: url, now: 0)
        m.update(state: .done(url), progress: 1, outputURL: url, now: 4)
        #expect(m.stage == .done(url) && m.isFinished)
        #expect(m.percentText == "100%")
        #expect(m.elapsedText == "0:04 elapsed")
        #expect(!m.shouldAutoClose(now: 4.5))
        #expect(m.shouldAutoClose(now: 5.0))
        m.tick(now: 60)
        #expect(m.elapsedText == "0:04 elapsed")   // frozen at the finish
    }

    @Test func failureStaysOpenWithErrorText() {
        var m = make()
        m.update(state: .running, progress: 0.2, outputURL: url, now: 0)
        m.update(state: .failed("Disk full"), progress: 0.2, outputURL: url, now: 3)
        #expect(m.errorText == "Disk full")
        #expect(!m.shouldAutoClose(now: 100))
        #expect(m.phaseText == "Export failed")
    }

    @Test func cancelNeedsConfirmationAndCanBeUndone() {
        var m = make()
        m.update(state: .running, progress: 0.2, outputURL: url, now: 0)
        m.requestCancel()
        #expect(m.stage == .confirmingCancel)
        m.update(state: .running, progress: 0.3, outputURL: url, now: 1)   // keeps asking while progress flows
        #expect(m.stage == .confirmingCancel)
        m.keepExporting()
        #expect(m.stage == .running)
        m.requestCancel()
        m.update(state: .cancelled, progress: 0.3, outputURL: url, now: 2)
        #expect(m.stage == .cancelled && m.isFinished && !m.shouldAutoClose(now: 99))
    }

    @Test func stoppingCannotFlipBackAndEndsCancelled() {
        var m = make()
        m.update(state: .running, progress: 0.2, outputURL: url, now: 0)
        m.requestCancel(); m.confirmCancel()
        #expect(m.stage == .stopping)
        m.keepExporting(); m.requestCancel()
        #expect(m.stage == .stopping)
        m.update(state: .running, progress: 0.3, outputURL: url, now: 1)
        #expect(m.stage == .stopping && m.phaseText == "Stopping…")
        m.update(state: .cancelled, progress: 0.3, outputURL: url, now: 2)
        #expect(m.stage == .cancelled)
    }

    @Test func requestCancelIgnoredAfterFinish() {
        var m = make()
        m.update(state: .done(url), progress: 1, outputURL: url, now: 1)
        m.requestCancel()
        #expect(m.stage == .done(url))
    }
}
