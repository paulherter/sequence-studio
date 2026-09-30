import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video,
                  link: UUID? = nil, media: Int64? = nil, m: UUID = UUID()) -> Clip {
    Clip(name: "c", media: m, kind: kind, source: TimeRange(start: s(src), duration: s(dur)),
         start: s(start), link: link, mediaDuration: media.map(s))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, locked: Bool = false, sync: Bool = true) throws -> Track {
    var t = Track(kind: kind, isLocked: locked, syncLock: sync)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func spans(_ t: Track) -> [[Int64]] {
    t.clips.map { [$0.start.value / $0.start.timescale, $0.timeline.end.value / $0.timeline.end.timescale] }
}

@Suite struct LiftByIdTests {
    @Test func removesGroupLeavesGaps() throws {
        let l = UUID()
        let v = clip(2, 3, link: l), a = clip(2, 3, kind: .audio, link: l), next = clip(5, 2)
        var tl = timeline(try track([v, next]), try track([a], kind: .audio))
        try tl.lift([v.id])
        #expect(spans(tl.tracks[0]) == [[5, 7]])
        #expect(tl.tracks[1].clips.isEmpty)
    }
    @Test func lockedAndUnknown() throws {
        let l = UUID()
        let v = clip(0, 3, link: l), a = clip(0, 3, kind: .audio, link: l)
        var tl = timeline(try track([v]), try track([a], kind: .audio, locked: true))
        let before = tl
        #expect(throws: EditError.trackLocked) { try tl.lift([v.id]) }
        #expect(throws: EditError.clipNotFound) { try tl.lift([UUID()]) }
        #expect(tl == before)
    }
}

@Suite struct OverwriteTests {
    @Test func coversAndKeepsOffsets() throws {
        var tl = timeline(try track([clip(0, 10)]), try track([clip(0, 10, kind: .audio)], kind: .audio))
        let v = clip(100, 2), a = clip(101, 2, kind: .audio)
        try tl.overwrite([(v, tl.tracks[0].id), (a, tl.tracks[1].id)], at: s(4))
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 6], [6, 10]])
        #expect(spans(tl.tracks[1]) == [[0, 5], [5, 7], [7, 10]])
    }
    @Test func lockedWrongKindEmpty() throws {
        var tl = timeline(try track([], locked: true), try track([], kind: .audio))
        #expect(throws: EditError.trackLocked) { try tl.overwrite([(clip(0, 2), tl.tracks[0].id)], at: s(0)) }
        #expect(throws: EditError.wrongTrackKind) { try tl.overwrite([(clip(0, 2), tl.tracks[1].id)], at: s(0)) }
        #expect(throws: EditError.emptyClip) { try tl.overwrite([], at: s(0)) }
    }
}

@Suite struct ThreePointTests {
    @Test func overwriteLinkedAV() throws {
        var tl = timeline(try track([clip(0, 10)]), try track([], kind: .audio))
        let media = UUID()
        try tl.threePointEdit(source: r(5, 8), media: media, mediaDuration: s(20),
                              targets: tl.tracks.map(\.id), at: s(2), mode: .overwrite)
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 5], [5, 10]])
        let v = tl.tracks[0].clips[1], a = tl.tracks[1].clips[0]
        #expect(v.link != nil && v.link == a.link)
        #expect(v.media == media && v.source == r(5, 8) && a.kind == .audio && a.start == s(2))
    }
    @Test func singleKindUnlinked() throws {
        var tl = timeline(try track([]), try track([]))
        try tl.threePointEdit(source: r(0, 2), media: UUID(), targets: tl.tracks.map(\.id), at: s(0), mode: .overwrite)
        #expect(tl.tracks[0].clips[0].link == nil && tl.tracks[1].clips[0].link == nil)
    }
    @Test func insertHonoursSyncLock() throws {
        var tl = timeline(try track([clip(0, 10)]), try track([clip(0, 10, kind: .audio)], kind: .audio),
                          try track([clip(0, 10)], sync: false), try track([clip(0, 10)], locked: true))
        try tl.threePointEdit(source: r(0, 3), media: UUID(), targets: [tl.tracks[0].id], at: s(4), mode: .insert)
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 7], [7, 13]])
        #expect(spans(tl.tracks[1]) == [[0, 4], [7, 13]])       // sync-locked audio gets gap
        #expect(spans(tl.tracks[2]) == [[0, 10]])
        #expect(spans(tl.tracks[3]) == [[0, 10]])
    }
    @Test func limitsAndLocks() throws {
        var tl = timeline(try track([], locked: true), try track([], kind: .audio))
        let ids = tl.tracks.map(\.id)
        #expect(throws: EditError.trackLocked) {
            try tl.threePointEdit(source: r(0, 2), media: UUID(), targets: ids, at: s(0), mode: .insert)
        }
        #expect(throws: EditError.emptyClip) {
            try tl.threePointEdit(source: r(0, 30), media: UUID(), mediaDuration: s(20), targets: [ids[1]], at: s(0), mode: .overwrite)
        }
        #expect(throws: EditError.clipNotFound) {
            try tl.threePointEdit(source: r(0, 2), media: UUID(), targets: [], at: s(0), mode: .overwrite)
        }
        #expect(tl.tracks.allSatisfy { $0.clips.isEmpty })
    }
}

@Suite struct AddEditTests {
    @Test func splitsLinkedAllTracksWithFreshRightLink() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var tl = timeline(try track([v]), try track([a], kind: .audio), try track([], locked: true))
        let made = try tl.addEdit(at: s(4), tracks: nil)
        #expect(made.count == 2)
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 10]])
        let (v0, v1) = (tl.tracks[0].clips[0], tl.tracks[0].clips[1])
        let (a0, a1) = (tl.tracks[1].clips[0], tl.tracks[1].clips[1])
        #expect(v0.id == v.id && v0.link == l && a0.link == l)
        #expect(v1.link != nil && v1.link == a1.link && v1.link != l)
        #expect(v1.source.start == s(4))
    }
    @Test func targetedOnlyAndEdgesNoop() throws {
        var tl = timeline(try track([clip(0, 10)]), try track([clip(0, 10)]))
        try tl.addEdit(at: s(4), tracks: [tl.tracks[0].id])
        #expect(tl.tracks[0].clips.count == 2 && tl.tracks[1].clips.count == 1)
        let made = try tl.addEdit(at: s(4), tracks: nil)       // edge on track 0, split on track 1
        #expect(made.count == 1 && tl.tracks[0].clips.count == 2 && tl.tracks[1].clips.count == 2)
    }
    @Test func lockedNamedThrows() throws {
        var tl = timeline(try track([clip(0, 10)], locked: true))
        #expect(throws: EditError.trackLocked) { try tl.addEdit(at: s(4), tracks: [tl.tracks[0].id]) }
        #expect(try tl.addEdit(at: s(4), tracks: nil).isEmpty)
    }
}

@Suite struct RippleTrimToPlayheadTests {
    @Test func headQ() throws {
        var tl = timeline(try track([clip(0, 10, src: 0), clip(10, 5)]))
        let id = tl.tracks[0].clips[0].id
        let moved = try tl.rippleTrimToPlayhead(.head, at: s(4), tracks: nil)
        #expect(moved == s(4))
        #expect(spans(tl.tracks[0]) == [[0, 6], [6, 11]])
        #expect(tl.tracks[0].clips[0].id == id && tl.tracks[0].clips[0].source.start == s(4))
    }
    @Test func tailW() throws {
        var tl = timeline(try track([clip(0, 10), clip(10, 5)]), try track([clip(10, 2, kind: .video)]))
        try tl.rippleTrimToPlayhead(.tail, at: s(7), tracks: [tl.tracks[0].id])
        #expect(spans(tl.tracks[0]) == [[0, 7], [7, 12]])
        #expect(spans(tl.tracks[1]) == [[7, 9]])               // sync-locked track shifts
    }
    @Test func linkedPartnerFollowsAndErrors() throws {
        let l = UUID()
        var tl = timeline(try track([clip(0, 10, link: l)]), try track([clip(0, 10, kind: .audio, link: l)], kind: .audio))
        try tl.rippleTrimToPlayhead(.tail, at: s(6), tracks: nil)
        #expect(spans(tl.tracks[0]) == [[0, 6]] && spans(tl.tracks[1]) == [[0, 6]])
        #expect(throws: EditError.clipNotFound) { try tl.rippleTrimToPlayhead(.head, at: s(50), tracks: nil) }
        #expect(throws: EditError.clipNotFound) { try tl.rippleTrimToPlayhead(.tail, at: s(0), tracks: nil) }
        var locked = timeline(try track([clip(0, 10)], locked: true))
        #expect(throws: EditError.trackLocked) { try locked.rippleTrimToPlayhead(.head, at: s(3), tracks: [locked.tracks[0].id]) }
    }
}

@Suite struct ExtendEditTests {
    @Test func tailGrowsLimitedByNeighbourAndMedia() throws {
        var tl = timeline(try track([clip(0, 4, media: 6), clip(8, 2)]))
        let id = tl.tracks[0].clips[0].id
        #expect(try tl.extendEdit(id, edge: .tail, to: s(7)) == s(2))    // media limit 6
        #expect(spans(tl.tracks[0]) == [[0, 6], [8, 10]])
        #expect(try tl.extendEdit(id, edge: .tail, to: s(3)) == .zero)   // inside: no-op
    }
    @Test func headGrowsLimitedByNeighbour() throws {
        var tl = timeline(try track([clip(0, 2), clip(6, 4, src: 10)]))
        let id = tl.tracks[0].clips[1].id
        #expect(try tl.extendEdit(id, edge: .head, to: s(1)) == s(-4))   // stops at previous clip end 2
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 10]])
    }
    @Test func abuttingEditRolls() throws {
        var tl = timeline(try track([clip(0, 5, media: 20), clip(5, 5, src: 5)]))
        let (a, b) = (tl.tracks[0].clips[0].id, tl.tracks[0].clips[1].id)
        #expect(try tl.extendEdit(a, edge: .tail, to: s(7)) == s(2))
        #expect(spans(tl.tracks[0]) == [[0, 7], [7, 10]])
        #expect(try tl.extendEdit(b, edge: .head, to: s(3)) == s(-4))
        #expect(spans(tl.tracks[0]) == [[0, 3], [3, 10]])
    }
    @Test func lockedAndUnknown() throws {
        var tl = timeline(try track([clip(0, 4)], locked: true))
        #expect(throws: EditError.trackLocked) { try tl.extendEdit(tl.tracks[0].clips[0].id, edge: .tail, to: s(9)) }
        #expect(throws: EditError.clipNotFound) { try tl.extendEdit(UUID(), edge: .tail, to: s(9)) }
    }
}
