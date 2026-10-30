import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

private func clip(_ name: String, start: Int64, from: Int64 = 30, frames: Int64 = 60) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         mediaDuration: f(300))
}

/// A at 0..60, B at 60..120 on one video track, both with 30 frames of head handle and lots of tail.
private func cut() throws -> (Timeline, Clip, Clip) {
    let a = clip("A", start: 0), b = clip("B", start: 60)
    var t = Track(kind: .video)
    try t.overwrite(a); try t.overwrite(b)
    return (Timeline(name: "t", frameDuration: fd, tracks: [t]), a, b)
}

@Suite struct TransitionEasingTests {
    @Test func linearAndEndpoints() {
        for c in [EasingCurve.linear, .easeInOut, .easeIn, .easeOut] {
            #expect(c.progress(0) == 0 && c.progress(1) == 1, "\(c.name)")
            #expect(c.progress(-1) == 0 && c.progress(2) == 1, "\(c.name) clamps")
        }
        #expect(abs(EasingCurve.linear.progress(0.3) - 0.3) < 1e-12)
    }

    @Test func easeShapes() {
        let io = EasingCurve.easeInOut
        #expect(abs(io.progress(0.5) - 0.5) < 1e-9)
        #expect(io.progress(0.2) < 0.2 && io.progress(0.8) > 0.8)
        // Premiere naming: Ease In slows into the end (decelerates), Ease Out leaves the start slowly.
        #expect(EasingCurve.easeIn.progress(0.25) > 0.25 && EasingCurve.easeOut.progress(0.25) < 0.25)
        var last = -1.0
        for i in 0...100 {
            let v = io.progress(Double(i) / 100)
            #expect(v >= last); last = v
        }
    }

    @Test func holdJumpsAtTheEnd() {
        #expect(EasingCurve.hold.progress(0.99) == 0 && EasingCurve.hold.progress(1) == 1)
    }
}

@Suite struct TransitionKindDefaultsTests {
    @Test func newKindsAreVideo() {
        for k in [TransitionKind.quickFade, .push, .slide, .whip, .zoomIn, .zoomOut, .zoomPop, .softWipe] {
            #expect(k.trackKind == .video, "\(k)")
            #expect(TransitionKind.kinds(for: .video).contains(k))
        }
    }

    @Test func easingDefaultsFollowPaulsUsage() {
        // Dissolves stay linear (Premiere; his opacity keys are 100 % linear); slides ease out; the rest ease in and out.
        #expect(TransitionKind.crossDissolve.defaultEasing == .linear)
        #expect(TransitionKind.quickFade.defaultEasing == .linear)
        #expect(TransitionKind.slide.defaultEasing == .easeIn)
        #expect(TransitionKind.zoomPop.defaultEasing == .easeIn)
        #expect(TransitionKind.push.defaultEasing == .easeInOut)
        #expect(TransitionKind.whip.defaultEasing == .easeInOut)
        #expect(TransitionKind.softWipe.defaultEasing == .easeInOut)
    }

    @Test func presetDurationsInWholeFrames() {
        let ntsc = Time(1001, 30000)
        #expect(TransitionKind.quickFade.presetDuration(frameDuration: fd) == f(3))
        #expect(TransitionKind.quickFade.presetDuration(frameDuration: ntsc) == ntsc * 3)
        #expect(TransitionKind.slide.presetDuration(frameDuration: fd) == f(30))     // 1 s
        #expect(TransitionKind.whip.presetDuration(frameDuration: fd) == f(15))      // 0.5 s
        #expect(TransitionKind.zoomPop.presetDuration(frameDuration: fd) == f(24))   // 0.8 s
        // Dissolves and dips follow the Preferences default.
        #expect(TransitionKind.crossDissolve.presetDuration(frameDuration: fd) == nil)
    }

    @Test func parameterAvailability() {
        #expect(TransitionKind.push.usesDirection && TransitionKind.softWipe.usesDirection && !TransitionKind.zoomIn.usesDirection)
        #expect(TransitionKind.softWipe.usesSoftness && !TransitionKind.push.usesSoftness)
        #expect(TransitionKind.whip.usesMotionBlur && !TransitionKind.crossDissolve.usesMotionBlur)
        #expect(TransitionKind.whip.defaultMotionBlur > TransitionKind.push.defaultMotionBlur)
        #expect(TransitionKind.push.isMotion && !TransitionKind.quickFade.isMotion && !TransitionKind.dipToBlack.isMotion)
    }
}

@Suite struct TransitionRenderTests {
    private func render(_ k: TransitionKind, _ i: Int, of n: Int, dir: TransitionDirection = .left,
                        easing: EasingCurve? = nil, blur: Double? = nil, soft: Double = 0.1) -> TransitionRender {
        TransitionRender.evaluate(kind: k, direction: dir, softness: soft, motionBlur: blur ?? k.defaultMotionBlur,
                                  easing: easing ?? k.defaultEasing, frameIndex: i, frames: n)
    }

    @Test func pushMovesBothPicturesTogether() {
        let r = render(.push, 4, of: 9, easing: .linear)
        let e = 0.5
        #expect(abs(r.outgoing.offset.x + e) < 1e-12 && r.outgoing.offset.y == 0)
        #expect(abs(r.incoming.offset.x - (1 - e)) < 1e-12)
        // The seam is shared: B's left edge sits exactly on A's right edge.
        #expect(abs((r.incoming.offset.x - r.outgoing.offset.x) - 1) < 1e-12)
        #expect(r.compose == .sum)
    }

    @Test func pushDirections() {
        for d in TransitionDirection.allCases {
            let r = render(.push, 2, of: 9, dir: d)
            let v = d.vector
            #expect(r.outgoing.offset.x * v.x >= 0 && r.outgoing.offset.y * v.y >= 0, "\(d) A moves along the direction")
            #expect(abs(r.incoming.offset.x - r.outgoing.offset.x + v.x) < 1e-12 && abs(r.incoming.offset.y - r.outgoing.offset.y + v.y) < 1e-12)
        }
    }

    @Test func pushOffsetsAreSubpixelAndEased() {
        // 30 fps, 0.67 s push at 1920 px: consecutive frames move by fractional pixels, and ease in/out moves least at the ends.
        let n = 20
        let xs = (0..<n).map { render(.push, $0, of: n).outgoing.offset.x * 1920 }
        let steps = zip(xs, xs.dropFirst()).map { abs($1 - $0) }
        #expect(steps.contains { abs($0 - $0.rounded()) > 0.01 }, "offsets are not snapped to whole pixels")
        #expect(steps.first! < steps[n / 2] && steps.last! < steps[n / 2], "ease in/out: slow ends, fast middle")
    }

    @Test func motionBlurFollowsSpeedAndDirection() {
        let n = 20
        let mid = render(.push, n / 2, of: n), end = render(.push, 0, of: n)
        #expect(mid.outgoing.blur.x < 0 && mid.outgoing.blur.y == 0, "smear along the motion")
        #expect(abs(mid.outgoing.blur.x) > abs(end.outgoing.blur.x))
        #expect(mid.outgoing.blur == mid.incoming.blur)
        // 180 degree shutter: half the distance travelled in one frame.
        let a = render(.push, n / 2 - 1, of: n, blur: 0.5).outgoing.offset.x, b = render(.push, n / 2 + 1, of: n, blur: 0.5).outgoing.offset.x
        #expect(abs(abs(mid.outgoing.blur.x) - 0.5 * abs(b - a) / 2) < 0.002)
        #expect(render(.push, n / 2, of: n, blur: 0).outgoing.blur == .zero)
        // A whip smears much more than a push.
        #expect(abs(render(.whip, 4, of: 8).outgoing.blur.x) > 2.5 * abs(render(.push, 4, of: 8).outgoing.blur.x))
    }

    @Test func slideMovesOnlyTheIncomingPictureOverTheOutgoingOne() {
        let r = render(.slide, 3, of: 9, dir: .up)
        #expect(r.outgoing == .identity)
        #expect(r.incoming.offset.x == 0 && r.incoming.offset.y > 0, "comes in from below when sliding up")
        #expect(r.compose == .incomingOver)
    }

    @Test func softWipeSweepsFromAllAToAllB() {
        let first = render(.softWipe, 0, of: 30, easing: .linear), last = render(.softWipe, 29, of: 30, easing: .linear)
        #expect(first.compose == .wipe && first.wipe.direction == TransitionDirection.left.vector)
        #expect(first.wipe.softness == 0.1)
        #expect(first.wipe.front + first.wipe.softness < 0.05, "nearly no B on the first frame")
        #expect(last.wipe.front - last.wipe.softness > 0.95, "nearly all B on the last frame")
        var prev = -10.0
        for i in 0..<30 { let fr = render(.softWipe, i, of: 30).wipe.front; #expect(fr > prev); prev = fr }
    }

    @Test func zooms() {
        // Zoom In / Out: ZoomTransitionTests.
        let p0 = render(.zoomPop, 0, of: 20), p1 = render(.zoomPop, 19, of: 20)
        #expect(p0.incoming.scale > 1.05 && abs(p1.incoming.scale - 1) < 0.01)
        #expect(p0.incoming.zoomBlur > p1.incoming.zoomBlur && p1.compose == .incomingOver)
    }

    /// Tail-only (an outgoing clip, nothing incoming): every kind must take the outgoing picture away, not hard-cut it.
    @Test func tailOnlyTakesTheOutgoingPictureAway() {
        let n = 20
        func tail(_ k: TransitionKind, _ i: Int) -> TransitionRender {
            TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: k.defaultMotionBlur,
                                      easing: k.defaultEasing, frameIndex: i, frames: n, hasIncoming: false)
        }
        /// How much of A is still on screen, 0...1 (offset out of frame, faded, or wiped).
        func shown(_ r: TransitionRender) -> Double {
            if r.compose == .wipe { return min(max(1 - r.wipe.front, 0), 1) }
            let o = r.outgoing
            return max(0, 1 - max(abs(o.offset.x), abs(o.offset.y))) * o.opacity
        }
        let kinds = TransitionKind.allCases.filter { $0.isMotion && $0 != .glitch && $0 != .iris && $0 != .lightLeak && !MoreTransitionsTests.newKinds.contains($0) && !ShapeWipeTransitionTests.kinds.contains($0) && ![.flip3D, .burn, .flare, .warp, .shake].contains($0) }  // glitch: GlitchTransitionT; iris/leak mask or mix, nothing movesests
        #expect(kinds.count == 9)   // + Spring, Fall
        for k in kinds {
            let first = tail(k, 0), mid = tail(k, n / 2), last = tail(k, n - 1)
            #expect(shown(first) > 0.85, "\(k) starts with A on screen")
            // (Zoom Pop keeps A whole until its final fade; mid-way it is growing.)
            // (Zoom In / Out keep A whole until their final fade too; mid-way A is zooming.)
            let zooming = k == .zoomPop || k == .zoomIn || k == .zoomOut
            #expect(zooming ? mid.outgoing.scale != first.outgoing.scale : shown(mid) < shown(first), "\(k) takes A away")
            #expect(shown(last) < 0.4, "\(k) ends with A (nearly) gone: \(shown(last))")
        }
        // Slide out: A moves along the direction; Zoom Pop out: A grows and fades.
        #expect(tail(.slide, n / 2).outgoing.offset.x < 0 && tail(.slide, n / 2).outgoing.offset.y == 0)
        #expect(tail(.zoomPop, n - 1).outgoing.scale > tail(.zoomPop, 0).outgoing.scale)
        // With an incoming side the slide still leaves A alone.
        #expect(render(.slide, n / 2, of: n).outgoing == .identity)
    }

    @Test func dissolvesHaveNoRender() {
        #expect(TransitionKind.crossDissolve.isMotion == false)
    }
}

@Suite struct TransitionMotionTimelineTests {
    @Test func pushTagsBothLayersWithTheRender() throws {
        var (t, a, b) = try cut()
        let tr = t.tracks[0].id
        let id = try t.addTransition(kind: .push, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        let l = t.videoLayers(at: f(60))
        #expect(l.count == 2)
        #expect(l[0].clip == a.id && l[0].pair?.role == .first && l[1].pair?.role == .second)
        #expect(l.allSatisfy { $0.pair?.id == id && $0.pair?.render != nil && $0.inTransition })
        // The pictures stay opaque: the render node moves them.
        #expect(l.allSatisfy { $0.transform.opacity == 1 })
        let r = try #require(l[0].pair?.render)
        #expect(r.outgoing.offset.x < 0)
    }

    @Test func singleSidedSlideIsTheIncomingSide() throws {
        let b = clip("B", start: 60)
        var track = Track(kind: .video)
        try track.overwrite(b)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        try t.addTransition(kind: .slide, track: t.tracks[0].id, outgoing: nil, incoming: b.id, duration: f(10))
        let l = t.videoLayers(at: f(62))
        #expect(l.count == 1 && l[0].pair?.role == .second && l[0].pair?.render != nil)
    }

    @Test func tailOnlySlideMovesTheOutgoingClip() throws {
        let a = clip("A", start: 0)
        var track = Track(kind: .video)
        try track.overwrite(a)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        try t.addTransition(kind: .slide, track: t.tracks[0].id, outgoing: a.id, incoming: nil, duration: f(10))
        let l = t.videoLayers(at: f(56))
        #expect(l.count == 1 && l[0].pair?.role == .first)
        let r = try #require(l[0].pair?.render)
        #expect(r.outgoing.offset.x < -0.1, "A slides out instead of staying put until the hard cut")
    }

    @Test func dissolveEasingShapesTheWeight() throws {
        var (t, a, b) = try cut()
        let tr = t.tracks[0].id
        let id = try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(9))
        // Frame 1 of 9 (span starts at 56): linear weight 2/10.
        let lin = t.videoLayers(at: f(57))
        #expect(abs(lin[1].transform.opacity - 0.2) < 1e-9 && lin[1].pair?.render == nil)
        try t.setTransition(id, easing: .easeInOut)
        let eased = t.videoLayers(at: f(57))
        #expect(abs(eased[1].transform.opacity - EasingCurve.easeInOut.progress(0.2)) < 1e-9)
        #expect(eased[1].transform.opacity < 0.2)
    }

    @Test func setTransitionStyleParameters() throws {
        var (t, a, b) = try cut()
        let id = try t.addTransition(kind: .softWipe, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        try t.setTransition(id, direction: .down, softness: 0.3, motionBlur: 0.2)
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.direction == .down && r.softness == 0.3 && r.motionBlur == 0.2 && r.easing == .easeInOut)
        // Out-of-range values are clamped.
        try t.setTransition(id, softness: 5, motionBlur: -1)
        let s = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(s.softness == 0.5 && s.motionBlur == 0)
    }

    @Test func styleFieldsAreOptionalInTheFile() throws {
        var tr = Transition(kind: .push, duration: f(10), outgoing: UUID(), incoming: UUID())
        let plain = String(data: try JSONEncoder().encode(tr), encoding: .utf8)!
        #expect(!plain.contains("easing") && !plain.contains("direction"))
        tr.direction = .up; tr.easing = .easeOut
        let back = try JSONDecoder().decode(Transition.self, from: try JSONEncoder().encode(tr))
        #expect(back == tr)
        #expect(ProjectFile.currentVersion >= 25)
    }
}
