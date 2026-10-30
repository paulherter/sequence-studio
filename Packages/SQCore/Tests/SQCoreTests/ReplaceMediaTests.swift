import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func media(_ seconds: Int64, video: Bool = true, audio: Bool = true, still: Bool = false) -> ReplacementMedia {
    ReplacementMedia(id: UUID(), name: "new", duration: s(seconds), hasVideo: video, hasAudio: audio, isStill: still)
}

@Suite struct ReplaceMediaTests {
    /// V clip 10..14 s (source 5..9 of 30 s media) linked to an A clip with the same range.
    private func setup() throws -> (Timeline, Clip, Clip) {
        let m = UUID(), link = UUID()
        var v = Clip(name: "old", media: m, kind: .video, source: TimeRange(start: s(5), duration: s(4)), start: s(10))
        var a = Clip(name: "old", media: m, kind: .audio, source: TimeRange(start: s(5), duration: s(4)), start: s(10))
        v.link = link; a.link = link
        v.mediaDuration = s(30); a.mediaDuration = s(30)
        v.animation.opacity = AnimatedProperty(0.5)
        v.effects = [ClipEffect(kind: "blur")]
        var tv = Track(kind: .video), ta = Track(kind: .audio)
        try tv.overwrite(v); try ta.overwrite(a)
        return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: [tv, ta]), v, a)
    }

    @Test func keepsPositionLengthEffectsAndSwapsMediaAndLinkedAudio() throws {
        var (tl, v, a) = try setup()
        let new = media(60)
        try tl.replaceMedia(of: v.id, with: new, alignment: .clipStart(sourceIn: s(20)))
        let nv = tl.find(v.id)!.clip, na = tl.find(a.id)!.clip
        #expect(nv.media == new.id && na.media == new.id)
        #expect(nv.start == s(10) && nv.duration == s(4))
        #expect(nv.source.start == s(20) && na.source.start == s(20))
        #expect(nv.animation.opacity.value == 0.5 && nv.effects == v.effects)
        #expect(nv.mediaDuration == s(60) && nv.link == v.link)
        a = na
    }

    @Test func keepsSpeed() throws {
        var (tl, v, _) = try setup()
        var fast = v
        fast.speed = ClipSpeed(percent: 200)               // 4 s of source over 2 s on the timeline
        tl.tracks[0].replace(fast)
        try tl.replaceMedia(of: v.id, with: media(60), alignment: .clipStart(sourceIn: s(0)))
        let c = tl.find(v.id)!.clip
        #expect(c.duration == s(2) && c.source.duration == s(4) && c.speed == fast.speed)
    }

    @Test func refusesMediaThatIsTooShort() throws {
        var (tl, v, _) = try setup()
        #expect(throws: EditError.insufficientMedia) {
            try tl.replaceMedia(of: v.id, with: media(6), alignment: .clipStart(sourceIn: s(3)))
        }
        #expect(tl.find(v.id)!.clip.media == v.media)       // nothing changed
    }

    @Test func matchFrameAlignsTheFrameUnderThePlayhead() throws {
        var (tl, v, _) = try setup()
        // Playhead at 12 s on the timeline (2 s into the clip) shows frame 40 s of the new media: the clip starts at 38 s.
        try tl.replaceMedia(of: v.id, with: media(60), alignment: .matchFrame(mediaTime: s(40), timelineTime: s(12)))
        #expect(tl.find(v.id)!.clip.source.start == s(38))
    }

    @Test func matchFrameBeforeTheMediaStartIsRefused() throws {
        var (tl, v, _) = try setup()
        #expect(throws: EditError.insufficientMedia) {
            try tl.replaceMedia(of: v.id, with: media(60), alignment: .matchFrame(mediaTime: s(1), timelineTime: s(12)))
        }
    }

    @Test func mediaWithoutAudioLeavesTheLinkedAudioAlone() throws {
        var (tl, v, a) = try setup()
        let new = media(60, audio: false)
        try tl.replaceMedia(of: v.id, with: new, alignment: .clipStart(sourceIn: s(0)))
        #expect(tl.find(v.id)!.clip.media == new.id)
        #expect(tl.find(a.id)!.clip.media == a.media)
    }

    @Test func wrongStreamsStillsNestsAndLockedTracksAreRefused() throws {
        var (tl, v, a) = try setup()
        #expect(throws: EditError.wrongTrackKind) {
            try tl.replaceMedia(of: v.id, with: media(60, video: false), alignment: .clipStart(sourceIn: s(0)))
        }
        #expect(throws: EditError.wrongTrackKind) {
            try tl.replaceMedia(of: a.id, with: media(60, audio: false), alignment: .clipStart(sourceIn: s(0)))
        }
        #expect(throws: EditError.speedUnsupported) {
            try tl.replaceMedia(of: v.id, with: media(60, still: true), alignment: .clipStart(sourceIn: s(0)))
        }
        tl.tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) {
            try tl.replaceMedia(of: v.id, with: media(60), alignment: .clipStart(sourceIn: s(0)))
        }
    }

    @Test func replacingFromTheAudioClipKeepsTheVideoPartnerWhenNewMediaHasNoPicture() throws {
        var (tl, v, a) = try setup()
        let new = media(60, video: false)
        try tl.replaceMedia(of: a.id, with: new, alignment: .clipStart(sourceIn: s(0)))
        #expect(tl.find(a.id)!.clip.media == new.id)
        #expect(tl.find(v.id)!.clip.media == v.media)
    }
}
