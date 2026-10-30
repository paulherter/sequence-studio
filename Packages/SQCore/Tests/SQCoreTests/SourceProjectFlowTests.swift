import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

private func media(_ name: String = "a") -> MediaRef {
    MediaRef(name: name, path: "/x/\(name)", fingerprint: MediaFingerprint(size: 1), duration: s(10))
}

private func clip(media id: UUID, at start: Time = .zero) -> Clip {
    Clip(name: "c", media: id, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: start)
}

@Suite struct SequenceMarkConventionTests {
    private func timeline(duration: Int64 = 10) -> Timeline {
        var v = Track(kind: .video)
        try? v.overwrite(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(duration)), start: .zero))
        return Timeline(name: "T", format: SequenceFormat(frameDuration: fd), tracks: [v])
    }

    @Test func exportRangeFollowsCurrentLengthForInOnly() {
        var t = timeline(duration: 10)
        #expect(t.exportRange == nil)
        t.markIn(at: s(2))                                            // stores end = 10 s at mark time
        try? t.tracks[0].overwrite(Clip(name: "d", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: s(10)))
        #expect(t.duration == s(15))
        #expect(t.exportRange == TimeRange(start: s(2), end: s(15)))   // grown sequence: In to the new end
        t.markOut(at: s(6))
        #expect(t.exportRange == TimeRange(start: s(2), end: s(6) + fd))
        // Older file without inOutKind whose stored end reaches the sequence end reads as In only (a later grown
        // sequence cannot be told apart from an explicit Out there: it keeps its stored end).
        var old = timeline(duration: 10)
        old.inOut = TimeRange(start: s(3), end: s(10)); old.inOutKind = nil
        #expect(old.exportRange == TimeRange(start: s(3), end: s(10)))
        // Out only starts at 0.
        var o = timeline(duration: 10)
        o.markOut(at: s(4))
        #expect(o.exportRange == TimeRange(start: .zero, end: s(4) + fd))
    }

    @Test func outIncludesItsOwnFrame() {
        var t = timeline()
        t.markIn(at: fd * 10)
        t.markOut(at: fd * 20)
        // In = frame 10, Out = frame 20: 11 frames (Adobe: In and Out both belong to the range).
        #expect(t.inOut == TimeRange(start: fd * 10, end: fd * 21))
        #expect(t.inOut!.duration == fd * 11)
        #expect(t.explicitMarks.markIn == fd * 10)
    }

    @Test func outAtFrameZeroIsAOneFrameRange() {
        var t = timeline()
        t.markOut(at: .zero)
        #expect(t.inOut == TimeRange(start: .zero, end: fd))
    }

    @Test func sameFrameForInAndOutIsOneFrame() {
        var t = timeline()
        t.markIn(at: fd * 5)
        t.markOut(at: fd * 5)
        #expect(t.inOut!.duration == fd)
    }

    @Test func inAfterOutMovesOutToTheEnd() {
        var t = timeline()
        t.markIn(at: fd * 10)
        t.markOut(at: fd * 20)
        t.markIn(at: fd * 40)
        #expect(t.inOut == TimeRange(start: fd * 40, end: s(10)))
    }

    @Test func outBeforeInDropsIn() {
        var t = timeline()
        t.markIn(at: fd * 100)
        t.markOut(at: fd * 20)
        #expect(t.inOut == TimeRange(start: .zero, end: fd * 21))
        #expect(t.explicitMarks.markIn == nil)
        #expect(t.explicitMarks.markOut == fd * 21)
    }

    @Test func outOnlyIsRememberedUntilAnInIsSet() {
        var t = timeline()
        t.markOut(at: fd * 59)
        #expect(t.explicitMarks.markIn == nil && t.explicitMarks.markOut == fd * 60)
        t.markIn(at: fd * 30)
        #expect(t.explicitMarks.markIn == fd * 30 && t.explicitMarks.markOut == fd * 60)
        #expect(t.inOut == TimeRange(start: fd * 30, end: fd * 60))        // the Out stays
    }

    @Test func placementWithOnlyOutIsBackTimed() {
        let d = s(4)
        #expect(Timeline.sourceEditPlacement(sourceDuration: d, markIn: nil, markOut: s(10), playhead: s(1)) == s(6))
        #expect(Timeline.sourceEditPlacement(sourceDuration: d, markIn: nil, markOut: s(3), playhead: s(1)) == .zero)   // never before 0
        #expect(Timeline.sourceEditPlacement(sourceDuration: d, markIn: s(2), markOut: s(10), playhead: s(1)) == s(2))
        #expect(Timeline.sourceEditPlacement(sourceDuration: d, markIn: nil, markOut: nil, playhead: s(7)) == s(7))
    }

    @Test func timelinePlacementUsesTheMarks() {
        var t = timeline()
        #expect(t.sourceEditPlacement(sourceDuration: s(4), playhead: s(1)) == s(1))
        t.markOut(at: s(10) - fd)                                            // Out frame = last frame before 10 s
        #expect(t.sourceEditPlacement(sourceDuration: s(4), playhead: s(1)) == s(6))
        t.markIn(at: s(2))
        #expect(t.sourceEditPlacement(sourceDuration: s(4), playhead: s(1)) == s(2))
    }

    @Test func markClipAfterAnOutOnlyMarkMakesBothExplicit() {
        var t = timeline()
        t.markOut(at: fd * 59)
        t.setMarkedRange(TimeRange(start: .zero, end: fd * 60))              // same numbers as the out-only range
        #expect(t.explicitMarks.markIn == .zero && t.explicitMarks.markOut == fd * 60)
        #expect(t.inOutKind == .both)
    }

    @Test func clearInAndOutKeepTheOtherMark() {
        var t = timeline()
        t.markIn(at: s(2)); t.markOut(at: s(5))
        t.clearIn()
        #expect(t.explicitMarks.markIn == nil && t.explicitMarks.markOut == s(5) + fd)
        t.clearIn()                                                         // nothing left to clear
        #expect(t.explicitMarks.markOut == s(5) + fd)
        t.markIn(at: s(1))
        t.clearOut()
        #expect(t.explicitMarks.markIn == s(1) && t.explicitMarks.markOut == nil)
        t.clearOut()
        #expect(t.explicitMarks.markIn == s(1))
        t.markOut(at: s(3)); t.clearIn(); t.clearOut()
        #expect(t.inOut == nil && t.inOutKind == nil)
    }

    /// Dragging the In/Out band: only a mark that was really set stays a mark.
    @Test func draggingAnInOnlyOrOutOnlyMarkKeepsItsKind() {
        var t = Timeline(name: "S", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(media: UUID(), at: s(8))])])
        let end = t.duration            // 10 s
        t.markIn(at: s(2))
        #expect(t.inOutKind == .inOnly)
        t.dragMarkedRange(to: TimeRange(start: s(3), end: end))                  // In edge dragged
        #expect(t.inOutKind == .inOnly && t.explicitMarks.markIn == s(3) && t.explicitMarks.markOut == nil && t.inOut?.end == end)
        t.dragMarkedRange(to: TimeRange(start: s(4), end: end + s(1)))           // body dragged: still only an In
        #expect(t.inOutKind == .inOnly && t.inOut?.start == s(4) && t.explicitMarks.markOut == nil)
        let inOnlyEnd = t.inOut!.end
        t.dragMarkedRange(to: TimeRange(start: s(4), end: inOnlyEnd + s(2)))     // Out edge dragged: now a real Out
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(4), end: inOnlyEnd + s(2)))

        t.setMarkedRange(nil)
        t.markOut(at: s(5))
        #expect(t.inOutKind == .outOnly)
        let stored = t.inOut!.end
        t.dragMarkedRange(to: TimeRange(start: .zero, end: stored + s(1)))       // Out edge dragged
        #expect(t.inOutKind == .outOnly && t.explicitMarks.markIn == nil && t.inOut == TimeRange(start: .zero, end: stored + s(1)))
        t.dragMarkedRange(to: TimeRange(start: s(1), end: stored + s(1)))        // In edge dragged: now a real In
        #expect(t.inOutKind == .both && t.inOut?.start == s(1))

        t.dragMarkedRange(to: TimeRange(start: s(2), end: s(3)))                 // both stay both
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(2), end: s(3)))
    }

    /// A freshly dragged range sets both marks whatever was marked before; edge and body drags keep an In-only or
    /// Out-only mark, told by the dragged part and not by comparing ranges.
    @Test func aNewlyDraggedRangeSetsBothMarksAndPartsKeepTheKind() {
        var t = Timeline(name: "S", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(media: UUID(), at: s(8))])])
        let end = t.duration            // 10 s
        t.markIn(at: s(2))
        t.dragMarkedRange(to: TimeRange(start: s(4), end: s(6)), part: .newRange)
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(4), end: s(6)))
        t.setMarkedRange(nil)
        t.markIn(at: s(2))
        t.dragMarkedRange(to: TimeRange(start: s(2), end: s(6)), part: .newRange)   // starts on the old In: still both
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(2), end: s(6)))

        t.setMarkedRange(nil)
        t.markOut(at: s(5))
        let stored = t.inOut!.end
        t.dragMarkedRange(to: TimeRange(start: s(1), end: s(3)), part: .newRange)
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(1), end: s(3)))
        t.setMarkedRange(nil)
        t.markOut(at: s(5))
        t.dragMarkedRange(to: TimeRange(start: s(1), end: stored), part: .newRange) // ends on the old Out: still both
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(1), end: stored))

        t.setMarkedRange(nil)
        t.markIn(at: s(2))
        t.dragMarkedRange(to: TimeRange(start: s(3), end: end + s(1)), part: .body)
        #expect(t.inOutKind == .inOnly && t.inOut?.start == s(3) && t.explicitMarks.markOut == nil)
        t.dragMarkedRange(to: TimeRange(start: s(4), end: end), part: .inEdge)
        #expect(t.inOutKind == .inOnly && t.inOut?.start == s(4) && t.explicitMarks.markOut == nil)
        t.dragMarkedRange(to: TimeRange(start: s(4), end: s(7)), part: .outEdge)
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(4), end: s(7)))

        t.setMarkedRange(nil)
        t.markOut(at: s(5))
        t.dragMarkedRange(to: TimeRange(start: s(1), end: s(7)), part: .body)
        #expect(t.inOutKind == .outOnly && t.inOut == TimeRange(start: .zero, end: s(7)))
        t.dragMarkedRange(to: TimeRange(start: .zero, end: s(6)), part: .outEdge)
        #expect(t.inOutKind == .outOnly && t.inOut == TimeRange(start: .zero, end: s(6)))
        t.dragMarkedRange(to: TimeRange(start: s(1), end: s(6)), part: .inEdge)
        #expect(t.inOutKind == .both && t.inOut == TimeRange(start: s(1), end: s(6)))
    }

    @Test func rippleBeforeAnOutOnlyMarkKeepsItOutOnly() throws {
        var t = timeline(duration: 10)
        t.markOut(at: s(8) - fd)                                            // Out frame just before 8 s, no In
        try t.addEdit(at: s(2), tracks: nil)
        let second = t.tracks[0].clips[1].id
        _ = try t.rippleDelete([t.tracks[0].clips[0].id])                   // removes 0..2 s, everything shifts left
        #expect(second == t.tracks[0].clips[0].id)
        #expect(t.explicitMarks.markIn == nil)
        #expect(t.explicitMarks.markOut == s(6))                            // 8 s - 2 s
        #expect(t.inOut?.start == .zero)
    }

    @Test func outOnlySurvivesSaveAndReload() throws {
        var t = timeline()
        t.markOut(at: s(5))
        var p = Project(name: "P", timelines: [t])
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].explicitMarks.markIn == nil)
        #expect(back.timelines[0].explicitMarks.markOut == s(5) + fd)
        p.timelines[0].markIn(at: s(1))
        let back2 = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back2.timelines[0].inOutKind == .both)
    }
}

@Suite struct SourceEditPlanTests {
    private func plan(_ m: SourceMarks, total: Int64 = 10, si: Time? = nil, so: Time? = nil, ph: Time = s(1)) -> SourceEditPlan? {
        Timeline.sourceEditPlan(sourceMarks: m, total: s(total), sequenceIn: si, sequenceOut: so, playhead: ph, frameDuration: fd)
    }

    @Test func outOnlyBackTimesAndCutsTheSourceHeadWhenThereIsNoRoom() {
        let m = SourceMarks(markIn: s(2), markOut: s(8))                     // 6 s of source
        let roomy = plan(m, so: s(20))!
        #expect(roomy.at == s(14) && roomy.source == TimeRange(start: s(2), end: s(8)))
        let tight = plan(m, so: s(4))!                                       // only 4 s before the Out
        #expect(tight.at == .zero)
        #expect(tight.source == TimeRange(start: s(4), end: s(8)))           // head cut, tail kept: ends exactly at the Out
        #expect(tight.source.duration == s(4))
    }

    @Test func sequenceInAndOutSetTheLengthAndSourceInChoosesThePart() {
        let m = SourceMarks(markIn: s(3), markOut: nil)
        let p = plan(m, si: s(10), so: s(14))!
        #expect(p.at == s(10) && p.source == TimeRange(start: s(3), end: s(7)) && !p.usedFourPointDefault)
        let none = plan(SourceMarks(), si: s(10), so: s(14))!
        #expect(none.source == TimeRange(start: .zero, end: s(4)))
        let outOnly = plan(SourceMarks(markIn: nil, markOut: s(9)), si: s(10), so: s(14))!
        #expect(outOnly.source == TimeRange(start: s(5), end: s(9)))        // source Out only: ends at that Out
    }

    @Test func fourPointUsesSequenceRangeAndSourceInAndSaysSo() {
        let p = plan(SourceMarks(markIn: s(2), markOut: s(9)), si: s(10), so: s(13))!
        #expect(p.usedFourPointDefault && p.source == TimeRange(start: s(2), end: s(5)) && p.at == s(10))
    }

    @Test func shortSourceShortensTheClipAndPlainCasesStayAsBefore() {
        let short = plan(SourceMarks(markIn: s(8)), si: s(0), so: s(5))!
        #expect(short.source.duration <= s(2))
        let inOnly = plan(SourceMarks(markIn: s(2), markOut: s(5)), si: s(7))!
        #expect(inOnly.at == s(7) && inOnly.source.duration == s(3))
        let none = plan(SourceMarks(markIn: s(2), markOut: s(5)), ph: s(4))!
        #expect(none.at == s(4))
        #expect(plan(SourceMarks(markIn: s(5), markOut: s(5))) == nil)
    }
}

@Suite struct SourceMarkClipTests {
    @Test func markClipSetsWholeClip() {
        var p = Project(name: "P")
        let m = media()
        p.add(m)
        let ok = p.markSourceClip(m.id, duration: s(10))
        #expect(ok)
        #expect(p.sourceMarks(for: m.id) == SourceMarks(markIn: .zero, markOut: s(10)))
        #expect(p.timelines.isEmpty)                                         // the sequence is untouched
        #expect(SourceMarks.wholeClip(duration: .zero) == nil)
    }

    @Test func markClipReplacesEarlierMarks() {
        var p = Project(name: "P")
        let m = media()
        p.add(m)
        p.setSourceIn(s(2), for: m.id)
        p.setSourceOut(s(3), for: m.id)
        p.markSourceClip(m.id, duration: s(10))
        #expect(p.sourceMarks(for: m.id).range == TimeRange(start: .zero, end: s(10)))
    }
}

@Suite struct SourceHistoryTests {
    @Test func keepsUniqueMostRecentFirst() {
        var h = SourceHistory()
        let a = UUID(), b = UUID(), c = UUID()
        h.open(a); h.open(b); h.open(c); h.open(a)
        #expect(h.ids == [a, c, b])
    }

    @Test func limitsToTwentyAndDropsTheOldest() {
        var h = SourceHistory()
        let ids = (0..<25).map { _ in UUID() }
        for id in ids { h.open(id) }
        #expect(h.ids.count == 20)
        #expect(h.ids.first == ids.last)
        #expect(!h.ids.contains(ids[0]))
    }

    @Test func multiSelectionLoadsFirstAndKeepsOrder() {
        var h = SourceHistory()
        let a = UUID(), b = UUID(), c = UUID()
        h.open(all: [a, b, c])
        #expect(h.ids == [a, b, c])
    }

    @Test func pruneAndClose() {
        var h = SourceHistory()
        let a = UUID(), b = UUID(), c = UUID()
        h.open(all: [a, b, c])
        h.prune(keeping: [a, c])
        #expect(h.ids == [a, c])
        h.close(a)
        #expect(h.ids == [c])
        h.closeAll()
        #expect(h.ids.isEmpty)
    }
}

@Suite struct SourceMarkerTests {
    @Test func addsSnappedSortedAndFindsExisting() {
        var p = Project(name: "P")
        let m = media()
        p.add(m)
        let late = p.addSourceMarker(at: s(5), frameDuration: fd, to: m.id)!
        let early = p.addSourceMarker(at: s(1) + Time(1, 90), frameDuration: fd, to: m.id)!    // snaps to 1 s
        #expect(late.isNew && early.isNew)
        #expect(p.sourceMarkers(for: m.id).map(\.time) == [s(1), s(5)])
        let again = p.addSourceMarker(at: s(5), frameDuration: fd, to: m.id)!
        #expect(!again.isNew && again.id == late.id)
        #expect(p.sourceMarkers(for: m.id).count == 2)
        let none = p.addSourceMarker(at: s(1), frameDuration: fd, to: UUID())
        #expect(none == nil)
    }

    @Test func updateAndRemove() {
        var p = Project(name: "P")
        let m = media()
        p.add(m)
        let id = p.addSourceMarker(at: s(2), frameDuration: fd, to: m.id)!.id
        let ok = p.updateSourceMarker(id, in: m.id) { $0.name = "Hook"; $0.color = .red }
        #expect(ok)
        #expect(p.sourceMarkers(for: m.id).first?.name == "Hook")
        let removed = p.removeSourceMarker(id, from: m.id)
        #expect(removed)
        #expect(p.media(m.id)?.sourceMarkers == nil)
    }

    @Test func roundTripsThroughTheProjectFile() throws {
        var p = Project(name: "P")
        let m = media()
        p.add(m)
        let id = p.addSourceMarker(at: s(3), frameDuration: fd, to: m.id)!.id
        p.updateSourceMarker(id, in: m.id) { $0.name = "Cut here"; $0.comment = "tighten" }
        p.setPosterTime(s(4), for: m.id)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.sourceMarkers(for: m.id).first?.name == "Cut here")
        #expect(back.sourceMarkers(for: m.id).first?.time == s(3))
        #expect(back.media(m.id)?.posterTime == s(4))
    }

    @Test func oldFilesDecodeWithoutMarkersOrPoster() throws {
        let p = Project(name: "P", media: [media()])
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.media.first?.sourceMarkers == nil && back.media.first?.posterTime == nil)
    }

    @Test func posterClearsWithNil() {
        var p = Project(name: "P")
        let m = media()
        p.add(m)
        p.setPosterTime(s(2), for: m.id)
        #expect(p.media(m.id)?.posterTime == s(2))
        p.setPosterTime(nil, for: m.id)
        #expect(p.media(m.id)?.posterTime == nil)
        let unknown = p.setPosterTime(s(1), for: UUID())
        #expect(!unknown)
    }
}

@Suite struct DeleteSequenceTests {
    @Test func refusesTheLastSequence() {
        var p = Project(name: "P", timelines: [Timeline(name: "A", frameDuration: fd)])
        let only = p.timelines[0].id
        let r = p.deleteSequence(only)
        #expect(!r)
        #expect(p.timelines.count == 1)
    }

    @Test func fixesActiveTimelineAndBins() {
        let a = Timeline(name: "A", frameDuration: fd), b = Timeline(name: "B", frameDuration: fd), c = Timeline(name: "C", frameDuration: fd)
        var p = Project(name: "P", timelines: [a, b, c], activeTimeline: b.id)
        let del = p.deleteSequence(b.id)
        #expect(del)
        #expect(p.timelines.map(\.name) == ["A", "C"])
        #expect(p.activeTimeline == c.id)
        #expect(p.rootBin.parent(of: .sequence(b.id)) == nil)
        let r2 = p.deleteSequence(c.id)
        #expect(r2)
        #expect(p.activeTimeline == a.id)
    }

    @Test func keepsActiveWhenAnotherIsDeleted() {
        let a = Timeline(name: "A", frameDuration: fd), b = Timeline(name: "B", frameDuration: fd)
        var p = Project(name: "P", timelines: [a, b], activeTimeline: a.id)
        let del = p.deleteSequence(b.id)
        #expect(del)
        #expect(p.activeTimeline == a.id)
    }

    @Test func refusesASequenceThatIsNested() {
        let inner = Timeline(name: "Inner", frameDuration: fd)
        var outerTrack = Track(kind: .video)
        try? outerTrack.overwrite(Clip(name: "Inner", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero, sequence: inner.id))
        let outer = Timeline(name: "Outer", format: SequenceFormat(frameDuration: fd), tracks: [outerTrack])
        var p = Project(name: "P", timelines: [outer, inner])
        #expect(p.sequenceNames(nesting: inner.id) == ["Outer"])
        let r3 = p.deleteSequence(inner.id)
        #expect(!r3)
        let r4 = p.deleteSequence(outer.id)
        #expect(r4)
    }

    @Test func namesTheSequencesUsingAClip() {
        let m = media()
        var t1 = Track(kind: .video); try? t1.overwrite(clip(media: m.id))
        let a = Timeline(name: "Main", format: SequenceFormat(frameDuration: fd), tracks: [t1])
        let b = Timeline(name: "Other", frameDuration: fd)
        var p = Project(name: "P", media: [m], timelines: [a, b])
        #expect(p.sequenceNames(using: m.id) == ["Main"])
        let cid = p.timelines[0].tracks[0].clips[0].id
        p.timelines[0].tracks[0].remove(cid)
        #expect(p.sequenceNames(using: m.id).isEmpty)
    }
}

@Suite struct PlaybackRollTests {
    @Test func inToOutExtendsByPrerollAndPostroll() {
        let r = PlaybackBounds.extended(TimeRange(start: s(10), end: s(20)), preroll: PlaybackBounds.defaultPreroll,
                                        postroll: PlaybackBounds.defaultPostroll, duration: s(60))
        #expect(r == TimeRange(start: s(7), end: s(22)))
    }

    @Test func extensionIsClamped() {
        let r = PlaybackBounds.extended(TimeRange(start: s(1), end: s(59)), preroll: s(3), postroll: s(2), duration: s(60))
        #expect(r == TimeRange(start: .zero, end: s(60)))
    }

    @Test func playAroundSurroundsThePlayhead() {
        #expect(PlaybackBounds.playAround(at: s(10), preroll: s(3), postroll: s(2), duration: s(60)) == TimeRange(start: s(7), end: s(12)))
        #expect(PlaybackBounds.playAround(at: s(1), preroll: s(3), postroll: s(2), duration: s(60)) == TimeRange(start: .zero, end: s(3)))
        #expect(PlaybackBounds.playAround(at: s(59), preroll: s(3), postroll: s(2), duration: s(60)) == TimeRange(start: s(56), end: s(60)))
        #expect(PlaybackBounds.playAround(at: s(5), preroll: .zero, postroll: .zero, duration: s(60)) == nil)
    }

    @Test func returnsToTheStartWhenTheRangeEnds() {
        let b = PlaybackBounds(range: TimeRange(start: s(7), end: s(12)), returnTo: s(10))
        #expect(b.action(at: s(12) - fd, rate: .forward, frameDuration: fd, duration: s(60)) == .stopAndReturn(to: s(10)))
        #expect(b.action(at: s(9), rate: .forward, frameDuration: fd, duration: s(60)) == .none)
        let loop = PlaybackBounds(loop: true, range: TimeRange(start: s(7), end: s(12)), returnTo: s(10))
        #expect(loop.action(at: s(12) - fd, rate: .forward, frameDuration: fd, duration: s(60)) == .wrap(to: s(7)))
    }
}

@Suite struct ProjectFileV19Tests {
    @Test func versionIs19AndMigrationIsIdentity() throws {
        #expect(ProjectFile.currentVersion >= 19)
        let obj: ProjectFile.JSONObject = ["formatVersion": 18, "project": ["name": "x"] as ProjectFile.JSONObject]
        let out = try ProjectFile.migrateV18toV19(obj)
        #expect((out["project"] as? ProjectFile.JSONObject)?["name"] as? String == "x")
        #expect(ProjectFile.migrations[18] != nil)
    }

    @Test func aV18FileLoadsWithoutSourceMarkersOrPoster() throws {
        let pid = UUID(), mid = UUID()
        let json = """
        {"formatVersion":18,"project":{"id":"\(pid)","name":"Old","media":[{"id":"\(mid)","name":"a","path":"/x/a","fingerprint":{"size":1}}],"timelines":[]}}
        """
        let p = try ProjectFile.decode(Data(json.utf8), migrations: ProjectFile.migrations)
        #expect(p.media.first?.posterTime == nil && p.media.first?.sourceMarkers == nil)
    }
}
