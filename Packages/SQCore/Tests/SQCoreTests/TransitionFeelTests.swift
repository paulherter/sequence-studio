import Foundation
import Testing
@testable import SQCore

// Transition feel defaults (the design notes 2026-10-06 "Transition feel defaults"): new transitions get a settling curve
// and a longer length; stored transitions keep what they have.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(60), duration: f(90)), start: f(start), mediaDuration: f(600))
}

/// Shape of a 0 -> 1 progress curve, sampled finely.
private struct Shape {
    var t90 = 0.0, overshoot = 0.0, undershoot = 0.0, peakAt = 0.0, endSpeed = 0.0
    init(_ p: (Double) -> Double) {
        let n = 2000
        let y = (0...n).map { p(Double($0) / Double(n)) }
        var peak = 0.0
        for i in 0..<n {
            if abs(1 - y[i]) > 0.1 { t90 = Double(i + 1) / Double(n) }
            let v = abs(y[i + 1] - y[i]) * Double(n)
            if v > peak { peak = v; peakAt = Double(i) / Double(n) }
        }
        overshoot = (y.max() ?? 1) - 1
        undershoot = -(y.min() ?? 0)
        endSpeed = abs(y[n] - y[n - 20]) * Double(n) / 20
    }
}

private func timeline(_ kinds: [TransitionKind] = []) throws -> (Timeline, Track.ID, Clip, Clip) {
    var v = Track(kind: .video, name: "V1")
    let a = clip(0), b = clip(90)
    try v.overwrite(a); try v.overwrite(b)
    return (Timeline(name: "T", frameDuration: fd, tracks: [v]), v.id, a, b)
}

@Suite struct TransitionFeelTests {
    // MARK: Factory look, one test per transition

    private func look(_ k: TransitionKind) -> (frames: Int64?, shape: Shape) {
        (k.presetDuration(frameDuration: fd).map { $0.frameIndex(frameDuration: fd) }, Shape { k.factoryEasing.progress($0) })
    }

    @Test func dissolveStartsAndEndsSoft() {
        let (frames, s) = look(.crossDissolve)
        #expect(frames == nil, "the Preferences length (1 s)")
        #expect(TransitionKind.crossDissolve.factoryEasing == .easeInOut)
        #expect(s.overshoot == 0 && s.undershoot == 0)
        #expect(abs(s.peakAt - 0.5) < 0.02 && s.endSpeed < 0.1, "fastest in the middle, no speed left at the end")
    }

    @Test func dipsQuickFadeAndBlurDissolveKeepTheirCurve() {
        for k in [TransitionKind.dipToBlack, .dipToWhite, .dipToColour, .quickFade] {
            #expect(k.factoryEasing == .linear && k.factoryEasing == k.defaultEasing, "\(k)")
        }
        #expect(TransitionKind.quickFade.presetDuration(frameDuration: fd) == f(3))
        #expect(TransitionKind.blurDissolve.factoryEasing == .easeInOut && TransitionKind.blurDissolve.presetDuration(frameDuration: fd) == nil)
        #expect(TransitionKind.softWipe.factoryEasing == .easeInOut && TransitionKind.softWipe.presetDuration(frameDuration: fd) == nil)
    }

    /// Fast start, 90 % of the way before the middle, then a long settle with no speed left and no overshoot.
    private func expectLongEaseOut(_ k: TransitionKind, frames want: Int64) {
        let (frames, s) = look(k)
        #expect(frames == want, "\(k): \(String(describing: frames))")
        #expect(k.factoryEasing == .easeOut100, "\(k)")
        #expect(s.t90 < 0.5, "\(k): 90 % at \(s.t90)")
        #expect(s.peakAt < 0.25, "\(k): fastest at \(s.peakAt)")
        #expect(s.endSpeed < 0.01, "\(k): lands with no speed")
        #expect(s.overshoot < 1e-9 && s.undershoot < 1e-9, "\(k): a full frame never runs past its place")
    }

    @Test func pushSettles() { expectLongEaseOut(.push, frames: 24) }
    @Test func slideSettles() { expectLongEaseOut(.slide, frames: 30) }
    @Test func whipSettles() {
        expectLongEaseOut(.whip, frames: 15)
        // The whip itself is as short as before (8 frames): 90 % of the way within the first 8 frames.
        #expect(look(.whip).shape.t90 * 15 < 8)
    }
    @Test func zoomPopSettles() { expectLongEaseOut(.zoomPop, frames: 24) }
    @Test func irisSettles() { expectLongEaseOut(.iris, frames: 24) }
    @Test func crossZoomSettles() { expectLongEaseOut(.crossZoom, frames: 24) }

    @Test func flashPeaksEarlyAndDecaysLong() {
        expectLongEaseOut(.flash, frames: 15)
        // The cut (weight 0.5) and with it the white peak sit in the first quarter; the decay takes the rest.
        let n = 15
        let dips = (0..<n).map { TransitionMix.video(.flash, weight: TransitionKind.flash.factoryEasing.mixWeight(TransitionMix.videoWeight(frameIndex: $0, frames: n))).dip }
        let peak = dips.firstIndex(of: dips.max()!)!
        #expect(peak <= 3, "peak on frame \(peak)")
        #expect(dips[n - 1] < 0.01 && dips[peak + 4] > 0.02, "still glowing 4 frames after the peak, gone at the end")
        for d in dips { #expect(d >= 0 && d <= 1) }
    }

    @Test func spinOvershootsAndComesBack() {
        let (frames, s) = look(.spin)
        #expect(frames == 24)
        #expect(TransitionKind.spin.factoryEasing == .overshoot)
        #expect(s.overshoot > 0.05 && s.overshoot < 0.15, "\(s.overshoot)")
        #expect(s.undershoot < 1e-9 && s.t90 < 0.35)
        // The pictures stay a clean mix while the rotation swings past its rest.
        var swung = false
        for i in 0..<24 {
            let r = TransitionRender.evaluate(kind: .spin, direction: .left, softness: 0, motionBlur: 1, easing: .overshoot, frameIndex: i, frames: 24)
            #expect(r.outgoing.opacity >= 0 && r.incoming.opacity <= 1 && abs(r.outgoing.opacity + r.incoming.opacity - 1) < 1e-9)
            if r.incoming.rotation > 0.01 { swung = true }
            #expect(r.incoming.scale >= 1 - 1e-9, "still covers the frame")
        }
        #expect(swung, "B (arriving from the negative side with direction left) passes zero")
        let last = TransitionRender.evaluate(kind: .spin, direction: .left, softness: 0, motionBlur: 1, easing: .overshoot, frameIndex: 23, frames: 24)
        #expect(abs(last.incoming.rotation) < 0.02)
    }

    @Test func lightLeakAndLightNoiseRunLongerAndSmooth() {
        for k in [TransitionKind.lightLeak, .lightNoise] {
            #expect(k.presetDuration(frameDuration: fd) == f(30), "\(k)")
            #expect(k.factoryEasing == .easeInOut, "\(k)")
        }
    }

    @Test func glitchStaticAndStrobeAreUnchanged() {
        #expect(TransitionKind.glitch.presetDuration(frameDuration: fd) == f(9))
        #expect(TransitionKind.staticNoise.presetDuration(frameDuration: fd) == f(12))
        #expect(TransitionKind.strobeCut.presetDuration(frameDuration: fd) == f(12))
        for k in [TransitionKind.glitch, .staticNoise, .strobeCut] { #expect(k.factoryEasing == k.defaultEasing) }
    }

    @Test func zoomInAndOutStoreTheirAmount() {
        for k in [TransitionKind.zoomIn, .zoomOut] {
            #expect(k.presetDuration(frameDuration: fd) == f(21), "0.7 s")
            #expect(k.factoryParams(atHead: true) == ["amount": 110])
            #expect(k.elementParams.map(\.key) == ["amount"] && k.hasParams && !k.isElement)
        }
        // B's settle: 90 % in the first third, a small swing past the rest, no speed at the end.
        let s = Shape { TransitionRender.zoomSettle($0) }
        #expect(s.t90 < 0.33 && s.overshoot > 0.03 && s.overshoot < 0.1 && s.endSpeed < 0.01 && s.undershoot == 0)
    }

    @Test func moveAndZoomArriveOnALongEaseOutAndLeaveAccelerating() {
        for k in [TransitionKind.move, .zoom] {
            #expect(k.presetDuration(frameDuration: fd) == f(24))
            let head = k.factoryParams(atHead: true)?[ClipEffect.motionCurveKey], tail = k.factoryParams(atHead: false)?[ClipEffect.motionCurveKey]
            #expect(head == Double(MotionCurve.easeOut100.rawValue) && tail == Double(MotionCurve.easeIn100.rawValue), "\(k)")
        }
        let arrive = Shape { MotionCurve.easeOut100.ease($0) }, leave = Shape { MotionCurve.easeIn100.ease($0) }
        #expect(arrive.t90 < 0.5 && arrive.endSpeed < 0.01 && arrive.overshoot < 1e-9)
        #expect(leave.peakAt > 0.75 && leave.overshoot < 1e-9, "fastest when it is gone")
    }

    @Test func popRisesFastAndSettlesOverTheLongerPart() throws {
        #expect(TransitionKind.pop.presetDuration(frameDuration: fd) == f(18))
        var tr = Transition(kind: .pop, duration: f(18), outgoing: nil, incoming: UUID())
        tr.applyFactoryLook()
        #expect(tr.param(ClipEffect.popFromKey) == 85 && tr.param(ClipEffect.popPeakKey) == 105 && tr.param(ClipEffect.popPeakAtKey) == 40)
        let e = try #require(tr.elementEffect(seconds: 0.6, motionBlur: 0))
        func scale(_ frame: Int64) -> Double {
            MotionEffects.stage(e, atLocal: f(frame), clipDuration: f(90), frame: Vec2(1920, 1080)).scale
        }
        let s = (0...18).map { scale(Int64($0)) }
        let peak = s.firstIndex(of: s.max()!)!
        #expect(abs(s[0] - 0.85) < 1e-9 && abs(s.max()! - 1.05) < 0.002 && abs(s[18] - 1) < 1e-9)
        #expect(peak >= 6 && peak <= 8, "peak on frame \(peak) of 18")
        // Smooth on both sides of the peak (no kink), and the way back takes longer than the way up.
        #expect(abs(s[peak] - s[peak - 1]) < 0.02 && abs(s[peak + 1] - s[peak]) < 0.02)
        #expect(18 - peak > peak)
        #expect(abs(s[17] - 1) < 0.002, "no speed left at the end")
    }

    @Test func everyVideoKindHasADecision() {
        // Kinds whose factory look differs from the stored-nil look, and only those.
        let changed: Set<TransitionKind> = [.crossDissolve, .lightNoise, .push, .slide, .whip, .zoomPop, .iris, .crossZoom, .flash, .spin]
        for k in TransitionKind.allCases {
            #expect((k.factoryEasing != k.defaultEasing) == changed.contains(k), "\(k)")
            if k.trackKind == .audio { #expect(k.factoryParams(atHead: true) == nil && k.presetDuration(frameDuration: fd) == nil) }
        }
        // Every factory curve has a name in the Curve pop-up (never "Custom") and stays editable as an ordinary curve.
        for k in TransitionKind.allCases where k.usesEasing {
            #expect(k.factoryEasing.matchingTransitionPreset == k.factoryEasing, "\(k)")
            #expect(EasingCurve.transitionCurve(for: k.factoryEasing.shape) == k.factoryEasing, "\(k)")
        }
        #expect(EasingCurve.overshoot.displayName == "Overshoot" && EasingCurve.easeOut100.displayName == EaseName.smoothIn100)
    }

    // MARK: Mix weights

    @Test func dissolveWeightsNeverLeaveZeroToOne() {
        let wild = EasingCurve.transitionCustom(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: -1.5), in: EaseHandle(dx: 0.2, dy: -2)))!
        let curves = EasingCurve.transitionPresets + [wild, .premiereDefault, .softLanding]
        #expect(Shape { wild.progress($0) }.overshoot > 0.2, "the test curve really leaves 0...1")
        let n = 24
        for c in curves {
            for i in 0..<n {
                let w = c.mixWeight(TransitionMix.videoWeight(frameIndex: i, frames: n))
                #expect(w >= 0 && w <= 1, "\(c.name) frame \(i): \(w)")
                for k in [TransitionKind.crossDissolve, .quickFade, .dipToBlack, .dipToWhite, .dipToColour, .flash] {
                    let m = TransitionMix.video(k, weight: w)
                    for x in [m.outgoing, m.incoming, m.dip] { #expect(x >= 0 && x <= 1, "\(k) \(c.name) frame \(i)") }
                    #expect(abs(m.outgoing + m.incoming + m.dip - 1) < 1e-9, "\(k) \(c.name) frame \(i)")
                }
                // Light Leak / Light Noise dissolve in the compositor, which clamps their weight (shader `clamp(u.wipeFront, 0, 1)`).
                for k in [TransitionKind.spin, .crossZoom] {
                    let r = TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: 1, easing: c, frameIndex: i, frames: n)
                    #expect(r.outgoing.opacity >= 0 && r.outgoing.opacity <= 1 && r.incoming.opacity >= 0 && r.incoming.opacity <= 1)
                    #expect(abs(r.outgoing.opacity + r.incoming.opacity - 1) < 1e-9, "\(k) \(c.name) frame \(i)")
                }
            }
        }
    }

    // MARK: Stored transitions keep their look

    /// What a transition without an own curve has always resolved to. Pinned: changing this changes old projects.
    private static let stored: [TransitionKind: EasingCurve] = [
        .crossDissolve: .linear, .dipToBlack: .linear, .dipToWhite: .linear, .quickFade: .linear, .dipToColour: .linear,
        .flash: .linear, .push: .easeInOut, .slide: .easeIn, .whip: .easeInOut, .zoomIn: .easeInOut, .zoomOut: .easeInOut,
        .zoomPop: .easeIn, .softWipe: .easeInOut, .glitch: .linear, .iris: .easeInOut, .lightLeak: .easeInOut,
        .blurDissolve: .easeInOut, .spin: .easeInOut, .crossZoom: .easeInOut, .staticNoise: .linear, .lightNoise: .linear,
        .strobeCut: .linear, .additiveDissolve: .linear, .clockWipe: .easeInOut, .boxIris: .easeInOut,
        .diamondIris: .easeInOut, .crossIris: .easeInOut, .barnDoors: .easeInOut, .venetianBlinds: .easeInOut,
        .radialWipe: .easeInOut, .wedgeWipe: .easeInOut, .pinwheel: .easeInOut, .checkerWipe: .easeInOut, .zigZagBlocks: .easeInOut,
        .insetWipe: .easeInOut, .randomBlocks: .easeInOut, .sliceWipe: .easeInOut, .mosaicDissolve: .easeInOut,
        .flip3D: .linear, .spring: .linear, .fall: .linear, .burn: .linear, .flare: .linear, .warp: .linear, .shake: .linear, .stinger: .linear, .move: .linear, .zoom: .linear, .pop: .linear,
        .constantPower: .linear, .constantGain: .linear, .exponentialFade: .linear,
    ]

    @Test func aTransitionWithoutAnOwnCurveResolvesAsBefore() throws {
        #expect(Self.stored.count == TransitionKind.allCases.count)
        for k in TransitionKind.allCases { #expect(k.defaultEasing == Self.stored[k], "\(k)") }
        // The element parameter defaults (what a stored transition without the key plays) are untouched.
        #expect(Transition(kind: .move, duration: f(15), outgoing: nil, incoming: UUID()).param(ClipEffect.motionCurveKey) == 0)
        let pop = Transition(kind: .pop, duration: f(15), outgoing: nil, incoming: UUID())
        #expect(pop.param(ClipEffect.popFromKey) == 90 && pop.param(ClipEffect.popPeakKey) == 105 && pop.param(ClipEffect.popPeakAtKey) == 77)
    }

    @Test func aStoredProjectKeepsDurationCurveAndRender() throws {
        // A project as an older build wrote it: transitions without easing / params, one with an own curve.
        var (t, v, a, b) = try timeline()
        let c = clip(180)
        try t.tracks[0].overwrite(c)
        let slide = try t.addTransition(kind: .slide, track: v, outgoing: a.id, incoming: b.id, duration: f(25))
        let zoom = try t.addTransition(kind: .zoomIn, track: v, outgoing: b.id, incoming: c.id, duration: f(12))
        let fade = try t.addTransition(kind: .crossDissolve, track: v, outgoing: nil, incoming: a.id, duration: f(30))
        let own = try t.addTransition(kind: .pop, track: v, outgoing: c.id, incoming: nil, duration: f(15))
        try t.setTransition(own, params: [ClipEffect.motionCurveKey: Double(MotionCurve.spring.rawValue)])
        for id in [slide, zoom, fade] {
            let tr = try #require(t.transition(id)?.transition)
            #expect(tr.easing == nil && tr.params == nil, "a plain add writes no look")
        }
        var p = Project(name: "P")
        p.timelines = [t]
        let data = try ProjectFile.encode(p)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("\"amount\"") && !json.contains("Overshoot"))
        let back = try #require(try ProjectFile.decode(data, migrations: ProjectFile.migrations).timelines.first)
        #expect(back.tracks[0].transitions == t.tracks[0].transitions)
        let r = back.tracks[0].resolvedTransitions(frameDuration: fd)
        let rs = try #require(r.first { $0.id == slide }), rz = try #require(r.first { $0.id == zoom }), rf = try #require(r.first { $0.id == fade })
        #expect(rs.duration == f(25) && rs.easing == EasingCurve.easeIn)
        #expect(rz.duration == f(12) && rz.zoomAmount == nil)
        #expect(rf.duration == f(30) && rf.easing == EasingCurve.linear)
        #expect(back.transition(own)?.transition.params == [ClipEffect.motionCurveKey: Double(MotionCurve.spring.rawValue)])
        // The fade in is still a straight ramp, the zoom still the two 100 -> 110 % layers (B ends at 110 %).
        for i in 0..<30 { #expect(rf.easing.mixWeight(TransitionMix.videoWeight(frameIndex: i, frames: 30)) == Double(i + 1) / 31) }
        let entries = back.tracks[0].videoEntries(at: f(90 + 180 - 90 + 5), frameDuration: fd)
        let legacy = TransitionRender.evaluate(kind: .zoomIn, direction: .left, softness: 0.1, motionBlur: 1, easing: .easeInOut,
                                               frameIndex: 11, frames: 12)
        #expect(entries.motion?.render == legacy)
        #expect(abs(legacy.incoming.scale - 1.1) < 0.001 && !legacy.incoming.mirrorEdges && !legacy.outgoing.mirrorEdges)
    }

    @Test func theFactoryLookIsOnlyWrittenWhereItIsAsked() throws {
        var (t, v, a, b) = try timeline()
        let old = try t.addTransition(kind: .push, track: v, outgoing: nil, incoming: a.id, duration: f(15))
        let new = try t.addTransition(kind: .push, track: v, outgoing: a.id, incoming: b.id, duration: f(24))
        try t.applyFactoryLook(new)
        #expect(t.transition(old)?.transition.easing == nil)
        #expect(t.transition(new)?.transition.easing == .easeOut100 && t.transition(new)?.transition.duration == f(24))
        let r = t.tracks[0].resolvedTransitions(frameDuration: fd)
        #expect(r.first { $0.id == old }?.easing == .easeInOut && r.first { $0.id == new }?.easing == .easeOut100)
        // A kind whose factory curve is the stored one writes nothing.
        let wipe = try t.addTransition(kind: .softWipe, track: v, outgoing: b.id, incoming: nil, duration: f(15))
        try t.applyFactoryLook(wipe)
        #expect(t.transition(wipe)?.transition.easing == nil && t.transition(wipe)?.transition.params == nil)
        t.tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) { try t.applyFactoryLook(old) }
    }

    @Test func crossZoomScaleFollowsTheCurveOnlyItsOpacityIsClamped() {
        let n = 24
        var past = false
        for i in 0..<n {
            let e = EasingCurve.overshoot.progress(TransitionMix.videoWeight(frameIndex: i, frames: n))
            let r = TransitionRender.evaluate(kind: .crossZoom, direction: .left, softness: 0, motionBlur: 1, easing: .overshoot, frameIndex: i, frames: n)
            #expect(r.outgoing.scale == 1 + TransitionRender.crossZoomAmount * e && r.incoming.scale == 1 + TransitionRender.crossZoomAmount * (1 - e))
            #expect(r.incoming.opacity == min(max(e, 0), 1) && r.outgoing.opacity == 1 - min(max(e, 0), 1))
            if e > 1.01 { past = true }
        }
        #expect(past, "Overshoot runs the scale past its rest")
    }

    /// Every video kind on a curve that leaves 0...1, without any of the new fields: the values of the build before
    /// 2026-10-06 (`TransitionRender.evaluate` there). The only difference allowed: Spin / Cross Zoom opacity is clamped.
    @Test func aStoredOvershootingCurveRendersAsBefore() {
        let wild = EasingCurve.transitionCustom(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: -1.5), in: EaseHandle(dx: 0.2, dy: -2)))!
        let n = 12
        func print(_ s: TransitionSide) -> Double {
            s.offset.x + 2 * s.offset.y + 3 * s.scale + 5 * s.opacity + 7 * s.blur.x + 11 * s.blur.y + 13 * s.zoomBlur + 17 * s.rotation
        }
        var got: [String: Double] = [:]
        for k in TransitionKind.allCases where k.trackKind == .video && !ShapeWipeTransitionTests.kinds.contains(k) && !ThirdTransitionSetTests.kinds.contains(k) {
            var sum = 0.0
            for i in 0..<n {
                var r = TransitionRender.evaluate(kind: k, direction: .up, softness: 0.2, motionBlur: 1, easing: wild, frameIndex: i, frames: n)
                #expect(!r.outgoing.mirrorEdges && !r.incoming.mirrorEdges)
                if k == .spin || k == .crossZoom {
                    let e = wild.progress(TransitionMix.videoWeight(frameIndex: i, frames: n)), w = min(max(e, 0), 1)
                    #expect(r.outgoing.opacity == 1 - w && r.incoming.opacity == w, "\(k) frame \(i)")
                    r.outgoing.opacity = 1 - e; r.incoming.opacity = e      // what the older build passed on
                }
                sum += Double(i + 1) * (print(r.outgoing) + 1.5 * print(r.incoming) + 19 * r.wipe.front + 23 * r.wipe.softness)
            }
            got[k.rawValue] = (sum * 1e9).rounded() / 1e9
        }
        #expect(got == Self.pinnedOvershoot, "\(got.sorted { $0.key < $1.key })")
    }

    private static let pinnedOvershoot: [String: Double] = [
        "blurDissolve": 3065.567698017, "crossDissolve": 1560.0, "crossZoom": 1872.42438008, "dipToBlack": 1560.0,
        "dipToColour": 1560.0, "dipToWhite": 1560.0, "flash": 1560.0, "glitch": 1560.0, "iris": 3695.719965589,
        "lightLeak": 3399.742832563, "lightNoise": 3040.942832563, "move": 1560.0, "pop": 1560.0, "push": 1172.588466439,
        "quickFade": 1560.0, "slide": 1421.153079863, "softWipe": 3695.719965589, "spin": -396.33248199,
        "staticNoise": 1560.0, "stinger": 1560.0, "strobeCut": 1087.5, "whip": 1172.588466439, "zoom": 1560.0,
        "zoomIn": 1225.705899917, "zoomOut": 1201.988474401, "zoomPop": 1574.060896849,
    ]

    @Test func aFileWithAmountOpensAndOneWithoutRoundTripsByteIdentical() throws {
        var (t, v, a, b) = try timeline()
        let c = clip(180)
        try t.tracks[0].overwrite(c)
        _ = try t.addTransition(kind: .slide, track: v, outgoing: a.id, incoming: b.id, duration: f(25))
        let zoom = try t.addTransition(kind: .zoomIn, track: v, outgoing: b.id, incoming: c.id, duration: f(12))
        var layer = TransitionLayer(kind: .zoomOut, cut: f(10))
        var lc = Clip(name: "L", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(21)), start: f(300), mediaDuration: f(21))
        lc.generator = GeneratorRef(kind: GeneratorRef.transitionLayer, payload: layer.payload, payloadVersion: TransitionLayer.payloadVersion)
        try t.tracks[0].overwrite(lc)
        var p = Project(name: "P")
        p.timelines = [t]
        // Without Amount: nothing new in the file, and decode + encode gives the same bytes (once the dates have lost
        // their fractions of a second in the first pass) with the same timelines.
        func reencode(_ d: Data) throws -> Data { try ProjectFile.encode(ProjectFile.decode(d, migrations: ProjectFile.migrations)) }
        func timelines(_ d: Data) throws -> NSArray? {
            ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["project"] as? [String: Any])?["timelines"] as? NSArray
        }
        let plain = try reencode(ProjectFile.encode(p))
        #expect(!String(decoding: plain, as: UTF8.self).contains("amount"))
        #expect(try reencode(plain) == plain)
        #expect(try timelines(plain) == timelines(ProjectFile.encode(p)) && timelines(plain) != nil)
        // With Amount (a transition and a transition layer): same file version, opens with the values.
        try p.timelines[0].setTransition(zoom, params: ["amount": 130])
        layer.setParam("amount", 150)
        lc.generator = GeneratorRef(kind: GeneratorRef.transitionLayer, payload: layer.payload, payloadVersion: TransitionLayer.payloadVersion)
        try p.timelines[0].replaceClip(lc)
        let data = try reencode(ProjectFile.encode(p))
        func version(_ d: Data) throws -> Int? { (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["formatVersion"] as? Int }
        #expect(try version(data) == version(plain) && version(plain) != nil)
        let back = try #require(try ProjectFile.decode(data, migrations: ProjectFile.migrations).timelines.first)
        #expect(back.transition(zoom)?.transition.zoomAmount == 1.3)
        let bl = try #require(back.tracks[0].clips.first { $0.id == lc.id })
        #expect(bl.resolvedTransitionLayer(frameDuration: fd)?.zoomAmount == 1.5)
        #expect(try reencode(data) == data)
        // An older build reads the layer payload without the key (unknown keys are ignored): the old zoom look.
        struct Old: Codable { var kind: TransitionKind; var cut: Time }
        #expect(try JSONDecoder().decode(Old.self, from: layer.payload).kind == .zoomOut)
    }

    @Test func kindChangeLeavesATransitionWithoutAWrittenLookAsItIs() throws {
        var (t, v, a, b) = try timeline()
        let id = try t.addTransition(kind: .push, track: v, outgoing: a.id, incoming: b.id, duration: f(15))
        try t.changeTransitionKind(id, to: .spin)
        #expect(t.transition(id)?.transition.easing == nil && t.transition(id)?.transition.params == nil)
        try t.changeTransitionKind(id, to: .zoomIn)
        #expect(t.transition(id)?.transition.params == nil, "no Amount: the older zoom")
        // An edited look is not the factory look: the curve stays, parameters go; Zoom In <-> Out keeps the Amount.
        try t.setTransition(id, params: ["amount": 140])
        #expect(t.transition(id)?.transition.carriesFactoryLook == false)
        try t.changeTransitionKind(id, to: .zoomOut)
        #expect(t.transition(id)?.transition.params == ["amount": 140] && t.transition(id)?.transition.easing == nil)
        try t.changeTransitionKind(id, to: .push)
        #expect(t.transition(id)?.transition.params == nil && t.transition(id)?.transition.easing == nil)
        // Factory curve but edited parameters: not the full look either.
        try t.changeTransitionKind(id, to: .zoomIn)
        try t.applyFactoryLook(id)
        #expect(t.transition(id)?.transition.carriesFactoryLook == true)
        try t.setTransition(id, params: ["amount": 120])
        try t.changeTransitionKind(id, to: .spin)
        #expect(t.transition(id)?.transition.easing == nil)
        var l = TransitionLayer(kind: .push, cut: f(12))
        l.changeKind(to: .spin)
        #expect(l.easing == nil && l.params == nil)
        l.changeKind(to: .zoomIn); l.setParam("amount", 150); l.changeKind(to: .zoomOut)
        #expect(l.params == ["amount": 150])
        l.changeKind(to: .push)
        #expect(l.params == nil && l.easing == nil)
    }

    @Test func changingTheKindStartsFromTheNewFactoryLookButKeepsAnOwnCurve() throws {
        var (t, v, a, b) = try timeline()
        let id = try t.addTransition(kind: .push, track: v, outgoing: a.id, incoming: b.id, duration: f(24))
        try t.applyFactoryLook(id)
        try t.changeTransitionKind(id, to: .spin)
        #expect(t.transition(id)?.transition.easing == .overshoot)
        try t.changeTransitionKind(id, to: .zoomIn)
        #expect(t.transition(id)?.transition.easing == nil && t.transition(id)?.transition.params == ["amount": 110])
        try t.changeTransitionKind(id, to: .softWipe)
        #expect(t.transition(id)?.transition.params == nil && t.transition(id)?.transition.easing == nil)
        try t.setTransition(id, easing: .fastStart)
        try t.changeTransitionKind(id, to: .slide)
        #expect(t.transition(id)?.transition.easing == .fastStart, "an own curve survives")
        #expect(t.transition(id)?.transition.duration == f(24), "the length is never touched")
    }

    @Test func resetWithoutAUserDefaultGivesTheFactoryLook() throws {
        var (t, v, a, b) = try timeline()
        let id = try t.addTransition(kind: .slide, track: v, outgoing: a.id, incoming: b.id, duration: f(25))
        try t.resetTransition(id, to: nil, factoryDuration: f(30))
        #expect(t.transition(id)?.transition.easing == .easeOut100 && t.transition(id)?.transition.duration == f(30))
        // A user default (saved with the look it had) wins and is applied exactly.
        let user = TransitionPreset(kind: .slide, duration: f(25))
        #expect(user.easing == .easeIn)
        try t.resetTransition(id, to: user, factoryDuration: f(30))
        #expect(t.transition(id)?.transition.easing == .easeIn && t.transition(id)?.transition.duration == f(25))
    }

    @Test func resetClearsReversedAndPresetCarriesIt() throws {
        var (t, v, a, b) = try timeline()
        let id = try t.addTransition(kind: .slide, track: v, outgoing: a.id, incoming: b.id, duration: f(25))
        try t.setTransition(id, reversed: true)
        let captured = TransitionPreset.capture(from: t.transition(id)!.transition)
        #expect(captured.reversed == true)
        try t.resetTransition(id, to: nil, factoryDuration: f(30))
        #expect(t.transition(id)?.transition.reversed == nil)
        try t.resetTransition(id, to: captured, factoryDuration: f(30))
        #expect(t.transition(id)?.transition.reversed == true)
        let old = try JSONDecoder().decode(TransitionPreset.self, from: JSONEncoder().encode(TransitionPreset(kind: .slide, duration: f(25))))
        #expect(old.reversed == nil)
    }

    // MARK: Zoom In / Out: settles, Amount

    private func zoom(_ k: TransitionKind, _ i: Int, of n: Int, amount: Double = 1.1, hasOutgoing: Bool = true, hasIncoming: Bool = true) -> TransitionRender {
        TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: 1, easing: .easeInOut, frameIndex: i, frames: n,
                                  hasIncoming: hasIncoming, hasOutgoing: hasOutgoing, zoomAmount: amount, zoomSettles: true)
    }

    @Test func settlingZoomIsAtRestOnBothSpanEdges() {
        for k in [TransitionKind.zoomIn, .zoomOut] {
            for n in [9, 21, 30] {
                // A at the first frame and B at the last are within a hair of 100 %: no jump against the clip outside the span.
                #expect(abs(zoom(k, 0, of: n).outgoing.scale - 1) < 0.001, "\(k) \(n)")
                #expect(abs(zoom(k, n - 1, of: n).incoming.scale - 1) < 0.001, "\(k) \(n)")
                #expect(zoom(k, 0, of: n).outgoing.opacity == 1 && zoom(k, n - 1, of: n).incoming.opacity == 1)
                #expect(zoom(k, n - 1, of: n).outgoing.opacity == 0)
                // No blur left where it meets the clip.
                #expect(zoom(k, n - 1, of: n).incoming.zoomBlur < 0.002 && zoom(k, 0, of: n).outgoing.zoomBlur < 0.002)
            }
            // Single-sided: the side that stays visible is at rest where the clip goes on / comes from.
            #expect(abs(zoom(k, 20, of: 21, hasOutgoing: false).incoming.scale - 1) < 0.001)
            #expect(abs(zoom(k, 0, of: 21, hasIncoming: false).outgoing.scale - 1) < 0.001)
        }
    }

    @Test func settlingZoomIsOneMoveInOneDirectionWithItsPeakAtTheFade() {
        let n = 21
        // Zoom In: A grows to the amount, B grows from 1 / amount; Zoom Out the reverse.
        var a = (0..<n).map { zoom(.zoomIn, $0, of: n).outgoing.scale }, b = (0..<n).map { zoom(.zoomIn, $0, of: n).incoming.scale }
        #expect(a == a.sorted() && abs(a[12] - 1.1) < 0.001, "A accelerates up to 110 %: \(a[12])")
        #expect(abs(b[9] - 1 / 1.1) < 0.03 && b.max()! > 1.001 && b.max()! < 1.01, "B from 91 %, a touch past 100 %: \(b.max()!)")
        #expect(a[10] - a[9] > a[5] - a[4], "A is fastest at its end")
        #expect(b[12] - b[11] > b[18] - b[17], "B is fastest at its start")
        a = (0..<n).map { zoom(.zoomOut, $0, of: n).outgoing.scale }; b = (0..<n).map { zoom(.zoomOut, $0, of: n).incoming.scale }
        #expect(a == a.sorted(by: >) && abs(a[12] - 1 / 1.1) < 0.001)
        #expect(Array(b[9...]) == Array(b[9...]).sorted(by: >) && abs(b[9] - 1.1) < 0.03 && b.min()! >= 1, "B never below 100 %")
        // The side that drops below 100 % repeats mirrored at its edges; the other needs nothing.
        #expect(zoom(.zoomIn, 12, of: n).incoming.mirrorEdges && !zoom(.zoomIn, 12, of: n).outgoing.mirrorEdges)
        #expect(zoom(.zoomOut, 5, of: n).outgoing.mirrorEdges && !zoom(.zoomOut, 5, of: n).incoming.mirrorEdges)
        // The fade is the one of the older look: B under A, A fades over a few frames in the middle.
        for k in [TransitionKind.zoomIn, .zoomOut] {
            for i in 0..<n {
                let new = zoom(k, i, of: n)
                let old = TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: 1, easing: .easeInOut, frameIndex: i, frames: n)
                #expect(new.outgoing.opacity == old.outgoing.opacity && new.incoming.opacity == old.incoming.opacity && new.compose == .outgoingOver)
            }
        }
    }

    @Test func amountIsAParameterOfZoomInAndOut() throws {
        var (t, v, a, b) = try timeline()
        let id = try t.addTransition(kind: .zoomIn, track: v, outgoing: a.id, incoming: b.id, duration: f(21))
        #expect(t.tracks[0].resolvedTransitions(frameDuration: fd).first?.zoomAmount == nil, "stored without: the older look")
        #expect(t.transition(id)?.transition.param("amount") == 110, "the control shows the default")
        try t.setTransition(id, params: ["amount": 130])
        #expect(t.tracks[0].resolvedTransitions(frameDuration: fd).first?.zoomAmount == 1.3)
        try t.setTransition(id, params: ["amount": 900])
        #expect(t.transition(id)?.transition.params == ["amount": 200], "clamped to the range")
        #expect(throws: EditError.invalidFormat) { try t.setTransition(id, params: ["peak": 3]) }
        try t.setTransition(id, params: ["amount": 130])
        // What plays is the settling zoom with that amount.
        let cut = f(90), start = cut - f(10)
        let got = try #require(t.tracks[0].videoEntries(at: start + f(10), frameDuration: fd).motion?.render)
        #expect(got == zoom(.zoomIn, 10, of: 21, amount: 1.3))
        let peak = (0..<21).map { zoom(.zoomIn, $0, of: 21, amount: 1.3).outgoing.scale }.max()!
        #expect(abs(peak - 1.3) < 0.001)
        // Presets and user defaults carry it; one saved from an older transition carries none.
        let preset = TransitionPreset.capture(from: try #require(t.transition(id)?.transition))
        #expect(preset.params == ["amount": 130])
        let other = try t.addTransition(preset: preset, point: .head(a.id), track: v)
        #expect(t.transition(other)?.transition.zoomAmount == 1.3)
        try t.applyTransitionPreset(TransitionPreset(kind: .zoomIn, duration: f(12)), to: other)
        #expect(t.transition(other)?.transition.params == nil)
        try t.applyTransitionDefault(preset, to: other)
        #expect(t.transition(other)?.transition.params == ["amount": 130])
    }

    // MARK: Transition layer

    @Test func aTransitionLayerTakesTheSameLook() throws {
        // An older payload has no params and decodes as before.
        let old = try #require(TransitionLayer.decode(Data(#"{"kind":"zoomIn","cut":{"value":10,"timescale":30}}"#.utf8))
                               ?? TransitionLayer.decode(TransitionLayer(kind: .zoomIn, cut: f(10)).payload))
        #expect(old.params == nil && old.zoomAmount == nil && old.easing == nil)
        #expect(!String(decoding: TransitionLayer(kind: .zoomIn, cut: f(10)).payload, as: UTF8.self).contains("params"))
        var l = TransitionLayer(kind: .push, cut: f(12))
        l.applyFactoryLook()
        #expect(l.easing == .easeOut100 && l.params == nil)
        l.changeKind(to: .zoomOut)
        #expect(l.easing == nil && l.zoomAmount == 1.1)
        l.setParam("amount", 125); l.setParam("nope", 3); l.setParam("amount", .nan)
        #expect(l.params == ["amount": 125])
        let back = try #require(TransitionLayer.decode(l.payload))
        #expect(back == l)
        // It resolves and renders through the same path as a transition on a cut.
        var c = Clip(name: "L", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(21)), start: f(30), mediaDuration: f(21))
        c.generator = GeneratorRef(kind: GeneratorRef.transitionLayer, payload: l.payload, payloadVersion: TransitionLayer.payloadVersion)
        let r = try #require(c.resolvedTransitionLayer(frameDuration: fd))
        #expect(r.zoomAmount == 1.25)
        #expect(Clip.stackRender(r, frameIndex: 20) == zoom(.zoomOut, 20, of: 21, amount: 1.25))
    }
}
