import Foundation
import Testing
@testable import SQCore

/// Premiere 22.5+: Cmd+V pastes onto the tracks the clips were copied from; "Paste to Targeted Track" keeps the old
/// rule (lowest targeted track per kind). Audit 2026-10 item 1.
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start), link: link)
}

/// V1..V4 and A1..A2; V1/A1 targeted (the default). A title on V4 linked to nothing, a sound on A2.
private func fixture() -> (Timeline, Clip, Clip, Clip) {
    let head = clip(0, 60)
    let title = clip(0, 5), sound = clip(0, 5, kind: .audio)
    var tracks = [Track(kind: .video, isTargeted: true), Track(kind: .video), Track(kind: .video), Track(kind: .video),
                  Track(kind: .audio, isTargeted: true), Track(kind: .audio)]
    try! tracks[0].overwrite(head)
    try! tracks[3].overwrite(title)
    try! tracks[5].overwrite(sound)
    return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks), head, title, sound)
}
private func lane(of id: Clip.ID, in t: Timeline) -> (TrackKind, Int)? {
    for k in [TrackKind.video, .audio] {
        for (i, tr) in t.tracks.filter({ $0.kind == k }).enumerated() where tr.clip(id) != nil { return (k, i) }
    }
    return nil
}

@Suite struct PasteTracksTests {
    @Test func pasteLandsOnTheCopiedTracksNotTheTargets() throws {
        var (t, head, title, sound) = fixture()
        let cb = t.clipboard(copying: [title.id, sound.id])!
        let made = try t.paste(cb, at: s(20))
        #expect(made.count == 2)
        let lanes = made.compactMap { lane(of: $0, in: t) }
        #expect(lanes.contains { $0 == (.video, 3) } && lanes.contains { $0 == (.audio, 1) })
        // The talking head on V1 is not cut.
        #expect(t.tracks[0].clips.count == 1 && t.tracks[0].clips[0].id == head.id)
    }

    @Test func pasteToTargetsUsesTheLowestTargetedTrack() throws {
        var (t, _, title, sound) = fixture()
        let cb = t.clipboard(copying: [title.id, sound.id])!
        let made = try t.pasteToTargets(cb, at: s(20))
        let lanes = made.compactMap { lane(of: $0, in: t) }
        #expect(lanes.contains { $0 == (.video, 0) } && lanes.contains { $0 == (.audio, 0) })
    }

    @Test func pasteToTargetsWithoutATargetFallsBackToTheCopiedTrack() throws {
        var (t, _, title, _) = fixture()
        for i in t.tracks.indices { t.tracks[i].isTargeted = false }
        let cb = t.clipboard(copying: [title.id])!
        let made = try t.pasteToTargets(cb, at: s(20))
        #expect(lane(of: made[0], in: t)! == (.video, 3))
    }

    @Test func pasteToTargetsKeepsLaneOffsets() throws {
        var (t, _, _, _) = fixture()
        let a = clip(100, 5), b = clip(100, 5)
        try t.tracks[1].overwrite(a)
        try t.tracks[2].overwrite(b)
        let cb = t.clipboard(copying: [a.id, b.id])!
        t.tracks[0].isTargeted = false
        t.tracks[3].isTargeted = true                        // V4 targeted: V2+V3 copy lands on V4+V5 (created)
        let made = try t.pasteToTargets(cb, at: s(200))
        #expect(Set(made.compactMap { lane(of: $0, in: t)?.1 }) == [3, 4])
        #expect(t.tracks.filter { $0.kind == .video }.count == 5)
    }

    @Test func pasteInsertFollowsTheSameLaneRule() throws {
        var (t, _, title, _) = fixture()
        let cb = t.clipboard(copying: [title.id])!
        let made = try t.paste(cb, at: s(0), insert: true)
        #expect(lane(of: made[0], in: t)! == (.video, 3))
        var u = fixture().0
        let cb2 = u.clipboard(copying: [u.tracks[3].clips[0].id])!
        let made2 = try u.pasteToTargets(cb2, at: s(0), insert: true)
        #expect(lane(of: made2[0], in: u)! == (.video, 0))
    }

    @Test func pasteEndIsTheLatestEndOfThePastedClips() throws {
        var (t, _, title, sound) = fixture()
        let cb = t.clipboard(copying: [title.id, sound.id])!
        let made = try t.paste(cb, at: s(20))
        #expect(t.end(of: made) == s(25))
        #expect(t.end(of: []) == nil)
    }
}
