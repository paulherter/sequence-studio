import Foundation
import Testing
@testable import SQCore

// Animation zones: intro and outro keep their length when a clip is trimmed or stretched, the middle holds or stretches.

private let fd = Time(1, 30)
private func s(_ x: Int64) -> Time { Time(x, 1) }
private func ms(_ x: Int64) -> Time { Time(x, 1000) }

private func keyed(_ times: [Time], duration: Time, start: Time = .zero) -> Clip {
    var c = Clip(name: "T", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: duration), start: start,
                 generator: GeneratorRef(kind: GeneratorRef.text, payload: Data()))
    c.animation.opacity.track = KeyframeTrack(keys: times.map { Keyframe(time: $0, value: 1.0) })
    return c
}

private func timeline(_ c: Clip) throws -> Timeline {
    var t = Track(kind: .video)
    try t.overwrite(c)
    return Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [t])
}

private func opacityKeys(_ tl: Timeline) -> [Time] { tl.tracks[0].clips[0].animation.opacity.track.keys.map(\.time) }

@Suite struct AnimationZonesTests {
    // MARK: Auto-detect

    @Test func detectsIntroAndOutroFromFirstAndLastKeys() throws {
        let z = try #require(AnimationZones.detect(keyTimes: [.zero, ms(500), ms(4500), s(5)], duration: s(5)))
        #expect(z.introEnd == ms(500))
        #expect(z.outroLength == ms(500))
        #expect(z.outroStart(in: s(5)) == ms(4500))
        #expect(z.middle == .hold)
    }

    @Test func detectsIntroOnly() throws {
        let z = try #require(AnimationZones.detect(keyTimes: [.zero, s(1)], duration: s(5)))
        #expect(z.introEnd == s(1))
        #expect(z.outroLength == .zero)
    }

    /// Keys in the first half belong to the intro, keys in the second half to the outro.
    @Test func middleKeysJoinTheNearerHalf() throws {
        let z = try #require(AnimationZones.detect(keyTimes: [.zero, ms(500), s(2), s(3), ms(4500), s(5)], duration: s(5)))
        #expect(z.introEnd == s(2) && z.outroStart(in: s(5)) == s(3))
    }

    @Test func noKeysNoZones() {
        #expect(AnimationZones.detect(keyTimes: [], duration: s(5)) == nil)
        #expect(AnimationZones.detect(keyTimes: [s(1)], duration: .zero) == nil)
    }

    @Test func clipDetectsFromItsKeyframes() throws {
        let c = keyed([.zero, ms(500), ms(4500), s(5)], duration: s(5))
        let z = try #require(c.detectedZones)
        #expect(z.introEnd == ms(500) && z.outroLength == ms(500))
    }

    // MARK: Content time (nested template clips)

    @Test func contentTimeHoldsTheMiddle() {
        let z = AnimationZones(introEnd: ms(500), outroStart: ms(4500), designDuration: s(5))
        // Stretched to 10 s.
        #expect(z.contentTime(atLocal: ms(250), duration: s(10)) == ms(250))
        #expect(z.contentTime(atLocal: s(2), duration: s(10)) == s(2))
        #expect(z.contentTime(atLocal: s(6), duration: s(10)) == ms(4500))      // held at the outro start
        #expect(z.contentTime(atLocal: ms(9500), duration: s(10)) == ms(4500))
        #expect(z.contentTime(atLocal: ms(9750), duration: s(10)) == ms(4750))
        // Trimmed to 3 s: the outro still plays whole at the end.
        #expect(z.contentTime(atLocal: s(1), duration: s(3)) == s(1))
        #expect(z.contentTime(atLocal: ms(2600), duration: s(3)) == ms(4600))
    }

    @Test func contentTimeStretchesTheMiddle() {
        let z = AnimationZones(introEnd: ms(500), outroStart: ms(4500), designDuration: s(5), middle: .stretch)
        // Middle 4 s of content over 9 s of clip.
        #expect(z.contentTime(atLocal: s(5), duration: s(10)) == ms(2500))
        #expect(z.contentTime(atLocal: ms(9500), duration: s(10)) == ms(4500))
        // Middle 4 s over 2 s.
        #expect(z.contentTime(atLocal: ms(1500), duration: s(3)) == ms(2500))
    }

    @Test func clipShorterThanBothZonesKeepsTheWholeOutro() {
        let z = AnimationZones(introEnd: s(1), outroStart: s(4), designDuration: s(5))
        #expect(z.contentTime(atLocal: ms(500), duration: s(1)) == ms(4500))
        #expect(z.contentTime(atLocal: .zero, duration: s(1)) == s(4))
    }

    // MARK: Trim with zones (any clip)

    @Test func tailTrimMovesOnlyTheOutroKeys() throws {
        var c = keyed([.zero, ms(500), s(2), ms(4500), s(5)], duration: s(5))
        c.zones = AnimationZones(introEnd: ms(500), outroStart: ms(4500), designDuration: s(5))
        var tl = try timeline(c)
        try tl.trim(c.id, edge: .tail, by: s(5))
        #expect(opacityKeys(tl) == [.zero, ms(500), s(2), ms(9500), s(10)])
        try tl.trim(c.id, edge: .tail, by: s(-7))
        #expect(opacityKeys(tl) == [.zero, ms(500), s(2), ms(2500), s(3)])
    }

    @Test func headTrimKeepsTheIntroAtTheClipStart() throws {
        var c = keyed([.zero, ms(500), s(2), ms(4500), s(5)], duration: s(5), start: s(5))
        c.zones = AnimationZones(introEnd: ms(500), outroStart: ms(4500), designDuration: s(5))
        var tl = try timeline(c)
        try tl.trim(c.id, edge: .head, by: s(-2))           // 2 s longer at the head
        #expect(tl.tracks[0].clips[0].start == s(3))
        #expect(opacityKeys(tl) == [.zero, ms(500), s(4), ms(6500), s(7)])
    }

    @Test func stretchMiddleScalesTheMiddleKeys() throws {
        var c = keyed([.zero, ms(500), ms(2500), ms(4500), s(5)], duration: s(5))
        c.zones = AnimationZones(introEnd: ms(500), outroStart: ms(4500), designDuration: s(5), middle: .stretch)
        var tl = try timeline(c)
        try tl.trim(c.id, edge: .tail, by: s(4))            // middle 4 s -> 8 s
        #expect(opacityKeys(tl) == [.zero, ms(500), ms(4500), ms(8500), s(9)])
    }

    @Test func withoutZonesKeysStayOnTheirFrames() throws {
        let c = keyed([.zero, ms(500), ms(4500), s(5)], duration: s(5), start: s(5))
        var tl = try timeline(c)
        try tl.trim(c.id, edge: .tail, by: s(5))
        #expect(opacityKeys(tl) == [.zero, ms(500), ms(4500), s(5)])
        try tl.trim(c.id, edge: .head, by: s(-1))
        #expect(opacityKeys(tl) == [s(1), ms(1500), ms(5500), s(6)])
    }

    // MARK: Project API + undo

    @Test func setZonesIsOneUndoStep() throws {
        let c = keyed([.zero, ms(500), ms(4500), s(5)], duration: s(5))
        let p = Project(name: "P", timelines: [try timeline(c)])
        var h = History(p)
        try h.commit("Animation Zones") { try $0.autoDetectAnimationZones(clip: c.id) }
        #expect(h.current.timelines[0].tracks[0].clips[0].zones?.introEnd == ms(500))
        try h.commit("Animation Zones") { try $0.setAnimationZones(nil, clip: c.id) }
        #expect(h.current.timelines[0].tracks[0].clips[0].zones == nil)
        _ = h.undo()
        #expect(h.current.timelines[0].tracks[0].clips[0].zones?.outroLength == ms(500))
        _ = h.undo()
        #expect(h.current == p)
    }

    @Test func autoDetectWithoutKeysThrows() throws {
        let c = keyed([], duration: s(5))
        var p = Project(name: "P", timelines: [try timeline(c)])
        #expect(throws: TitleTemplateError.noKeyframes) { try p.autoDetectAnimationZones(clip: c.id) }
    }
}
