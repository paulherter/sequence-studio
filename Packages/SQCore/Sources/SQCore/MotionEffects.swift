import Foundation

// W7.4 parametric motion effects. Five built-in effects (Move, Zoom, Pop, Fade, Shake) each evaluate live on the effect
// transform stage (`ClipEffect.isTransformStage`, W7.1): no keyframes are written, the stage reads its parameters at the
// clip-local time. Every one has a Mode (In = at the clip's start, Out = at its end, In & Out, Loop), a Duration and a
// Curve (the keyframe easing library, W7.2). Stored parameter keys are strings: never rename.
//
// Progress: with edge length d, `uIn` is the eased 0...1 progress of the first d seconds of the clip and `uOut` that of the
// last d seconds (0 before, 1 at the clip's end); Loop uses the eased triangle wave of period d. Each type maps these onto
// its own transform:
//   Move  displacement (share of the full distance): In 1 - uIn, Out uOut, In & Out both, Loop triangle.
//         Direction = where the picture comes from / goes to (0 = top, 90 = right, 180 = bottom, 270 = left, clockwise).
//         Distance is a % of the frame along that direction; Rotation (deg) is reached at full displacement; optional fade.
//   Zoom  scale From % -> To %: In from -> to at the start (then holds `to`), Out from (held) -> to at the end,
//         In & Out from -> to -> hold -> from, Loop from -> to -> from.
//   Pop   scale From % -> Peak % (at Peak at % of the duration) -> Settle %, one pass through the three values.
//   Fade  opacity Edge % -> 100 % (In), 100 -> Edge (Out), both, Loop pulse.
//   Shake smooth noise offset (% of the frame) and rotation; its envelope decays (In), builds (Out), both ends, or stays (Loop).

extension ClipEffect {
    public static let moveKind = "motionMove", zoomKind = "motionZoom", popKind = "motionPop"
    public static let fadeKind = "motionFade", shakeKind = "motionShake"
    // N3 loop animators (always looping, no Mode/Curve): evaluated live like the others, work on any clip (text, shape, video).
    public static let bounceKind = "motionBounce", pulseKind = "motionPulse", wiggleKind = "motionWiggle"
    public static let motionKinds: Set<String> = [moveKind, zoomKind, popKind, fadeKind, shakeKind, bounceKind, pulseKind, wiggleKind]
    public var isMotionPreset: Bool { Self.motionKinds.contains(kind) }

    // Shared keys.
    public static let motionModeKey = "mode", motionCurveKey = "curve", motionDurationKey = "duration"
    public static let motionOutDurationKey = "outDuration"
    // Move.
    public static let moveDirectionKey = "direction", moveDistanceKey = "distance", moveRotationKey = "rotation"
    public static let moveFadeKey = "fade", moveFadeLengthKey = "fadeLength"
    /// FB-T3: Direction pop-up (`MoveSide`; absent in older effects = the angle), Rotation pop-up (`MoveSpin`; absent =
    /// the signed Rotation Strength), Scale at Edge in %.
    public static let moveSideKey = "side", moveSpinKey = "spin", moveScaleKey = "edgeScale"
    // Zoom and Pop.
    public static let zoomFromKey = "from", zoomToKey = "to"
    public static let popFromKey = "from", popPeakKey = "peak", popSettleKey = "settle", popPeakAtKey = "peakAt"
    // Fade.
    public static let fadeStartKey = "start"
    // Loop animators (N3).
    public static let loopPeriodKey = "period", loopPhaseKey = "phase"
    public static let bounceHeightKey = "height", bounceDirectionKey = "direction", bounceSquashKey = "squash"
    public static let pulseFromKey = "from", pulseToKey = "to", pulseFadeKey = "fadeDepth"
    public static let wiggleAngleKey = "angle", wiggleShiftKey = "shift"
    public static let shakeStrengthKey = "strength", shakeRotationKey = "rotation", shakeSpeedKey = "speed", shakeSeedKey = "seed"
}

public enum MotionMode: Int, Sendable, CaseIterable {
    case `in`, out, inOut, loop
    public static let titles = ["In", "Out", "In & Out", "Loop"]
}

// MotionCurve (the easing library) lives in MotionEasing.swift.

/// Where a Move comes from / goes to. `angle` uses the Angle slider.
public enum MoveSide: Int, Sendable, CaseIterable {
    case left, right, top, bottom, angle
    public static let titles = ["Left", "Right", "Top", "Bottom", "Angle"]
    /// Direction in degrees (0 = top, clockwise); nil for `angle`.
    public var degrees: Double? {
        switch self {
        case .left: 270
        case .right: 90
        case .top: 0
        case .bottom: 180
        case .angle: nil
        }
    }
}

/// Which way a Move turns while it travels; Rotation Strength is the angle at full displacement.
public enum MoveSpin: Int, Sendable, CaseIterable {
    case none, clockwise, counterClockwise
    public static let titles = ["None", "Clockwise", "Counter-clockwise"]
}

public enum MotionEffects {
    static func common() -> [EffectParamSpec] {
        [.choice(ClipEffect.motionModeKey, "Mode", MotionMode.titles),
         .choice(ClipEffect.motionCurveKey, "Curve", MotionCurve.titles),
         EffectParamSpec(key: ClipEffect.motionDurationKey, title: "Duration", unit: "s", defaultValue: 0.5,
                         range: 0.01...60, step: 0.01, decimals: 2),
         EffectParamSpec(key: ClipEffect.motionOutDurationKey, title: "Out Duration (0 = same)", unit: "s", defaultValue: 0,
                         range: 0...60, step: 0.01, decimals: 2)]
    }
    static func slider(_ key: String, _ title: String, _ unit: String, _ d: Double, _ r: ClosedRange<Double>,
                       _ step: Double = 1, _ decimals: Int = 1) -> EffectParamSpec {
        EffectParamSpec(key: key, title: title, unit: unit, defaultValue: d, range: r, step: step, decimals: decimals)
    }

    /// FB-T3: the one Move (Move From / To Left, Right, Top, Bottom are presets of it, `MotionPresets`).
    public static let moveSpec = EffectSpec(kind: ClipEffect.moveKind, title: "Move", params: common() + [
        .choice(ClipEffect.moveSideKey, "Direction", MoveSide.titles),
        slider(ClipEffect.moveDirectionKey, "Angle", "\u{00B0}", 270, -3_600...3_600, 1, 0),
        slider(ClipEffect.moveDistanceKey, "Distance", "% of frame", 100, 0...1_000, 0.5),
        // Clockwise by default: raising the strength turns the picture straight away (None switches it off).
        .choice(ClipEffect.moveSpinKey, "Rotation", MoveSpin.titles, default: MoveSpin.clockwise.rawValue),
        slider(ClipEffect.moveRotationKey, "Rotation Strength", "\u{00B0}", 0, -3_600...3_600, 1),
        slider(ClipEffect.moveScaleKey, "Scale at Edge", "%", 100, 0...10_000, 0.5),
        .checkbox(ClipEffect.moveFadeKey, "Fade"),
        slider(ClipEffect.moveFadeLengthKey, "Fade Length", "s", 0.14, 0...60, 0.01, 2),
    ])
    public static let zoomSpec = EffectSpec(kind: ClipEffect.zoomKind, title: "Zoom", params: common() + [
        slider(ClipEffect.zoomFromKey, "From", "%", 100, 0...10_000, 0.5),
        slider(ClipEffect.zoomToKey, "To", "%", 110, 0...10_000, 0.5),
    ])
    public static let popSpec = EffectSpec(kind: ClipEffect.popKind, title: "Pop", params: common() + [
        slider(ClipEffect.popFromKey, "From", "%", 90, 0...10_000, 0.5),
        slider(ClipEffect.popPeakKey, "Peak", "%", 105, 0...10_000, 0.5),
        slider(ClipEffect.popSettleKey, "Settle", "%", 100, 0...10_000, 0.5),
        slider(ClipEffect.popPeakAtKey, "Peak at", "%", 77, 1...99, 1, 0),
    ])
    public static let fadeSpec = EffectSpec(kind: ClipEffect.fadeKind, title: "Fade", params: common() + [
        slider(ClipEffect.fadeStartKey, "Opacity at Edge", "%", 0, 0...100, 1, 0),
    ])
    public static let shakeSpec = EffectSpec(kind: ClipEffect.shakeKind, title: "Shake", params: common() + [
        slider(ClipEffect.shakeStrengthKey, "Strength", "% of frame", 2, 0...100, 0.1),
        slider(ClipEffect.shakeRotationKey, "Rotation", "\u{00B0}", 1, 0...180, 0.1),
        slider(ClipEffect.shakeSpeedKey, "Speed", "Hz", 8, 0.1...60, 0.1),
        slider(ClipEffect.shakeSeedKey, "Seed", "", 1, 0...10_000, 1, 0),
    ])
    static func loopCommon(_ period: Double) -> [EffectParamSpec] {
        [slider(ClipEffect.loopPeriodKey, "Period", "s", period, 0.05...60, 0.01, 2),
         slider(ClipEffect.loopPhaseKey, "Phase", "%", 0, 0...100, 1, 0)]
    }
    /// Bounce: a ball-like hop along Direction (0 = up) every Period; Squash stretches the picture at the top of the hop.
    public static let bounceSpec = EffectSpec(kind: ClipEffect.bounceKind, title: "Bounce", params: loopCommon(0.6) + [
        slider(ClipEffect.bounceHeightKey, "Height", "% of frame", 5, 0...100, 0.1),
        slider(ClipEffect.bounceDirectionKey, "Direction", "\u{00B0}", 0, -3_600...3_600, 1, 0),
        slider(ClipEffect.bounceSquashKey, "Squash", "%", 0, 0...50, 1, 0),
    ])
    /// Pulse: scale breathes between From and To (smooth sine), optionally dipping the opacity at the small end.
    public static let pulseSpec = EffectSpec(kind: ClipEffect.pulseKind, title: "Pulse", params: loopCommon(0.8) + [
        slider(ClipEffect.pulseFromKey, "From", "%", 100, 0...10_000, 0.5),
        slider(ClipEffect.pulseToKey, "To", "%", 112, 0...10_000, 0.5),
        slider(ClipEffect.pulseFadeKey, "Fade Depth", "%", 0, 0...100, 1, 0),
    ])
    /// Wiggle: rotates back and forth by +-Angle (sine) every Period; Shift adds a sideways sway in % of the frame.
    public static let wiggleSpec = EffectSpec(kind: ClipEffect.wiggleKind, title: "Wiggle", params: loopCommon(0.5) + [
        slider(ClipEffect.wiggleAngleKey, "Angle", "\u{00B0}", 8, 0...180, 0.1),
        slider(ClipEffect.wiggleShiftKey, "Shift", "% of frame", 0, 0...100, 0.1),
    ])
    public static let specs: [EffectSpec] = [moveSpec, zoomSpec, popSpec, fadeSpec, shakeSpec, bounceSpec, pulseSpec, wiggleSpec]
    /// FB-G: Move, Zoom, Pop and Fade act once at a clip edge, so they are transitions now (`TransitionKind.isElement`,
    /// Fade = a one-sided Cross Dissolve). They are no longer offered as effects but keep evaluating in old projects.
    public static let retiredKinds: Set<String> = [ClipEffect.moveKind, ClipEffect.zoomKind, ClipEffect.popKind, ClipEffect.fadeKind]
    /// What the Effects panel and the palette offer: Shake and the loop animators.
    public static let offeredSpecs: [EffectSpec] = specs.filter { !retiredKinds.contains($0.kind) }

    // Specs by kind (default and range), read per frame.
    private static let table: [String: [String: EffectParamSpec]] = Dictionary(uniqueKeysWithValues: specs.map { s in
        (s.kind, Dictionary(uniqueKeysWithValues: s.params.map { ($0.key, $0) }))
    })

    /// Smooth deterministic noise in -1...1 (cubic-interpolated hashed lattice).
    static func noise(_ x: Double, seed: UInt64) -> Double {
        func h(_ i: Int64) -> Double {
            var z = UInt64(bitPattern: i) &* 0x9E37_79B9_7F4A_7C15 ^ seed &* 0xC2B2_AE3D_27D4_EB4F
            z ^= z >> 30; z &*= 0xBF58_476D_1CE4_E5B9; z ^= z >> 27; z &*= 0x94D0_49BB_1331_11EB; z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53) * 2 - 1
        }
        let f = floor(x), u = x - f, s = u * u * (3 - 2 * u)
        return h(Int64(f)) * (1 - s) + h(Int64(f) + 1) * s
    }

    /// The stage of motion effect `e` at clip-local `t` in a clip of timeline length `clipDuration` on a `frame` (px).
    static func stage(_ e: ClipEffect, atLocal t: Time, clipDuration: Time?, frame: Vec2) -> StageTransform {
        guard let specs = table[e.kind] else { return .identity }
        func v(_ k: String) -> Double {
            let spec = specs[k]
            let x = e.parameters[k]?.value(atLocal: t) ?? spec?.defaultValue ?? 0
            guard let r = spec?.range else { return x }
            return min(max(x, r.lowerBound), r.upperBound)
        }
        if let loop = loopStage(e.kind, local: KeyframeMath.seconds(t), frame: frame, v) { return loop }
        let mode = MotionMode(rawValue: Int(v(ClipEffect.motionModeKey).rounded())) ?? .in
        let curveKind = MotionCurve(rawValue: Int(v(ClipEffect.motionCurveKey).rounded())) ?? .premiereDefault
        let custom = curveKind == .custom ? e.customCurve : nil
        let curve = EaseFunction { curveKind.ease($0, custom: custom) }
        // An element transition's span is its exact length (not limited to the Duration's 60 s).
        let span = e.parameters[ClipEffect.elementSpanKey].map { max($0.value(atLocal: t), 1e-6) }
        let dIn = span ?? v(ClipEffect.motionDurationKey)
        let dOutRaw = span == nil ? v(ClipEffect.motionOutDurationKey) : 0
        let dOut = dOutRaw > 0 ? dOutRaw : dIn
        let local = KeyframeMath.seconds(t)
        // nil clip length = no end edge: Out windows never start, end fades never run.
        let total: Double? = clipDuration.flatMap { $0.value > 0 ? KeyframeMath.seconds($0) : nil }

        // Edge progress: eased, 0 before the edge window, 1 after it.
        let uIn = curve.ease(local / dIn)
        let uOut = total.map { curve.ease((local - ($0 - dOut)) / dOut) } ?? 0
        var phase = (local / dIn).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let tri = curve.ease(1 - abs(2 * phase - 1))

        switch e.kind {
        case ClipEffect.moveKind:
            let share: Double
            switch mode {
            case .in: share = 1 - uIn
            case .out: share = uOut
            case .inOut: share = min((1 - uIn) + uOut, 1)
            case .loop: share = tri
            }
            // Older effects without the Direction pop-up use the angle; without the Rotation pop-up the signed strength.
            let side = e.parameters[ClipEffect.moveSideKey] == nil ? MoveSide.angle
                : MoveSide(rawValue: Int(v(ClipEffect.moveSideKey).rounded())) ?? .left
            let a = (side.degrees ?? v(ClipEffect.moveDirectionKey)) * .pi / 180
            let dist = v(ClipEffect.moveDistanceKey) / 100 * (abs(sin(a)) * frame.x + abs(cos(a)) * frame.y)
            let strength = v(ClipEffect.moveRotationKey)
            let rotation: Double
            if e.parameters[ClipEffect.moveSpinKey] == nil { rotation = strength } else {
                switch MoveSpin(rawValue: Int(v(ClipEffect.moveSpinKey).rounded())) ?? .none {
                case .none: rotation = 0
                case .clockwise: rotation = abs(strength)
                case .counterClockwise: rotation = -abs(strength)
                }
            }
            let edgeScale = v(ClipEffect.moveScaleKey) / 100
            var opacity = 1.0
            if v(ClipEffect.moveFadeKey) >= 0.5, mode != .loop {
                let len = max(v(ClipEffect.moveFadeLengthKey), 1e-6)
                let fin = mode == .out ? 1 : min(max(local / len, 0), 1)
                let fout = mode == .in ? 1 : total.map { min(max(($0 - local) / len, 0), 1) } ?? 1
                opacity = fin * fout
            }
            return StageTransform(position: Vec2(sin(a) * dist * share, -cos(a) * dist * share),
                                  scale: max(1 + (edgeScale - 1) * share, 0), rotation: rotation * share, opacity: opacity)
        case ClipEffect.zoomKind:
            let from = v(ClipEffect.zoomFromKey), to = v(ClipEffect.zoomToKey)
            let pct: Double
            switch mode {
            case .in: pct = from + (to - from) * uIn
            case .out: pct = from + (to - from) * uOut
            case .inOut: pct = from + (to - from) * uIn * (1 - uOut)
            case .loop: pct = from + (to - from) * tri
            }
            return StageTransform(scale: pct / 100)
        case ClipEffect.popKind:
            let from = v(ClipEffect.popFromKey), peak = v(ClipEffect.popPeakKey), settle = max(v(ClipEffect.popSettleKey), 1e-6)
            let at = v(ClipEffect.popPeakAtKey) / 100
            func s(_ tau: Double, _ d: Double) -> Double {
                let x = min(max(tau / d, 0), 1)
                return x < at ? from + (peak - from) * curve.ease(x / at) : peak + (settle - peak) * curve.ease((x - at) / (1 - at))
            }
            let sOut = total.map { s($0 - local, dOut) } ?? settle
            let pct: Double
            switch mode {
            case .in: pct = s(local, dIn)
            case .out: pct = sOut / settle * 100
            case .inOut: pct = s(local, dIn) * sOut / settle
            case .loop:
                var tau = local.truncatingRemainder(dividingBy: dIn)
                if tau < 0 { tau += dIn }
                pct = s(tau, dIn) / settle * 100
            }
            return StageTransform(scale: pct / 100)
        case ClipEffect.fadeKind:
            let lo = v(ClipEffect.fadeStartKey) / 100
            let o: Double
            switch mode {
            case .in: o = lo + (1 - lo) * uIn
            case .out: o = lo + (1 - lo) * (1 - uOut)
            case .inOut: o = (lo + (1 - lo) * uIn) * (lo + (1 - lo) * (1 - uOut))
            case .loop: o = lo + (1 - lo) * tri
            }
            return StageTransform(opacity: o)
        case ClipEffect.shakeKind:
            let env: Double
            switch mode {
            case .in: env = 1 - uIn
            case .out: env = uOut
            case .inOut: env = min((1 - uIn) + uOut, 1)
            case .loop: env = 1
            }
            let seed = UInt64(max(v(ClipEffect.shakeSeedKey), 0).rounded())
            let x = local * v(ClipEffect.shakeSpeedKey)
            let amp = v(ClipEffect.shakeStrengthKey) / 100 * env
            return StageTransform(position: Vec2(noise(x, seed: seed &* 3 &+ 1) * amp * frame.x,
                                                 noise(x, seed: seed &* 3 &+ 2) * amp * frame.y),
                                  rotation: noise(x, seed: seed &* 3 &+ 3) * v(ClipEffect.shakeRotationKey) * env)
        default:
            return .identity
        }
    }

    /// Loop phase 0...1 at `local` seconds (Phase shifts it); periodic with the Period, pure in `local`.
    static func loopPhase(_ local: Double, period: Double, offset: Double) -> Double {
        let p = max(period, 1e-6)
        var x = (local / p + offset).truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        return x
    }

    /// The N3 loop animators (nil for every other kind).
    static func loopStage(_ kind: String, local: Double, frame: Vec2, _ v: (String) -> Double) -> StageTransform? {
        guard kind == ClipEffect.bounceKind || kind == ClipEffect.pulseKind || kind == ClipEffect.wiggleKind else { return nil }
        let ph = loopPhase(local, period: v(ClipEffect.loopPeriodKey), offset: v(ClipEffect.loopPhaseKey) / 100)
        switch kind {
        case ClipEffect.bounceKind:
            // Hop arc: 0 at the ground, 1 at the top (parabola), so each Period is one bounce.
            let arc = 1 - pow(2 * ph - 1, 2)
            let a = v(ClipEffect.bounceDirectionKey) * .pi / 180
            let dist = v(ClipEffect.bounceHeightKey) / 100 * (abs(sin(a)) * frame.x + abs(cos(a)) * frame.y) * arc
            // Squash: stretched at the top, flattened at the ground contact (uniform scale stays in the stage model).
            let sq = v(ClipEffect.bounceSquashKey) / 100
            return StageTransform(position: Vec2(sin(a) * dist, -cos(a) * dist), scale: 1 + sq * (arc - 0.5) * 0.5)
        case ClipEffect.pulseKind:
            let s = (1 - cos(2 * .pi * ph)) / 2                       // 0 -> 1 -> 0, smooth
            let from = v(ClipEffect.pulseFromKey), to = v(ClipEffect.pulseToKey)
            return StageTransform(scale: (from + (to - from) * s) / 100,
                                  opacity: 1 - v(ClipEffect.pulseFadeKey) / 100 * (1 - s))
        default:
            let w = sin(2 * .pi * ph)
            return StageTransform(position: Vec2(w * v(ClipEffect.wiggleShiftKey) / 100 * frame.x, 0),
                                  rotation: w * v(ClipEffect.wiggleAngleKey))
        }
    }
}
