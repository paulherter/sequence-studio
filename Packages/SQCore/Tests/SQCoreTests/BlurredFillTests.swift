import Foundation
import Testing
@testable import SQCore

@Suite struct BlurredFillTests {
    let fd = Time(1, 30)
    func s(_ n: Int64) -> Time { Time(n, 1) }

    func make(link: UUID? = nil, audio: Bool = false) -> (Timeline, Clip) {
        let m = UUID()
        var c = Clip(name: "shot", media: m, kind: .video, source: TimeRange(start: s(2), duration: s(5)), start: s(1))
        c.link = link
        var v = Track(kind: .video)
        try! v.overwrite(c)
        var tracks = [v, Track(kind: .video)]
        if audio {
            var a = Clip(name: "shot", media: m, kind: .audio, source: c.source, start: s(1)); a.link = link
            var at = Track(kind: .audio); try! at.overwrite(a); tracks.append(at)
        }
        return (Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: tracks), c)
    }

    @Test func fitPutsBlurredCopyOnNewTrackBelow() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1920, 1080), style: .fit, options: .init(blur: 50, dim: 0.5))
        #expect(t.tracks.count == 3)
        let pic = t.tracks[1].clips[0], bg = t.tracks[0].clips[0]
        #expect(pic.id == c.id && bg.id != c.id)
        #expect(abs(pic.animation.scale.value.x - 1080.0 / 1920.0) < 1e-9)
        #expect(abs(bg.animation.scale.value.x - 1920.0 / 1080.0 * 1.12) < 1e-9)   // cover: the height 1920 / 1080
        #expect(bg.animation.opacity.value == 0.5)
        #expect(bg.effect(ofKind: ClipEffect.gaussianBlurKind)?.parameters[ClipEffect.blurrinessKey]?.value == 50)
        #expect(bg.start == c.start && bg.source == c.source && bg.media == c.media)
        #expect(bg.link == nil && pic.link == nil)
        #expect(bg.name == "shot (Blur Fill)")
        #expect(t.blurredFillPair(of: bg.id)?.picture.id == c.id)
    }

    @Test func backgroundCopyDropsMasksAndBakedEffects() throws {
        let m = UUID()
        var c = Clip(name: "shot", media: m, kind: .video, source: TimeRange(start: s(2), duration: s(5)), start: s(1))
        c.masks = [ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))]
        c.bakedEffects = [BakedEffect(recipeID: "r", effect: ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!, index: 0,
                                      motion: ClipAnimation())]
        var v = Track(kind: .video)
        try v.overwrite(c)
        var t = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: [v])
        try t.applyBlurredFill(c.id, picture: (1920, 1080), style: .fit)
        let pic = t.tracks[1].clips[0], bg = t.tracks[0].clips[0]
        #expect(pic.masks.count == 1)
        #expect(bg.masks.isEmpty)
        #expect(bg.bakedEffects.isEmpty)
    }

    @Test func matchingAspectIsRefusedForFitButNotCard() throws {
        var (t, c) = make()
        let before = t
        #expect(throws: BlurredFillError.aspectMatches) { try t.applyBlurredFill(c.id, picture: (1080, 1920), style: .fit) }
        #expect(t == before)
        try t.applyBlurredFill(c.id, picture: (1080, 1920), style: .card)
        #expect(t.tracks[1].clips[0].effects.map(\.kind) == [ClipEffect.roundedCornersKind, ClipEffect.dropShadowKind])
    }

    @Test func cardScalesPictureAndAddsRoundedCornersAndShadow() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1600, 1200), style: .card)
        let pic = t.tracks[1].clips[0]
        #expect(abs(pic.animation.scale.value.x - 1080.0 / 1600.0 * 0.85) < 1e-9)
        #expect(pic.effects.count == 2)
        #expect(t.blurredFillPair(of: c.id)?.style == .card)
    }

    @Test func removeRestoresClipAndDeletesTheEmptyTrack() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1600, 1200), style: .card)
        try t.removeBlurredFill(c.id)
        #expect(t.tracks.count == 2)
        let pic = t.tracks[0].clips[0]
        #expect(pic.effects.isEmpty)
        #expect(abs(pic.animation.scale.value.x - 1080.0 / 1600.0) < 1e-9)
        #expect(t.blurredFillPair(of: c.id) == nil)
    }

    @Test func copyIsNotInTheAVLinkAndRemoveFromTheCopyKeepsAudio() throws {
        let link = UUID()
        var (t, c) = make(link: link, audio: true)
        try t.applyBlurredFill(c.id, picture: (1920, 1080), style: .fit)
        let bg = t.tracks[0].clips[0]
        #expect(bg.link == nil)
        try t.removeBlurredFill(bg.id)
        #expect(t.tracks.count == 3)
        #expect(t.tracks[0].clips[0].link == link)
        #expect(t.tracks[2].clips[0].link == link)
    }

    @Test func applyingWithTheCopySelectedActsOnThePicture() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1920, 1080), style: .fit)
        let copy = t.tracks[0].clips[0]
        try t.applyBlurredFill(copy.id, picture: (1920, 1080), style: .card)
        #expect(t.tracks.count == 3 && t.tracks.flatMap(\.clips).count == 2)
        #expect(t.blurredFillPair(of: c.id)?.style == .card)
        #expect(t.blurredFillPair(of: copy.id)?.picture.id == c.id)
    }

    @Test func pairSurvivesRenameAndUnlinkedTrimOfOneSide() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1920, 1080), style: .fit)
        var bg = t.tracks[0].clips[0]
        bg.name = "something else"
        try t.replaceClip(bg)
        _ = try t.rippleTrim(c.id, edge: .tail, by: .zero - s(1))      // only the picture shortens
        #expect(t.blurredFillPair(of: c.id)?.background?.id == bg.id)
        try t.removeBlurredFill(c.id)
        #expect(t.tracks.count == 2 && t.tracks.flatMap(\.clips).count == 1)
    }

    @Test func userClipNamedCardWithBlurIsNotAPair() throws {
        var (t, c) = make()
        var other = Clip(name: "x (Card)", media: c.media, kind: .video, source: c.source, start: c.start)
        other.effects = [ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!]
        var tr = Track(kind: .video); try tr.overwrite(other)
        t.tracks.append(tr)
        #expect(t.blurredFillPair(of: other.id) == nil && t.blurredFillPair(of: c.id) == nil)
        try t.removeBlurredFill(other.id)
        #expect(t.tracks.flatMap(\.clips).count == 2)
    }

    @Test func cardOnlyRemovesItsOwnEffects() throws {
        var (t, c) = make()
        var mine = c
        mine.effects = [ClipEffect.roundedCorners(radius: 5), ClipEffect.make(kind: ClipEffect.dropShadowKind)!]
        try t.replaceClip(mine)
        try t.applyBlurredFill(c.id, picture: (1600, 1200), style: .card)
        #expect(t.blurredFillPair(of: c.id)?.picture.effects.count == 4)
        try t.removeBlurredFill(c.id)
        let back = t.tracks.flatMap(\.clips)[0]
        #expect(back.effects == mine.effects)
    }

    @Test func applyingAgainReplacesTheLook() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1600, 1200), style: .fit)
        try t.applyBlurredFill(c.id, picture: (1600, 1200), style: .card)
        #expect(t.tracks.count == 3)
        #expect(t.tracks.flatMap(\.clips).count == 2)
        #expect(t.blurredFillPair(of: c.id)?.style == .card)
        #expect(t.tracks[1].clips[0].effects.count == 2)
    }

    @Test func refusesLockedTrackAndAudioAndLeavesTimelineUnchanged() throws {
        var (t, c) = make()
        t.tracks[0].isLocked = true
        let before = t
        #expect(throws: EditError.trackLocked) { try t.applyBlurredFill(c.id, picture: (1920, 1080), style: .fit) }
        #expect(t == before)
        var (t2, _) = make(audio: true)
        let a = t2.tracks[2].clips[0]
        #expect(throws: EditError.wrongTrackKind) { try t2.applyBlurredFill(a.id, picture: (1920, 1080), style: .fit) }
    }

    @Test func fileRoundTripNeedsNoNewFormat() throws {
        var (t, c) = make()
        try t.applyBlurredFill(c.id, picture: (1600, 1200), style: .card)
        let back = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(t))
        #expect(back.blurredFillPair(of: c.id)?.style == .card)
    }
}
