import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func media(_ seconds: Int64, still: Bool = false) -> ReplacementMedia {
    ReplacementMedia(id: UUID(), name: "new", duration: s(seconds), hasVideo: true, hasAudio: true, isStill: still)
}

@Suite struct ReelFillTests {
    /// Three 4 s clips back to back on V1.
    private func reel() throws -> (Timeline, [Clip]) {
        let m = UUID()
        let cs = (0..<3).map { i -> Clip in
            var c = Clip(name: "shot\(i)", media: m, kind: .video, source: TimeRange(start: s(Int64(i) * 10), duration: s(4)),
                         start: s(Int64(i) * 4))
            c.mediaDuration = s(60); c.effects = [ClipEffect(kind: "blur")]
            return c
        }
        var v1 = Track(kind: .video)
        for c in cs { try v1.overwrite(c) }
        return (Timeline(name: "reel", frameDuration: Time(1, 30), tracks: [v1]), cs)
    }

    @Test func slotsAreBaseTrackClipsInTimeOrder() throws {
        let (tl, cs) = try reel()
        #expect(tl.reelSlots == cs.map(\.id))
    }

    @Test func copyHasFreshIDsAndSameTiming() throws {
        let (tl, cs) = try reel()
        let copy = tl.copyWithFreshIDs(name: "copy")
        #expect(copy.id != tl.id && copy.name == "copy")
        let ids = copy.tracks.flatMap(\.clips)
        #expect(Set(ids.map(\.id)).isDisjoint(with: Set(cs.map(\.id))))
        #expect(ids.map(\.start) == cs.map(\.start) && ids.map(\.media) == cs.map(\.media))
    }

    @Test func copyDoesNotShareGradeLinksWithTheTemplate() throws {
        var (tl, cs) = try reel()
        let link = UUID()
        for c in cs.prefix(2) { var n = c; n.gradeLink = link; tl.tracks[0].replace(n) }
        let copy = tl.copyWithFreshIDs(name: "copy")
        let links = copy.tracks[0].clips.sorted { $0.start < $1.start }.map(\.gradeLink)
        #expect(links[0] != nil && links[0] == links[1] && links[0] != link && links[2] == nil)
    }

    @Test func shortMediaIsFlooredToFrames() throws {
        var (tl, cs) = try reel()
        tl.frameDuration = Time(1, 24)
        // 10.02 s of media is 240.48 frames: 240 frames = 10 s
        let m = ReplacementMedia(id: UUID(), name: "n", duration: Time(1002, 100), hasVideo: true, hasAudio: true)
        var long = cs[0]; long.source = TimeRange(start: .zero, duration: s(12)); long.start = .zero
        tl.tracks[0] = Track(kind: .video); try tl.tracks[0].overwrite(long)
        let r = tl.fillReel(slots: [long.id], with: [m])
        #expect(r.filled == [long.id])
        #expect(tl.find(long.id)!.clip.duration == s(10))
    }

    @Test func linkPartnersOnOtherMediaStayUntouchedWhenShortening() throws {
        var (tl, cs) = try reel()
        let link = UUID()
        var v = cs[0]; v.link = link
        var a = Clip(name: "other", media: UUID(), kind: .audio, source: v.source, start: v.start)
        a.link = link; a.mediaDuration = s(60)
        tl.tracks[0].replace(v)
        var ta = Track(kind: .audio); try ta.overwrite(a)
        tl.tracks.append(ta)
        let m = ReplacementMedia(id: UUID(), name: "n", duration: s(2), hasVideo: true, hasAudio: true)
        let r = tl.fillReel(slots: [v.id], with: [m])
        #expect(r.filled == [v.id])
        #expect(tl.find(v.id)!.clip.duration == s(2))
        #expect(tl.find(a.id)!.clip == a)
    }

    @Test func linkPartnerWithoutMatchingStreamStaysUntouched() throws {
        var (tl, cs) = try reel()
        let link = UUID()
        var v = cs[0]; v.link = link
        var a = Clip(name: "aud", media: v.media, kind: .audio, source: v.source, start: v.start)
        a.link = link; a.mediaDuration = s(60)
        tl.tracks[0].replace(v)
        var ta = Track(kind: .audio); try ta.overwrite(a)
        tl.tracks.append(ta)
        let m = ReplacementMedia(id: UUID(), name: "n", duration: s(2), hasVideo: true, hasAudio: false)
        let r = tl.fillReel(slots: [v.id], with: [m])
        #expect(r.filled == [v.id])
        #expect(tl.find(a.id)!.clip == a)
    }

    @Test func fillsInOrderKeepingPositionsAndEffects() throws {
        var (tl, cs) = try reel()
        let new = [media(30), media(30), media(30)]
        let r = tl.fillReel(slots: tl.reelSlots, with: new)
        #expect(r.filled == cs.map(\.id) && r.skipped.isEmpty && r.shortened.isEmpty)
        for (i, c) in cs.enumerated() {
            let n = tl.find(c.id)!.clip
            #expect(n.media == new[i].id && n.start == c.start && n.duration == s(4))
            #expect(n.source.start == .zero && n.effects == c.effects)
        }
    }

    @Test func shortMediaShortensTheSlot() throws {
        var (tl, cs) = try reel()
        let r = tl.fillReel(slots: tl.reelSlots, with: [media(2), media(30), media(30)])
        #expect(r.shortened == [cs[0].id])
        #expect(tl.find(cs[0].id)!.clip.duration == s(2))
        #expect(tl.find(cs[1].id)!.clip.start == s(4))
    }

    @Test func fewerMediaLeavesSlotsAndMoreCountsUnused() throws {
        var (tl, cs) = try reel()
        let r = tl.fillReel(slots: tl.reelSlots, with: [media(30)])
        #expect(r.filled == [cs[0].id] && r.unfilled == [cs[1].id, cs[2].id])
        #expect(tl.find(cs[1].id)!.clip.media == cs[1].media)
        var (tl2, _) = try reel()
        let r2 = tl2.fillReel(slots: tl2.reelSlots, with: Array(repeating: media(30), count: 5))
        #expect(r2.unusedMedia == 2)
    }

    @Test func unusableMediaIsSkippedAndSlotUntouched() throws {
        var (tl, cs) = try reel()
        let r = tl.fillReel(slots: tl.reelSlots, with: [ReplacementMedia(id: UUID(), name: "a", duration: s(30), hasVideo: false, hasAudio: true), media(30), media(30)])
        #expect(r.skipped == [cs[0].id] && r.filled.count == 2)
        #expect(tl.find(cs[0].id)!.clip == cs[0])
    }

    @Test func stillTakesTheSlotLengthAndKeepsPlaceAndEffects() throws {
        var (tl, cs) = try reel()
        let still = media(0, still: true)
        let r = tl.fillReel(slots: tl.reelSlots, with: [still, media(30), media(30)])
        #expect(r.filled.count == 3 && r.skipped.isEmpty && r.shortened.isEmpty)
        let c = tl.find(cs[0].id)!.clip
        #expect(c.isStill && c.media == still.id && c.mediaDuration == nil)
        #expect(c.start == s(0) && c.duration == s(4) && c.source.start == .zero)
        #expect(c.effects == cs[0].effects)
        #expect(tl.find(cs[1].id)!.clip.start == s(4))
    }

    @Test func stillInASpeedChangedSlotKeepsTheTimelineLength() throws {
        var (tl, cs) = try reel()
        var c = cs[0]
        c.speed = ClipSpeed(num: 2, den: 1); c.source = TimeRange(start: s(10), duration: s(8))   // 8 s of source at 2x = 4 s on the timeline
        tl.tracks[0].replace(c)
        let r = tl.fillReel(slots: tl.reelSlots, with: [media(0, still: true)])
        #expect(r.filled == [c.id])
        let n = tl.find(c.id)!.clip
        #expect(n.isStill && n.duration == s(4) && n.speed == .normal)
    }

    @Test func stillDropsTheSilentAudioPartnerOfTheOldMedia() throws {
        let m = UUID(), link = UUID()
        var v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero, link: link)
        v.mediaDuration = s(60)
        var a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(4)), start: .zero, link: link)
        a.mediaDuration = s(60)
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(v); try a1.overwrite(a)
        var tl = Timeline(name: "r", frameDuration: Time(1, 30), tracks: [v1, a1])
        let r = tl.fillReel(slots: tl.reelSlots, with: [media(0, still: true)])
        #expect(r.filled == [v.id])
        #expect(tl.find(a.id) == nil)
        #expect(tl.find(v.id)!.clip.link == nil)
    }

    @Test func aSlotFilledWithAStillStaysASlotForTheNextFill() throws {
        var (tl, cs) = try reel()
        tl.fillReel(slots: tl.reelSlots, with: [media(0, still: true), media(30), media(30)])
        #expect(tl.reelSlots == cs.map(\.id))
        let next = media(30)
        let r = tl.fillReel(slots: tl.reelSlots, with: [next, media(30), media(30)])
        #expect(r.filled.count == 3 && r.skipped.isEmpty)
        let c = tl.find(cs[0].id)!.clip
        #expect(!c.isStill && c.media == next.id && c.mediaDuration == s(30))
        #expect(c.start == .zero && c.duration == s(4) && c.source.start == .zero)
    }

    @Test func stillOverStillKeepsTheSlot() throws {
        var (tl, cs) = try reel()
        tl.fillReel(slots: tl.reelSlots, with: [media(0, still: true)])
        let again = media(0, still: true)
        let r = tl.fillReel(slots: tl.reelSlots, with: [again])
        #expect(r.filled == [cs[0].id])
        #expect(tl.find(cs[0].id)!.clip.media == again.id && tl.find(cs[0].id)!.clip.duration == s(4))
    }

    private func linkedPair(audioMedia: UUID?, lockAudio: Bool) throws -> (Timeline, Clip, Clip) {
        let m = UUID(), link = UUID()
        var v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero, link: link)
        v.mediaDuration = s(60)
        var a = Clip(name: "a", media: audioMedia ?? m, kind: .audio, source: TimeRange(start: .zero, duration: s(4)),
                     start: .zero, link: link)
        a.mediaDuration = s(60)
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(v); try a1.overwrite(a)
        a1.isLocked = lockAudio
        return (Timeline(name: "r", frameDuration: Time(1, 30), tracks: [v1, a1]), v, a)
    }

    @Test func lockedTrackOfAnUntouchedPartnerDoesNotBlockAStill() throws {
        var (tl, v, a) = try linkedPair(audioMedia: UUID(), lockAudio: true)
        let r = tl.fillReel(slots: tl.reelSlots, with: [media(0, still: true)])
        #expect(r.filled == [v.id] && r.skipped.isEmpty)
        #expect(tl.find(a.id)!.clip == a)
        #expect(tl.find(v.id)!.clip.isStill)
    }

    @Test func lockedTrackOfARemovedPartnerStillSkipsTheStill() throws {
        var (tl, v, _) = try linkedPair(audioMedia: nil, lockAudio: true)
        let r = tl.fillReel(slots: tl.reelSlots, with: [media(0, still: true)])
        #expect(r.skipped == [v.id])
        #expect(tl.find(v.id)!.clip == v)
    }
}
