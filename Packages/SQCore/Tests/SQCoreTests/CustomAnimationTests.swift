import XCTest
@testable import SQCore

final class CustomAnimationTests: XCTestCase {
    private let f = Time(1, 30)
    private var clip: Time { Time(3, 1) }

    private func fadeIn(_ end: Time) -> KeyframeTemplate {
        KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (end, 1, .linear)])], duration: end)
    }
    private func fadeOut(_ length: Time) -> KeyframeTemplate {
        KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (length, 0, .linear)])],
                         duration: length, anchor: .end)
    }

    // MARK: Off

    func testOffIsNoAnimationBitForBit() {
        let off = AnimationSet(in: nil, out: nil)
        for t in [Time.zero, f * 7, clip, clip + f] {
            XCTAssertEqual(off.sample(clipTime: t, clipDuration: clip), .rest)
            XCTAssertTrue(off.sample(clipTime: t, clipDuration: clip).isRest)
        }
        XCTAssertNil(AnimationSet(single: KeyframeTemplate.none))
        XCTAssertNil(AnimationSet(single: nil))
        // A row that was read and written back without a key leaves Off as it was: the same bits.
        var s = off
        s.edit(.scale, side: .intro, clipDuration: clip) { _ in }
        XCTAssertEqual(s.sample(clipTime: f * 3, clipDuration: clip), .rest)
        XCTAssertEqual(s, off)
    }

    // MARK: Ranges

    func testIntroAndOutroRangesInClipTime() {
        let s = AnimationSet(in: fadeIn(f * 10), out: fadeOut(f * 6))
        XCTAssertEqual(s.offset(of: .intro, clipDuration: clip), .zero)
        XCTAssertEqual(s.offset(of: .outro, clipDuration: clip), clip - f * 6)
        XCTAssertEqual(s.scalar(.opacity, side: .intro, clipDuration: clip).track.keys.map(\.time), [.zero, f * 10])
        XCTAssertEqual(s.scalar(.opacity, side: .outro, clipDuration: clip).track.keys.map(\.time), [clip - f * 6, clip])
        // A row nothing keys rests.
        let scale = s.scalar(.scale, side: .intro, clipDuration: clip)
        XCTAssertFalse(scale.isAnimated)
        XCTAssertEqual(scale.value, 1)
        XCTAssertEqual(s.position(side: .outro, clipDuration: clip).value, .zero)
    }

    func testValuesAtBothEnds() {
        var s = AnimationSet(in: nil, out: nil)
        s.edit(.scale, side: .intro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.5), Keyframe(time: self.f * 12, value: 1)])
        }
        s.edit(.rotation, side: .outro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: self.clip - self.f * 9, value: 0), Keyframe(time: self.clip, value: 45)])
        }
        XCTAssertEqual(s.animationIn?.duration, f * 12)
        XCTAssertEqual(s.animationOut?.duration, f * 9)
        XCTAssertEqual(s.animationIn?.anchor, .start)
        XCTAssertEqual(s.animationOut?.anchor, .end)
        XCTAssertEqual(s.sample(clipTime: .zero, clipDuration: clip).scale, 0.5)
        XCTAssertEqual(s.sample(clipTime: f * 12, clipDuration: clip).scale, 1)
        XCTAssertEqual(s.sample(clipTime: f * 40, clipDuration: clip), .rest)
        XCTAssertEqual(s.sample(clipTime: clip - f * 9, clipDuration: clip).rotation, 0)
        XCTAssertEqual(s.sample(clipTime: clip, clipDuration: clip).rotation, 45)
        XCTAssertEqual(s.sample(clipTime: f * 6, clipDuration: clip).scale, 0.75, accuracy: 1e-9)
    }

    // MARK: Writing keeps clip times

    func testMovingTheFirstOutroKeyKeepsEveryClipTime() {
        var s = AnimationSet(in: nil, out: fadeOut(f * 6))
        let early = clip - f * 11
        s.edit(.opacity, side: .outro, clipDuration: clip) { p in
            let first = p.track.keys[0].id
            p.track.move(first, to: early)
        }
        XCTAssertEqual(s.animationOut?.duration, f * 11)
        XCTAssertEqual(s.scalar(.opacity, side: .outro, clipDuration: clip).track.keys.map(\.time), [early, clip])
        XCTAssertEqual(s.sample(clipTime: early, clipDuration: clip).opacity, 1)
        XCTAssertEqual(s.sample(clipTime: clip, clipDuration: clip).opacity, 0)
        // And later again: the side gets shorter, the end stays at the clip's end.
        s.edit(.opacity, side: .outro, clipDuration: clip) { p in
            let first = p.track.keys[0].id
            p.track.move(first, to: self.clip - self.f * 4)
        }
        XCTAssertEqual(s.animationOut?.duration, f * 4)
        XCTAssertEqual(s.scalar(.opacity, side: .outro, clipDuration: clip).track.keys.map(\.time), [clip - f * 4, clip])
    }

    func testIntroLengthFollowsItsLastKeyAndAnEmptyRowIsRemoved() {
        var s = AnimationSet(in: fadeIn(f * 10), out: nil)
        s.edit(.opacity, side: .intro, clipDuration: clip) { p in
            let last = p.track.keys[1].id
            p.track.move(last, to: self.f * 20)
        }
        XCTAssertEqual(s.animationIn?.duration, f * 20)
        s.edit(.opacity, side: .intro, clipDuration: clip) { $0.track = KeyframeTrack() }
        XCTAssertNil(s.animationIn)          // the last key gone: the side is Off again
        XCTAssertEqual(s.sample(clipTime: f * 3, clipDuration: clip), .rest)
    }

    func testPositionIsOneRowOverTwoTracks() {
        var s = AnimationSet(in: nil, out: nil)
        s.editPosition(side: .intro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-40, 60)), Keyframe(time: self.f * 8, value: .zero)])
        }
        XCTAssertEqual(s.animationIn?.tracks.map(\.property).sorted(), ["positionX", "positionY"])
        XCTAssertEqual(s.sample(clipTime: .zero, clipDuration: clip).offset, Vec2(-40, 60))
        XCTAssertEqual(s.sample(clipTime: f * 8, clipDuration: clip).offset, .zero)
        XCTAssertEqual(s.position(side: .intro, clipDuration: clip).track.keys.map(\.value), [Vec2(-40, 60), .zero])
        // The members never share key ids.
        let ids = s.animationIn?.tracks.flatMap { $0.track.keys.map(\.id) } ?? []
        XCTAssertEqual(Set(ids).count, 4)
    }

    // MARK: A clip shorter than intro + outro

    func testClipShorterThanIntroPlusOutro() {
        let short = f * 12
        let s = AnimationSet(in: fadeIn(f * 10), out: fadeOut(f * 6))
        // The intro has priority: the outro starts when it ended and is cut by the clip's end.
        XCTAssertEqual(s.outStart(clipDuration: short), f * 10)
        XCTAssertEqual(s.scalar(.opacity, side: .outro, clipDuration: short).track.keys.map(\.time), [f * 10, f * 16])
        XCTAssertEqual(s.sample(clipTime: f * 5, clipDuration: short).opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.sample(clipTime: f * 10, clipDuration: short).opacity, 1)
        // A clip no longer than the intro: the outro does not play, its row still shows it ending at the clip's end.
        let tiny = f * 8
        XCTAssertNil(s.outStart(clipDuration: tiny))
        XCTAssertEqual(s.offset(of: .outro, clipDuration: tiny), tiny - f * 6)
        XCTAssertEqual(s.sample(clipTime: tiny, clipDuration: tiny).opacity, 0.8, accuracy: 1e-9)
    }

    // MARK: Key ids

    func testBuiltInKeyIDsAreUniquePerSideAndTrack() {
        let both = KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (f * 6, 1, .linear)]),
            AnimationTrack(property: "scale", keys: [(.zero, 0.8, .easeOut), (f * 6, 1, .linear)]),
        ], duration: f * 6)
        let s = AnimationSet(in: both, out: fadeOut(f * 6))
        let ids = s.scalar(.opacity, side: .intro, clipDuration: clip).track.keys.map(\.id)
            + s.scalar(.scale, side: .intro, clipDuration: clip).track.keys.map(\.id)
            + s.scalar(.opacity, side: .outro, clipDuration: clip).track.keys.map(\.id)
        XCTAssertEqual(Set(ids).count, 6)
        XCTAssertEqual(ids, s.scalar(.opacity, side: .intro, clipDuration: clip).track.keys.map(\.id)
            + s.scalar(.scale, side: .intro, clipDuration: clip).track.keys.map(\.id)
            + s.scalar(.opacity, side: .outro, clipDuration: clip).track.keys.map(\.id))
    }

    func testCustomStartAndSameCurves() {
        let a = KeyframeTemplate.customStart(.intro), b = KeyframeTemplate.customStart(.intro)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.sameCurves(as: b))
        XCTAssertTrue(a.sameCurves(as: fadeIn(AnimationSet.customLength)))
        XCTAssertFalse(a.sameCurves(as: fadeIn(f * 6)))
        XCTAssertEqual(KeyframeTemplate.customStart(.outro).anchor, .end)
        let s = AnimationSet(in: a, out: KeyframeTemplate.customStart(.outro))
        XCTAssertEqual(s.sample(clipTime: .zero, clipDuration: clip).opacity, 0)
        XCTAssertEqual(s.sample(clipTime: clip, clipDuration: clip).opacity, 0)
        XCTAssertEqual(s.sample(clipTime: f * 45, clipDuration: clip), .rest)
    }

    func testLoopSurvivesTheKeystoneFormat() throws {
        let frame = Vec2(1080, 1920)
        var looping = KeyframeTemplate.customStart(.intro)
        looping.loops = true
        let k = try XCTUnwrap(Keystone(animation: looping, side: .intro, name: "Loop", frameSize: frame))
        XCTAssertEqual(k.loops, true)
        XCTAssertEqual(k.animationTemplate(frameSize: frame)?.loops, true)
        let again = try Keystone(payload: k.payload(), version: k.writtenPayloadVersion)
        XCTAssertEqual(again.animationTemplate(frameSize: frame)?.loops, true)
        // Once stays once, and the field is absent from the payload (older saved keystones decode as before).
        let once = try XCTUnwrap(Keystone(animation: .customStart(.intro), side: .intro, name: "Once", frameSize: frame))
        XCTAssertNil(once.loops)
        XCTAssertEqual(once.animationTemplate(frameSize: frame)?.loops, false)
        XCTAssertFalse(String(decoding: try once.payload(), as: UTF8.self).contains("loops"))
        // A keystone applied to a clip ignores the flag.
        XCTAssertEqual(k.writtenPayloadVersion, 1)
    }

    func testSavedAsKeystoneAndBack() throws {
        let frame = Vec2(1080, 1920)
        var s = AnimationSet(in: .customStart(.intro), out: nil)
        s.editPosition(side: .intro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-108, 192)), Keyframe(time: self.f * 10, value: .zero)])
        }
        s.edit(.scale, side: .intro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.8), Keyframe(time: self.f * 10, value: 1)])
        }
        let custom = try XCTUnwrap(s.animationIn)
        XCTAssertTrue(custom.hasOwnKeyIDs)
        let k = try XCTUnwrap(Keystone(animation: custom, side: .intro, name: "Mine", frameSize: frame))
        XCTAssertEqual(k.anchor, .clipStart)
        XCTAssertEqual(k.animationSide, .intro)
        XCTAssertEqual(k.duration, f * 10)
        XCTAssertEqual(k.properties, [.position, .scale, .opacity])
        XCTAssertEqual(k.position?.keys.first?.value.x ?? 0, -0.1, accuracy: 1e-12)
        XCTAssertEqual(k.position?.keys.first?.value.y ?? 0, 0.1, accuracy: 1e-12)
        let back = try XCTUnwrap(k.animationTemplate(frameSize: frame))
        XCTAssertFalse(back.hasOwnKeyIDs)
        XCTAssertEqual(back.anchor, .start)
        // Same picture at every time.
        let a = AnimationSet(in: custom, out: nil), b = AnimationSet(in: back, out: nil)
        for t in [Time.zero, f, f * 3, f * 5, f * 9, f * 10, f * 12] {
            let x = a.sample(clipTime: t, clipDuration: clip), y = b.sample(clipTime: t, clipDuration: clip)
            XCTAssertEqual(x.opacity, y.opacity, accuracy: 1e-9)
            XCTAssertEqual(x.scale, y.scale, accuracy: 1e-9)
            XCTAssertEqual(x.offset.x, y.offset.x, accuracy: 1e-9)
            XCTAssertEqual(x.offset.y, y.offset.y, accuracy: 1e-9)
        }
        // Read twice it is the same animation, also through the preset payload.
        XCTAssertEqual(back, k.animationTemplate(frameSize: frame))
        let again = try Keystone(payload: k.payload(), version: Keystone.payloadVersion)
        XCTAssertEqual(again.animationTemplate(frameSize: frame), back)
        // Nothing keyed, or a free keystone: nothing to save or play.
        XCTAssertNil(Keystone(animation: KeyframeTemplate(tracks: [], duration: f * 10), side: .outro, name: "x", frameSize: frame))
        XCTAssertNil(Keystone(name: "free", duration: f * 10, opacity: k.opacity).animationTemplate(frameSize: frame))
        XCTAssertEqual(Keystone(animation: .customStart(.outro), side: .outro, name: "o", frameSize: frame)?
            .animationTemplate(frameSize: frame)?.anchor, .end)
    }

    func testPresetsCarryNoOwnKeyIDs() {
        let preset = fadeIn(f * 6)
        XCTAssertFalse(preset.hasOwnKeyIDs)
        XCTAssertTrue(preset.withFreshKeyIDs().hasOwnKeyIDs)
        // Reading a preset's rows and writing one back keeps it a preset as far as ids go.
        var s = AnimationSet(in: preset, out: nil)
        s.edit(.opacity, side: .intro, clipDuration: clip) { _ in }
        XCTAssertFalse(s.animationIn?.hasOwnKeyIDs ?? true)
    }

    /// Reading a preset's rows and writing them back unchanged leaves the preset bit for bit, on both sides and for a
    /// preset with one Position member only (no second track appears).
    func testAnUneditedPresetStaysWhatItWas() {
        let rise = KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (f * 6, 1, .linear)]),
            AnimationTrack(property: "positionY", keys: [(.zero, 40, .easeOut), (f * 6, 0, .linear)]),
        ], duration: f * 6, anchor: .start)
        var out = rise; out.anchor = .end
        let original = AnimationSet(in: rise, out: out)
        var s = original
        for side in AnimationSide.allCases {
            for p in AnimationParam.allCases where p != .position { s.edit(p, side: side, clipDuration: clip) { _ in } }
            s.editPosition(side: side, clipDuration: clip) { _ in }
            s.editPosition(side: side, clipDuration: clip) { $0.track = $0.track }
        }
        XCTAssertEqual(s, original)
        // The ids the rows show for a preset are distinct per side and track, and still not "own" ids.
        var ids = Set<UUID>()
        var count = 0
        for side in AnimationSide.allCases {
            for name in ["opacity", "positionY"] {
                for k in original.track(name, side: side, clipDuration: clip).track.keys {
                    ids.insert(k.id); count += 1
                    XCTAssertFalse(KeyframeTemplate(tracks: [AnimationTrack(property: name, track: KeyframeTrack(keys: [k]))],
                                                    duration: f).hasOwnKeyIDs)
                }
            }
        }
        XCTAssertEqual(ids.count, count)
        // A Custom intro is read as stored: the same ids, the same times.
        let custom = AnimationSet(in: .customStart(.intro), out: nil)
        XCTAssertEqual(custom.track("opacity", side: .intro, clipDuration: clip).track, custom.animationIn?.track(for: "opacity")?.track)
    }

    /// A saved animation is the same in every sequence format: Position scales with the frame, nothing else may differ.
    func testSameShapeIgnoresTheFrameAndKeyIDs() throws {
        var s = AnimationSet(in: .customStart(.intro), out: nil)
        s.editPosition(side: .intro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-120, 300)), Keyframe(time: self.f * 10, value: .zero)])
        }
        let t = try XCTUnwrap(s.animationIn)
        let k = try XCTUnwrap(Keystone(animation: t, side: .intro, name: "Mine", frameSize: Vec2(1080, 1920)))
        let tall = try XCTUnwrap(k.animationTemplate(frameSize: Vec2(1080, 1920)))
        let wide = try XCTUnwrap(k.animationTemplate(frameSize: Vec2(3840, 2160)))
        XCTAssertFalse(tall.hasOwnKeyIDs)
        XCTAssertNotEqual(tall, wide)
        XCTAssertTrue(tall.sameShape(as: wide) && wide.sameShape(as: tall) && t.sameShape(as: wide))
        var other = wide
        let o = try XCTUnwrap(other.tracks.firstIndex { $0.property == "opacity" })
        other.tracks[o].track.keys[0].value += 0.25                  // Opacity is not a matter of the frame
        XCTAssertFalse(tall.sameShape(as: other))
        var flipped = wide
        let x = try XCTUnwrap(flipped.tracks.firstIndex { $0.property == "positionX" })
        flipped.tracks[x].track.keys[0].value *= -1                  // the other direction is another animation
        XCTAssertFalse(tall.sameShape(as: flipped))
        var later = wide
        later.duration = later.duration + f
        XCTAssertFalse(tall.sameShape(as: later))
    }

    func testCodableRoundTripOfACustomSet() throws {
        var s = AnimationSet(in: .customStart(.intro), out: nil)
        s.editPosition(side: .outro, clipDuration: clip) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: self.clip - self.f * 5, value: .zero), Keyframe(time: self.clip, value: Vec2(0, 30))])
        }
        let back = try JSONDecoder().decode(AnimationSet.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    /// A keystone's own curve replaces the shape of every key of the side it plays; without one the keys stay as stored.
    func testKeystoneEasingShapesTheAnimationTemplate() throws {
        let frame = Vec2(1080, 1920)
        var k = Keystone(name: "Fade", duration: Time(1, 2), anchor: .clipStart,
                         opacity: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(1, 2), value: 1.0)]))
        let plain = try XCTUnwrap(k.animationTemplate(frameSize: frame)?.track(for: "opacity")?.track.keys)
        XCTAssertTrue(plain.allSatisfy { $0.interpolation == .linear })
        k.easing = .fastStart
        let eased = try XCTUnwrap(k.animationTemplate(frameSize: frame)?.track(for: "opacity")?.track.keys)
        XCTAssertTrue(eased.allSatisfy { $0.interpolation == .bezier })
        XCTAssertEqual(eased[0].outHandle, EasingCurve.fastStart.outHandle)
        XCTAssertEqual(eased[1].inHandle, EasingCurve.fastStart.inHandle)
        XCTAssertEqual(eased.map(\.time), plain.map(\.time))
        XCTAssertEqual(eased.map(\.value), plain.map(\.value))
    }
}
