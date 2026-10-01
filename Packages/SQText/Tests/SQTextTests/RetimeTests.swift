import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct RetimeTests {
    let popIn = CaptionPresetLibrary.builtIn.animation(for: "pop-in")   // 1/4 s, keys at 0, 1/8, 1/4

    @Test func scalesKeyTimesProportionallyAndExactly() {
        let r = popIn.retimed(toDuration: Time(1, 3))
        #expect(r.duration == Time(1, 3))
        #expect(r.track(for: "opacity")!.track.keys.map(\.time) == [.zero, Time(1, 6), Time(1, 3)])
        #expect(r.track(for: "scale")!.track.keys.map(\.time) == [.zero, Time(1, 3)])
        // 1/3 of 3/7 -> exact rational, no rounding.
        let odd = KeyframeTemplate(tracks: [AnimationTrack(property: "p", keys: [(.zero, 0, .linear), (Time(1, 3), 1, .linear), (Time(1, 1), 2, .linear)])],
                                   duration: Time(1, 1)).retimed(toDuration: Time(3, 7))
        #expect(odd.track(for: "p")!.track.keys.map(\.time) == [.zero, Time(1, 7), Time(3, 7)])
    }

    @Test func keepsValuesShapesIdsAnchorAndNormalizedEvaluation() {
        var out = CaptionPresetLibrary.builtIn.animation(for: "fade-out")
        out = out.retimed(toDuration: Time(2, 5))
        #expect(out.anchor == .end)
        let fadeOut = CaptionPresetLibrary.builtIn.animation(for: "fade-out")
        #expect(out.tracks[0].track.keys.map(\.id) == fadeOut.tracks[0].track.keys.map(\.id))
        let r = popIn.retimed(toDuration: Time(1, 2))
        // Same curve, stretched: value at half the time equals the original's value at half its time.
        for f: Int64 in [0, 1, 3, 5, 8] {
            let a = popIn.value(of: "scale", at: Time(popIn.duration.value * f, popIn.duration.timescale * 8))!
            let b = r.value(of: "scale", at: Time(r.duration.value * f, r.duration.timescale * 8))!
            #expect(abs(a - b) < 1e-12)
        }
    }

    @Test func identityAndRoundTrip() {
        #expect(popIn.retimed(toDuration: popIn.duration) == popIn)
        #expect(popIn.retimed(toDuration: Time(3, 4)).retimed(toDuration: popIn.duration) == popIn)
    }

    @Test func zeroTargetDuration() {
        let r = popIn.retimed(toDuration: .zero)
        #expect(r.duration == .zero)
        #expect(r.tracks.allSatisfy { $0.track.keys.allSatisfy { $0.time == .zero } && $0.track.keys.count == 1 })
        #expect(r.value(of: "opacity", at: .zero) == 1)          // collapsed to the final key
        #expect(popIn.retimed(toDuration: Time(-1, 2)).duration == .zero)   // negative treated as zero
    }

    @Test func zeroSourceDuration() {
        let r = KeyframeTemplate.none.retimed(toDuration: Time(1, 2))
        #expect(r.duration == Time(1, 2) && r.tracks.isEmpty)
        let flat = KeyframeTemplate(tracks: [AnimationTrack(property: "p", keys: [(.zero, 4, .hold)])], duration: .zero)
        let f = flat.retimed(toDuration: Time(1, 2))
        #expect(f.duration == Time(1, 2) && f.track(for: "p")!.track.keys.map(\.time) == [.zero])
    }

    @Test func anchoredPlaybackDoesNotUseRetiming() {
        // Resolving never changes the template's duration: the out-animation keeps its own length on any clip.
        let out = CaptionPresetLibrary.builtIn.animation(for: "fade-out")
        for clip in [Time(1, 1), Time(60, 1)] {
            #expect(out.resolved(clipDuration: clip)[0].track.keys.first?.time == clip - out.duration)
        }
    }

    @Test func extremeRetimeNeverTraps() {
        let big = Int64.max - 1
        // Huge ratio: key times far beyond Int64 clamp to Int64.max seconds.
        let t = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(Time(1, 1), 1.0, .linear)])],
                                 duration: Time(1, 1_000_000_000))
        let r = t.retimed(toDuration: Time(big, 1))
        #expect(r.track(for: "opacity")!.track.keys[0].time == Time(Int64.max, 1))
        // Coprime huge scales: approximated, finite, positive.
        let r2 = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(Time(big, 3), 1.0, .linear)])],
                                  duration: Time(big, 7)).retimed(toDuration: Time(big - 2, 11))
        #expect(r2.track(for: "opacity")!.track.keys[0].time > .zero)
    }
}
