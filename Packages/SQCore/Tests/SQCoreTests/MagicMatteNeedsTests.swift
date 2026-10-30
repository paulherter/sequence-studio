import Foundation
import Testing
@testable import SQCore

/// Which Magic mattes export reads per frame (incl. nested sequences), the project's referenced matte keys (orphan sweep),
/// and Subject masks as effect inputs.
@Suite struct MagicMatteNeedsTests {
    private let fd = Time(1, 25)

    private func magicClip(start: Time = .zero, sourceStart: Time = Time(2, 1), seconds: Int = 1) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video,
                     source: TimeRange(start: sourceStart, duration: Time(Int64(seconds), 1)), start: start)
        c.masks = [ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: sourceStart)])]
        return c
    }

    private func timeline(_ clips: [Clip], name: String = "t") throws -> Timeline {
        var track = Track(kind: .video)
        for c in clips { try track.overwrite(c) }
        return Timeline(name: name, frameDuration: fd, tracks: [track])
    }

    /// Inner sequence with two video tracks (angles), each holding a clip with a Magic mask; outer clip nests it.
    private func twoAngleFixture(angle: Int?) throws -> (outer: Timeline, inner: Timeline, keys: [String]) {
        let a = magicClip(), b = magicClip()
        var t0 = Track(kind: .video), t1 = Track(kind: .video)
        try t0.overwrite(a); try t1.overwrite(b)
        let inner = Timeline(name: "angles", frameDuration: fd, tracks: [t0, t1])
        var nest = Clip(name: "n", media: inner.id, kind: .video,
                        source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        nest.sequence = inner.id
        if let angle { nest.angle = AngleChoice(index: angle) }
        return (try timeline([nest], name: "outer"), inner,
                [a.masks[0].magic!.matteKey(media: a.media), b.masks[0].magic!.matteKey(media: b.media)])
    }

    @Test func hiddenAngleMattesAreNotNeeded() throws {
        for shown in 0...1 {
            let f = try twoAngleFixture(angle: shown)
            let needs = f.outer.magicMatteNeeds(sequences: [f.inner.id: f.inner])
            #expect(needs.count == 25)
            #expect(Set(needs.flatMap { $0.map(\.key) }) == [f.keys[shown]])
        }
    }

    @Test func nonAnglesNestedSequenceListsEveryTrack() throws {
        let f = try twoAngleFixture(angle: nil)
        let needs = f.outer.magicMatteNeeds(sequences: [f.inner.id: f.inner])
        #expect(Set(needs.flatMap { $0.map(\.key) }) == Set(f.keys))
    }

    /// A reversed clip shows the frame ENDING at the mapped instant, so the matte it needs starts one (speed-scaled) frame
    /// earlier than the instant: the same time the picture, the tint and the render read.
    @Test func reversedAndSpeedClipsNeedTheShownFramesMatte() throws {
        for (reversed, speed) in [(false, ClipSpeed.normal), (true, ClipSpeed.normal), (true, ClipSpeed(num: 2, den: 1)), (false, ClipSpeed(num: 2, den: 1))] {
            var c = magicClip()
            c.reversed = reversed
            c.speed = speed
            let tl = try timeline([c])
            let key = c.masks[0].magic!.cacheKey(media: c.media)
            let needs = tl.magicMatteNeeds(sequences: [:])
            for i in [0, 3, 7] {
                let shown = c.sourceTime(at: c.start + fd * Int64(i), frameDuration: fd)
                let n = needs[i].first { $0.key == key }
                #expect(abs((n?.pts ?? -1) - Double(shown.value) / Double(shown.timescale)) < 1e-9, "reversed \(reversed) speed \(speed) frame \(i)")
                let one = tl.magicMatteNeeds(at: fd * Int64(i), sequences: [:], depth: 0).first { $0.key == key }
                #expect(one?.pts == n?.pts)
            }
        }
    }

    @Test func directClipNeedsOneMattePerFrame() throws {
        let c = magicClip()
        let needs = try timeline([c]).magicMatteNeeds(sequences: [:])
        #expect(needs.count == 25)
        let key = c.masks[0].magic!.cacheKey(media: c.media)
        #expect(needs[0] == [MagicMatteNeed(key: key, pts: 2)])
        #expect(abs(needs[24][0].pts - (2 + 24.0 / 25)) < 1e-9)
    }

    @Test func unusedOrDisabledMagicMasksAreNotNeeded() throws {
        var c = magicClip()
        c.masks[0].usedByOpacity = false
        #expect(try timeline([c]).magicMatteNeeds(sequences: [:]).isEmpty)
        c.masks[0].usedByOpacity = true
        c.masks[0].enabled = false
        #expect(try timeline([c]).magicMatteNeeds(sequences: [:]).isEmpty)
    }

    @Test func nestedSequenceFramesCountTheirInnerMagicMattes() throws {
        let inner = magicClip(start: Time(1, 1), sourceStart: Time(2, 1), seconds: 1)     // inner 1 s ... 2 s
        let innerTL = try timeline([inner], name: "inner")
        // The outer clip plays inner 0.5 s ... 2.5 s: only its frames over inner 1 s ... 2 s need a matte.
        var nest = Clip(name: "n", media: innerTL.id, kind: .video,
                        source: TimeRange(start: Time(1, 2), duration: Time(2, 1)), start: .zero)
        nest.sequence = innerTL.id
        let outer = try timeline([nest], name: "outer")
        let needs = outer.magicMatteNeeds(sequences: [innerTL.id: innerTL])
        #expect(needs.count == 25)
        let key = inner.masks[0].magic!.cacheKey(media: inner.media)
        #expect(needs.allSatisfy { $0.count == 1 && $0[0].key == key })
        #expect(abs(needs[0][0].pts - 2.02) < 1e-9)      // outer frame 13 = inner 1.02 s
        // Without the inner sequence nothing is known.
        #expect(outer.magicMatteNeeds(sequences: [:]).isEmpty)
    }

    @Test func projectListsEveryPickedMatteKey() throws {
        let a = magicClip()
        var b = magicClip(start: Time(5, 1))
        b.masks.append(ClipMask.makeMagic(name: "Mask (2)", points: []))      // not picked yet: no key
        let p = Project(name: "P", timelines: [try timeline([a, b])])
        let keys = p.magicMatteCacheKeys
        #expect(keys == [a.masks[0].magic!.cacheKey(media: a.media), b.masks[0].magic!.cacheKey(media: b.media)])
    }

    @Test func subjectMaskFeedsAnEffectWithoutCuttingThePicture() {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        var m = ClipMask.makeSubject(name: "Subject")
        m.usedByOpacity = false
        c.masks = [m]
        var e = ClipEffect(kind: ClipEffect.mosaicKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.mosaicKind))
        e.maskInput = [m.id]
        c.effects = [e]
        let fx = c.effects(at: Time(1, 1))
        #expect(fx.masks.isEmpty)
        #expect(fx.segments.first?.scope.first?.source == .subject)
        #expect(fx.needsSubjectMatte)
    }
}
