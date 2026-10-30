import Foundation
import Testing
@testable import SQCore

// Intro / outro zones of a text clip: the clip cannot get shorter than in + out; the zone lengths never change.

private let fd = Time(1, 30)
private func s(_ x: Int64) -> Time { Time(x, 1) }

private func fade(_ d: Time, side: AnimationSide) -> KeyframeTemplate {
    KeyframeTemplate(tracks: [AnimationTrack(property: "opacity",
        keys: side == .intro ? [(.zero, 0, .linear), (d, 1, .linear)] : [(.zero, 1, .linear), (d, 0, .linear)])],
                     duration: d, anchor: side == .intro ? .start : .end)
}

private func textClip(duration: Time, intro: Time?, outro: Time?, start: Time = .zero) throws -> Clip {
    let set = AnimationSet(in: intro.map { fade($0, side: .intro) }, out: outro.map { fade($0, side: .outro) })
    let data = try JSONEncoder().encode(["animations": set])
    return Clip(name: "T", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: duration), start: start,
                generator: GeneratorRef(kind: GeneratorRef.text, payload: data))
}

private func timeline(_ c: Clip) throws -> Timeline {
    var t = Track(kind: .video)
    try t.overwrite(c)
    return Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [t])
}

@Suite struct AnimationFloorTests {
    @Test func lengthsComeFromThePayload() throws {
        let c = try textClip(duration: s(5), intro: Time(1, 2), outro: Time(3, 4))
        let z = try #require(c.animationZoneLengths)
        #expect(z.intro == Time(1, 2) && z.outro == Time(3, 4))
        #expect(c.minimumDuration(frame: fd) == Time(5, 4))
    }

    @Test func noAnimationsMeansOneFrame() throws {
        let c = try textClip(duration: s(5), intro: nil, outro: nil)
        #expect(c.animationZoneLengths == nil)
        #expect(c.minimumDuration(frame: fd) == fd)
    }

    @Test func loopingIntroIsNoZone() throws {
        var loop = fade(s(1), side: .intro); loop.loops = true
        let data = try JSONEncoder().encode(["animations": AnimationSet(in: loop, out: nil)])
        let c = Clip(name: "T", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero,
                     generator: GeneratorRef(kind: GeneratorRef.text, payload: data))
        #expect(c.animationZoneLengths == nil)
    }

    @Test func tailTrimStopsAtInPlusOut() throws {
        var tl = try timeline(try textClip(duration: s(5), intro: s(1), outro: s(1)))
        let id = tl.tracks[0].clips[0].id
        let moved = try tl.trim(id, edge: .tail, by: s(-4))
        #expect(moved == s(-3))
        #expect(tl.tracks[0].clips[0].duration == s(2))
    }

    @Test func headTrimStopsAtInPlusOut() throws {
        var tl = try timeline(try textClip(duration: s(5), intro: s(1), outro: s(1), start: s(2)))
        let id = tl.tracks[0].clips[0].id
        let moved = try tl.trim(id, edge: .head, by: s(4))
        #expect(moved == s(3))
        #expect(tl.tracks[0].clips[0].duration == s(2))
    }

    @Test func lengtheningKeepsTheZones() throws {
        var tl = try timeline(try textClip(duration: s(3), intro: s(1), outro: s(1)))
        let id = tl.tracks[0].clips[0].id
        let before = tl.tracks[0].clips[0].generator
        try tl.trim(id, edge: .tail, by: s(4))
        let c = tl.tracks[0].clips[0]
        #expect(c.duration == s(7))
        #expect(c.generator == before)
        let set = AnimationSet(in: fade(s(1), side: .intro), out: fade(s(1), side: .outro))
        #expect(set.sample(clipTime: s(7), clipDuration: s(7)).opacity == 0)
        #expect(set.sample(clipTime: s(3), clipDuration: s(7)).opacity == 1)
    }

    @Test func rippleTrimIsLimitedToo() throws {
        var tl = try timeline(try textClip(duration: s(5), intro: s(1), outro: s(1)))
        let id = tl.tracks[0].clips[0].id
        let moved = try tl.rippleTrim(id, edge: .tail, by: s(-4))
        #expect(moved == s(-3))
        #expect(tl.tracks[0].clips[0].duration == s(2))
    }

    @Test func rollFollowerTailStopsAtInPlusOut() throws {
        let link = UUID()
        var x = try textClip(duration: s(5), intro: nil, outro: nil)
        var y = try textClip(duration: s(5), intro: nil, outro: nil, start: s(5))
        var t = try textClip(duration: s(5), intro: s(1), outro: s(1))
        x.link = link; t.link = link
        var a = Track(kind: .video); try a.overwrite(x); try a.overwrite(y)
        var b = Track(kind: .video); try b.overwrite(t)
        var tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [a, b])
        let moved = try tl.roll(x.id, by: s(-4))
        #expect(moved == s(-3))
        #expect(tl.tracks[1].clips[0].duration == s(2))
        #expect(tl.tracks[0].clips[0].duration == s(2))
        y = tl.tracks[0].clips[1]
        #expect(y.start == s(2))
    }

    @Test func splitEditStopsAtInPlusOut() throws {
        let l = try textClip(duration: s(5), intro: s(1), outro: s(1))
        let r = try textClip(duration: s(5), intro: nil, outro: nil, start: s(5))
        var a = Track(kind: .video); try a.overwrite(l); try a.overwrite(r)
        var tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [a])
        let moved = try tl.splitEdit(cut: s(5), side: .video, to: s(0))
        #expect(moved == s(-3))
        #expect(tl.tracks[0].clips[0].duration == s(2))
    }
}
