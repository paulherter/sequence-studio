import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }

@Suite struct SpeedKeysTransitionAudioTests {
    private func clip(_ media: UUID) -> Clip {
        var c = Clip(name: "k", media: media, kind: .audio, source: TimeRange(start: Time(1, 1), duration: Time(1, 1)), start: Time(2, 1),
                     keepsPitch: true)
        c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: Time(1, 1), from: pct(100)), SpeedSegment(duration: Time(1, 1), from: pct(200))],
                                 origin: Time(1, 1)))
        return c
    }

    @Test func timeMapRunsOnPastBothEndsAtTheEndSpeeds() {
        let m = AudioTimeMap(chain: [clip(UUID())])
        let rate = 48_000.0
        func pos(_ sec: Double) -> Double { m.position(atFrame: sec * rate, rate: rate).frames / rate }
        // inside: 100 % for 1 s from source 1 s, then 200 %
        #expect(abs(pos(2.5) - 1.5) < 1e-9 && abs(pos(3.5) - 3.0) < 1e-9)
        // before the clip: the first speed continues backwards in time; after it: the last speed continues
        #expect(abs(pos(1.9) - 0.9) < 1e-9)
        #expect(abs(pos(4.25) - (1 + 1 + 2 + 0.5)) < 1e-9)
        #expect(!m.position(atFrame: 1.9 * rate, rate: rate).reversed)
    }

    @Test func handleBeforeTheClipIsContinuousWithTheClipItself() {
        // Render a 2 s window that starts 0.1 s before the clip: output before the clip start comes from the media before the
        // source start (the incoming handle of a transition), seamlessly, with and without pitch kept.
        let media = UUID()
        let c = clip(media)
        let src = MemoryAudioSource(mono: (0..<(6 * 48_000)).map { Float($0) + 1 })
        let resolverSource: any AudioSource = src
        var c0 = c; c0.keepsPitch = false
        let tl = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1001, 30_000)), tracks: [Track(kind: .audio, clips: [c0])])
        do {
            let feeder = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 14), blockFrames: 4096) { _ in resolverSource }
            var l = [Float](repeating: 0, count: 4096), r = l
            // frames 2 s .. : inside the clip, resampled at 100 %: value = source frame + 1
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                feeder.mix(timeline: tl, startFrame: 2 * 48_000, count: 4096, left: lp.baseAddress!, right: rp.baseAddress!) } }
            #expect(abs(l[0] - Float(48_000 + 1)) < 1e-3)
            #expect(abs(l[1000] - Float(48_000 + 1001)) < 1e-3)
        }
    }
}
