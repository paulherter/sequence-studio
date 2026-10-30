import Foundation
import Testing
@testable import SQPlayback

/// On-glass frame timing (EngineBench `project-play --window`).
@Suite struct PresentProbeTests {
    private let fd = 1.0 / 30

    private func sample(_ frame: Int, at t: Double, target: Double? = nil) -> PresentProbe.Sample {
        .init(time: Double(frame) * fd, target: target ?? t, presented: t)
    }

    @Test func evenCadenceHasNoLateOrSkippedFrames() {
        let s = (0..<10).map { sample($0, at: 100 + Double($0) * fd) }
        let r = PresentProbe.summarize(s, frameDuration: fd)
        #expect(r.frames == 10 && r.neverShown == 0 && r.late == 0 && r.skipped == 0)
        #expect(r.intervals.count == 9)
        #expect(abs(r.percentile(0.5, of: r.intervals) - 33.333) < 0.01)
        #expect(abs(r.percentile(0.99, of: r.intervals) - 33.333) < 0.01)
    }

    @Test func aFrameThatStaysTwoFramesIsLateAndTheJumpCountsSkipped() {
        // Frame 2 stays for two frames, then the playhead shows frame 4: one late interval, one skipped frame.
        let s = [sample(0, at: 0.1), sample(1, at: 0.1 + fd), sample(2, at: 0.1 + 2 * fd), sample(4, at: 0.1 + 4 * fd)]
        let r = PresentProbe.summarize(s, frameDuration: fd)
        #expect(r.late == 1)
        #expect(r.skipped == 1)
        #expect(abs((r.intervals.last ?? 0) - 66.667) < 0.01)
    }

    @Test func oneRefreshOfJitterIsNotLate() {
        // 30 fps on a 120 Hz panel: a frame one refresh (8.3 ms) late is jitter, not a late frame.
        let s = [sample(0, at: 0.1), sample(1, at: 0.1 + fd + 1.0 / 120), sample(2, at: 0.1 + 2 * fd)]
        #expect(PresentProbe.summarize(s, frameDuration: fd).late == 0)
    }

    @Test func framesThatNeverReachedTheGlassAreCountedApart() {
        let s = [sample(0, at: 0.1), .init(time: fd, target: 0.1 + fd, presented: 0), sample(2, at: 0.1 + 2 * fd)]
        let r = PresentProbe.summarize(s, frameDuration: fd)
        #expect(r.neverShown == 1)
        #expect(r.intervals.count == 1 && r.late == 1 && r.skipped == 1)
    }

    @Test func offsetIsGlassTimeMinusTheAskedTime() {
        let s = [sample(0, at: 0.110, target: 0.100), sample(1, at: 0.140, target: 0.1333)]
        let r = PresentProbe.summarize(s, frameDuration: fd)
        #expect(abs(r.offsets[0] - 6.7) < 0.01 && abs(r.offsets[1] - 10) < 0.01)
    }

    @Test func slotRecordsOnceBothHalvesArrivedInEitherOrder() {
        let p = PresentProbe()
        let a = PresentProbe.Slot(p)
        a.commit(.init(time: 0, target: 1, presented: 0)); #expect(p.take(reset: false).isEmpty)
        a.presented(at: 1.01); a.presented(at: 9)
        let b = PresentProbe.Slot(p)
        b.presented(at: 1.05); b.commit(.init(time: fd, target: 1.04, presented: 0))
        let c = PresentProbe.Slot(p)                       // the tick presented nothing
        c.discard(); c.presented(at: 2); c.commit(.init(time: 1, target: 2, presented: 0))
        #expect(p.take().map(\.presented) == [1.01, 1.05])
        #expect(p.take().isEmpty)
    }
}
