import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip() -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(5)), start: s(0))
}

private func close(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }
private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { close(a.x, b.x) && close(a.y, b.y) && close(a.z, b.z) }

/// A v23 Drop Shadow as older builds stored it: three 0...255 channels and a 0/1 Shadow Only slider.
private func legacyShadow(red: AnimatedProperty<Double>, green: AnimatedProperty<Double> = AnimatedProperty(0),
                          blue: AnimatedProperty<Double> = AnimatedProperty(0), only: AnimatedProperty<Double> = AnimatedProperty(0)) -> ClipEffect {
    ClipEffect(kind: ClipEffect.dropShadowKind, parameters: [
        ClipEffect.shadowRedKey: red, ClipEffect.shadowGreenKey: green, ClipEffect.shadowBlueKey: blue,
        ClipEffect.shadowOpacityKey: AnimatedProperty(80), ClipEffect.shadowDirectionKey: AnimatedProperty(135),
        ClipEffect.shadowDistanceKey: AnimatedProperty(10), ClipEffect.shadowSoftnessKey: AnimatedProperty(4),
        ClipEffect.shadowOnlyKey: only,
    ])
}

private func project(with effects: [ClipEffect]) -> Project {
    var c = clip()
    c.effects = effects
    let t = Timeline(name: "t", frameDuration: Time(1, 25), tracks: [Track(kind: .video, clips: [c])])
    return Project(name: "P", timelines: [t])
}
private func project(with effect: ClipEffect) -> Project { project(with: [effect]) }

/// Encodes `p` with an older format number, then loads it through the migration chain.
private func loadAsV23(_ p: Project) throws -> Project {
    var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
    obj["formatVersion"] = 23
    return try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
}

@Suite struct EffectParamTypesTests {
    // MARK: Values

    @Test func colourIsKeyframable() {
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        var p = AnimatedProperty(EffectColor.black)
        p.track.insert(Keyframe(time: s(0), value: EffectColor(red: 0, green: 0, blue: 0)))
        p.track.insert(Keyframe(time: s(2), value: EffectColor(red: 1, green: 0.5, blue: 0, alpha: 0.5)))
        e.colors[ClipEffect.shadowColorKey] = p
        let mid = e.color(ClipEffect.shadowColorKey, atLocal: s(1))
        #expect(close(mid.red, 0.5) && close(mid.green, 0.25) && close(mid.blue, 0) && close(mid.alpha, 0.75))
    }

    @Test func colourClampsToUnitRange() {
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        e.colors[ClipEffect.shadowColorKey] = AnimatedProperty(EffectColor(red: 1.4, green: -0.2, blue: 0.5))
        #expect(e.color(ClipEffect.shadowColorKey, atLocal: .zero) == EffectColor(red: 1, green: 0, blue: 0.5))
    }

    @Test func pointIsKeyframableAndFallsBackToDefault() {
        var e = ClipEffect(kind: "test")
        #expect(e.point("centre", atLocal: .zero) == .zero)
        var p = AnimatedProperty(Vec2(0, 0))
        p.track.insert(Keyframe(time: s(0), value: Vec2(0, 0)))
        p.track.insert(Keyframe(time: s(4), value: Vec2(100, -40)))
        e.points["centre"] = p
        #expect(e.point("centre", atLocal: s(1)) == Vec2(25, -10))
    }

    @Test func choiceRoundsAndClamps() {
        let k = EffectParamKind.choice(["A", "B", "C"])
        #expect(k.choiceIndex(for: 1.4) == 1)
        #expect(k.choiceIndex(for: 1.6) == 2)
        #expect(k.choiceIndex(for: -3) == 0)
        #expect(k.choiceIndex(for: 9) == 2)
        #expect(EffectParamKind.checkbox.isOn(0.5) && !EffectParamKind.checkbox.isOn(0.49))
    }

    // MARK: Catalog

    @Test func dropShadowUsesColourAndCheckbox() {
        let spec = EffectCatalog.spec(for: ClipEffect.dropShadowKind)!
        #expect(spec.params.map(\.title) == ["Shadow Color", "Opacity", "Direction", "Distance", "Spread", "Softness", "Shadow Only"])
        #expect(EffectCatalog.param(ClipEffect.dropShadowKind, ClipEffect.shadowColorKey)?.kind == .color(.black))
        #expect(EffectCatalog.param(ClipEffect.dropShadowKind, ClipEffect.shadowOnlyKey)?.kind == .checkbox)
        let e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        #expect(e.colors[ClipEffect.shadowColorKey]?.value == .black)
        #expect(e.parameters[ClipEffect.shadowColorKey] == nil)
        #expect(e.parameters[ClipEffect.shadowRedKey] == nil)
        #expect(e.parameters.count == 6)
        #expect(e.points.isEmpty)
    }

    // MARK: Evaluation

    @Test func shadowColourComesFromTheColourParameter() {
        var c = clip()
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        var col = AnimatedProperty(EffectColor.black)
        col.track.insert(Keyframe(time: s(0), value: EffectColor(red: 0, green: 0, blue: 0)))
        col.track.insert(Keyframe(time: s(2), value: EffectColor(red: 1, green: 0, blue: 0.4)))
        e.colors[ClipEffect.shadowColorKey] = col
        c.effects = [e]
        #expect(close(c.effects(at: s(1)).segments[0].shadow!.color, SIMD3(0.5, 0, 0.2)))
        #expect(close(c.effects(at: s(2)).segments[0].shadow!.color, SIMD3(1, 0, 0.4)))
    }

    @Test func shadowOnlyCheckboxKeyframesHold() {
        var c = clip()
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        var only = AnimatedProperty(0.0)
        only.track.insert(Keyframe(time: s(0), value: 0, interpolation: .hold))
        only.track.insert(Keyframe(time: s(2), value: 1, interpolation: .hold))
        e.parameters[ClipEffect.shadowOnlyKey] = only
        c.effects = [e]
        #expect(c.effects(at: Time(19, 10)).segments[0].shadow!.shadowOnly == false)
        #expect(c.effects(at: s(2)).segments[0].shadow!.shadowOnly == true)
    }

    // MARK: Editing

    @Test func setColourAndPointKeepKeys() {
        var c = clip()
        let id = c.addEffect(kind: ClipEffect.dropShadowKind)!
        c.setColor(id, ClipEffect.shadowColorKey, to: EffectColor(red: 0.2, green: 0.4, blue: 0.6))
        #expect(c.effects[0].colors[ClipEffect.shadowColorKey]?.value == EffectColor(red: 0.2, green: 0.4, blue: 0.6))
        c.setPoint(id, "centre", to: Vec2(3, 4))
        #expect(c.effects[0].points["centre"]?.value == Vec2(3, 4))
    }

    @Test func colourAndPointKeysShiftWithTheClipAndSnap() {
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        e.colors[ClipEffect.shadowColorKey]!.track.insert(Keyframe(time: s(1), value: .black))
        e.points["centre"] = AnimatedProperty(.zero, track: KeyframeTrack(keys: [Keyframe(time: s(2), value: .zero)]))
        let moved = e.shifted(by: s(1))
        #expect(moved.colors[ClipEffect.shadowColorKey]!.track.keys.map(\.time) == [s(2)])
        #expect(moved.points["centre"]!.track.keys.map(\.time) == [s(3)])
        var c = clip()
        c.effects = [e]
        #expect(c.keyframeTimes.contains(s(1)) && c.keyframeTimes.contains(s(2)))
    }

    // MARK: Codable

    @Test func effectRoundTripsTypedParameters() throws {
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        e.colors[ClipEffect.shadowColorKey] = AnimatedProperty(EffectColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
        e.points["centre"] = AnimatedProperty(Vec2(5, 6))
        let back = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(e))
        #expect(back == e)
    }

    @Test func effectWithoutTypedParametersOmitsAndDecodesThem() throws {
        let e = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        #expect(obj["colors"] == nil && obj["points"] == nil)
        let back = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(e))
        #expect(back == e)
    }

    // MARK: v24 migration

    @Test func currentVersionIsAtLeast24() { #expect(ProjectFile.currentVersion >= 24) }

    @Test func staticLegacyShadowOpensIdentical() throws {
        let legacy = legacyShadow(red: AnimatedProperty(255), green: AnimatedProperty(0), blue: AnimatedProperty(51),
                                  only: AnimatedProperty(1))
        let loaded = try loadAsV23(project(with: legacy))
        let e = loaded.timelines[0].tracks[0].clips[0].effects[0]
        #expect(e.id == legacy.id)
        #expect(e.parameters[ClipEffect.shadowRedKey] == nil && e.parameters[ClipEffect.shadowGreenKey] == nil
                && e.parameters[ClipEffect.shadowBlueKey] == nil)
        let col = try #require(e.colors[ClipEffect.shadowColorKey])
        #expect(!col.isAnimated)
        #expect(close(SIMD3(col.value.red, col.value.green, col.value.blue), SIMD3(1, 0, 0.2)) && col.value.alpha == 1)
        let sh = loaded.timelines[0].tracks[0].clips[0].effects(at: s(1)).segments[0].shadow!
        #expect(close(sh.color, SIMD3(1, 0, 0.2)))
        #expect(sh.shadowOnly && close(sh.opacity, 0.8) && abs(sh.sigma - 0.8) < 1e-12)
    }

    @Test func keyframedLegacyChannelsBecomeOneColourTrack() throws {
        var red = AnimatedProperty(0.0)
        red.track.insert(Keyframe(time: s(0), value: 0))
        red.track.insert(Keyframe(time: s(2), value: 255))
        var blue = AnimatedProperty(0.0)
        blue.track.insert(Keyframe(time: s(0), value: 102))
        blue.track.insert(Keyframe(time: s(2), value: 0))
        let legacy = legacyShadow(red: red, green: AnimatedProperty(51), blue: blue)
        var before = clip(); before.effects = [legacy]
        let loaded = try loadAsV23(project(with: legacy))
        let after = loaded.timelines[0].tracks[0].clips[0]
        let col = try #require(after.effects[0].colors[ClipEffect.shadowColorKey])
        #expect(col.track.keys.map(\.time) == [s(0), s(2)])
        for t in [s(0), Time(1, 2), s(1), Time(3, 2), s(2), s(3)] {
            #expect(close(after.effects(at: t).segments[0].shadow!.color, before.legacyShadowColor(at: t)))
        }
    }

    @Test func legacyChannelsKeyedAtDifferentTimesMergeTheirKeyTimes() throws {
        var red = AnimatedProperty(0.0)
        red.track.insert(Keyframe(time: s(0), value: 0))
        red.track.insert(Keyframe(time: s(4), value: 255))
        var green = AnimatedProperty(0.0)
        green.track.insert(Keyframe(time: s(2), value: 255, interpolation: .hold))
        let legacy = legacyShadow(red: red, green: green)
        var before = clip(); before.effects = [legacy]
        let after = try loadAsV23(project(with: legacy)).timelines[0].tracks[0].clips[0]
        let col = try #require(after.effects[0].colors[ClipEffect.shadowColorKey])
        #expect(col.track.keys.map(\.time) == [s(0), s(2), s(4)])
        // Red's linear ramp split at 2 s stays linear, green is constant: exact everywhere.
        for t in [s(0), Time(1, 3), s(1), s(2), Time(7, 3), s(3), s(4), s(5)] {
            #expect(close(after.effects(at: t).segments[0].shadow!.color, before.legacyShadowColor(at: t)))
        }
    }

    private static let eased = EaseHandle(dx: 0.6, dy: 0), easedIn = EaseHandle(dx: 0.4, dy: 1)

    private func ramp(_ from: Double, _ to: Double, _ interpolation: Interpolation = .linear,
                      out: EaseHandle = .linear, in inH: EaseHandle = .linear) -> AnimatedProperty<Double> {
        var p = AnimatedProperty(from)
        p.track.insert(Keyframe(time: s(0), value: from, interpolation: interpolation, outHandle: out))
        p.track.insert(Keyframe(time: s(2), value: to, inHandle: inH))
        return p
    }

    /// Every 1/30 s from 0 to 3 s (the migration samples segments it cannot express on this grid).
    private var grid: [Time] { (0...90).map { Time(Int64($0), 30) } }

    @Test func sharedEaseIsKeptWithoutExtraKeys() throws {
        let legacy = legacyShadow(red: ramp(0, 255, .bezier, out: Self.eased, in: Self.easedIn),
                                  green: ramp(255, 0, .bezier, out: Self.eased, in: Self.easedIn), blue: AnimatedProperty(40))
        var before = clip(); before.effects = [legacy]
        let after = try loadAsV23(project(with: legacy)).timelines[0].tracks[0].clips[0]
        let col = try #require(after.effects[0].colors[ClipEffect.shadowColorKey])
        #expect(col.track.keys.map(\.time) == [s(0), s(2)])
        #expect(col.track.keys[0].outHandle == Self.eased && col.track.keys[1].inHandle == Self.easedIn)
        for t in grid + [Time(37, 100), Time(151, 100)] {
            #expect(close(after.effects(at: t).segments[0].shadow!.color, before.legacyShadowColor(at: t)))
        }
    }

    @Test func mixedHoldAndLinearAtSharedTimesStayExactAtSamples() throws {
        let legacy = legacyShadow(red: ramp(0, 255, .hold), green: ramp(0, 255))
        var before = clip(); before.effects = [legacy]
        let after = try loadAsV23(project(with: legacy)).timelines[0].tracks[0].clips[0]
        let col = try #require(after.effects[0].colors[ClipEffect.shadowColorKey])
        #expect(col.track.keys.count > 2)
        for t in grid {
            #expect(close(after.effects(at: t).segments[0].shadow!.color, before.legacyShadowColor(at: t)))
        }
    }

    @Test func mixedHandlesAtSharedTimesStayExactAtSamples() throws {
        let legacy = legacyShadow(red: ramp(0, 255, .bezier, out: Self.eased, in: Self.easedIn), green: ramp(0, 255),
                                  blue: ramp(255, 0, .bezier, out: Self.easedIn, in: Self.eased))
        var before = clip(); before.effects = [legacy]
        let after = try loadAsV23(project(with: legacy)).timelines[0].tracks[0].clips[0]
        for t in grid {
            #expect(close(after.effects(at: t).segments[0].shadow!.color, before.legacyShadowColor(at: t)))
        }
    }

    @Test func holdOnAllChannelsStaysHold() throws {
        let legacy = legacyShadow(red: ramp(0, 255, .hold), green: ramp(10, 20, .hold), blue: AnimatedProperty(3))
        var before = clip(); before.effects = [legacy]
        let after = try loadAsV23(project(with: legacy)).timelines[0].tracks[0].clips[0]
        let col = try #require(after.effects[0].colors[ClipEffect.shadowColorKey])
        #expect(col.track.keys.map(\.time) == [s(0), s(2)] && col.track.keys[0].interpolation == .hold)
        for t in grid + [Time(199, 100)] {
            #expect(close(after.effects(at: t).segments[0].shadow!.color, before.legacyShadowColor(at: t)))
        }
    }

    @Test func migratedProjectStaysPutWhenSavedAgain() throws {
        let legacy = legacyShadow(red: AnimatedProperty(10), green: AnimatedProperty(20), blue: AnimatedProperty(30))
        let once = try loadAsV23(project(with: legacy))
        let again = try ProjectFile.decode(ProjectFile.encode(once), migrations: ProjectFile.migrations)
        #expect(again == once)
    }

    @Test func otherEffectsAndNewShadowsAreUntouched() throws {
        var blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        blur.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(7)
        let fresh = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        let loaded = try loadAsV23(project(with: [blur, fresh]))
        #expect(loaded.timelines[0].tracks[0].clips[0].effects == [blur, fresh])
    }
}

extension Clip {
    /// What a v23 build rendered for the three legacy channels at `t` (0...1).
    fileprivate func legacyShadowColor(at t: Time) -> SIMD3<Double> {
        let e = effects[0], l = t - start
        func ch(_ k: String) -> Double { min(max(e.parameters[k]!.value(atLocal: l), 0), 255) / 255 }
        return SIMD3(ch(ClipEffect.shadowRedKey), ch(ClipEffect.shadowGreenKey), ch(ClipEffect.shadowBlueKey))
    }
}
