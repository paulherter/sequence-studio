import Foundation

// W7.5 user presets that bake. Built-in effects stay live (D3); a user can still turn one Transform-stage effect into
// plain Motion keys ("Convert to Keyframes"). The clip remembers what was baked (recipe = the effect kind, plus the
// effect with all its parameters and the Motion it was baked onto), so "Re-open as Effect" gives the live effect back.
// Transitions are not clip effects and have no Convert command.
//
// Bake: the stage is composed onto Motion at every frame of the clip (`renderTransform`), so each frame renders as
// before; per-frame keys are then thinned to the ones a linear curve needs (a linear move keeps two keys).
// Only the last enabled stage can be baked (stages act inside Motion, so Motion ∘ stage_n is exact; an earlier stage
// would need the later ones moved inside it). Refused as well: an open Shutter Angle (Motion has no shutter), text
// generators (text conform scales Position per axis), and a format variant that overrides Motion or this effect.
// The baked curve matches the live one on the sequence frame grid (clip start on the grid); between frames, and after
// a retime to another rate, it is the linear in-between of the frame samples.
// Records stack: only the newest can be re-opened (an older bake lies under the newer one's keys).

public enum BakeError: Error, Equatable, Sendable {
    /// Not a Transform-stage effect, disabled, followed by another stage, overridden by a format variant,
    /// or the clip's Motion / Opacity is switched off.
    case notConvertible
    case recordNotFound
    /// Re-open on a record that is not the newest (`Clip.canReopenAsEffect`).
    case notNewest
}

/// What Convert to Keyframes baked into the clip's Motion (v29, `Clip.bakedEffects`).
public struct BakedEffect: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// The recipe: the effect kind that was baked (`ClipEffect.transformKind`, later the parametric motion kinds).
    public var recipeID: String
    /// The effect as it was, every parameter and key (clip-local times, kept in step with the clip).
    public var effect: ClipEffect
    /// Its place in `Clip.effects`.
    public var index: Int
    /// The clip's Motion / Opacity before the bake (restored by Re-open; volume is not part of the bake).
    public var motion: ClipAnimation

    public init(id: UUID = UUID(), recipeID: String, effect: ClipEffect, index: Int, motion: ClipAnimation) {
        self.id = id; self.recipeID = recipeID; self.effect = effect; self.index = index; self.motion = motion
    }

    func remapped(_ f: (Time) -> Time) -> BakedEffect {
        var b = self
        b.effect = effect.remapped(f); b.motion = motion.remapped(f)
        return b
    }

    /// Every key frozen at clip-local `t` (an inserted frame hold).
    func frozen(atLocal t: Time) -> BakedEffect {
        var b = self
        b.effect = effect.frozen(atLocal: t)
        let m = motion
        b.motion.position = AnimatedProperty(m.position.value(atLocal: t))
        b.motion.scale = AnimatedProperty(m.scale.value(atLocal: t))
        b.motion.rotation = AnimatedProperty(m.rotation.value(atLocal: t))
        b.motion.opacity = AnimatedProperty(m.opacity.value(atLocal: t))
        b.motion.anchor = AnimatedProperty(m.anchor.value(atLocal: t))
        return b
    }
}

extension Clip {
    /// Effects baked into Motion, newest last. Setting an empty list stores nothing.
    public var bakedEffects: [BakedEffect] {
        get { bakedStore ?? [] }
        set { bakedStore = newValue.isEmpty ? nil : newValue }
    }

    mutating func remapBakedKeys(_ f: (Time) -> Time) {
        guard let b = bakedStore else { return }
        bakedStore = b.map { $0.remapped(f) }
    }

    /// Whether Convert to Keyframes is offered for the effect `id`.
    public func canConvertToKeyframes(effect id: ClipEffect.ID) -> Bool {
        guard motionEnabled, opacityEnabled, let i = effects.firstIndex(where: { $0.id == id }) else { return false }
        let e = effects[i]
        guard e.enabled, e.isTransformStage else { return false }
        if effects[(i + 1)...].contains(where: { $0.enabled && $0.isTransformStage }) { return false }
        // A variant's own Motion replaces the baked keys wholesale (`resolved(for:)`): the stage would vanish there.
        if variantOverrides.values.contains(where: {
            $0.effectParameters[id] != nil || $0.position != nil || $0.scale != nil || $0.rotation != nil || $0.anchor != nil
        }) { return false }
        // Text conform scales Position per axis, which a baked R·S·offset does not survive when the axes differ.
        if generator?.kind == GeneratorRef.text { return false }
        // An open shutter blurs the picture; Motion has no shutter, so the bake would change the render.
        if let sh = e.parameters[ClipEffect.stageShutterAngleKey], sh.value > 0 || sh.track.keys.contains(where: { $0.value > 0 }) {
            return false
        }
        return true
    }

    /// Only the newest record can be re-opened: an older bake lies underneath the newer one's keys.
    public func canReopenAsEffect(_ record: BakedEffect.ID) -> Bool { bakedEffects.last?.id == record }

    /// Bakes the effect `id` into Motion keys sampled every `frameDuration`, removes it and records it.
    public mutating func convertToKeyframes(effect id: ClipEffect.ID, frameDuration fd: Time, frame: Vec2) throws {
        guard fd > .zero, canConvertToKeyframes(effect: id), let i = effects.firstIndex(where: { $0.id == id })
        else { throw BakeError.notConvertible }
        let fx = effects[i]
        var single = self
        single.effects = [fx]
        let a = animation
        let animated = a.position.isAnimated || a.scale.isAnimated || a.rotation.isAnimated || a.opacity.isAnimated
            || a.anchor.isAnimated || fx.parameters.values.contains(where: \.isAnimated)
            || fx.isMotionPreset   // FB-T3: motion effects animate without keys (their curve runs over the clip time)
        var times: [Time] = [.zero]
        if animated {
            var t = fd
            while t < duration { times.append(t); t = t + fd }
        }
        let samples = times.map { single.renderTransform(at: start + $0, frame: frame) }
        bakedEffects.append(BakedEffect(recipeID: fx.kind, effect: fx, index: i, motion: animation))
        animation.position = Self.baked(times, samples.map(\.position), \.x, \.y)
        animation.scale = Self.baked(times, samples.map(\.scale), \.x, \.y)
        animation.rotation = Self.baked(times, samples.map(\.rotation))
        animation.opacity = Self.baked(times, samples.map(\.opacity))
        effects.remove(at: i)
    }

    /// Puts the baked effect `record` back where it was and restores the Motion it was baked onto.
    public mutating func reopenAsEffect(_ record: BakedEffect.ID) throws {
        guard let r = bakedEffects.first(where: { $0.id == record }) else { throw BakeError.recordNotFound }
        guard canReopenAsEffect(record) else { throw BakeError.notNewest }
        var fx = r.effect
        if effects.contains(where: { $0.id == fx.id }) { fx.id = UUID() }
        let volume = animation.volume
        animation = r.motion
        animation.volume = volume
        effects.insert(fx, at: min(max(r.index, 0), effects.count))
        pinCovers()
        bakedEffects.removeAll { $0.id == record }
    }

    // MARK: Thinning

    /// A property from per-frame samples: static when every sample is the same, else linear keys where the curve bends.
    private static func baked(_ times: [Time], _ v: [Double]) -> AnimatedProperty<Double> {
        let keep = thinned(v.count) { i, a, b in near(v[i], lerp(v[a], v[b], i, a, b)) }
        return property(times, v, keep)
    }

    private static func baked(_ times: [Time], _ v: [Vec2], _ x: KeyPath<Vec2, Double>, _ y: KeyPath<Vec2, Double>)
        -> AnimatedProperty<Vec2> {
        let keep = thinned(v.count) { i, a, b in
            near(v[i][keyPath: x], lerp(v[a][keyPath: x], v[b][keyPath: x], i, a, b))
                && near(v[i][keyPath: y], lerp(v[a][keyPath: y], v[b][keyPath: y], i, a, b))
        }
        return property(times, v, keep)
    }

    private static func property<V: KeyframeValue>(_ times: [Time], _ v: [V], _ keep: [Int]) -> AnimatedProperty<V> {
        guard keep.count > 1 else { return AnimatedProperty(v[keep.first ?? 0]) }
        return AnimatedProperty(v[keep[0]], track: KeyframeTrack(keys: keep.map { Keyframe(time: times[$0], value: v[$0]) }))
    }

    /// Indices to keep: interior samples that lie on the line between their kept neighbors go, and so do flat runs at
    /// either end (a track holds its first value before the first key and its last after the last).
    /// `onLine(i, a, b)`: sample i lies on the line from sample a to sample b.
    private static func thinned(_ n: Int, onLine: (Int, Int, Int) -> Bool) -> [Int] {
        guard n > 1 else { return [0] }
        var keep = [0]
        var i = 1
        while i < n - 1 {
            let a = keep[keep.count - 1]
            // Drop i when every sample from a to i + 1 is on the line a -> i + 1.
            if !(a + 1...i).allSatisfy({ onLine($0, a, i + 1) }) { keep.append(i) }
            i += 1
        }
        keep.append(n - 1)
        // Flat ends: the hold before the first key and after the last key already give those values.
        func flat(_ p: Int, _ q: Int) -> Bool { onLine(p, q, q) }
        while keep.count > 1, flat(keep[keep.count - 1], keep[keep.count - 2]) { keep.removeLast() }
        while keep.count > 1, flat(keep[0], keep[1]) { keep.removeFirst() }
        return keep
    }

    private static func lerp(_ va: Double, _ vb: Double, _ i: Int, _ a: Int, _ b: Int) -> Double {
        b == a ? vb : va + (vb - va) * Double(i - a) / Double(b - a)
    }

    private static func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= 1e-9 * max(1, abs(x), abs(y)) }
}

extension Timeline {
    /// Whether Convert to Keyframes is offered for the effect `effect` of clip `clip` (never for a transition).
    public func canConvertToKeyframes(effect: ClipEffect.ID, in clip: Clip.ID) -> Bool {
        find(clip)?.clip.canConvertToKeyframes(effect: effect) ?? false
    }

    /// Convert to Keyframes at the sequence's frame rate. Throws `.clipNotFound`, `.trackLocked`, `BakeError`.
    public mutating func convertToKeyframes(effect: ClipEffect.ID, in clip: Clip.ID) throws {
        let fd = frameDuration
        let frame = Vec2(Double(format.displayWidth), Double(format.height))
        try editBaked(clip) { try $0.convertToKeyframes(effect: effect, frameDuration: fd, frame: frame) }
    }

    /// Re-open as Effect. Throws `.clipNotFound`, `.trackLocked`, `BakeError.recordNotFound` / `.notNewest`.
    public mutating func reopenAsEffect(_ record: BakedEffect.ID, in clip: Clip.ID) throws {
        try editBaked(clip) { try $0.reopenAsEffect(record) }
    }

    private mutating func editBaked(_ id: Clip.ID, _ body: (inout Clip) throws -> Void) throws {
        guard let m = find(id) else { throw EditError.clipNotFound }
        if tracks[m.track].isLocked { throw EditError.trackLocked }
        var c = m.clip
        try body(&c)
        tracks[m.track].replace(c)
    }
}
