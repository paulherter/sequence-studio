import Foundation

// W7.4: the maintainer's top-10 animation recipes (docs/RESEARCH-PAUL-CURVES.md section 3) as parameters of the motion effects.
// Each returns the effects to stack on a clip (they compose on the transform stage and leave Motion alone). Times are
// from the clip's start (In) or end (Out); positions are normalized in his keys, here a % of the frame along the axis.
// Not covered: recipe 10's Mirror angle/center keys (Mirror is its own effect; only the 50 % pop is reproduced).

public enum MotionRecipes {
    public enum Side: Sendable, CaseIterable { case left, right, bottom }

    static func make(_ kind: String, _ values: [String: Double]) -> ClipEffect {
        var e = ClipEffect.make(kind: kind)!
        for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
        return e
    }
    static func ms(_ seconds: Double) -> Time { Time(Int64((seconds * 1000).rounded()), 1000) }
    static let mode = ClipEffect.motionModeKey, curve = ClipEffect.motionCurveKey, dur = ClipEffect.motionDurationKey

    /// Gaussian Blur with two bezier keys (clip-local times).
    static func blur(_ a: (Time, Double), _ b: (Time, Double)) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        let c = EasingCurve.premiereDefault
        func key(_ p: (Time, Double)) -> Keyframe<Double> {
            Keyframe(time: p.0, value: p.1, interpolation: .bezier, inHandle: c.inHandle, outHandle: c.outHandle)
        }
        e.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(a.1, track: KeyframeTrack(keys: [key(a), key(b)]))
        return e
    }

    /// 1. Caption pop: scale 90 -> 105 @0.10 s -> 100 @0.13 s, linear, clip start.
    public static func captionPop() -> [ClipEffect] {
        [make(ClipEffect.popKind, [mode: 0, curve: Double(MotionCurve.linear.rawValue), dur: 0.13,
                                   ClipEffect.popFromKey: 90, ClipEffect.popPeakKey: 105, ClipEffect.popSettleKey: 100,
                                   ClipEffect.popPeakAtKey: 0.10 / 0.13 * 100])]
    }

    /// 2. Zoom In & Out (BOT; `top` adds the 0.1 s opacity ends): 100 -> 110 in 0.97 s, hold, 110 -> 100 over the last 1.1 s.
    public static func zoomInOut(top: Bool = false) -> [ClipEffect] {
        zoomPair(from: 100, to: 110, top: top)
    }
    /// 3. Zoom Out & In: the inverse (110 -> 100 -> hold -> 110).
    public static func zoomOutIn(top: Bool = false) -> [ClipEffect] {
        zoomPair(from: 110, to: 100, top: top)
    }
    private static func zoomPair(from: Double, to: Double, top: Bool) -> [ClipEffect] {
        var out = [make(ClipEffect.zoomKind, [mode: 2, curve: Double(MotionCurve.premiereDefault.rawValue), dur: 0.97,
                                              ClipEffect.motionOutDurationKey: 1.1,
                                              ClipEffect.zoomFromKey: from, ClipEffect.zoomToKey: to])]
        if top { out.append(fade(mode: 2, 0.1)) }
        return out
    }

    /// 4. VideoStart IN: scale 100 -> 110 over 1.8 s ease-out, Gaussian Blur 40 -> 0 over the first 0.5 s
    /// (Premiere Blurriness, as in the maintainer's preset).
    public static func videoStartIn() -> [ClipEffect] {
        [make(ClipEffect.zoomKind, [mode: 0, curve: Double(MotionCurve.easeOut100.rawValue), dur: 1.8,
                                    ClipEffect.zoomFromKey: 100, ClipEffect.zoomToKey: 110]),
         blur((.zero, 40), (ms(0.5), 0))]
    }

    /// 5. VideoEnd: scale 100 -> 110 over the last 0.65 s, Gaussian Blur 0 -> 40 over the last 0.17 s. Needs the clip length.
    public static func videoEnd(clipDuration: Time) -> [ClipEffect] {
        return [make(ClipEffect.zoomKind, [mode: 1, curve: Double(MotionCurve.premiereDefault.rawValue), dur: 0.65,
                                           ClipEffect.zoomFromKey: 100, ClipEffect.zoomToKey: 110]),
                blur((clipDuration - Time(17, 100), 0), (clipDuration, 40))]
    }

    /// 6. Move From Left / Right / Bottom: position -0.52 -> 0.5 (a 102 % frame width) over 0.83 s, ease-out; bottom starts
    /// 0.085 of the height below center, takes 1.0 s and fades in over 0.14 s. (The right side mirrors the left.)
    public static func moveFrom(_ side: Side) -> [ClipEffect] {
        switch side {
        case .left: return [move(270, 102, 0.83, mode: 0)]
        case .right: return [move(90, 102, 0.83, mode: 0)]
        case .bottom: return [move(180, 8.5, 1.0, mode: 0, fade: 0.14)]
        }
    }

    /// 7. Move To Right / Left / Bottom: position 0.5 -> 1.51 (left -0.505, bottom 0.94) over 0.83 s (bottom 1.1 s), at the end.
    public static func moveTo(_ side: Side) -> [ClipEffect] {
        switch side {
        case .right: return [move(90, 101, 0.83, mode: 1)]
        case .left: return [move(270, 100.5, 0.83, mode: 1)]
        case .bottom: return [move(180, 44, 1.1, mode: 1)]
        }
    }

    /// 8. Slide-in + overshoot: position 0.964 -> 0.5 over 0.38 s, scale 200 -> 104.6 -> 100.3 (hold) over 0.35 s.
    public static func slideInOvershoot() -> [ClipEffect] {
        // Scale first, move second: the stages compose in list order, so the slide is not scaled with the pop.
        [make(ClipEffect.popKind, [mode: 0, curve: Double(MotionCurve.linear.rawValue), dur: 0.35,
                                   ClipEffect.popFromKey: 200, ClipEffect.popPeakKey: 104.6, ClipEffect.popSettleKey: 100.3,
                                   ClipEffect.popPeakAtKey: 60]),
         move(90, 46.4, 0.38, mode: 0)]
    }

    /// 9. Opacity fade over 3 frames (0.1 s): In at the start, Out at the end.
    public static func fadeIn() -> [ClipEffect] { [fade(mode: 0, 0.1)] }
    public static func fadeOut() -> [ClipEffect] { [fade(mode: 1, 0.1)] }

    /// 10. The "50 %" pop: scale 50 -> 95.6 @0.23 s -> 99.7 @0.33 s (hold).
    public static func pop50() -> [ClipEffect] {
        [make(ClipEffect.popKind, [mode: 0, curve: Double(MotionCurve.linear.rawValue), dur: 0.33,
                                   ClipEffect.popFromKey: 50, ClipEffect.popPeakKey: 95.6, ClipEffect.popSettleKey: 99.7,
                                   ClipEffect.popPeakAtKey: 0.23 / 0.33 * 100])]
    }

    static func fade(mode m: Double, _ d: Double) -> ClipEffect {
        make(ClipEffect.fadeKind, [mode: m, curve: Double(MotionCurve.linear.rawValue), dur: d])
    }
    static func move(_ direction: Double, _ distance: Double, _ d: Double, mode m: Double, fade f: Double? = nil) -> ClipEffect {
        var v: [String: Double] = [mode: m, curve: Double(MotionCurve.easeOut100.rawValue), dur: d,
                                   ClipEffect.moveDirectionKey: direction, ClipEffect.moveDistanceKey: distance]
        if let f { v[ClipEffect.moveFadeKey] = 1; v[ClipEffect.moveFadeLengthKey] = f }
        let side = MoveSide.allCases.first { $0.degrees == direction } ?? .angle
        v[ClipEffect.moveSideKey] = Double(side.rawValue)
        return make(ClipEffect.moveKind, v)
    }
}
