import Foundation

// W7.1 effect transform stage. An effect of kind `transform` (Effects panel > Transform) or `reframe` (written by Auto
// Reframe, not offered in the panel) carries its own Position / Scale / Rotation / Anchor / Opacity that start at its
// own 100 % and multiply onto the clip's Motion: a 110 % stage on a clip at 120 % renders at 132 %, and the user's own
// Motion values and keys are never touched.
//
// Order: the stages act on the clip's own frame (source px from the frame center, y down) in list order, then Motion
// places the result: render = Motion ∘ stage_n ∘ ... ∘ stage_1. One stage maps p to R s (p - anchor) + anchor + position.
// Pixel effects (Crop, Blur, Shadow, ...) are applied before every stage, whatever their place in the list.
// The composed result is one `ClipTransform`; it is exact unless Motion's scale is non-uniform and the stages rotate
// (that needs a skew): then the frame center lands exactly and the picture is scaled after the summed rotation.
//
// Shutter Angle (Transform, and Motion's own since FB-G) blurs the clip's whole rendered motion (Motion and stages): the
// largest angle of Motion and the enabled stages opens a shutter centered on the frame, sampled `sampleCount` times (`LayerRequest.motionBlur`).
// Nested-sequence clips get the stage but no motion blur.

extension ClipEffect {
    public static let transformKind = "transform"
    public static let reframeKind = "reframe"
    // Stored parameter keys (never rename). Scalars, so format-variant effect-parameter overrides work on them.
    public static let stageAnchorXKey = "anchorX", stageAnchorYKey = "anchorY"
    public static let stagePositionXKey = "positionX", stagePositionYKey = "positionY"
    public static let stageScaleKey = "scale", stageScaleYKey = "scaleY", stageRotationKey = "rotation", stageOpacityKey = "opacity"
    public static let stageShutterAngleKey = "shutterAngle"

    /// Transform, Auto Reframe or Stabilizer: an effect with its own transform stage.
    public var isTransformStage: Bool {
        kind == Self.transformKind || kind == Self.reframeKind || kind == Self.dynamicZoomKind || kind == Self.stabilizeKind || isMotionPreset
    }

    /// The stage at clip-local `t` (identity for any other kind). Reads the stage keys directly (defaults and ranges as in
    /// `EffectTransformStage.params`), no catalog lookup: this runs per sub-frame sample on the render tick.
    ///
    /// Motion presets (W7.4: Move, Zoom, Pop, Fade, Shake) also need the clip's timeline length (Out and In & Out anchor to its
    /// end; nil = no end edge) and the canvas size in px (distances are a share of the canvas). Their Move and Shake positions
    /// come back in CANVAS px; `Clip.renderTransform` converts them to the stage's source px (see there).
    public func stageTransform(atLocal t: Time, clipDuration: Time?, frame: Vec2) -> StageTransform {
        guard isTransformStage else { return .identity }
        // A Gyroflow Stabilizer renders in its own pass; leftover Standard keys must not move the picture as well.
        if kind == Self.stabilizeKind, stabilizeMethod != .standard { return .identity }
        if isMotionPreset {
            return MotionEffects.stage(self, atLocal: t, clipDuration: clipDuration, frame: frame)
        }
        func v(_ k: String, _ d: Double, _ lo: Double, _ hi: Double) -> Double {
            min(max(parameters[k]?.value(atLocal: t) ?? d, lo), hi)
        }
        let p = 100_000.0
        return StageTransform(position: Vec2(v(Self.stagePositionXKey, 0, -p, p), v(Self.stagePositionYKey, 0, -p, p)),
                              scale: v(Self.stageScaleKey, 100, 0, 10_000) / 100,
                              scaleY: parameters[Self.stageScaleYKey] == nil ? nil : v(Self.stageScaleYKey, 100, 0, 10_000) / 100,
                              rotation: v(Self.stageRotationKey, 0, -36_000, 36_000),
                              anchor: Vec2(v(Self.stageAnchorXKey, 0, -p, p), v(Self.stageAnchorYKey, 0, -p, p)),
                              opacity: v(Self.stageOpacityKey, 100, 0, 100) / 100)
    }

    /// Shutter Angle at clip-local `t`: Transform's, and a motion preset's when it carries one (the element transitions
    /// write it from their Motion Blur, FB-G; a preset applied as an effect has none). 0 for any other kind.
    func stageShutterAngle(atLocal t: Time) -> Double {
        guard kind == Self.transformKind || isMotionPreset else { return 0 }
        return min(max(parameters[Self.stageShutterAngleKey]?.value(atLocal: t) ?? 0, 0), 360)
    }
}

/// One effect transform stage at one instant, in px of the clip's own frame.
public struct StageTransform: Sendable, Hashable {
    public var position: Vec2
    /// Width factor, linear (1 = 100 %), >= 0; also the height factor unless `scaleYOverride` is set.
    public var scale: Double
    /// Separate height factor (Transform's unlinked Scale, P5); nil = linked to `scale`.
    public var scaleYOverride: Double?
    public var scaleY: Double {
        get { scaleYOverride ?? scale }
        set { scaleYOverride = newValue }
    }
    /// Degrees, clockwise on screen.
    public var rotation: Double
    /// Pivot, offset from the frame center.
    public var anchor: Vec2
    /// 0...1.
    public var opacity: Double
    public init(position: Vec2 = .zero, scale: Double = 1, scaleY: Double? = nil, rotation: Double = 0, anchor: Vec2 = .zero,
                opacity: Double = 1) {
        self.position = position; self.scale = scale; self.scaleYOverride = scaleY; self.rotation = rotation; self.anchor = anchor; self.opacity = opacity
    }
    public static let identity = StageTransform()
    /// Moves no pixel (the anchor then does not matter) and keeps the opacity.
    public var isIdentity: Bool { position == .zero && scale == 1 && scaleY == 1 && rotation == 0 && opacity == 1 }
}

/// A 2-D affine map p -> L p + c (L row-major), in Double.
struct Affine2: Sendable, Hashable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0
    var t = Vec2.zero
    static let identity = Affine2()

    /// Rotation (degrees, clockwise with y down) times scale (sx, sy), scale applied first.
    static func rotScale(_ degrees: Double, _ sx: Double, _ sy: Double) -> Affine2 {
        let r = degrees * .pi / 180, co = cos(r), si = sin(r)
        return Affine2(a: co * sx, b: -si * sy, c: si * sx, d: co * sy)
    }
    func linear(_ p: Vec2) -> Vec2 { Vec2(a * p.x + b * p.y, c * p.x + d * p.y) }
    func apply(_ p: Vec2) -> Vec2 { linear(p) + t }
    /// self after `o`: p -> self(o(p)).
    func after(_ o: Affine2) -> Affine2 {
        Affine2(a: a * o.a + b * o.c, b: a * o.b + b * o.d, c: c * o.a + d * o.c, d: c * o.b + d * o.d, t: linear(o.t) + t)
    }
    /// The map of a stage: p -> R s (p - anchor) + anchor + position.
    init(_ s: StageTransform) {
        let m = Affine2.rotScale(s.rotation, s.scale, s.scaleY)
        self = m
        t = s.anchor + s.position - m.linear(s.anchor)
    }
    init(a: Double, b: Double, c: Double, d: Double, t: Vec2 = .zero) { self.a = a; self.b = b; self.c = c; self.d = d; self.t = t }
    init() {}
}

extension ClipTransform {
    /// Where the clip-frame point `p` (offset from the frame center, source px, y down) lands on the canvas (offset from
    /// the canvas center): R S (p - anchor) + position, as the compositor draws it.
    public func map(_ p: Vec2) -> Vec2 {
        Affine2.rotScale(rotation, scale.x, scale.y).linear(p - anchor) + position
    }
}

public enum EffectTransformStage {
    /// Motion's row order (Position, Scale, Rotation, Anchor, Opacity, Shutter); X/Y members are paired in the UI.
    static func params(shutter: Bool) -> [EffectParamSpec] {
        var p = [
            EffectParamSpec(key: ClipEffect.stagePositionXKey, title: "Position X", unit: "px", defaultValue: 0,
                            range: -100_000...100_000, step: 1, decimals: 1),
            EffectParamSpec(key: ClipEffect.stagePositionYKey, title: "Position Y", unit: "px", defaultValue: 0,
                            range: -100_000...100_000, step: 1, decimals: 1),
            EffectParamSpec(key: ClipEffect.stageScaleKey, title: "Scale", unit: "%", defaultValue: 100,
                            range: 0...10_000, step: 0.5, decimals: 1),
            // P5: stored only while Scale is unlinked (absent = Height follows Scale); never created by default.
            EffectParamSpec(key: ClipEffect.stageScaleYKey, title: "Scale Height", unit: "%", defaultValue: 100,
                            range: 0...10_000, step: 0.5, decimals: 1),
            EffectParamSpec(key: ClipEffect.stageRotationKey, title: "Rotation", unit: "\u{00B0}", defaultValue: 0,
                            range: -36_000...36_000, step: 1, decimals: 1),
            EffectParamSpec(key: ClipEffect.stageAnchorXKey, title: "Anchor X", unit: "px", defaultValue: 0,
                            range: -100_000...100_000, step: 1, decimals: 1),
            EffectParamSpec(key: ClipEffect.stageAnchorYKey, title: "Anchor Y", unit: "px", defaultValue: 0,
                            range: -100_000...100_000, step: 1, decimals: 1),
            EffectParamSpec(key: ClipEffect.stageOpacityKey, title: "Opacity", unit: "%", defaultValue: 100,
                            range: 0...100, step: 1, decimals: 1),
        ]
        if shutter {
            p.append(EffectParamSpec(key: ClipEffect.stageShutterAngleKey, title: "Shutter Angle", unit: "\u{00B0}",
                                     defaultValue: 0, range: 0...360, step: 1, decimals: 0))
        }
        return p
    }

    /// Offered in the Effects panel.
    public static let transformSpec = EffectSpec(kind: ClipEffect.transformKind, title: "Transform", params: params(shutter: true),
                                                 pairs: EffectParamPair.stagePairs)
    /// Written by Auto Reframe only (one per clip, replaced on the next run); `EffectCatalog.spec(for:)` knows it.
    public static let reframeSpec = EffectSpec(kind: ClipEffect.reframeKind, title: "Auto Reframe", params: params(shutter: false),
                                                pairs: EffectParamPair.stagePairs)

    /// Sub-frame samples for a shutter of `angle` degrees: none when closed, 2 at the least, 16 for a full 360.
    public static func sampleCount(shutterAngle angle: Double) -> Int {
        guard angle.isFinite, angle > 0 else { return 0 }
        return min(max(Int((min(angle, 360) / 22.5).rounded(.up)), 2), 16)
    }

    /// The Auto Reframe stage for a clip whose Motion is `base` (static, at the clip's first frame): together they put the
    /// picture at the absolute framing the planner chose (uniform `scale`, the base anchor at `position`). Position keys
    /// become X and Y keys at the same times with the same easing.
    public static func reframeEffect(scale: Double, position: AnimatedProperty<Vec2>, base: ClipTransform,
                                     id: UUID = UUID()) -> ClipEffect {
        // Motion maps q to B (q - a) + P0 with B = R S. With the stage anchor at a: render(p) = B s (p - a) + B pos + P0.
        // The plan wants scale_plan (p - a) + P(t): s = scale_plan / S, pos = B^-1 (P(t) - P0).
        let sx = base.scale.x, sy = base.scale.y
        let bs = sx > 0 && sy > 0 ? (sx + sy) / 2 : 1
        let inv = Affine2.rotScale(base.rotation, sx > 0 ? sx : 1, sy > 0 ? sy : 1)
        let det = inv.a * inv.d - inv.b * inv.c
        func local(_ p: Vec2) -> Vec2 {
            let q = p - base.position
            return Vec2((inv.d * q.x - inv.b * q.y) / det, (-inv.c * q.x + inv.a * q.y) / det)
        }
        func split(_ axis: KeyPath<Vec2, Double>) -> AnimatedProperty<Double> {
            let keys = position.track.keys.map { k in
                Keyframe(time: k.time, value: local(k.value)[keyPath: axis], interpolation: k.interpolation,
                         inHandle: k.inHandle, outHandle: k.outHandle)
            }
            return AnimatedProperty(local(position.value)[keyPath: axis], track: KeyframeTrack(keys: keys))
        }
        var e = ClipEffect.make(kind: ClipEffect.reframeKind)!
        e.id = id
        e.parameters[ClipEffect.stageAnchorXKey] = AnimatedProperty(base.anchor.x)
        e.parameters[ClipEffect.stageAnchorYKey] = AnimatedProperty(base.anchor.y)
        e.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(scale / bs * 100)
        e.parameters[ClipEffect.stagePositionXKey] = split(\.x)
        e.parameters[ClipEffect.stagePositionYKey] = split(\.y)
        return e
    }
}

/// Sub-frame transforms of one layer for motion blur: `transforms` (oldest first, same opacity as the layer) are drawn
/// with 1 / count of the opacity each and summed in a transparent `format` image (`RenderNode.tree`).
public struct MotionBlurSamples: Sendable, Hashable {
    /// The canvas of the sequence the layer lives in.
    public var format: SequenceFormat
    public var transforms: [ClipTransform]
    public init(format: SequenceFormat, transforms: [ClipTransform]) { self.format = format; self.transforms = transforms }
}

extension Clip {
    /// Has an enabled Transform / Auto Reframe effect.
    public var hasTransformStage: Bool { effects.contains { movesClip($0) } }

    /// `e` is an enabled stage of the clip's transform. A Transform with a live mask input is not: it warps the picture
    /// inside its masks instead (`EffectSegment.filter` = `ImageFilter.stageWarp`).
    func movesClip(_ e: ClipEffect) -> Bool { e.enabled && e.isTransformStage && !hasLiveMaskInput(e) && !e.stabilizeFillsEdges }

    /// What the renderer draws at timeline time `t`: Motion (`transform(at:)`) after the clip's enabled transform stages.
    /// Equal to `transform(at:)` when there is no stage.
    /// `frame` is the canvas the clip renders on (motion presets measure distances against it).
    /// Group Transform effects (an ungrouped Group's Motion, Grouping.swift) then act on the result in canvas px.
    public func renderTransform(at t: Time, frame: Vec2) -> ClipTransform {
        guard let first = effects.firstIndex(where: { movesClip($0) }) else {
            return applyingGroupStages(transform(at: t), at: t)
        }
        return renderTransform(at: t, stagesFrom: first, frame: frame)
    }

    /// `renderTransform(at:)` with the first enabled stage's index known (no rescan per motion-blur sample).
    func renderTransform(at t: Time, stagesFrom first: Int, frame: Vec2) -> ClipTransform {
        applyingGroupStages(stagedTransform(at: t, stagesFrom: first, frame: frame), at: t)
    }

    private func stagedTransform(at t: Time, stagesFrom first: Int, frame: Vec2) -> ClipTransform {
        let base = transform(at: t)
        let local = t - start
        let length = duration
        let motion = Affine2.rotScale(base.rotation, base.scale.x, base.scale.y)
        // Motion presets (Move, Shake) work in canvas px: a stage position p becomes (Motion after the later stages)^-1 p, so the
        // on-canvas shift is right whatever the clip's scale, Motion rotation or later stages. Collected first, converted last-to-first.
        var staged: [(index: Int, s: StageTransform)] = []
        for i in first..<effects.count where movesClip(effects[i]) {
            staged.append((i, effects[i].stageTransform(atLocal: local, clipDuration: length, frame: frame)))
        }
        var later = motion
        for k in staged.indices.reversed() {
            var c = staged[k].s
            c.scale = max(c.scale, 0); c.scaleY = max(c.scaleY, 0)
            if effects[staged[k].index].isMotionPreset, c.position != .zero {
                let det = later.a * later.d - later.b * later.c
                if abs(det) > 1e-12 {
                    let p = c.position
                    c.position = Vec2((later.d * p.x - later.b * p.y) / det, (-later.c * p.x + later.a * p.y) / det)
                } else { c.position = .zero }
            }
            staged[k].s = c
            later = later.after(Affine2.rotScale(c.rotation, c.scale, c.scaleY))
        }
        var f = Affine2.identity, rotation = 0.0, scale = Vec2(1, 1), opacity = 1.0, any = false
        for (_, s) in staged {
            opacity *= min(max(s.opacity, 0), 1)
            guard !s.isIdentity else { continue }
            var c = s; c.scale = max(s.scale, 0); c.scaleY = max(s.scaleY, 0)
            f = Affine2(c).after(f)
            rotation += c.rotation; scale = Vec2(scale.x * c.scale, scale.y * c.scaleY); any = true
        }
        var out = base
        out.opacity = base.opacity * opacity
        guard any else { return out }
        // Exact center: Motion after the stages, evaluated at the frame center.
        let centre = motion.linear(f.t - base.anchor) + base.position
        out.rotation = base.rotation + rotation
        out.scale = Vec2(base.scale.x * scale.x, base.scale.y * scale.y)
        // Keep Motion's anchor: position = center + L anchor, so map(.zero) == center.
        out.position = centre + Affine2.rotScale(out.rotation, out.scale.x, out.scale.y).linear(base.anchor)
        return out
    }

    /// Nothing that places the picture changes over time: no keyed Motion or Opacity property, no keyed parameter on an
    /// enabled transform or group stage, no live motion preset (they evaluate from the clip time). An open shutter then has
    /// nothing to blur, so `motionBlur` skips the sub-frame samples (FB-G: an open shutter on a still clip costs nothing).
    public var transformIsStatic: Bool {
        let a = animation
        if motionEnabled, a.position.isAnimated || a.scale.isAnimated || a.rotation.isAnimated || a.anchor.isAnimated
            || a.tiltX.isAnimated || a.tiltY.isAnimated { return false }
        if opacityEnabled, a.opacity.isAnimated { return false }
        for e in effects where movesClip(e) || e.enabled && e.kind == ClipEffect.groupTransformKind {
            if e.isMotionPreset { return false }
            if e.parameters.values.contains(where: \.isAnimated) || e.points.values.contains(where: \.isAnimated) { return false }
        }
        return true
    }

    /// The widest shutter open at clip-local `local`: Motion's own (when Motion is on) and every enabled stage's, 0...360.
    func shutterAngle(atLocal local: Time, stagesFrom first: Int?) -> Double {
        var angle = motionEnabled ? min(max(animation.shutterAngle.value(atLocal: local), 0), 360) : 0
        if let first {
            for i in first..<effects.count where effects[i].enabled && !hasLiveMaskInput(effects[i]) {
                angle = max(angle, effects[i].stageShutterAngle(atLocal: local))
            }
        }
        return angle
    }

    /// Motion-blur samples at `t` for a clip whose Motion or transform stages open a shutter; nil when it is closed or
    /// nothing moves.
    public func motionBlur(at t: Time, frameDuration fd: Time, format: SequenceFormat, opacityFactor: Double = 1) -> MotionBlurSamples? {
        let first = effects.firstIndex(where: { movesClip($0) })
        let hasEffect = effects.contains { $0.enabled && $0.kind == ClipEffect.motionBlurKind }
        guard first != nil || hasEffect || motionEnabled && animation.isShutterOpenOrKeyed else { return nil }
        let local = t - start
        // The widest shutter wins: Motion's / a transform stage's (centered, its own sample count) or the Motion Blur effect's
        // (its own side and smoothness).
        var shutter = MotionBlurShutter(angle: shutterAngle(atLocal: local, stagesFrom: first))
        if hasEffect, let fx = MotionBlurShutter.of(effects, atLocal: local), fx.angle >= shutter.angle { shutter = fx }
        let n = shutter.sampleCount
        guard n >= 2, fd.value > 0 else { return nil }
        // Sample k at t + fd * A/360 * s_k, A whole degrees, s_k = k/(n-1) - 1/2 (both sides), k/(n-1) - 1 (from the previous
        // frame) or k/(n-1) (toward the next): rational offsets, never Double time.
        let a = Int64(min(shutter.angle, 360).rounded())
        guard a > 0, !transformIsStatic else { return nil }
        let den = 720 * Int64(n - 1)
        let shift: Int64 = switch shutter.side { case .both: -Int64(n - 1); case .fromPrevious: -2 * Int64(n - 1); case .towardNext: 0 }
        let frame = Vec2(Double(format.displayWidth), Double(format.height))
        var out: [ClipTransform] = []
        out.reserveCapacity(n)
        for k in 0..<n {
            let tk = t + Time.scaled(fd, by: a * (2 * Int64(k) + shift), over: den)
            var tr = first.map { renderTransform(at: tk, stagesFrom: $0, frame: frame) } ?? renderTransform(at: tk, frame: frame)
            tr.opacity *= opacityFactor
            out.append(tr)
        }
        guard out.contains(where: { $0 != out[0] }) else { return nil }
        return MotionBlurSamples(format: format, transforms: out)
    }
}

extension Project {
    /// Some clip opens Motion's own Shutter Angle (v40).
    public var containsMotionShutter: Bool {
        // Also a baked effect's Motion: Re-open as Effect restores it, and older builds would drop its shutter.
        timelines.contains { $0.tracks.contains { $0.clips.contains { c in
            c.animation.isShutterOpenOrKeyed || c.bakedEffects.contains { $0.motion.isShutterOpenOrKeyed }
        } } }
    }
}
