import Foundation
import Testing
@testable import SQCore

/// Color target bar (DECISIONS 2026-10-03, variant E step 1): source-linked grades by default with a per-clip
/// "Linked" switch (`Clip.gradeIndependent`, v47), and the Timeline grade (an auto-created adjustment layer).
@Suite struct ColorGradeTargetTests {
    typealias L = ColorGradeLinkTests
    static let fd = Time(1, 25)

    static func clip(_ name: String, media: UUID, start: Int64, temperature: Float? = nil) -> Clip {
        var c = L.clip(name, media: media, start: Time(start, 1))
        if let temperature { c.effects = [L.warm(temperature)] }
        return c
    }

    // MARK: Linked state (display)

    @Test func anUngradedClipIsLinkedToItsSourceByDefault() {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0), b = Self.clip("B", media: m, start: 4)
        let p = L.project([a, b])
        #expect(p.isGradeLinkedToSource(a.id))
        #expect(p.sourceGradeShareCount(a.id) == 2)
    }

    @Test func generatorsAdjustmentLayersAndNestedClipsHaveNoSourceLink() throws {
        var p = L.project([Self.clip("A", media: UUID(), start: 0)])
        let tl = p.timelines[0].id, tr = p.timelines[0].tracks[0].id
        let adj = try p.addAdjustmentClip(in: tl, at: Time(4, 1), track: tr, duration: Time(2, 1))
        #expect(!p.isGradeLinkedToSource(adj))
        #expect(p.sourceGradeShareCount(adj) == 1)
    }

    @Test func aClipWithItsOwnDifferentGradeNextToALinkGroupShowsUnlinked() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 10), b = Self.clip("B", media: m, start: 4)
        let c = Self.clip("C", media: m, start: 8, temperature: 40)
        var p = L.project([a, b, c])
        let r1 = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(r1)
        #expect(p.isGradeLinkedToSource(a.id) && p.isGradeLinkedToSource(b.id))
        #expect(!p.isGradeLinkedToSource(c.id))            // graded on its own, differs from the group
        #expect(p.sourceGradeShareCount(a.id) == 2)
    }

    // MARK: Edit while linked

    @Test func editingALinkedClipGradesEveryUngradedClipOfTheSource() {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0), b = Self.clip("B", media: m, start: 4)
        let other = Self.clip("X", media: UUID(), start: 8)
        var p = L.project([a, b, other])
        let r2 = p.prepareSourceGradeEdit(a.id)
        #expect(r2)
        L.edit(&p, a.id, temperature: 25)
        #expect(L.temperature(L.find(p, b.id)) == 25)
        #expect(L.find(p, a.id).gradeLink != nil && L.find(p, a.id).gradeLink == L.find(p, b.id).gradeLink)
        #expect(L.temperature(L.find(p, other.id)) == 0)   // other source untouched
    }

    @Test func aNewUngradedClipJoinsTheGroupAndTakesItsGradeBeforeTheEdit() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 30), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let r3 = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(r3)
        let c = Self.clip("C", media: m, start: 8)          // dropped in later, ungraded
        try p.edit(p.timelines[0].id) { try $0.tracks[0].overwrite(c) }
        let r4 = p.prepareSourceGradeEdit(c.id)
        #expect(r4)
        #expect(L.temperature(L.find(p, c.id)) == 30)       // adopted the group grade
        // The panel edit then changes another value of the shared grade.
        let old = p
        p.forEachClipInPlace { x in
            guard x.id == c.id else { return }
            var col = x.color; col.effects[0].basic.tint = 5; x.color = col
        }
        p.propagateGradeLinks(from: old)
        for id in [a.id, b.id, c.id] {
            #expect(L.find(p, id).color.effects[0].basic.tint == 5)
            #expect(L.temperature(L.find(p, id)) == 30)
        }
    }

    @Test func siblingsGradedOnTheirOwnKeepTheirGradeAndBecomeIndependent() {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0), b = Self.clip("B", media: m, start: 4, temperature: 40)
        var p = L.project([a, b])
        let r5 = p.prepareSourceGradeEdit(a.id)
        #expect(r5)
        L.edit(&p, a.id, temperature: 10)
        #expect(L.temperature(L.find(p, b.id)) == 40)
        #expect(L.find(p, b.id).gradeIndependent)
        #expect(L.find(p, b.id).gradeLink == nil)
    }

    @Test func aGradedLoneClipNextToADifferentGroupEditsOnlyItself() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 10), b = Self.clip("B", media: m, start: 4)
        let c = Self.clip("C", media: m, start: 8, temperature: 40)
        var p = L.project([a, b, c])
        let r6 = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(r6)
        let r7 = p.prepareSourceGradeEdit(c.id)
        #expect(r7)
        #expect(L.find(p, c.id).gradeIndependent)
        L.edit(&p, c.id, temperature: 45)
        #expect(L.temperature(L.find(p, a.id)) == 10 && L.temperature(L.find(p, b.id)) == 10)
    }

    @Test func prepareIsANoOpWhenEverythingIsAlreadyLinked() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let r8 = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(r8)
        let r9 = p.prepareSourceGradeEdit(a.id)
        #expect(!r9)
    }

    // MARK: Linked switch

    @Test func switchingLinkedOffChangesOnlyThatClipFromThenOn() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 20), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let r10 = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(r10)
        let r11 = p.setGradeLinkedToSource(b.id, false)
        #expect(r11)
        let r12 = p.setGradeLinkedToSource(b.id, false)
        #expect(!r12)  // already off
        #expect(!p.isGradeLinkedToSource(b.id))
        #expect(L.temperature(L.find(p, b.id)) == 20)       // keeps the grade
        let r13 = p.prepareSourceGradeEdit(b.id)
        #expect(!r13)  // independent: nothing joins
        L.edit(&p, b.id, temperature: 50)
        #expect(L.temperature(L.find(p, a.id)) == 20)
        // Editing A does not pull B back in.
        let r14 = p.prepareSourceGradeEdit(a.id)
        #expect(!r14)
        L.edit(&p, a.id, temperature: 5)
        #expect(L.temperature(L.find(p, b.id)) == 50)
    }

    @Test func switchingLinkedOnAgainAdoptsTheGroupGrade() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 20), b = Self.clip("B", media: m, start: 4)
        let c = Self.clip("C", media: m, start: 8)
        var p = L.project([a, b, c])
        let r15 = p.linkGrades([a.id, b.id, c.id], source: a.id)
        _ = try #require(r15)
        let r16 = p.setGradeLinkedToSource(c.id, false)
        #expect(r16)
        L.edit(&p, c.id, temperature: 70)
        let r17 = p.setGradeLinkedToSource(c.id, true)
        #expect(r17)
        let r18 = p.setGradeLinkedToSource(c.id, true)
        #expect(!r18)
        #expect(L.temperature(L.find(p, c.id)) == 20)
        #expect(L.find(p, c.id).gradeLink == L.find(p, a.id).gradeLink)
        #expect(!L.find(p, c.id).gradeIndependent)
    }

    @Test func switchingLinkedOnAdoptsALoneGradedSiblingWhoseLinkDissolved() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 20), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let lk = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(lk)
        let off = p.setGradeLinkedToSource(b.id, false)
        #expect(off)
        #expect(L.find(p, a.id).gradeLink == nil)           // a link of one is no link
        L.edit(&p, b.id, temperature: 70)
        let on = p.setGradeLinkedToSource(b.id, true)
        #expect(on)
        #expect(L.temperature(L.find(p, b.id)) == 20)
        #expect(L.find(p, b.id).gradeLink != nil && L.find(p, b.id).gradeLink == L.find(p, a.id).gradeLink)
    }

    @Test func unlinkGradesTurnsLinkedOffSoTheNextEditStaysAlone() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 20), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let lk = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(lk)
        let un = p.unlinkGrades([b.id])
        #expect(un)
        #expect(L.find(p, b.id).gradeIndependent && !p.isGradeLinkedToSource(b.id))
        let prep = p.prepareSourceGradeEdit(b.id)
        #expect(!prep)
        L.edit(&p, b.id, temperature: 60)
        #expect(L.temperature(L.find(p, a.id)) == 20)
    }

    @Test func linkGradesClearsIndependence() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0, temperature: 20), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let r19 = p.setGradeLinkedToSource(b.id, false)
        #expect(r19)
        let r20 = p.linkGrades([a.id, b.id], source: a.id)
        _ = try #require(r20)
        #expect(!L.find(p, b.id).gradeIndependent)
    }

    @Test func independentClipsNeverShareALinkByThemselves() {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        let r21 = p.setGradeLinkedToSource(a.id, false)
        #expect(r21)
        let r22 = p.setGradeLinkedToSource(b.id, false)
        #expect(r22)
        L.edit(&p, a.id, temperature: 9)
        #expect(L.temperature(L.find(p, b.id)) == 0)
        #expect(p.gradeLinkMembers(of: a.id).isEmpty)
    }

    // MARK: File

    @Test func independenceRoundTripsAndNeedsV47() throws {
        let m = UUID()
        let a = Self.clip("A", media: m, start: 0), b = Self.clip("B", media: m, start: 4)
        var p = L.project([a, b])
        #expect(try L.writtenVersion(p) < 47)
        let r23 = p.setGradeLinkedToSource(b.id, false)
        #expect(r23)
        #expect(try L.writtenVersion(p) == 47)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(L.find(back, b.id).gradeIndependent)
        #expect(!L.find(back, a.id).gradeIndependent)
    }

    // MARK: Timeline grade

    @Test func theTimelineGradeIsCreatedOnceOnANewTopTrackOverTheWholeSequence() throws {
        let m = UUID()
        var p = L.project([Self.clip("A", media: m, start: 0), Self.clip("B", media: m, start: 4)])
        let tl = p.timelines[0].id
        #expect(p.timelines[0].sequenceGradeClip == nil)
        let tracksBefore = p.timelines[0].tracks.count
        let id = try p.ensureSequenceGrade(in: tl)
        let t = p.timelines[0]
        let g = try #require(t.sequenceGradeClip)
        #expect(g.id == id && g.isSequenceGrade && g.isAdjustment && g.acceptsColor)
        #expect(g.start == .zero && g.timeline.end == Time(8, 1))
        #expect(t.tracks.count == tracksBefore + 1)
        #expect(t.tracks.last(where: { $0.kind == .video })?.clips.map(\.id) == [id])
        // Reused after.
        let again = try p.ensureSequenceGrade(in: tl)
        #expect(again == id)
        #expect(p.timelines[0].tracks.count == tracksBefore + 1)
        // Not a source clip.
        #expect(!p.isGradeLinkedToSource(id))
    }

    @Test func theTimelineGradeGrowsWithTheSequence() throws {
        let m = UUID()
        var p = L.project([Self.clip("A", media: m, start: 0)])
        let tl = p.timelines[0].id
        let id = try p.ensureSequenceGrade(in: tl)
        try p.edit(tl) { try $0.tracks[0].overwrite(Self.clip("B", media: m, start: 4)) }
        let again = try p.ensureSequenceGrade(in: tl)
        #expect(again == id)
        #expect(p.timelines[0].sequenceGradeClip?.timeline.end == Time(8, 1))
    }

    @Test func theTimelineGradeNeverMovesItsStart() throws {
        let m = UUID()
        var p = L.project([Self.clip("A", media: m, start: 0), Self.clip("B", media: m, start: 4)])
        let tl = p.timelines[0].id
        let id = try p.ensureSequenceGrade(in: tl)
        // Trimmed by hand to start at 2 s: its start (and clip-local keys/ranges) stay.
        try p.edit(tl) { t in
            var g = try #require(t.sequenceGradeClip)
            g.start = Time(2, 1)
            g.source = TimeRange(start: Time(2, 1), duration: Time(6, 1))
            let tr = try #require(t.tracks.firstIndex { $0.clips.contains { $0.id == g.id } })
            t.tracks[tr].replace(g)
        }
        let trimmed = try #require(p.timelines[0].sequenceGradeClip)
        let same = try p.ensureSequenceGrade(in: tl)
        #expect(same == id)
        #expect(p.timelines[0].sequenceGradeClip == trimmed, "nothing changes while coverage is right")
        try p.edit(tl) { try $0.tracks[0].overwrite(Self.clip("C", media: m, start: 8)) }
        try p.ensureSequenceGrade(in: tl)
        let grown = try #require(p.timelines[0].sequenceGradeClip)
        #expect(grown.start == Time(2, 1) && grown.source.start == Time(2, 1))
        #expect(grown.timeline.end == Time(12, 1))
    }

    @Test func theTimelineGradeStaysOnTopWhenTracksAreAdded() throws {
        var p = L.project([Self.clip("A", media: UUID(), start: 0)])
        let tl = p.timelines[0].id
        let id = try p.ensureSequenceGrade(in: tl)
        let added = p.timelines[0].addTrack(kind: .video)
        #expect(p.timelines[0].tracks.last(where: { $0.kind == .video })?.id == added)
        try p.ensureSequenceGrade(in: tl)
        let top = try #require(p.timelines[0].tracks.last(where: { $0.kind == .video }))
        #expect(top.clips.map(\.id) == [id])
        #expect(p.timelines[0].tracks.contains { $0.id == added })
    }

    @Test func anEmptySequenceGetsNoTimelineGrade() {
        var p = L.project([])
        let tl = p.timelines[0].id
        var threw = false
        do { try p.ensureSequenceGrade(in: tl) } catch { threw = true }
        #expect(threw)
    }

    @Test func aPlainAdjustmentLayerIsNoTimelineGrade() throws {
        var p = L.project([Self.clip("A", media: UUID(), start: 0)])
        let tl = p.timelines[0].id, tr = p.timelines[0].tracks[0].id
        _ = try p.addAdjustmentClip(in: tl, at: Time(4, 1), track: tr, duration: Time(2, 1))
        #expect(p.timelines[0].sequenceGradeClip == nil)
    }
}
