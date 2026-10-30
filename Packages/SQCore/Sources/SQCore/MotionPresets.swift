import Foundation

// FB-T3 built-in motion presets (Effects panel > Presets). Each is a stack of live motion effects on the clip's own
// transform stage: it starts at its own 100 %, leaves the clip's Motion alone, and every value stays editable in
// Effect Controls (start values, never locks). Convert to Keyframes works on them like on any transform-stage effect.
// Move From / To Left, Right, Top, Bottom are presets of the one Move effect (the maintainer's timings, MotionRecipes 6 and 7).
// They are `EffectStackPreset`s of the `.motion` bin (one type with the keying presets, film looks and Voice).

public enum MotionPresets {
    typealias R = MotionRecipes

    static func e(_ kind: String, _ curve: MotionCurve, _ duration: Double, mode: MotionMode = .in,
                  _ values: [String: Double] = [:]) -> ClipEffect {
        var v = values
        v[ClipEffect.motionModeKey] = Double(mode.rawValue)
        v[ClipEffect.motionCurveKey] = Double(curve.rawValue)
        v[ClipEffect.motionDurationKey] = duration
        return R.make(kind, v)
    }

    static func move(_ side: MoveSide, _ distance: Double, _ curve: MotionCurve, _ duration: Double, mode: MotionMode = .in,
                     _ extra: [String: Double] = [:]) -> ClipEffect {
        var v = extra
        v[ClipEffect.moveSideKey] = Double(side.rawValue)
        v[ClipEffect.moveDistanceKey] = distance
        if v[ClipEffect.moveRotationKey] == nil { v[ClipEffect.moveSpinKey] = Double(MoveSpin.none.rawValue) }
        return e(ClipEffect.moveKind, curve, duration, mode: mode, v)
    }

    /// A keyframed effect for the emphasis presets: static `values` plus `keys` per parameter as (seconds, value) pairs
    /// (clip-local; `endAnchored` presets write them against a 1 s clip). Keys ease with Premiere's default bezier unless `linear`.
    static func keyed(_ kind: String, values: [String: Double] = [:], keys: [String: [(Double, Double)]],
                      linear: Bool = false) -> ClipEffect {
        var fx = R.make(kind, values)
        let c = EasingCurve.premiereDefault
        for (param, pts) in keys {
            let ks = pts.map { p in
                linear ? Keyframe(time: R.ms(p.0), value: p.1)
                       : Keyframe(time: R.ms(p.0), value: p.1, interpolation: .bezier, inHandle: c.inHandle, outHandle: c.outHandle)
            }
            fx.parameters[param] = AnimatedProperty(pts[0].1, track: KeyframeTrack(keys: ks))
        }
        return fx
    }

    static func fadeIn(_ d: Double) -> ClipEffect { e(ClipEffect.fadeKind, .linear, d) }

    public static let builtIns: [EffectStackPreset] = {
        func p(_ id: String, _ name: String, _ fx: [ClipEffect]) -> EffectStackPreset {
            EffectStackPreset(id: id, name: name, bin: .motion, effects: fx)
        }
        func end(_ id: String, _ name: String, _ fx: [ClipEffect]) -> EffectStackPreset {
            EffectStackPreset(id: id, name: name, bin: .motion, effects: fx, anchor: .end)
        }
        let repeatEdge = [ClipEffect.repeatEdgePixelsKey: 1.0]
        let fadeBottom = [ClipEffect.moveFadeKey: 1.0, ClipEffect.moveFadeLengthKey: 0.14]
        return [
            // The maintainer's Move From / To (0.83 s, Premiere Ease In 100 %; top / bottom move a short way and fade).
            p("moveFromLeft", "Move From Left", [move(.left, 102, .easeOut100, 0.83)]),
            p("moveFromRight", "Move From Right", [move(.right, 102, .easeOut100, 0.83)]),
            p("moveFromTop", "Move From Top", [move(.top, 8.5, .easeOut100, 1.0, fadeBottom)]),
            p("moveFromBottom", "Move From Bottom", [move(.bottom, 8.5, .easeOut100, 1.0, fadeBottom)]),
            p("moveToLeft", "Move To Left", [move(.left, 100.5, .easeOut100, 0.83, mode: .out)]),
            p("moveToRight", "Move To Right", [move(.right, 101, .easeOut100, 0.83, mode: .out)]),
            p("moveToTop", "Move To Top", [move(.top, 44, .easeOut100, 1.1, mode: .out)]),
            p("moveToBottom", "Move To Bottom", [move(.bottom, 44, .easeOut100, 1.1, mode: .out)]),
            // Short-form.
            p("popIn", "Pop In", [e(ClipEffect.zoomKind, .backOut, 0.35, [ClipEffect.zoomFromKey: 60, ClipEffect.zoomToKey: 100]),
                                  fadeIn(0.12)]),
            p("slideIn", "Slide In", [move(.right, 35, .quintOut, 0.45, [ClipEffect.moveFadeKey: 1, ClipEffect.moveFadeLengthKey: 0.15])]),
            p("whipIn", "Whip In", [move(.left, 102, .expoOut, 0.3, [ClipEffect.stageShutterAngleKey: 360])]),
            p("bounceIn", "Bounce In", [move(.bottom, 60, .bounceOut, 0.7)]),
            p("spinIn", "Spin In", [e(ClipEffect.zoomKind, .backOut, 0.5, [ClipEffect.zoomFromKey: 0, ClipEffect.zoomToKey: 100]),
                                    move(.left, 0, .cubicOut, 0.5, [ClipEffect.moveSpinKey: Double(MoveSpin.counterClockwise.rawValue),
                                                                    ClipEffect.moveRotationKey: 180])]),
            p("elasticIn", "Elastic Pop", [e(ClipEffect.zoomKind, .elasticOut, 0.8, [ClipEffect.zoomFromKey: 70, ClipEffect.zoomToKey: 100])]),
            // Drift: a slow push and sideways float over the first 4 s (longer clips hold the end).
            p("drift", "Drift", [e(ClipEffect.zoomKind, .sineInOut, 4, [ClipEffect.zoomFromKey: 100, ClipEffect.zoomToKey: 108]),
                                 move(.angle, 3, .sineInOut, 4, [ClipEffect.moveDirectionKey: 250])]),
            // The maintainer's recipes (docs/RESEARCH-PAUL-CURVES.md section 3).
            p("captionPop", "Caption Pop", R.captionPop()),
            p("pop50", "Pop 50%", R.pop50()),
            p("slideInOvershoot", "Slide In Overshoot", R.slideInOvershoot()),
            p("zoomInOut", "Zoom In & Out", R.zoomInOut()),
            p("zoomOutIn", "Zoom Out & In", R.zoomOutIn()),
            // Emphasis (docs/research/USAGE-PREMIERE.md): live effects and keys on the clip, all editable afterwards.
            // Punch-In: 100 -> 118 % in 6 frames, ease-out, then holds.
            p("punchIn", "Punch-In", [e(ClipEffect.zoomKind, .easeOut100, 0.2, [ClipEffect.zoomFromKey: 100, ClipEffect.zoomToKey: 118])]),
            // Camera Shake: Transform at 115 % (hides the moving edges) with Shutter Angle 360, plus a looping Shake.
            p("cameraShake", "Camera Shake", [
                R.make(ClipEffect.transformKind, [ClipEffect.stageScaleKey: 115, ClipEffect.stageShutterAngleKey: 360]),
                R.make(ClipEffect.shakeKind, [ClipEffect.motionModeKey: Double(MotionMode.loop.rawValue),
                                              ClipEffect.motionCurveKey: Double(MotionCurve.linear.rawValue),
                                              ClipEffect.motionDurationKey: 1, ClipEffect.shakeStrengthKey: 2.5,
                                              ClipEffect.shakeRotationKey: 1.2, ClipEffect.shakeSpeedKey: 10])]),
            // RGB Split Hit: color fringes of 30 px that settle in 8 frames.
            p("rgbSplitHit", "RGB Split Hit", [keyed(ClipEffect.rgbSplitKind, values: [ClipEffect.rgbSplitAngleKey: 0],
                                                     keys: [ClipEffect.rgbSplitAmountKey: [(0, 30), (0.27, 0)]])]),
            // Pop 0-120-100: scale 0 / 120 / 100 % at frames 0 / 4 / 10 (30 fps).
            p("pop0120100", "Pop 0-120-100", [e(ClipEffect.popKind, .linear, 10.0 / 30,
                                                [ClipEffect.popFromKey: 0, ClipEffect.popPeakKey: 120, ClipEffect.popSettleKey: 100,
                                                 ClipEffect.popPeakAtKey: 40])]),
            // Whip Blur In / Out: Gaussian Blur 1000 -> 0 over 5 frames with Repeat Edge Pixels and a horizontal smear.
            // Put In on the incoming clip and Out on the outgoing one; together they are 0 / 1000 / 0 around the cut.
            p("whipBlurIn", "Whip Blur In", [
                keyed(ClipEffect.gaussianBlurKind, values: repeatEdge, keys: [ClipEffect.blurrinessKey: [(0, 1000), (0.17, 0)]]),
                keyed(ClipEffect.directionalBlurKind, values: [ClipEffect.blurDirectionKey: 90],
                      keys: [ClipEffect.blurLengthKey: [(0, 250), (0.17, 0)]])]),
            end("whipBlurOut", "Whip Blur Out", [
                keyed(ClipEffect.gaussianBlurKind, values: repeatEdge, keys: [ClipEffect.blurrinessKey: [(0.83, 0), (1, 1000)]]),
                keyed(ClipEffect.directionalBlurKind, values: [ClipEffect.blurDirectionKey: 90],
                      keys: [ClipEffect.blurLengthKey: [(0.83, 0), (1, 250)]])]),
            // RGB Glitch: RGB Split jumps (hard keys) while a Mosaic goes 500 -> 20 x 10 blocks over 9 frames and clears again.
            p("rgbGlitch", "RGB Glitch", [
                keyed(ClipEffect.rgbSplitKind, values: [ClipEffect.rgbSplitAngleKey: 0],
                      keys: [ClipEffect.rgbSplitAmountKey: [(0, 0), (0.07, 30), (0.13, 12), (0.2, 36), (0.27, 0)]], linear: true),
                keyed(ClipEffect.mosaicKind, keys: [ClipEffect.mosaicColumnsKey: [(0, 500), (0.15, 20), (0.3, 4000)],
                                                    ClipEffect.mosaicRowsKey: [(0, 500), (0.15, 10), (0.3, 4000)]], linear: true)]),
            // Ghost Frame: a doubled, glowing image (RGB Split blended 50 % with the original) on a stepped 8 fps time (Posterize Time).
            p("ghostFrame", "Ghost Frame", [
                R.make(ClipEffect.posterizeTimeKind, [ClipEffect.posterizeRateKey: 8]),
                R.make(ClipEffect.rgbSplitKind, [ClipEffect.rgbSplitAmountKey: 24, ClipEffect.rgbSplitAngleKey: 0,
                                                 ClipEffect.rgbSplitBlendKey: 50]),
                R.make(ClipEffect.glowKind, [:])]),
        ]
    }()

    /// The motion bin without the hidden ones (`HiddenCatalog`); `EffectStackPresets.preset(id:)` still finds every one.
    public static var offered: [EffectStackPreset] { builtIns.filter { !HiddenCatalog.isHidden(motionPresetID: $0.id) } }

    public static func builtIn(named name: String) -> EffectStackPreset? { builtIns.first { $0.name == name } }
}
