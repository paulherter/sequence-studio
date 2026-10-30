import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64 = 0, frames: Int64 = 60) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(frames)), start: f(start), mediaDuration: f(300))
}
private let blur = ClipEffect.gaussianBlurKind
private let shadow = ClipEffect.dropShadowKind
private let k = ClipEffect.blurrinessKey

/// A Gaussian Blur with Blurriness 0 → 40 over the first 10 frames (clip-local), eased out.
private func animatedBlur(on c: inout Clip) -> ClipEffect.ID {
    let id = c.addEffect(kind: blur)!
    let i = c.effects.firstIndex { $0.id == id }!
    c.effects[i].parameters[k] = AnimatedProperty(0, track: KeyframeTrack(keys: [
        Keyframe(time: .zero, value: 0.0, interpolation: .bezier, outHandle: EaseHandle(dx: 0.6, dy: 0)),
        Keyframe(time: f(10), value: 40.0),
    ]))
    return id
}

@Suite struct EffectDefaultsTests {
    /// A Lens Distortion default saved before F7.15 has no `lensModel`: a new effect made from it still gets the key
    /// (the exact model); an effect already in a project is not touched.
    @Test func aLensDistortionDefaultFromBeforeTheModelKeyStillMakesNewEffectsWithIt() throws {
        let kind = ClipEffect.lensDistortionKind
        var old = try #require(ClipEffect.make(kind: kind))
        old.parameters[ClipEffect.lensCurvatureKey] = AnimatedProperty(-30)
        old.parameters[ClipEffect.lensModelKey] = nil
        var d = EffectDefaults()
        d.effects[kind] = old
        let made = try #require(d.makeEffect(kind: kind))
        #expect(made.parameters[ClipEffect.lensModelKey]?.value == 1)
        #expect(made.parameters[ClipEffect.lensCurvatureKey]?.value == -30)
        var c = clip()
        let added = c.addEffect(kind: kind, defaults: d)
        let id = try #require(added)
        #expect(c.effects.first { $0.id == id }?.parameters[ClipEffect.lensModelKey]?.value == 1)
        // Through the payload (a default read back from disk).
        let back = try EffectDefaults(payload: try d.payload(), version: EffectDefaults.payloadVersion)
        #expect(back.makeEffect(kind: kind)?.parameters[ClipEffect.lensModelKey]?.value == 1)
    }

    // MARK: Effects

    @Test func newInstanceStartsWithTheUserDefault() throws {
        var src = clip()
        let id = src.addEffect(kind: shadow)!
        src.setParameter(id, ClipEffect.shadowDistanceKey, to: 33)
        src.setColor(id, ClipEffect.shadowColorKey, to: EffectColor(red: 1, green: 0, blue: 0))
        var d = EffectDefaults()
        let ok = d.setDefault(from: src.effects.first { $0.id == id }!, keepKeyframes: true, at: .zero)
        #expect(ok)
        #expect(d.hasDefault(effect: shadow))

        var target = clip(100)
        let added = target.addEffect(kind: shadow, defaults: d)
        let nid = try #require(added)
        let e = try #require(target.effects.first { $0.id == nid })
        #expect(nid != id)
        #expect(e.parameters[ClipEffect.shadowDistanceKey]?.value == 33)
        #expect(e.colors[ClipEffect.shadowColorKey]?.value == EffectColor(red: 1, green: 0, blue: 0))
        // Another kind is untouched; no defaults = factory.
        var plain = clip()
        let pid = plain.addEffect(kind: shadow)!
        #expect(plain.effects.first { $0.id == pid }!.parameters == ClipEffect.make(kind: shadow)!.parameters)
    }

    @Test func styleKitMotionDefaultsPathAlsoUsesUserDefault() throws {
        var src = clip()
        let id = src.addEffect(kind: blur)!
        src.setParameter(id, k, to: 12)
        var d = EffectDefaults()
        d.setDefault(from: src.effects[0], keepKeyframes: true, at: .zero)
        var c = clip()
        let added = c.addEffect(kind: blur, motionDefaults: nil, defaults: d)
        let nid = try #require(added)
        #expect(c.effects.first { $0.id == nid }?.parameters[k]?.value == 12)
    }

    @Test func keyframesAreStoredRelativeToTheClipStartWithFreshIDs() throws {
        var src = clip(200, frames: 90)                 // sits at frame 200 on the timeline
        _ = animatedBlur(on: &src)
        var d = EffectDefaults()
        d.setDefault(from: src.effects[0], keepKeyframes: true, at: .zero)
        let saved = try #require(d.effect(blur)?.parameters[k])
        #expect(saved.track.keys.map(\.time) == [.zero, f(10)])

        var target = clip(500, frames: 40)
        let a = target.addEffect(kind: blur, defaults: d)!
        let b = target.addEffect(kind: blur, defaults: d)!
        let pa = target.effects.first { $0.id == a }!.parameters[k]!
        let pb = target.effects.first { $0.id == b }!.parameters[k]!
        #expect(pa.track.keys.map(\.time) == [.zero, f(10)])   // clip-local: from the new clip's first frame
        #expect(pa.track.keys.map(\.value) == [0, 40])
        #expect(pa.track.keys[0].outHandle == EaseHandle(dx: 0.6, dy: 0))   // the curve comes along
        #expect(Set(pa.track.keys.map(\.id)).isDisjoint(with: pb.track.keys.map(\.id)))
        #expect(Set(pa.track.keys.map(\.id)).isDisjoint(with: saved.track.keys.map(\.id)))
    }

    @Test func withoutKeyframesTheValueAtTheGivenTimeIsKept() throws {
        var src = clip()
        _ = animatedBlur(on: &src)
        var d = EffectDefaults()
        d.setDefault(from: src.effects[0], keepKeyframes: false, at: f(10))
        let p = try #require(d.effect(blur)?.parameters[k])
        #expect(!p.isAnimated && p.value == 40)
    }

    @Test func resetGoesToTheSavedDefaultElseFactory() throws {
        var src = clip()
        let sid = src.addEffect(kind: blur)!
        src.setParameter(sid, k, to: 12)
        var d = EffectDefaults()
        d.setDefault(from: src.effects[0], keepKeyframes: true, at: .zero)

        var c = clip()
        let id = c.addEffect(kind: blur, defaults: d)!
        c.setParameter(id, k, to: 99)
        let i = c.effects.firstIndex { $0.id == id }!
        c.effects[i].enabled = false
        let reset = c.resetEffect(id, defaults: d); #expect(reset)
        #expect(c.effects[i].id == id && c.effects[i].enabled)
        #expect(c.effects[i].parameters[k]?.value == 12)

        // Reset Default to Factory: the saved default is gone, Reset goes to the built-in values.
        d.removeDefault(effect: blur)
        #expect(!d.hasDefault(effect: blur))
        let reset2 = c.resetEffect(id, defaults: d); #expect(reset2)
        #expect(c.effects[i].parameters == ClipEffect.make(kind: blur)!.parameters)
        // A new instance is factory again (with the applied start values, AUDIT G13).
        var n = clip()
        let nid = n.addEffect(kind: blur, defaults: d)!
        var factory = ClipEffect.make(kind: blur)!.parameters
        for (key, v) in ClipEffect.appliedStartValues[blur] ?? [:] { factory[key] = AnimatedProperty(v) }
        #expect(n.effects.first { $0.id == nid }!.parameters == factory)
    }

    @Test func resetRestoresTheDefaultsKeyframes() throws {
        var src = clip()
        _ = animatedBlur(on: &src)
        var d = EffectDefaults()
        d.setDefault(from: src.effects[0], keepKeyframes: true, at: .zero)
        var c = clip()
        let id = c.addEffect(kind: blur, defaults: d)!
        let i = c.effects.firstIndex { $0.id == id }!
        c.effects[i].parameters[k] = AnimatedProperty(5)
        c.resetEffect(id, defaults: d)
        #expect(c.effects[i].parameters[k]?.track.keys.map(\.value) == [0, 40])
    }

    @Test func colourAndGeneratorOwnedKindsCannotHaveADefault() {
        #expect(!EffectDefaults.canHaveDefault(kind: ClipEffect.colorKind))
        #expect(!EffectDefaults.canHaveDefault(kind: "noSuchEffect"))
        #expect(EffectDefaults.canHaveDefault(kind: blur))
        var d = EffectDefaults()
        let ok = d.setDefault(from: ClipEffect(kind: ClipEffect.colorKind), keepKeyframes: true, at: .zero)
        #expect(!ok)
        #expect(d.isEmpty)
    }

    @Test func parametersTheCatalogNoLongerKnowsAreDroppedAndNewOnesStartAtFactory() throws {
        var e = ClipEffect.make(kind: blur)!
        e.parameters["gone"] = AnimatedProperty(3)
        e.parameters[k] = AnimatedProperty(7)
        let d = EffectDefaults(effects: [blur: e])
        let made = try #require(d.makeEffect(kind: blur))
        #expect(made.parameters["gone"] == nil && made.parameters[k]?.value == 7)
        #expect(Set(made.parameters.keys) == Set(ClipEffect.make(kind: blur)!.parameters.keys))
    }

    // MARK: Transitions

    private func cut() throws -> (Timeline, Track.ID, Clip, Clip, Clip) {
        var v = Track(kind: .video, name: "V1")
        let a = clip(0), b = clip(60), c = clip(120)
        for x in [a, b, c] { try v.overwrite(x) }
        return (Timeline(name: "T", frameDuration: fd, tracks: [v]), v.id, a, b, c)
    }

    @Test func transitionDefaultIsPerKindAndAppliesToEveryEdge() throws {
        var (t, track, a, b, c) = try cut()
        let first = try t.addTransition(kind: .push, track: track, outgoing: a.id, incoming: b.id, duration: f(12))
        try t.setTransition(first, easing: .fastStart, direction: .up, motionBlur: 1.5)
        var d = EffectDefaults()
        d.setDefault(from: t.transition(first)!.1)
        #expect(d.hasDefault(transition: .push) && !d.hasDefault(transition: .crossDissolve))
        #expect(d.transition(.push)?.duration == f(12))

        // Next cut, and a single-sided transition at a clip end: both take the look.
        let second = try t.addTransition(point: .cut(outgoing: b.id, incoming: c.id), kind: .push, track: track, duration: d.transition(.push)!.duration)
        try t.applyTransitionDefault(d.transition(.push)!, to: second)
        let tail = try t.addTransition(point: .tail(c.id), kind: .push, track: track, duration: f(6), alignment: .endAtCut)
        try t.applyTransitionDefault(d.transition(.push)!, to: tail)
        for id in [second, tail] {
            let tr = t.transition(id)!.1
            #expect(tr.effectiveEasing == .fastStart && tr.effectiveDirection == .up && tr.effectiveMotionBlur == 1.5)
        }
        // The place decides the alignment, not the default.
        #expect(t.transition(tail)!.1.alignment == .endAtCut)
    }

    @Test func transitionResetGoesToUserDefaultElseFactory() throws {
        var (t, track, a, b, _) = try cut()
        let id = try t.addTransition(kind: .push, track: track, outgoing: a.id, incoming: b.id, duration: f(12))
        try t.setTransition(id, easing: .fastStart, direction: .up, motionBlur: 1.5)
        var d = EffectDefaults()
        d.setDefault(from: t.transition(id)!.1)

        try t.setTransition(id, duration: f(20), easing: .easeIn, direction: .down, motionBlur: 0)
        try t.resetTransition(id, to: d.transition(.push), factoryDuration: f(30))
        var tr = t.transition(id)!.1
        #expect(tr.duration == f(12) && tr.effectiveEasing == .fastStart && tr.effectiveDirection == .up)

        d.removeDefault(transition: .push)
        try t.resetTransition(id, to: d.transition(.push), factoryDuration: f(30))
        tr = t.transition(id)!.1
        // Factory: the kind's settling curve (DECISIONS 2026-10-06), nothing else of its own.
        #expect(tr.duration == f(30) && tr.easing == .easeOut100 && tr.direction == nil && tr.motionBlur == nil && tr.softness == nil)
    }

    // MARK: Payload

    @Test func payloadRoundTripsAndRejectsNewerVersion() throws {
        var src = clip()
        _ = animatedBlur(on: &src)
        var d = EffectDefaults()
        d.setDefault(from: src.effects[0], keepKeyframes: true, at: .zero)
        d.transitions[TransitionKind.crossDissolve.rawValue] = TransitionPreset(kind: .crossDissolve, duration: f(8))
        let data = try d.payload()
        #expect(try EffectDefaults(payload: data, version: EffectDefaults.payloadVersion) == d)
        #expect(throws: EffectDefaults.PayloadError.newerVersion(found: 2, supported: 1)) {
            _ = try EffectDefaults(payload: data, version: 2)
        }
    }
}
