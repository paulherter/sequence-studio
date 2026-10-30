import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}
private func project(_ tracks: [Track]) -> Project {
    Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: tracks)])
}

/// Every id the user-facing API could hold on to: clips, tracks, links, markers, sequences.
private struct Ids: Equatable {
    var clips: [UUID], tracks: [UUID], links: [UUID], markers: [UUID], sequences: [UUID]
    init(_ p: Project) {
        let all = p.timelines.flatMap { $0.tracks }
        clips = all.flatMap(\.clips).map(\.id)
        tracks = all.map(\.id)
        links = all.flatMap(\.clips).compactMap(\.link)
        markers = p.timelines.flatMap { $0.markers.map(\.id) }
        sequences = p.timelines.map(\.id)
    }
}

private func roundtrip(_ p: Project) throws -> Project {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-id-\(UUID().uuidString).sqproj")
    defer { try? FileManager.default.removeItem(at: dir) }
    try ProjectFile.write(p, to: dir)
    return try ProjectFile.read(from: dir)
}

/// Runs `edit` as one undo step, then checks undo restores the exact ids and redo reproduces the exact ids of the first run.
private func checkUndoRedo(_ p: Project, _ name: String,
                           _ edit: (inout Project) throws -> Void) throws -> (before: Ids, after: Ids) {
    var h = History(p)
    let before = Ids(p)
    try h.commit(name, edit)
    let after = Ids(h.current)
    let undone = h.undo()
    #expect(undone)
    #expect(Ids(h.current) == before, "undo of \(name) must restore identical ids")
    #expect(h.current == p)
    let redone = h.redo()
    #expect(redone)
    #expect(Ids(h.current) == after, "redo of \(name) must reproduce identical ids")
    #expect(Ids(try roundtrip(h.current)) == after, "roundtrip after \(name)")
    return (before, after)
}

@Suite struct IdStabilityTests {
    @Test func splitKeepsLeftIdAndMintsRight() throws {
        let a = clip(0, 4)
        let p = project([track([a])])
        let tid = p.timelines[0].id
        let r = try checkUndoRedo(p, "Split") { try $0.edit(tid) { try $0.tracks[0].split(at: s(2)) } }
        #expect(r.after.clips.count == 2 && r.after.clips.contains(a.id))
        #expect(r.after.clips.filter { !r.before.clips.contains($0) }.count == 1)
    }

    @Test func addEditAcrossLinkedPairMintsNewLinkForRightHalves() throws {
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l)
        let p = project([track([v]), track([a], kind: .audio)])
        let tid = p.timelines[0].id
        let r = try checkUndoRedo(p, "Add Edit") { try $0.edit(tid) { _ = try $0.addEdit(at: s(2), tracks: nil) } }
        #expect(r.after.clips.contains(v.id) && r.after.clips.contains(a.id))
        #expect(r.after.clips.count == 4)
        #expect(Set(r.after.links).count == 2)
        #expect(r.after.links.contains(l))
    }

    @Test func liftAndRippleDeleteKeepSurvivorIds() throws {
        let a = clip(0, 2), b = clip(2, 2), c = clip(4, 2)
        let p = project([track([a, b, c])])
        let tid = p.timelines[0].id
        let trackID = p.timelines[0].tracks[0].id
        let ripple = try checkUndoRedo(p, "Ripple Delete") { try $0.edit(tid) { _ = try $0.rippleDelete([b.id]) } }
        #expect(ripple.after.clips == [a.id, c.id])
        let lift = try checkUndoRedo(p, "Clear Range") {
            try $0.edit(tid) { try $0.lift(TimeRange(start: s(2), end: s(4)), tracks: [trackID]) }
        }
        #expect(lift.after.clips == [a.id, c.id])
    }

    @Test func liftInsideClipSplitsIdsLikeSplit() throws {
        let a = clip(0, 6)
        let p = project([track([a])])
        let tid = p.timelines[0].id
        let trackID = p.timelines[0].tracks[0].id
        let r = try checkUndoRedo(p, "Clear Range") {
            try $0.edit(tid) { try $0.lift(TimeRange(start: s(2), end: s(3)), tracks: [trackID]) }
        }
        #expect(r.after.clips.count == 2 && r.after.clips.contains(a.id))
    }

    @Test func moveAndRippleTrimKeepIds() throws {
        let a = clip(0, 2), b = clip(4, 2)
        let p = project([track([a, b])])
        let tid = p.timelines[0].id
        let m = try checkUndoRedo(p, "Move") { try $0.edit(tid) { _ = try $0.move(b.id, to: s(2)) } }
        #expect(m.after.clips == m.before.clips)
        let t = try checkUndoRedo(p, "Ripple Trim") { try $0.edit(tid) { _ = try $0.rippleTrim(a.id, edge: .tail, by: s(-1)) } }
        #expect(t.after.clips == t.before.clips)
    }

    @Test func moveIntoMiddleOfClipSplitsTargetWithNewRightId() throws {
        let a = clip(0, 6), b = clip(10, 1)
        let p = project([track([a, b])])
        let tid = p.timelines[0].id
        let r = try checkUndoRedo(p, "Move") { try $0.edit(tid) { _ = try $0.move(b.id, to: s(2)) } }
        #expect(r.after.clips.count == 3 && r.after.clips.contains(a.id) && r.after.clips.contains(b.id))
    }

    @Test func pasteMintsFreshIdsEachTimeAndRedoReplaysThem() throws {
        let a = clip(0, 2)
        let p = project([track([a])])
        let tid = p.timelines[0].id
        let cb = try #require(p.timelines[0].clipboard(copying: [a.id]))
        let r = try checkUndoRedo(p, "Paste") { try $0.edit(tid) { _ = try $0.paste(cb, at: s(5)) } }
        #expect(r.after.clips.count == 2 && r.after.clips.contains(a.id))
        var t = p.timelines[0]
        let first = try t.paste(cb, at: s(5)), second = try t.paste(cb, at: s(8))
        #expect(first != second && !first.contains(a.id))
    }

    @Test func nestKeepsClipIdsButMintsInnerTrackAndSequenceIds() throws {
        let a = clip(0, 2), b = clip(2, 2), c = clip(4, 2)
        let p = project([track([a, b, c])])
        let tid = p.timelines[0].id
        let r = try checkUndoRedo(p, "Nest") { _ = try $0.nest(clips: [b.id], in: tid) }
        #expect(r.after.sequences.count == 2)
        var q = p
        let seq = try q.nest(clips: [b.id], in: tid)
        let loaded = try roundtrip(q)
        let inner = try #require(loaded.timeline(seq))
        #expect(inner.tracks.flatMap(\.clips).map(\.id) == [b.id])          // nested clip keeps its id inside
        #expect(inner.tracks[0].id != p.timelines[0].tracks[0].id)          // inner track id is new
        let outer = try #require(loaded.timeline(tid)).tracks[0].clips
        #expect(outer.contains { $0.id == a.id } && outer.contains { $0.id == c.id })
        #expect(!outer.contains { $0.id == b.id })                          // b's id now lives only in the inner sequence
        #expect(outer.contains { $0.sequence == seq })                      // the nested clip is a NEW clip id
    }

    @Test func trackAndMarkerIdsSurviveEditsUndoAndSave() throws {
        let a = clip(0, 4)
        var tl = Timeline(name: "Main", frameDuration: fd, tracks: [track([a])])
        let m = tl.addMarker(at: s(1), name: "m")
        let p = Project(name: "P", timelines: [tl])
        let tid = tl.id
        let r = try checkUndoRedo(p, "Marker edits") {
            try $0.edit(tid) { t in
                t.moveMarker(m, to: s(3)); t.renameMarker(m, to: "x")
                try t.tracks[0].split(at: s(2))
            }
        }
        #expect(r.after.markers == [m] && r.after.tracks == r.before.tracks)
    }

    @Test func saveReloadPreservesEveryIdIncludingLinks() throws {
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l), w = clip(4, 2)
        var tl = Timeline(name: "Main", frameDuration: fd, tracks: [track([v, w]), track([a], kind: .audio)])
        tl.addMarker(at: s(1))
        let p = Project(name: "P", timelines: [tl])
        let loaded = try roundtrip(p)
        #expect(Ids(loaded) == Ids(p))
        #expect(loaded == p)
        #expect(Ids(try roundtrip(loaded)) == Ids(p))
    }
}
