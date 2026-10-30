import Foundation
import Testing
import SQCore
@testable import SQPlayback

/// Q-PERF2 rec 1: display-link rate locked to the sequence rate while playing.
@Suite struct FramePacingTests {
    private func valid(_ r: FramePacing.Range) -> Bool { r.minimum <= r.preferred && r.preferred <= r.maximum && r.minimum > 0 }

    @Test func pausedOrScrubbingIsInteractive() {
        #expect(FramePacing.range(fps: 25, rate: .zero, scrubbing: false) == FramePacing.interactive)
        #expect(FramePacing.range(fps: 25, rate: .forward, scrubbing: true) == FramePacing.interactive)
        #expect(FramePacing.interactive == FramePacing.Range(minimum: 60, maximum: 120, preferred: 120))
    }

    @Test func playingLocksToSequenceRate() {
        #expect(FramePacing.range(fps: 30, rate: .forward, scrubbing: false) == .init(minimum: 30, maximum: 60, preferred: 30))
        #expect(FramePacing.range(fps: 25, rate: .forward, scrubbing: false) == .init(minimum: 25, maximum: 50, preferred: 25))
        #expect(FramePacing.range(fps: 24, rate: .reverse, scrubbing: false) == .init(minimum: 24, maximum: 48, preferred: 24))
        let r = FramePacing.range(fps: 60, rate: .forward, scrubbing: false)
        #expect(r == .init(minimum: 60, maximum: 60, preferred: 60))
    }

    @Test func fastShuttleShowsMoreFramesUpTo120() {
        #expect(FramePacing.range(fps: 30, rate: PlaybackRate(2), scrubbing: false) == .init(minimum: 60, maximum: 60, preferred: 60))
        #expect(FramePacing.range(fps: 30, rate: PlaybackRate(8), scrubbing: false) == FramePacing.interactive)
    }

    @Test func slowMotionStaysAtSequenceRate() {
        #expect(FramePacing.range(fps: 30, rate: PlaybackRate(1, 2), scrubbing: false).preferred == 30)
    }

    @Test func rangesAreAlwaysValid() {
        for fps in [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 120, 240, 0.5] {
            for rate in [PlaybackRate.zero, .forward, .reverse, PlaybackRate(2), PlaybackRate(-4), PlaybackRate(1, 4), PlaybackRate(32)] {
                #expect(valid(FramePacing.range(fps: fps, rate: rate, scrubbing: false)), "fps \(fps) rate \(rate)")
            }
        }
    }

    @Test func pacingMeterSpread() {
        var m = PacingMeter(window: 4)
        #expect(m.spreadMilliseconds == nil)
        for t in [0.0, 1.0 / 30, 2.0 / 30, 3.0 / 30] { m.record(t) }
        #expect(abs(m.spreadMilliseconds! - 0) < 0.01)
        m.record(3.0 / 30 + 1.0 / 60)                    // one short interval (2:3 cadence)
        #expect(abs(m.spreadMilliseconds! - (1000.0 / 30 - 1000.0 / 60)) < 0.01)
        m.reset()
        #expect(m.spreadMilliseconds == nil)
    }
}
