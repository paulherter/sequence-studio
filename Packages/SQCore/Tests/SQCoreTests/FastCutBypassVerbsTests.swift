import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

private func vclip(_ name: String, _ start: Int64, _ frames: Int64, src: Int64 = 0, link: UUID? = nil, media: UUID = UUID()) -> Clip {
    Clip(name: name, media: media, kind: .video, source: TimeRange(start: f(src), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(600))
}
private func aclip(_ name: String, _ start: Int64, _ frames: Int64, src: Int64 = 0, link: UUID? = nil, media: UUID = UUID()) -> Clip {
    Clip(name: name, media: media, kind: .audio, source: TimeRange(start: f(src), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(600))
}
private func timeline(_ tracks: [Track], fastCut: Bool) -> Timeline {
    var t = Timeline(name: "t", frameDuration: fd, tracks: tracks)
    if fastCut { t.editMode = .magnetic }
    return t
}

/// Fast Cut regression tests for the edit paths that used to bypass the magnetic verbs (Trim mode, Snap to Beats,
/// Move into Sync, Put on Main Track).
@Suite struct FastCutBypassVerbsTests {
    // MARK: Move into Sync

    @Test func moveIntoSyncOnMainClipMovesThePartnerAndKeepsTheClip() throws {
        let link = UUID(), m = UUID()
        let v = vclip("v", 0, 100, link: link, media: m), a = aclip("a", 3, 100, link: link, media: m)
        var t = timeline([Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])], fastCut: true)
        #expect(t.syncOffsets()[v.id] != nil)
        try t.moveIntoSync(v.id)
        #expect(t.find(v.id)?.clip.start == .zero)
        #expect(t.find(a.id)?.clip.start == .zero)
        #expect(t.syncOffsets().isEmpty)
    }

    @Test func moveIntoSyncOnMainClipWithoutMovablePartnerIsRefusedAndChangesNothing() {
        let link = UUID(), m = UUID()
        let v = vclip("v", 0, 100, link: link, media: m), a = aclip("a", 3, 100, link: link, media: m)
        var audio = Track(kind: .audio, clips: [a])
        audio.isLocked = true
        var t = timeline([Track(kind: .video, clips: [v]), audio], fastCut: true)
        let before = t
        #expect(throws: EditError.collision) { try t.moveIntoSync(v.id) }
        #expect(t == before)
    }

    @Test func moveIntoSyncSkipsLockedPartnersAndMovesTheOthers() throws {
        let link = UUID(), m = UUID()
        let v = vclip("v", 0, 100, link: link, media: m), a = aclip("a", 3, 100, link: link, media: m), b = aclip("b", 5, 100, link: link, media: m)
        var locked = Track(kind: .audio, clips: [a])
        locked.isLocked = true
        var t = timeline([Track(kind: .video, clips: [v]), locked, Track(kind: .audio, clips: [b])], fastCut: true)
        try t.moveIntoSync(v.id)
        #expect(t.find(a.id)?.clip.start == f(3))
        #expect(t.find(b.id)?.clip.start == .zero)
        #expect(t.find(v.id)?.clip.start == .zero)
    }

    @Test func moveIntoSyncOnMainClipInNormalModeStillMovesTheClip() throws {
        let link = UUID(), m = UUID()
        let v = vclip("v", 0, 100, link: link, media: m), a = aclip("a", 3, 100, link: link, media: m)
        var t = timeline([Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])], fastCut: false)
        try t.moveIntoSync(v.id)
        #expect(t.find(v.id)?.clip.start == f(3))
        #expect(t.find(a.id)?.clip.start == f(3))
    }

    // MARK: Put on Main Track

    @Test func dragOntoMainTrackWithOverwriteLandsAtMostAtTheEnd() throws {
        let c = vclip("c", 0, 30), x = vclip("x", 80, 20)
        var t = timeline([Track(kind: .video, clips: [c]), Track(kind: .video, clips: [x])], fastCut: true)
        try t.dragOntoMainTrack(x.id, at: f(200), overwrite: true)
        let main = t.tracks[0].clips
        #expect(main.map(\.name) == ["c", "x"])
        #expect(main[1].start == f(30))
        #expect(t.tracks[0].clips.first!.start == .zero)
    }

    @Test func dragOntoMainTrackWithPartnerAppendsExactlyAtTheEnd() throws {
        let link = UUID()
        let c = vclip("c", 0, 30), x = vclip("x", 90, 20, link: link), p = aclip("p", 60, 20, link: link)
        var t = timeline([Track(kind: .video, clips: [c]), Track(kind: .video, clips: [x]), Track(kind: .audio, clips: [p])],
                         fastCut: true)
        try t.dragOntoMainTrack(x.id, at: f(300), overwrite: true)
        #expect(t.find(x.id)?.clip.start == f(30))
        #expect(t.find(x.id)?.track == 0)
        #expect(t.find(p.id)?.clip.start == .zero)          // keeps its 30-frame offset to the clip
        #expect(t.tracks[0].clips.map(\.start) == [.zero, f(30)])
    }

    @Test func dragOntoMainTrackRefusesWhenAPartnerWouldStartBeforeZero() {
        let link = UUID()
        let c = vclip("c", 0, 30), x = vclip("x", 90, 20, link: link), p = aclip("p", 30, 20, link: link)
        var t = timeline([Track(kind: .video, clips: [c]), Track(kind: .video, clips: [x]), Track(kind: .audio, clips: [p])],
                         fastCut: true)
        let before = t
        #expect(throws: EditError.collision) { try t.dragOntoMainTrack(x.id, at: f(300), overwrite: true) }
        #expect(t == before)
    }

    @Test func dragOntoEmptyMainTrackLandsAtZero() throws {
        let x = vclip("x", 40, 20)
        var t = timeline([Track(kind: .video), Track(kind: .video, clips: [x])], fastCut: true)
        try t.dragOntoMainTrack(x.id, at: f(100), overwrite: true)
        #expect(t.tracks[0].clips.map(\.start) == [.zero])
    }

    @Test func dragOntoMainTrackBeforeTheEndStillOverwritesInPlace() throws {
        let a = vclip("a", 0, 60), b = vclip("b", 60, 60), x = vclip("x", 200, 20)
        var t = timeline([Track(kind: .video, clips: [a, b]), Track(kind: .video, clips: [x])], fastCut: true)
        try t.dragOntoMainTrack(x.id, at: f(70), overwrite: true)
        #expect(t.find(x.id)?.clip.start == f(70))
        #expect(t.tracks[0].clips.map(\.name).contains("x"))
    }

    // MARK: Trim mode and Snap to Beats

    private func trimTimeline(fastCut: Bool) -> (Timeline, Clip, Clip) {
        let a = vclip("a", 0, 60, src: 30), b = vclip("b", 60, 60, src: 30)
        let t = timeline([Track(kind: .video, clips: [a, b])], fastCut: fastCut)
        return (t, a, b)
    }

    @Test func trimEditInFastCutKeepsMainTrackGapless() throws {
        for side in TrimSide.allCases {
            var (t, a, b) = trimTimeline(fastCut: true)
            let p = TrimPoint(track: t.tracks[0].id, outgoing: a.id, incoming: b.id, time: f(60))
            _ = try t.trimEdit(p, side: side, by: f(-10))
            let clips = t.tracks[0].clips
            #expect(clips.first?.start == .zero, "\(side)")
            #expect(zip(clips, clips.dropFirst()).allSatisfy { $0.timeline.end == $1.start }, "\(side)")
        }
    }

    @Test func trimEditInNormalModeIsThePlainRippleTrimAndRoll() throws {
        for side in TrimSide.allCases {
            var (t, a, b) = trimTimeline(fastCut: false)
            var expected = t
            let p = TrimPoint(track: t.tracks[0].id, outgoing: a.id, incoming: b.id, time: f(60))
            _ = try t.trimEdit(p, side: side, by: f(-10))
            switch side {
            case .outgoing: _ = try expected.rippleTrim(a.id, edge: .tail, by: f(-10))
            case .incoming: _ = try expected.rippleTrim(b.id, edge: .head, by: f(-10))
            case .roll: _ = try expected.roll(a.id, by: f(-10))
            }
            #expect(t == expected, "\(side)")
        }
    }

    @Test func snapToBeatsInNormalModeIsThePlainRippleTrim() throws {
        let a = vclip("a", 0, 60, src: 30), b = vclip("b", 60, 60, src: 30)
        var t = timeline([Track(kind: .video, clips: [a, b])], fastCut: false)
        t.replaceBeatMarkers(in: TimeRange(start: .zero, duration: f(600)), with: [f(50)])
        var expected = t
        _ = try expected.rippleTrim(a.id, edge: .tail, by: f(-10))
        let n = try t.snapToBeats(clips: [a.id])
        #expect(n == 1)
        #expect(t.tracks == expected.tracks)
    }

    @Test func snapToBeatsInFastCutClosesTheGapOnTheMainTrack() throws {
        let a = vclip("a", 0, 60, src: 30), b = vclip("b", 60, 60, src: 30)
        var t = timeline([Track(kind: .video, clips: [a, b])], fastCut: true)
        t.replaceBeatMarkers(in: TimeRange(start: .zero, duration: f(600)), with: [f(50)])
        _ = try t.snapToBeats(clips: [a.id])
        let clips = t.tracks[0].clips
        #expect(clips[0].timeline.end == f(50))
        #expect(clips[1].start == f(50))
    }
}
