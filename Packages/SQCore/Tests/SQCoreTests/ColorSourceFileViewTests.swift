import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct ColorSourceFileViewTests {
    private let media = UUID()

    /// A Color effect with a static saturation and an exposure keyed 0 -> 2 over clip-local 0...1 s (linear).
    static func grade() -> ClipEffect {
        var e = ColorEffect(id: 1, inputLUT: .automatic)
        e.basic.saturation = 150
        var fx = ClipEffect.colorGrade(e)
        var prop = AnimatedProperty(0.0)
        prop.track.insert(Keyframe(time: .zero, value: 0, interpolation: .linear))
        prop.track.insert(Keyframe(time: s(1), value: 2, interpolation: .linear))
        fx.parameters[ClipEffect.colorExposureKey] = prop
        return fx
    }

    /// V1: other clip 0-2, the graded clip 2-6 showing source 10-14 of a 30 s file (linked to A1); V2: a title over it.
    /// The graded clip also carries a blur, scale / position keys, opacity, rotation, a blend mode and a mask.
    private func sequence(speed: ClipSpeed = .normal, reversed: Bool = false) throws -> (Timeline, Clip.ID) {
        let link = UUID()
        var v1 = Track(kind: .video), v2 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(Clip(name: "other", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                              mediaDuration: s(5)))
        var graded = Clip(name: "graded", media: media, kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(2),
                          link: link, mediaDuration: s(30), speed: speed)
        graded.reversed = reversed
        graded.effects = [try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind)), Self.grade()]
        graded.effects[0].parameters[ClipEffect.blurrinessKey] = AnimatedProperty(20)
        graded.animation.scale.track.insert(Keyframe(time: .zero, value: Vec2(1, 1), interpolation: .linear))
        graded.animation.scale.track.insert(Keyframe(time: s(1), value: Vec2(2, 2), interpolation: .linear))
        graded.animation.position.track.insert(Keyframe(time: .zero, value: Vec2(0, 0), interpolation: .linear))
        graded.animation.position.track.insert(Keyframe(time: s(1), value: Vec2(300, 100), interpolation: .linear))
        graded.animation.rotation = AnimatedProperty(30)
        graded.animation.opacity = AnimatedProperty(0.5)
        graded.blendMode = .screen
        graded.masks = [ClipMask(name: "Mask 1", kind: .ellipse, path: .ellipse(center: Vec2(0, 0), radius: Vec2(100, 100)))]
        try v1.overwrite(graded)
        try a1.overwrite(Clip(name: "graded", media: media, kind: .audio, source: TimeRange(start: s(10), duration: s(4)), start: s(2),
                              link: link, mediaDuration: s(30)))
        try v2.overwrite(Clip(name: "title", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(6)), start: .zero))
        return (Timeline(name: "seq", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25)),
                         tracks: [v1, v2, a1]), graded.id)
    }

    private func soloClip(_ v: ColorSourceFileView) throws -> Clip {
        try #require(v.timeline.tracks.first { $0.kind == .video }?.clips.first)
    }

    @Test func viewHoldsTheWholeFileWithOnlyTheClipsGrade() throws {
        let (t, id) = try sequence()
        let v = try #require(t.colorSourceFileView(of: id, at: s(3)))
        #expect(v.timeline.duration == s(30))
        let videos = v.timeline.tracks.filter { $0.kind == .video }
        #expect(videos.count == 1 && videos[0].clips.count == 1)
        #expect(v.timeline.captionTracks.isEmpty && videos[0].transitions.isEmpty)
        let c = videos[0].clips[0]
        #expect(c.media == media)
        #expect(c.start == .zero && c.source == TimeRange(start: .zero, duration: s(30)))
        #expect(c.effects.map(\.kind) == [ClipEffect.colorKind])        // the blur is gone, the grade stays
        #expect(c.id == id)                                             // compare/bypass by clip id keeps working
        #expect(c.animation == ClipAnimation())                         // no scale / position / rotation / opacity / keys
        #expect(c.blendMode == .normal && c.masks.isEmpty)
        // The file's audio plays along.
        let audio = v.timeline.tracks.filter { $0.kind == .audio }.flatMap(\.clips)
        #expect(audio.count == 1 && audio[0].media == media && audio[0].source == TimeRange(start: .zero, duration: s(30)))
        // Opens on the frame the sequence playhead shows: 1 s into the clip = source 11 s.
        #expect(v.position == s(11))
    }

    /// The render plan of the solo view: exactly one layer, identity geometry, the file frame at normal speed, no effects
    /// other than the grade, and the grade values the timeline clip shows on the same source frame.
    @Test func renderPlanIsOneRawLayerWithTheGrade() throws {
        let (t, id) = try sequence(speed: ClipSpeed(num: 2, den: 1))
        let v = try #require(t.colorSourceFileView(of: id, at: s(3)))
        let c = try soloClip(v)
        #expect(c.speed == .normal && !c.reversed && c.speedKeys == nil && c.holdFrame == nil)
        for file in [s(10), Time(21, 2), s(11), s(12), s(20)] {
            let layers = v.timeline.videoLayers(at: file)
            #expect(layers.count == 1)
            let l = try #require(layers.first)
            #expect(l.clip == id && l.sourceTime == file)
            #expect(l.transform == .identity)
            #expect(l.blendMode == .normal)
            #expect(l.effects == .none)                                  // no blur, no mask
            // Timeline frame that plays the same source frame (200 %: clip-local (file - 10) / 2), held at the clip ends.
            let local = min(max(.zero, Time.scaled(file - s(10), by: 1, over: 2)), s(2) - Time(1, 25))
            let original = try #require(t.tracks.flatMap(\.clips).first { $0.id == id })
            #expect(l.color == original.color(atLocal: local))
        }
    }

    @Test func gradeKeysSitOnTheirSourceFrames() throws {
        let (t, id) = try sequence(speed: ClipSpeed(num: 2, den: 1))
        let c = try soloClip(try #require(t.colorSourceFileView(of: id, at: s(3))))
        let keys = c.effects[0].parameters[ClipEffect.colorExposureKey]?.track.keys.map(\.time)
        #expect(keys == [s(10), s(12)])                                  // local 0 / 1 s at 200 % = source 10 / 12 s
    }

    @Test func reversedClipKeepsKeysSorted() throws {
        let (t, id) = try sequence(reversed: true)
        let c = try soloClip(try #require(t.colorSourceFileView(of: id, at: s(2))))
        let keys = c.effects[0].parameters[ClipEffect.colorExposureKey]?.track.keys
        // Local 1 s shows the frame ending at source 13, local 0 the one ending at 14 (25 fps: starts 1/25 s earlier).
        #expect(keys?.map(\.time) == [s(13) - Time(1, 25), s(14) - Time(1, 25)])
        #expect(keys?.map(\.value) == [2, 0])
    }

    @Test func viewUsesTheMediasOwnSizeAndFrameRate() throws {
        let (t, id) = try sequence()
        let info = VideoTrackInfo(width: 3840, height: 2160, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1001, 60000), isVariableFrameRate: false)
        let v = try #require(t.colorSourceFileView(of: id, at: s(3), picture: info))
        #expect(v.timeline.format.width == 3840 && v.timeline.format.height == 2160)
        #expect(v.timeline.frameDuration == Time(1001, 60000))
        #expect(v.position == v.position.snapped(to: Time(1001, 60000)))
        #expect(try soloClip(v).animation.scale.value == Vec2(1, 1))      // 100 % = the file's own pixels = fills the frame
        // Rotated phone footage: upright size.
        var phone = info; phone.rotation = 90
        let p = try #require(t.colorSourceFileView(of: id, at: s(3), picture: phone))
        #expect(p.timeline.format.width == 2160 && p.timeline.format.height == 3840)
        // Without probe info: the sequence frame.
        #expect(try #require(t.colorSourceFileView(of: id, at: s(3))).timeline.format == t.format)
    }

    @Test func unlinkedClipsShowTheirOwnGrade() throws {
        var v1 = Track(kind: .video)
        var a = Clip(name: "a", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero, mediaDuration: s(30))
        var b = Clip(name: "b", media: media, kind: .video, source: TimeRange(start: s(5), duration: s(2)), start: s(2), mediaDuration: s(30))
        var ea = ColorEffect(id: 1, inputLUT: .automatic); ea.basic.exposure = 1
        var eb = ColorEffect(id: 1, inputLUT: .automatic); eb.basic.exposure = -1
        a.effects = [ClipEffect.colorGrade(ea)]
        b.effects = [ClipEffect.colorGrade(eb)]
        b.gradeIndependent = true
        try v1.overwrite(a); try v1.overwrite(b)
        let t = Timeline(name: "s", frameDuration: Time(1, 25), tracks: [v1])
        let va = try soloClip(try #require(t.colorSourceFileView(of: a.id, at: .zero)))
        let vb = try soloClip(try #require(t.colorSourceFileView(of: b.id, at: .zero)))
        #expect(va.color.primary.basic.exposure == 1)
        #expect(vb.color.primary.basic.exposure == -1)
    }

    @Test func playheadOutsideTheClipOpensOnItsFirstFrame() throws {
        let (t, id) = try sequence()
        #expect(try #require(t.colorSourceFileView(of: id, at: s(0))).position == s(10))
    }

    @Test func stillSoloIsRawWithTheGrade() throws {
        var still = Clip(name: "p", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(1))
        still.isStill = true
        still.effects = [try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind)), Self.grade()]
        still.animation.scale = AnimatedProperty(Vec2(3, 3))
        still.blendMode = .multiply
        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        try v1.overwrite(still)
        try v2.overwrite(Clip(name: "title", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(6)), start: .zero))
        let t = Timeline(name: "s", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)), tracks: [v1, v2])
        let solo = t.soloingVideoClip(still.id, picture: (width: 3840, height: 2160))
        let layers = solo.videoLayers(at: s(2))
        #expect(layers.count == 1)
        let l = try #require(layers.first)
        #expect(l.transform.scale == Vec2(0.5, 0.5) && l.transform.position == .zero && l.transform.rotation == 0)
        #expect(l.transform.opacity == 1 && l.blendMode == .normal && l.effects == .none)
        #expect(l.color == still.color(atLocal: s(1)))
    }

    @Test func noFileNoView() throws {
        let (t, _) = try sequence()
        #expect(t.colorSourceFileView(of: UUID(), at: .zero) == nil)    // unknown clip
        var title = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        title.generator = GeneratorRef(kind: "text", payload: Data())
        var still = Clip(name: "p", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(2))
        still.isStill = true
        var tr = Track(kind: .video)
        try tr.overwrite(title); try tr.overwrite(still)
        let t2 = Timeline(name: "s", frameDuration: Time(1, 25), tracks: [tr])
        #expect(t2.colorSourceFileView(of: title.id, at: .zero) == nil)
        #expect(t2.colorSourceFileView(of: still.id, at: .zero) == nil)  // nothing to scrub: the solo stays
    }
}
