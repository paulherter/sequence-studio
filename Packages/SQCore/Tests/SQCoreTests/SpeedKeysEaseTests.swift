import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func secs(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

/// Ease in and out: flat at both ends (Premiere's default Bezier speed transition).
private let easeInOut = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.5, dy: 0), in: EaseHandle(dx: 0.5, dy: 0))
/// Asymmetric: slow start only.
private let easeOutOnly = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.6, dy: 0), in: .linear)

/// 1 s at 100 %, a 2 s ramp 100 % -> 300 %, 1 s at 300 %.
private func ramped(_ ease: EaseShape? = nil, reversed: Bool = false) -> SpeedKeys {
    var k = SpeedKeys(segments: [SpeedSegment(duration: f(30), from: pct(100), reversed: reversed),
                                 SpeedSegment(duration: f(60), from: pct(100), to: pct(300), reversed: reversed),
                                 SpeedSegment(duration: f(30), from: pct(300), reversed: reversed)],
                      origin: reversed ? Time(20, 1) : f(60))
    if let ease { k = k.settingEase(ease, ofSegment: 1)! }
    return k
}

@Suite struct SpeedKeysEaseTests {
    @Test func linearEaseIsTheStoredDefault() {
        let k = ramped()
        #expect(k.segments[1].ease == nil)
        #expect(k.settingEase(.linear, ofSegment: 1) == k)
        #expect(k.settingEase(.hold, ofSegment: 1) == k)                    // a speed ramp cannot hold
        #expect(k.settingEase(easeInOut, ofSegment: 0) == nil)              // not a ramp
        #expect(k.ease(ofSegment: 1) == .linear)
        let e = ramped(easeInOut)
        #expect(e.ease(ofSegment: 1).isApproximatelyEqual(to: easeInOut, tolerance: 1e-3))
        #expect(e.settingEase(.linear, ofSegment: 1) == k)                  // back to linear equals untouched
    }

    @Test func symmetricEaseKeepsSpanDurationAndEndpointsExactly() {
        let lin = ramped(), e = ramped(easeInOut)
        #expect(e.duration == lin.duration)
        #expect(e.segments[1].span == Time(4, 1))                           // T (a + b) / 2, exact
        #expect(e.boundaryPositions == lin.boundaryPositions)
        #expect(e.position(at: f(30)) == f(60) + Time(1, 1))
        #expect(e.position(at: f(90)) == f(60) + Time(5, 1))
        #expect(e.endPosition == lin.endPosition)
        // Speed is a at the start, b at the end of the transition, and continuous with the neighbors.
        #expect(abs(e.speedValue(at: f(30)) - 1) < 1e-9)
        #expect(abs(e.segments[1].speedValue(at: f(60)) - 3) < 1e-9)
    }

    @Test func easedSpeedStartsFlatAndPositionsLagTheLinearRamp() {
        let lin = ramped(), e = ramped(easeInOut)
        // A quarter into the ramp the eased speed is lower than the linear one (flat start) ...
        #expect(e.speedValue(at: f(45)) < lin.speedValue(at: f(45)) - 0.05)
        // ... so the eased track is behind until the middle, then catches up (same total).
        #expect(e.position(at: f(45)) < lin.position(at: f(45)))
        #expect(e.position(at: f(60)) < lin.position(at: f(60)))
        #expect(e.speedValue(at: f(75)) > lin.speedValue(at: f(75)) + 0.05)   // faster in the second half
    }

    @Test func sourceTimeMappingIsMonotonicForwardAndReversed() {
        for shape in [easeInOut, easeOutOnly,
                      EaseShape(interpolation: .bezier, out: EaseHandle(dx: 1, dy: 0), in: EaseHandle(dx: 1, dy: 0))] {
            for rev in [false, true] {
                let k = ramped(shape, reversed: rev)
                var last = k.position(at: .zero)
                for i in 1...(120 * 8) {                                    // every 1/240 s
                    let p = k.position(at: Time(Int64(i), 240))
                    if rev { #expect(p < last) } else { #expect(p > last) }
                    last = p
                }
                // Speeds stay between the ramp's ends (no overshoot through zero).
                for i in 0...60 {
                    let v = k.segments[1].speedValue(at: f(Int64(i)))
                    #expect(v >= 1 - 1e-9 && v <= 3 + 1e-9)
                }
            }
        }
    }

    @Test func overshootingHandlesAreClampedSoTheSpeedNeverLeavesTheRamp() {
        let wild = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.4, dy: -2), in: EaseHandle(dx: 0.4, dy: 3))
        let k = ramped(wild)
        for i in 0...60 {
            let v = k.segments[1].speedValue(at: f(Int64(i)))
            #expect(v >= 1 - 1e-9 && v <= 3 + 1e-9)
        }
        #expect(k.segments[1].ease!.out.dy >= 0 && k.segments[1].ease!.in.dy >= 0)
        #expect(k.segments[1].ease!.out.dy <= 1 && k.segments[1].ease!.in.dy <= 1)
    }

    @Test func asymmetricEaseChangesTheSpanAndTheTableStaysConsistent() {
        let e = ramped(easeOutOnly)
        let s = e.segments[1]
        // Slow start: less source than the linear 4 s, measured as the integral of speed (Simpson).
        let n = 600
        var sum = 0.0
        for i in 0...n {
            let w = i == 0 || i == n ? 1.0 : (i % 2 == 1 ? 4.0 : 2.0)
            sum += w * s.speedValue(at: Time(Int64(i) * 2, Int64(n)))
        }
        let integral = sum * (2.0 / Double(n)) / 3
        #expect(abs(secs(s.span) - integral) < 1e-6)
        #expect(secs(s.span) < 4 - 0.05)
        // The boundary table, the end of the ramp and the start of the next segment agree exactly.
        let b2 = e.boundaryPositions[2]
        #expect(e.position(at: f(90)) == b2)
        #expect(b2 == f(60) + Time(1, 1) + s.span)
        #expect(e.position(at: f(105)) == b2 + Time(3, 2))                  // 0.5 s at 300 %
        // Approaching the end from inside converges to the exact boundary.
        let near = e.position(at: f(90) - Time(1, 2400))
        #expect(near < b2 && secs(b2) - secs(near) < 0.0013)
        #expect(e.hull == TimeRange(start: f(60), end: e.endPosition))
    }

    @Test func approximationsAndInverseFollowTheEasedCurve() {
        let e = ramped(easeOutOnly)
        for i in stride(from: 0, through: 120, by: 7) {
            let t = f(Int64(i))
            #expect(abs(e.positionApprox(atSeconds: secs(t)) - secs(e.position(at: t))) < 1e-6)
            let back = e.localTime(forSource: e.position(at: t))
            #expect(abs(secs(back) - secs(t)) < 1e-4)
        }
    }

    @Test func slicingAnEasedRampKeepsTheMapping() {
        let e = ramped(easeInOut)
        let cut = f(50)
        let left = e.sliced(from: .zero, to: cut), right = e.sliced(from: cut, to: e.duration)
        #expect(right.origin == e.position(at: cut))
        #expect(abs(secs(left.endPosition) - secs(e.position(at: cut))) < 1e-5)
        #expect(left.duration + right.duration == e.duration)
        for i in stride(from: 0, through: 50, by: 5) {
            #expect(abs(secs(left.position(at: f(Int64(i)))) - secs(e.position(at: f(Int64(i))))) < 1e-5)
        }
        for i in stride(from: 50, through: 120, by: 5) {
            #expect(abs(secs(right.position(at: f(Int64(i)) - cut)) - secs(e.position(at: f(Int64(i))))) < 1e-5)
        }
        // The cut speeds join: the left piece ends at the speed the right piece starts with.
        #expect(abs(left.speedValue(at: left.duration - Time(1, 100_000)) - right.speedValue(at: .zero)) < 1e-3)
    }

    @Test func addingAKeyInsideAnEasedRampKeepsSpeedAndPosition() {
        let e = ramped(easeInOut)
        let (k, b) = e.addingKey(at: f(50), frameDuration: fd)!
        #expect(k.segments[b - 1].to == k.segments[b].from)
        #expect(abs(k.segments[b].from.percent / 100 - e.speedValue(at: f(50))) < 1e-4)
        for i in stride(from: 0, through: 120, by: 3) {
            #expect(abs(secs(k.position(at: f(Int64(i)))) - secs(e.position(at: f(Int64(i))))) < 1e-5)
        }
    }

    @Test func scalingAndMovingKeepTheEase() {
        let e = ramped(easeInOut)
        let s = e.scaled(toDuration: f(240), frameDuration: fd)
        #expect(s.segments[1].ease == e.segments[1].ease)
        #expect(s.hull == e.hull)                                          // symmetric ease: same source after scaling
        let m = e.movingRamp(atSegment: 1, by: f(6), frameDuration: fd)!
        #expect(m.segments[1].ease == e.segments[1].ease)
        let w = e.settingRampWidth(ofSegment: 1, to: f(40), frameDuration: fd)!
        #expect(w.segments[1].ease == e.segments[1].ease)
        // Removing the transition drops the ease with it.
        let r = e.removingRamp(atSegment: 1, frameDuration: fd)!
        #expect(r.segments.allSatisfy { $0.ease == nil })
    }

    @Test func codableKeepsTheEaseAndOldFilesStayReadable() throws {
        let e = ramped(easeOutOnly)
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(SpeedKeys.self, from: data) == e)
        // A linear track writes no ease key: the file is unchanged for everything that existed before.
        let lin = try JSONEncoder().encode(ramped())
        #expect(!String(decoding: lin, as: UTF8.self).contains("ease"))
        #expect(try JSONDecoder().decode(SpeedKeys.self, from: lin) == ramped())
    }

    @Test func timelineEditAppliesTheEaseWithoutChangingTheClipLength() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(60), duration: f(120)), start: .zero,
                     mediaDuration: f(6000))
        c.setSpeedKeys(ramped())
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        try t.tracks[0].overwrite(c)
        let before = t
        let delta = try t.editSpeedKeys(c.id) { $0.settingEase(easeOutOnly, ofSegment: 1) }
        #expect(delta == .zero)
        let r = t.tracks[0].clips[0]
        #expect(r.duration == c.duration && r.speedKeys?.segments[1].ease != nil)
        #expect(r.source == r.speedKeys!.hull)
        #expect(r.source.end < c.source.end)                                // slow start reads less source
        // Undo is a snapshot: the earlier timeline value is the untouched clip.
        #expect(before.tracks[0].clips[0] == c)
    }

    @Test func reverseKeepsTheCurveRotatedWithTheSameSpanAndSource() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(60), duration: f(120)), start: .zero,
                     mediaDuration: f(6000))
        c.setSpeedKeys(ramped(easeOutOnly))
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        try t.tracks[0].overwrite(c)
        try t.setDuration(c.id, to: c.duration, reversed: true)
        let r = t.tracks[0].clips[0]
        let k = r.speedKeys!
        let ramp = k.segments.firstIndex(where: { $0.isRamp })!
        let e = k.segments[ramp].ease!
        #expect(k.segments[ramp].reversed)
        let orig = c.speedKeys!.segments[1].ease!
        #expect(e.out == orig.in && e.in == orig.out)
        #expect(k.segments[ramp].span == c.speedKeys!.segments[1].span)
        #expect(r.source == c.source)
        #expect(r.duration == c.duration)
        // Played backwards, the speed at each mirrored instant is the same.
        for i in stride(from: 0, through: 60, by: 6) {
            let fwd = c.speedKeys!.segments[1].speedValue(at: f(Int64(i)))
            let back = k.segments[ramp].speedValue(at: f(60 - Int64(i)))
            #expect(abs(fwd - back) < 1e-4)
        }
    }

    @Test func repeatedTailTrimsOfAnEasedRampDoNotDrift() {
        let e = ramped(easeOutOnly)
        var k = e
        for n in 1...40 {                                                  // 40 one-frame trims, each from the previous result
            k = k.extendedTail(by: .zero - fd)
            #expect(abs(secs(k.endPosition) - secs(e.position(at: e.duration - fd * Int64(n)))) < 1e-5)
        }
        // fitting slices once from the original: identical to a single slice.
        let limit = e.position(at: f(70))
        let fit = e.fitting(media: limit, frameDuration: fd)!
        #expect(fit == e.sliced(from: .zero, to: fit.duration))
        #expect(fit.hull.end <= limit)
    }

    @Test func decodingNormalisesTheCurve() throws {
        let json = #"{"duration":{"value":2,"timescale":1},"from":{"num":1,"den":1},"to":{"num":3,"den":1},"reversed":false,"#
            + #""ease":{"interpolation":"bezier","out":{"dx":0.25,"dy":0.25},"in":{"dx":0.7,"dy":0.7}}}"#
        let s = try JSONDecoder().decode(SpeedSegment.self, from: Data(json.utf8))
        #expect(s.ease == nil)                                              // handles on the diagonal: a straight ramp
        let wild = json.replacingOccurrences(of: #""dy":0.25"#, with: #""dy":-4"#)
        let w = try JSONDecoder().decode(SpeedSegment.self, from: Data(wild.utf8))
        #expect(w.ease?.out.dy == 0)
    }
}
