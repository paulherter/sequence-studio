import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil, group: UUID? = nil) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)),
                 start: s(start), link: link, mediaDuration: s(100))
    c.group = group
    return c
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func closure(_ tl: Timeline, _ id: Clip.ID, individual: Bool = false) throws -> Set<Clip.ID> {
    Set(try tl.linkedGroup(id, individual: individual).map(\.clip.id))
}
private func find(_ tl: Timeline, _ id: Clip.ID) -> Clip { tl.find(id)!.clip }

@Suite struct GroupTests {
    /// V1: a [0,10) b [20,30); V2: c [5,15)
    private func three() throws -> (Timeline, Clip, Clip, Clip) {
        let a = clip(0, 10), b = clip(20, 10), c = clip(5, 10)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [try track([a, b]), try track([c])])
        return (tl, a, b, c)
    }

    @Test func groupAndUngroup() throws {
        var (tl, a, b, c) = try three()
        let g = try tl.group([a.id, b.id])
        #expect(find(tl, a.id).group == g && find(tl, b.id).group == g)
        #expect(find(tl, c.id).group == nil)
        #expect(tl.groupMembers(g).count == 2)
        let freed = try tl.ungroup([a.id])            // ungroups the whole group of a selected clip
        #expect(freed == [a.id, b.id])
        #expect(find(tl, b.id).group == nil)
        #expect(try tl.ungroup([c.id]).isEmpty)
    }

    @Test func groupNeedsTwoClipsAndUnlockedTracks() throws {
        var (tl, a, b, _) = try three()
        #expect(throws: EditError.clipNotFound) { try tl.group([a.id]) }
        tl.tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) { try tl.group([a.id, b.id]) }
    }

    @Test func groupingMergesExistingGroups() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id])
        let g = try tl.group([b.id, c.id])             // a joins through b: groups merge, never nest
        #expect(Set(tl.groupMembers(g)) == [a.id, b.id, c.id])
    }

    @Test func selectionExpandsAndOptionPicksOne() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id])
        #expect(tl.expandedSelection([a.id]) == [a.id, b.id])
        #expect(tl.expandedSelection([a.id], individual: true) == [a.id])
        #expect(tl.expandedSelection([c.id]) == [c.id])
    }

    @Test func groupCoexistsWithLinks() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l), w = clip(20, 5)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [try track([v, w]), try track([a], kind: .audio)])
        try tl.group([v.id, w.id])
        #expect(try closure(tl, w.id) == [v.id, a.id, w.id])     // w brings v, v brings its audio
        #expect(try closure(tl, a.id) == [v.id, a.id, w.id])
        #expect(try closure(tl, v.id, individual: true) == [v.id])
    }

    @Test func movesAsOneUnit() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id])
        let d = try tl.move(a.id, to: s(3))
        #expect(d == s(3))
        #expect(find(tl, a.id).start == s(3) && find(tl, b.id).start == s(23))
        #expect(find(tl, c.id).start == s(5))
        _ = try tl.move(b.id, to: s(40), individual: true)        // Option-drag moves only b
        #expect(find(tl, a.id).start == s(3) && find(tl, b.id).start == s(40))
    }

    @Test func nudgeAndDeleteAsOneUnit() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id])
        _ = try tl.nudge([a.id], by: s(2))
        #expect(find(tl, b.id).start == s(22))
        try tl.lift([b.id])
        #expect(tl.find(a.id) == nil && tl.find(b.id) == nil && tl.find(c.id) != nil)
    }

    @Test func optionDeleteRemovesOnlyOneMember() throws {
        var (tl, a, b, _) = try three()
        try tl.group([a.id, b.id])
        try tl.lift([a.id], individual: true)
        #expect(tl.find(a.id) == nil && tl.find(b.id) != nil)
        tl.dropOrphanGroups()
        #expect(find(tl, b.id).group == nil)
    }

    @Test func rippleDeleteTakesTheGroup() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id])
        try tl.rippleDelete([a.id])
        #expect(tl.find(a.id) == nil && tl.find(b.id) == nil && tl.find(c.id) != nil)
    }

    @Test func trimActsOnOuterEdgesOnly() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id, c.id])
        // Tail: b ends at 30, the outer tail. a (ends 10) and c (ends 15) stay.
        let moved = try tl.trim(b.id, edge: .tail, by: s(-5))
        #expect(moved == s(-5))
        #expect(find(tl, b.id).duration == s(5))
        #expect(find(tl, a.id).duration == s(10) && find(tl, c.id).duration == s(10))
        // An inner edge (a's tail) cannot be trimmed.
        #expect(try tl.trim(a.id, edge: .tail, by: s(-2)) == .zero)
        #expect(find(tl, a.id).duration == s(10))
        // Head: a starts at 0, the outer head.
        #expect(try tl.trim(c.id, edge: .head, by: s(1)) == .zero)
        _ = try tl.trim(a.id, edge: .head, by: s(2))
        #expect(find(tl, a.id).start == s(2))
        #expect(find(tl, c.id).start == s(5))
    }

    @Test func trimMovesAllMembersSharingTheOuterEdge() throws {
        let a = clip(0, 10), c = clip(0, 10)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [try track([a]), try track([c])])
        try tl.group([a.id, c.id])
        _ = try tl.trim(a.id, edge: .tail, by: s(-4))
        #expect(find(tl, a.id).duration == s(6) && find(tl, c.id).duration == s(6))
        _ = try tl.trim(a.id, edge: .tail, by: s(-2), individual: true)
        #expect(find(tl, a.id).duration == s(4) && find(tl, c.id).duration == s(6))
    }

    @Test func rippleTrimAlsoUsesOuterEdges() throws {
        var (tl, a, b, c) = try three()
        try tl.group([a.id, b.id, c.id])
        #expect(try tl.rippleTrim(a.id, edge: .tail, by: s(-2)) == .zero)
        #expect(find(tl, a.id).duration == s(10))
    }

    @Test func splitKeepsHalvesGroupedSeparately() throws {
        var (tl, a, b, c) = try three()
        let g = try tl.group([a.id, c.id])               // a [0,10), c [5,15); b stays out
        try tl.addEdit(at: s(8), tracks: nil)
        let right = tl.tracks.flatMap(\.clips).filter { $0.start == s(8) }
        #expect(right.count == 2)
        #expect(right.allSatisfy { $0.group != nil && $0.group != g })
        #expect(right[0].group == right[1].group)           // the right halves share one new group
        #expect(find(tl, a.id).group == g && find(tl, c.id).group == g)
        #expect(find(tl, b.id).group == nil)
    }

    @Test func insertSplitRelinksGroup() throws {
        let g = UUID()
        let a = clip(0, 10, group: g), c = clip(0, 10, group: g)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [try track([a]), try track([c])])
        try tl.insert([(clip(0, 2), tl.tracks[0].id)], at: s(5))
        let right = tl.tracks.flatMap(\.clips).filter { $0.group != nil && $0.group != g }
        #expect(!right.isEmpty)
        #expect(Set(right.compactMap(\.group)).count == 1)
    }

    @Test func pasteKeepsTheGroupAmongCopies() throws {
        var (tl, a, b, _) = try three()
        let g = try tl.group([a.id, b.id])
        let cb = try #require(tl.clipboard(copying: [a.id, b.id]))
        let made = try tl.paste(cb, at: s(40))
        let copies = made.map { find(tl, $0) }
        #expect(copies.count == 2)
        #expect(copies[0].group != nil && copies[0].group == copies[1].group && copies[0].group != g)
        // A single copied member does not stay grouped.
        let one = try #require(tl.clipboard(copying: [a.id]))
        let m2 = try tl.paste(one, at: s(80))
        #expect(find(tl, m2[0]).group == nil)
    }

    @Test func optionCopyMoveGetsItsOwnGroup() throws {
        var (tl, a, b, _) = try three()
        let g = try tl.group([a.id, b.id])
        let spec = CopySpec()
        _ = try tl.move(a.id, to: s(50), copy: spec)
        let copies = tl.tracks.flatMap(\.clips).filter { $0.group == spec.group }
        #expect(copies.count == 2)
        #expect(Set(tl.groupMembers(g)) == [a.id, b.id])
    }

    @Test func groupSurvivesProjectFileRoundTrip() throws {
        var (tl, a, b, _) = try three()
        let g = try tl.group([a.id, b.id])
        let back = try ProjectFile.decode(try ProjectFile.encode(Project(name: "P", timelines: [tl])),
                                          migrations: ProjectFile.migrations)
        let flat = back.timelines[0].tracks.flatMap(\.clips)
        #expect(flat.filter { $0.group == g }.count == 2)
    }
}

@Suite struct SourcePatchTests {
    private func tl() -> Timeline { Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 3, audio: 3)) }

    @Test func newTracksPatchWhereTargeted() {
        let t = tl()
        #expect(t.tracks.map(\.isSourcePatched) == t.tracks.map(\.isTargeted))
    }

    @Test func patchesDecideSourceEditTargetsNotTargets() {
        var t = tl()
        let v3 = t.tracks.filter { $0.kind == .video }[2].id, a2 = t.tracks.filter { $0.kind == .audio }[1].id
        t.togglePatch(v3, option: true)                        // V3 only
        t.togglePatch(a2, option: true)                        // A2 only
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: true) == [v3, a2])
        // Targets stay on V1 / A1 and still drive paste.
        #expect(t.tracks.filter(\.isTargeted).map(\.kind) == [.video, .audio])
        #expect(t.tracks.first { $0.isTargeted && $0.kind == .video }?.id != v3)
    }

    @Test func targetClicksDoNotMovePatches() {
        var t = tl()
        let before = t.tracks.map(\.isSourcePatched)
        for tr in t.tracks { t.toggleTarget(tr.id, option: true) }
        #expect(t.tracks.map(\.isSourcePatched) == before)
    }

    @Test func patchModifiersMirrorTargeting() {
        var t = tl()
        let vs = t.tracks.filter { $0.kind == .video }.map(\.id)
        t.togglePatch(vs[1])                                    // plain: flips V2 on
        #expect(t.patchedTracks(.video) == [vs[0], vs[1]])
        t.togglePatch(vs[1], shift: true)                       // all video to V2's new state (off)
        #expect(t.patchedTracks(.video).isEmpty)
        t.togglePatch(vs[2], option: true)
        #expect(t.patchedTracks(.video) == [vs[2]])
        t.resetPatchesToTargets()
        #expect(t.patchedTracks(.video) == [vs[0]])
    }

    @Test func unpatchedKindIsDropped() {
        var t = tl()
        let a1 = t.tracks.first { $0.kind == .audio }!.id
        t.togglePatch(a1)
        t.tracks.indices.filter { t.tracks[$0].kind == .audio }.forEach { t.tracks[$0].isSourcePatched = false }
        let v1 = t.tracks.first { $0.kind == .video }!.id
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: true) == [v1])
    }

    @Test func oldFilesDefaultPatchesFromTargets() throws {
        var tr = Track(kind: .video, isTargeted: true)
        tr.isSourcePatched = false
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tr)) as? [String: Any])
        obj.removeValue(forKey: "isSourcePatched")
        let old = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.isTargeted && old.isSourcePatched)
        obj["isTargeted"] = false
        let off = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(!off.isSourcePatched)
    }

    @Test func storedPatchWinsOverTarget() throws {
        var t = tl()
        let v1 = t.tracks[0].id
        t.togglePatch(v1)                                       // targeted but unpatched
        let back = try ProjectFile.decode(try ProjectFile.encode(Project(name: "P", timelines: [t])),
                                          migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].isTargeted && !back.timelines[0].tracks[0].isSourcePatched)
    }

    @Test func v23FileGetsPatchesFromTargets() throws {
        let t = tl()
        let data = try ProjectFile.encode(Project(name: "P", timelines: [t]))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var p = obj["project"] as! [String: Any]
        var tls = p["timelines"] as! [[String: Any]]
        tls[0]["tracks"] = (tls[0]["tracks"] as! [[String: Any]]).map { var x = $0; x.removeValue(forKey: "isSourcePatched"); return x }
        p["timelines"] = tls; obj["project"] = p; obj["formatVersion"] = 23
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks.map(\.isSourcePatched) == t.tracks.map(\.isTargeted))
        #expect(ProjectFile.currentVersion == 24 && ProjectFile.realMigrations[23] != nil)
    }
}

@Suite struct FourPointTests {
    private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
    private func resolve(_ src: TimeRange, _ seq: TimeRange, _ c: FourPointChoice, total: Int64? = 100) -> FourPointPlacement? {
        Timeline.resolveFourPoint(source: src, sequence: seq, choice: c, total: total.map(s), frameDuration: fd)
    }

    @Test func fitClipChangesSpeed() throws {
        let p = try #require(resolve(r(10, 20), r(0, 5), .fitClip))      // 10 s of source over 5 s
        #expect(p.source == r(10, 20) && p.at == s(0) && p.duration == s(5))
        #expect(p.speed == ClipSpeed(num: 2, den: 1))
        let slow = try #require(resolve(r(10, 12), r(4, 10), .fitClip))  // 2 s over 6 s: 33.33 %
        #expect(slow.speed == ClipSpeed(num: 1, den: 3) && slow.duration == s(6) && slow.at == s(4))
    }

    @Test func fitClipClampsToSpeedRange() throws {
        let p = try #require(resolve(r(0, 1), r(0, 1000), .fitClip))
        #expect(p.speed == .minimum)
        #expect(p.duration == ClipSpeed.minimum.unscale(s(1)))
    }

    @Test func ignoreSourceOutKeepsInAndSequenceRange() throws {
        let p = try #require(resolve(r(10, 20), r(5, 8), .ignoreSourceOut))
        #expect(p.source == r(10, 13) && p.at == s(5) && p.duration == s(3) && p.speed == .normal)
        let short = try #require(resolve(r(95, 99), r(0, 20), .ignoreSourceOut))  // media ends at 100
        #expect(short.source == r(95, 100) && short.duration == s(5))
    }

    @Test func ignoreSourceInKeepsOut() throws {
        let p = try #require(resolve(r(10, 20), r(5, 8), .ignoreSourceIn))
        #expect(p.source == r(17, 20) && p.at == s(5) && p.duration == s(3))
        let short = try #require(resolve(r(0, 2), r(5, 15), .ignoreSourceIn))     // only 2 s before the Out
        #expect(short.source == r(0, 2) && short.at == s(5) && short.duration == s(2))
    }

    @Test func ignoreSequenceOutKeepsSourceLength() throws {
        let p = try #require(resolve(r(10, 20), r(5, 8), .ignoreSequenceOut))
        #expect(p.source == r(10, 20) && p.at == s(5) && p.duration == s(10) && p.speed == .normal)
    }

    @Test func ignoreSequenceInEndsAtSequenceOut() throws {
        let p = try #require(resolve(r(10, 20), r(30, 40), .ignoreSequenceIn))
        #expect(p.source == r(10, 20) && p.at == s(30))
        let q = try #require(resolve(r(10, 20), r(30, 35), .ignoreSequenceIn))
        #expect(q.at == s(25) && q.source == r(10, 20))
        let cut = try #require(resolve(r(10, 20), r(0, 4), .ignoreSequenceIn))     // would start at -6: head cut
        #expect(cut.at == s(0) && cut.source == r(16, 20) && cut.duration == s(4))
        #expect(resolve(r(10, 20), r(0, 0), .ignoreSequenceIn) == nil)
    }

    @Test func invalidInputGivesNil() {
        #expect(resolve(r(5, 5), r(0, 5), .fitClip) == nil)
        #expect(resolve(r(0, 200), r(0, 5), .fitClip) == nil)                      // beyond the media
        #expect(resolve(r(0, 200), r(0, 5), .fitClip, total: nil) != nil)           // unbounded media (stills)
    }

    @Test func everyChoiceStaysInsideTheMedia() {
        for c in FourPointChoice.allCases {
            guard let p = resolve(r(90, 100), r(0, 30), c) else { continue }
            #expect(p.source.start >= .zero && p.source.end <= s(100), "\(c)")
            #expect(p.duration > .zero && p.at >= .zero, "\(c)")
            #expect(p.duration == p.speed.unscale(p.source.duration), "\(c)")
        }
    }
}
