import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

// Channels (v82): the scrub path `mix` folds Mono exactly like `renderBlock` (playback/export), so a Mono sequence scrubs mono.

private let rate: Int64 = 48_000

private func scrubbed(_ layout: ChannelLayout) -> (l: [Float], r: [Float]) {
    let m = UUID()
    let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)), start: .zero)
    var t = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .audio, clips: [c])])
    t.channelLayout = layout
    let src = MemoryAudioSource(left: [Float](repeating: 0.5, count: 30_000), right: [Float](repeating: 0, count: 30_000))
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
    var l = [Float](repeating: 9, count: 2048), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: 0, count: 2048, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
    return (l, r)
}

@Suite struct AudioFeederScrubMonoTests {
    @Test func monoScrubFoldsHardLeftToHalfOnBothSides() {
        let (l, r) = scrubbed(.mono)
        #expect(l == r)
        #expect(abs(l[100] - 0.25) < 1e-6)
    }
    @Test func stereoScrubIsUntouched() {
        let (l, r) = scrubbed(.stereo)
        #expect(abs(l[100] - 0.5) < 1e-6)
        #expect(r[100] == 0)
    }
}
