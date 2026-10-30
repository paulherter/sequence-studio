import Foundation
import Testing
@testable import SQCore

/// The Color solo shows on every file frame the clip uses exactly the grade the timeline shows on the frame that plays it
/// (reviewer round 1: reversed keys, hold keys, frame-hold range grades, floor snapping).
@Suite struct ColorSoloFrameMatchTests {
    private let fd = Time(1, 25)
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    /// One video clip at 1 s showing source 10-14 s of a 30 s file at `speed` (reversed when asked), graded with `exposure`
    /// keys and an optional range grade.
    private func timeline(_ keys: [Keyframe<Double>], speed: ClipSpeed = .normal, reversed: Bool = false,
                          range: ClipEffect? = nil, hold: Time? = nil) throws -> (Timeline, Clip) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(1),
                     mediaDuration: s(30), speed: speed)
        c.reversed = reversed
        c.holdFrame = hold
        var g = ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic))
        var p = AnimatedProperty(0.0)
        for k in keys { p.track.insert(k) }
        g.parameters[ClipEffect.colorExposureKey] = p
        c.effects = [g] + (range.map { [$0] } ?? [])
        var v = Track(kind: .video)
        try v.overwrite(c)
        return (Timeline(name: "t", frameDuration: fd, tracks: [v]), c)
    }

    private func exposure(_ c: ClipColor) -> Float { c.primary.basic.exposure }

    /// Every timeline frame of `clip`: the solo layer at the file frame it shows has the same render color.
    private func expectFramesMatch(_ t: Timeline, _ clip: Clip, tolerance: Float = 0) throws {
        let v = try #require(t.colorSourceFileView(of: clip.id, at: clip.start))
        var local = Time.zero
        while local < clip.duration {
            let file = clip.sourceTime(at: clip.start + local, frameDuration: fd)
            let l = try #require(v.timeline.videoLayers(at: file).first)
            let want = clip.renderColor(atLocal: local)
            if tolerance == 0 {
                #expect(l.color == want, "local \(local) file \(file)")
            } else {
                #expect(abs(exposure(l.color) - exposure(want)) <= tolerance, "local \(local) file \(file)")
                #expect(l.color.effects.count == want.effects.count)
            }
            local = local + fd
        }
    }

    @Test func forwardLinearAndHoldKeysMatch() throws {
        let (t, c) = try timeline([Keyframe(time: .zero, value: 0, interpolation: .hold), Keyframe(time: s(1), value: 2),
                                   Keyframe(time: s(3), value: -1)])
        try expectFramesMatch(t, c)
    }

    @Test func reversedLinearKeysMatchOnTheirFrames() throws {
        let (t, c) = try timeline([Keyframe(time: .zero, value: 0), Keyframe(time: s(1), value: 2)], reversed: true)
        try expectFramesMatch(t, c)
    }

    /// Hold A then linear B on a reversed clip: every frame before B holds A, as on the timeline.
    @Test func reversedHoldKeyHoldsTheRightValue() throws {
        let (t, c) = try timeline([Keyframe(time: .zero, value: 0, interpolation: .hold), Keyframe(time: s(1), value: 2),
                                   Keyframe(time: s(2), value: 1, interpolation: .hold), Keyframe(time: s(3), value: -2)],
                                  reversed: true)
        try expectFramesMatch(t, c)
    }

    /// A Hold Ahead and its next key: the keys of `timeline`.
    private var mirroredHold: [Keyframe<Double>] {
        [Keyframe(time: Time(1, 2), value: 2, interpolation: .holdAhead), Keyframe(time: Time(3, 2), value: -1)]
    }

    private func soloExposure(_ t: Timeline, _ c: Clip) throws -> KeyframeTrack<Double> {
        let solo = try #require(t.colorSourceFileView(of: c.id, at: c.start)?.timeline.tracks.first?.clips.first)
        return try #require(solo.effects.first?.parameters[ClipEffect.colorExposureKey]).track
    }

    /// At another speed the solo view has the same two keys.
    @Test func aHoldAheadIsTwoKeysOfTheSoloViewAtAnotherSpeed() throws {
        let (t, c) = try timeline(mirroredHold, speed: ClipSpeed(num: 2, den: 1))
        let k = try soloExposure(t, c)
        #expect(k.keys.map(\.time) == [s(11), s(13)] && k.keys.map(\.interpolation) == [.holdAhead, .linear])
        try expectFramesMatch(t, c)
        let (slow, sc) = try timeline(mirroredHold, speed: ClipSpeed(num: 1, den: 2))
        #expect(try soloExposure(slow, sc).keys.map(\.interpolation) == [.holdAhead, .linear])
        try expectFramesMatch(slow, sc)
    }

    /// On a reversed clip the Hold Ahead is a plain Hold on the file axis.
    @Test func aHoldAheadOnAReversedClipIsAHoldOfTheSoloView() throws {
        let (t, c) = try timeline(mirroredHold, reversed: true)
        let k = try soloExposure(t, c)
        #expect(k.keys.count == 2 && k.keys[0].interpolation == .hold)
        try expectFramesMatch(t, c)
    }

    @Test func maskKeyTimesAreItsKeys() {
        var m = ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        m.feather.track = KeyframeTrack(keys: mirroredHold)
        #expect(m.keyTimes == [Time(1, 2), Time(3, 2)])
    }

    @Test func reversedEasedKeysMirrorTheirHandles() throws {
        let (t, c) = try timeline([Keyframe(time: .zero, value: 0, interpolation: .bezier, outHandle: EaseHandle(dx: 0.6, dy: 0)),
                                   Keyframe(time: s(2), value: 2, interpolation: .bezier, inHandle: EaseHandle(dx: 0.2, dy: 0))],
                                  speed: ClipSpeed(num: 2, den: 1), reversed: true)
        try expectFramesMatch(t, c, tolerance: 1e-4)
    }

    @Test func reversedRangeGradeCoversItsFramesAndSwapsItsFades() throws {
        var e = ColorEffect(id: 2, inputLUT: nil); e.basic.exposure = 1
        var r = ClipEffect.colorGrade(e)
        r.colorRange = TimeRange(start: s(1), duration: s(1))
        let (t, c) = try timeline([], reversed: true, range: r)
        try expectFramesMatch(t, c)
        var faded = r
        faded.colorFadeIn = Time(1, 5); faded.colorFadeOut = Time(2, 5)
        let (t2, c2) = try timeline([], reversed: true, range: faded)
        let solo = try #require(t2.colorSourceFileView(of: c2.id, at: c2.start)?.timeline.tracks.first?.clips.first)
        let sr = try #require(solo.effects.last)
        #expect(sr.colorRange == TimeRange(start: s(12), duration: s(1)))       // local 1-2 s of source 10-14 reversed
        #expect(sr.colorFadeIn == Time(2, 5) && sr.colorFadeOut == Time(1, 5))  // the timeline's fade-in sits at the file end
    }

    @Test func frameHoldRangeGradeGradesTheHeldFrameLikeTheTimeline() throws {
        var e = ColorEffect(id: 2, inputLUT: nil); e.basic.exposure = 1
        var r = ClipEffect.colorGrade(e)
        r.colorRange = TimeRange(start: s(1), duration: s(1))
        r.colorFadeIn = Time(1, 5)
        // Playhead inside the range: the range grade covers the whole view, without fades.
        let (t, c) = try timeline([], range: r, hold: s(11))
        let inside = try #require(t.colorSourceFileView(of: c.id, at: c.start + Time(3, 2))?.timeline.tracks.first?.clips.first)
        #expect(inside.effects.count == 2)
        let ir = try #require(inside.effects.last)
        #expect(ir.colorRange == TimeRange(start: .zero, duration: s(30)) && ir.colorFadeIn == nil && ir.colorFadeOut == nil)
        // Outside: the range grade does not show.
        let outside = try #require(t.colorSourceFileView(of: c.id, at: c.start + Time(1, 2))?.timeline.tracks.first?.clips.first)
        #expect(outside.effects.count == 1)
    }

    /// 25 fps sequence over a 30 fps file: sequence frame 3 (0.12 s) shows file frame 3 (0.1 s), the frame containing it.
    @Test func openingFrameIsTheFrameContainingTheSourceTime() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero,
                     mediaDuration: s(30))
        c.effects = [ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic))]
        var v = Track(kind: .video)
        try v.overwrite(c)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [v])
        let info = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let view = try #require(t.colorSourceFileView(of: c.id, at: Time(3, 25), picture: info))
        #expect(view.position == Time(3, 30))
    }
}
