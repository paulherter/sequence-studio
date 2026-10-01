import Foundation
import Testing
@testable import SQCore

// Round 2, stream timeline-edit: Q/W variants, insert copy, enable/disable, duplicate, lane moves, snap targets.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video,
                  link: UUID? = nil, media: Int64? = 1000, m: UUID = UUID()) -> Clip {
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

// MARK: Q / W variants

@Suite struct TrimToPlayheadModeTests {
    private func abTimeline() throws -> (Timeline, Clip, Clip) {
        let a = clip(0, 10), b = clip(10, 10, src: 10)
        return (timeline(try track([a, b])), a, b)
    }

    @Test func plainWRipplesLaterClipsBack() throws {
        var (tl, _, _) = try abTimeline()
        try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .ripple)
        #expect(spans(tl.tracks[0]) == [[0, 7], [7, 17]])
    }

    @Test func shiftWRollsTheCut() throws {
        var (tl, a, b) = try abTimeline()
        let moved = try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .roll)
        #expect(spans(tl.tracks[0]) == [[0, 7], [7, 20]])
        #expect(moved == s(-3))
        #expect(tl.duration == s(20))
        // B's head now shows 3 s earlier source.
        let nb = tl.tracks[0].clips.first { $0.id == b.id }!
        #expect(nb.source.start == b.source.start - s(3))
        #expect(tl.tracks[0].clips.first { $0.id == a.id }!.source.duration == s(7))
    }

    @Test func optWLeavesAGap() throws {
        var (tl, _, _) = try abTimeline()
        try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .plain)
        #expect(spans(tl.tracks[0]) == [[0, 7], [10, 20]])
    }

    @Test func shiftQRollsTheCutLater() throws {
        var (tl, _, _) = try abTimeline()
        try tl.trimToPlayhead(.head, at: s(13), tracks: nil, mode: .roll)
        #expect(spans(tl.tracks[0]) == [[0, 13], [13, 20]])
    }

    @Test func optQLeavesAGapBeforeTheClip() throws {
        var (tl, _, _) = try abTimeline()
        try tl.trimToPlayhead(.head, at: s(13), tracks: nil, mode: .plain)
        #expect(spans(tl.tracks[0]) == [[0, 10], [13, 20]])
    }

    @Test func rollWithoutNeighbourIsRefused() throws {
        var tl = timeline(try track([clip(0, 10)]))
        let before = tl
        #expect(throws: EditError.collision) { try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .roll) }
        #expect(tl == before)
    }

    @Test func lockedTrackRefusesEveryMode() throws {
        for mode in [PlayheadTrimMode.ripple, .roll, .plain] {
            var tl = timeline(try track([clip(0, 10), clip(10, 10)], locked: true))
            let id = tl.tracks[0].id
            #expect(throws: EditError.trackLocked) { try tl.trimToPlayhead(.tail, at: s(7), tracks: [id], mode: mode) }
        }
    }

    @Test func rollMovesLinkedPartnerCutToo() throws {
        let l1 = UUID(), l2 = UUID()
        let v1 = clip(0, 10, link: l1), v2 = clip(10, 10, src: 10, link: l2)
        let a1 = clip(0, 10, kind: .audio, link: l1), a2 = clip(10, 10, src: 10, kind: .audio, link: l2)
        var tl = timeline(try track([v1, v2]), try track([a1, a2], kind: .audio))
        try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .roll)
        #expect(spans(tl.tracks[0]) == [[0, 7], [7, 20]])
        #expect(spans(tl.tracks[1]) == [[0, 7], [7, 20]])
    }
}

@Suite struct RollSkipsTests {
    @Test func tracksWithoutANeighbourAreSkippedNotFatal() throws {
        let a = clip(0, 10), b = clip(10, 10, src: 10)
        let lone = clip(0, 20, kind: .video)
        var tl = timeline(try track([a, b]), try track([lone]))
        try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .roll)
        #expect(spans(tl.tracks[0]) == [[0, 7], [7, 20]])
        #expect(spans(tl.tracks[1]) == [[0, 20]])
    }

    @Test func throwsOnlyWhenNothingCouldRoll() throws {
        var tl = timeline(try track([clip(0, 10)]), try track([clip(0, 20)]))
        #expect(throws: EditError.collision) { try tl.trimToPlayhead(.tail, at: s(7), tracks: nil, mode: .roll) }
    }

    @Test func playheadOnTheCutIsNothingToRoll() throws {
        var tl = timeline(try track([clip(0, 10), clip(10, 10, src: 10)]))
        #expect(throws: EditError.collision) { try tl.trimToPlayhead(.tail, at: s(10), tracks: nil, mode: .roll) }
    }
}

// MARK: Cmd-drag insert move versus Cmd+Opt rearrange

@Suite struct InsertMoveGapTests {
    @Test func insertMoveLeavesTheOldGapAndPushesLaterClipsRight() throws {
        let a = clip(0, 4), b = clip(4, 4, src: 4), c = clip(8, 4, src: 8)
        var tl = timeline(try track([a, b, c]))
        try tl.insertMove(a.id, to: s(6))
        // a lifted (gap [0,4) stays), b split at 6, a lands at [6,10), the right half of b and c move right by 4.
        #expect(spans(tl.tracks[0]) == [[4, 6], [6, 10], [10, 12], [12, 16]])
        #expect(tl.tracks[0].clips.contains { $0.id == a.id })
    }

    @Test func rearrangeClosesTheOldGapSoNothingGrows() throws {
        let a = clip(0, 4), b = clip(4, 4, src: 4), c = clip(8, 4, src: 8)
        var tl = timeline(try track([a, b, c]))
        try tl.moveInsert(a.id, to: s(6))
        #expect(tl.duration == s(12))
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 6], [6, 8], [8, 12]])
    }

    @Test func lockedRefuses() throws {
        let a = clip(0, 4)
        var tl = timeline(try track([a], locked: true))
        #expect(throws: EditError.trackLocked) { try tl.insertMove(a.id, to: s(8)) }
    }
}

// MARK: Cmd+Opt drag: insert a copy

@Suite struct InsertCopyTests {
    @Test func copyLandsAtDropLaterClipsRippleOriginalStays() throws {
        let a = clip(0, 4), b = clip(4, 4, src: 4)
        var tl = timeline(try track([a, b]))
        let spec = CopySpec(ids: [a.id: UUID()], link: UUID())
        try tl.insertCopy(a.id, to: s(6), copy: spec)
        // b is split at 6; the copy (4 s) lands at 6; the right half of b moves back by 4.
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 6], [6, 10], [10, 12]])
        #expect(tl.tracks[0].clips.contains { $0.id == a.id })
        #expect(tl.tracks[0].clips.contains { $0.id == spec.ids[a.id]! })
        #expect(tl.duration == s(12))
    }

    @Test func copyAtEndPushesNothing() throws {
        let a = clip(0, 4)
        var tl = timeline(try track([a]))
        try tl.insertCopy(a.id, to: s(4), copy: CopySpec(ids: [a.id: UUID()]))
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 8]])
    }

    @Test func linkedGroupCopiesKeepTheirLink() throws {
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l)
        var tl = timeline(try track([v]), try track([a], kind: .audio))
        let newLink = UUID()
        try tl.insertCopy(v.id, to: s(4), copy: CopySpec(ids: [:], link: newLink))
        let copies = tl.tracks.flatMap(\.clips).filter { $0.link == newLink }
        #expect(copies.count == 2)
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 8]])
        #expect(spans(tl.tracks[1]) == [[0, 4], [4, 8]])
    }

    @Test func lockedDestinationRefuses() throws {
        let a = clip(0, 4)
        var tl = timeline(try track([a]), try track([], locked: true))
        let dest = tl.tracks[1].id
        #expect(throws: EditError.trackLocked) { try tl.insertCopy(a.id, to: s(4), track: dest, copy: CopySpec()) }
    }
}

// MARK: Enable / disable

@Suite struct EnableClipTests {
    @Test func defaultsToEnabledAndDecodesFromOldFiles() throws {
        let c = clip(0, 4)
        #expect(c.isEnabled)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        obj.removeValue(forKey: "isEnabled")
        let back = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.isEnabled)
    }

    @Test func disabledRoundTrips() throws {
        var c = clip(0, 4); c.isEnabled = false
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(!back.isEnabled)
        #expect(back == c)
    }

    @Test func toggleDisablesThenEnablesTheGroupAsOne() throws {
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l)
        var tl = timeline(try track([v]), try track([a], kind: .audio))
        try tl.toggleEnabled([v.id])
        #expect(tl.tracks.flatMap(\.clips).allSatisfy { !$0.isEnabled })
        try tl.toggleEnabled([v.id])
        #expect(tl.tracks.flatMap(\.clips).allSatisfy { $0.isEnabled })
    }

    @Test func mixedSelectionEnablesFirst() throws {
        var x = clip(0, 4), y = clip(4, 4)
        x.isEnabled = false; y.isEnabled = true
        var tl = timeline(try track([x, y]))
        try tl.toggleEnabled([x.id, y.id])
        #expect(tl.tracks[0].clips.allSatisfy { $0.isEnabled })
    }

    @Test func lockedTrackRefuses() throws {
        let c = clip(0, 4)
        var tl = timeline(try track([c], locked: true))
        #expect(throws: EditError.trackLocked) { try tl.toggleEnabled([c.id]) }
    }

    @Test func disabledVideoClipIsSkippedByRenderResolution() throws {
        var low = clip(0, 10), top = clip(0, 10)
        low.name = "low"; top.name = "top"
        let tl = timeline(try track([low]), try track([top]))
        #expect(tl.videoLayers(at: s(1)).count == 2)
        var off = top; off.isEnabled = false
        var t2 = tl
        try t2.replaceClip(off)
        let layers = t2.videoLayers(at: s(1))
        #expect(layers.map(\.clip) == [low.id])
    }

    @Test func disabledAudioClipIsSkippedByTheMix() throws {
        var c = clip(0, 10, kind: .audio)
        var tl = timeline(try track([c], kind: .audio))
        #expect(tl.audioSegments(in: TimeRange(start: s(0), duration: s(10))).count == 1)
        c.isEnabled = false
        try tl.replaceClip(c)
        #expect(tl.audioSegments(in: TimeRange(start: s(0), duration: s(10))).isEmpty)
    }

    @Test func editsStillWorkOnDisabledClips() throws {
        var c = clip(0, 10); c.isEnabled = false
        var tl = timeline(try track([c]))
        try tl.trim(c.id, edge: .tail, by: s(-2))
        #expect(!tl.tracks[0].clips[0].isEnabled)
        #expect(spans(tl.tracks[0]) == [[0, 8]])
    }
}

@Suite struct ProjectFileV18Tests {
    @Test func migrationIsAnIdentity() throws {
        let obj: ProjectFile.JSONObject = ["formatVersion": 17, "project": ["name": "x"]]
        let out = try ProjectFile.migrateV17toV18(obj)
        #expect((out["project"] as? [String: Any])?["name"] as? String == "x")
        #expect(ProjectFile.migrations[17] != nil)
    }

    @Test func projectWithDisabledClipRoundTripsThroughTheFile() throws {
        var c = clip(0, 4); c.isEnabled = false
        let tl = timeline(try track([c]))
        let p = Project(name: "p", timelines: [tl])
        let data = try ProjectFile.encode(p)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].isEnabled == false)
    }
}

// MARK: Duplicate

@Suite struct DuplicateTests {
    @Test func copiesLandAfterSelectionEndOnSameTracksAndBecomeSelection() throws {
        let a = clip(0, 4), b = clip(4, 2, src: 4)
        var tl = timeline(try track([a, b]))
        let made = try tl.duplicate([a.id, b.id])
        #expect(made.count == 2)
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 6], [6, 10], [10, 12]])
        #expect(Set(made).isDisjoint(with: [a.id, b.id]))
    }

    @Test func linkedCopiesStayLinkedToEachOtherOnly() throws {
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l)
        var tl = timeline(try track([v]), try track([a], kind: .audio))
        let made = try tl.duplicate([v.id, a.id])
        let copies = tl.tracks.flatMap(\.clips).filter { made.contains($0.id) }
        #expect(copies.count == 2)
        let link = copies[0].link
        #expect(link != nil && link != l && copies[1].link == link)
        #expect(tl.tracks[0].clips.map(\.link).filter { $0 == l }.count == 1)
    }

    @Test func overwritesWhatIsInTheWay() throws {
        let a = clip(0, 4), later = clip(5, 10, src: 50)
        var tl = timeline(try track([a, later]))
        _ = try tl.duplicate([a.id])
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 8], [8, 15]])
    }

    @Test func emptySelectionAndLockedTrackThrow() throws {
        var tl = timeline(try track([clip(0, 4)]))
        #expect(throws: EditError.clipNotFound) { try tl.duplicate([UUID()]) }
        let c = clip(0, 4)
        var locked = timeline(try track([c], locked: true))
        #expect(throws: EditError.trackLocked) { try locked.duplicate([c.id]) }
    }
}

// MARK: Opt+Up / Opt+Down

@Suite struct MoveLaneTests {
    private func twoVideo() throws -> (Timeline, Clip) {
        let c = clip(0, 4)
        return (timeline(try track([c]), try track([])), c)          // V1 with clip, V2 empty
    }

    @Test func videoMovesUpOneLane() throws {
        var (tl, c) = try twoVideo()
        let moved = try tl.moveToLane([c.id], up: true); #expect(moved)
        #expect(tl.tracks[0].clips.isEmpty)
        #expect(tl.tracks[1].clips.map(\.id) == [c.id])
    }

    @Test func outermostLaneBlocks() throws {
        var (tl, c) = try twoVideo()
        let moved = try tl.moveToLane([c.id], up: true); #expect(moved)
        let before = tl
        let blocked = try tl.moveToLane([c.id], up: true); #expect(!blocked)          // V2 is the top
        #expect(tl == before)
        let back = try tl.moveToLane([c.id], up: false); #expect(back)
        let blockedDown = try tl.moveToLane([c.id], up: false); #expect(!blockedDown)         // V1 is the bottom
    }

    @Test func audioUpMeansTowardTheVideoSide() throws {
        let c = clip(0, 4, kind: .audio)
        var tl = timeline(try track([], kind: .audio), try track([c], kind: .audio))   // A1 empty, A2 has it
        let moved = try tl.moveToLane([c.id], up: true); #expect(moved)
        #expect(tl.tracks[0].clips.map(\.id) == [c.id])
    }

    @Test func linkedVideoAndAudioMoveMirrored() throws {
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l)
        var tl = timeline(try track([v]), try track([]), try track([a], kind: .audio), try track([], kind: .audio))
        let moved = try tl.moveToLane([v.id, a.id], up: true); #expect(moved)
        #expect(tl.tracks[1].clips.map(\.id) == [v.id])                // V2
        #expect(tl.tracks[3].clips.map(\.id) == [a.id])                // A2: stays pair-aligned
    }

    @Test func lockedSourceOrDestinationRefuses() throws {
        let c = clip(0, 4)
        var a = timeline(try track([c]), try track([], locked: true))
        #expect(throws: EditError.trackLocked) { try a.moveToLane([c.id], up: true) }
        var b = timeline(try track([c], locked: true), try track([]))
        #expect(throws: EditError.trackLocked) { try b.moveToLane([c.id], up: true) }
    }

    @Test func coveredDestinationClipsAreOverwritten() throws {
        let c = clip(0, 4)
        var tl = timeline(try track([c]), try track([clip(2, 6, src: 20)]))
        let moved = try tl.moveToLane([c.id], up: true); #expect(moved)
        #expect(spans(tl.tracks[1]) == [[0, 4], [4, 8]])
    }
}

// MARK: Snap targets

@Suite struct SnapTargetTests {
    @Test func inAndOutMarksAreSnapPoints() throws {
        var tl = timeline(try track([clip(0, 20)]))
        tl.inOut = TimeRange(start: s(5), end: s(12))
        let pts = tl.snapPoints()
        #expect(pts.contains(SnapPoint(time: s(5), kind: .inOut)))
        #expect(pts.contains(SnapPoint(time: s(12), kind: .inOut)))
        let r = snap(s(5) + Time(1, 60), to: pts, threshold: Time(1, 30), frameDuration: nil)
        #expect(r.hit?.kind == .inOut && r.time == s(5))
    }

    @Test func noMarksNoPoints() throws {
        let tl = timeline(try track([clip(0, 20)]))
        #expect(tl.snapPoints().allSatisfy { $0.kind != .inOut })
    }

    @Test func keyframeTimesOnlyWhenAsked() throws {
        var c = clip(10, 10)
        c.animation.opacity.track.keys = [Keyframe(time: s(2), value: 0.5), Keyframe(time: s(4), value: 1)]
        let tl = timeline(try track([c]))
        #expect(tl.snapPoints().allSatisfy { $0.kind != .keyframe })
        let pts = tl.snapPoints(includeKeyframes: true)
        #expect(pts.contains(SnapPoint(time: s(12), kind: .keyframe)))
        #expect(pts.contains(SnapPoint(time: s(14), kind: .keyframe)))
        // The dragged clip's own keys never attract it.
        #expect(tl.snapPoints(excluding: [c.id], includeKeyframes: true).allSatisfy { $0.kind != .keyframe })
    }

    @Test func clipEdgeWinsOverKeyframeOnTheSameTime() throws {
        var c = clip(10, 10)
        c.animation.opacity.track.keys = [Keyframe(time: s(0), value: 0.5)]
        let tl = timeline(try track([c]))
        let at10 = tl.snapPoints(includeKeyframes: true).filter { $0.time == s(10) }
        #expect(at10.count == 1)
    }
}

// MARK: Markers

@Suite struct MarkerDragTests {
    @Test func clampsAtZero() throws {
        var tl = timeline(try track([clip(0, 4)]))
        let id = tl.addMarker(at: s(2))
        tl.moveMarker(id, to: s(-5))
        #expect(tl.markers[0].time == .zero)
    }
}

// MARK: Target toggle modifiers

@Suite struct TargetToggleTests {
    private func tl() -> (Timeline, [Track.ID]) {
        let t = timeline(Track(kind: .video, isTargeted: true), Track(kind: .video), Track(kind: .video, isTargeted: true),
                         Track(kind: .audio, isTargeted: true), Track(kind: .audio))
        return (t, t.tracks.map(\.id))
    }

    @Test func plainClickFlipsOnlyThatTrack() {
        var (t, ids) = tl()
        t.toggleTarget(ids[1])
        #expect(t.tracks.map(\.isTargeted) == [true, true, true, true, false])
        t.toggleTarget(ids[1])
        #expect(t.tracks[1].isTargeted == false)
    }

    @Test func shiftClickSetsEveryTrackOfTheKind() {
        var (t, ids) = tl()
        t.toggleTarget(ids[1], shift: true)                       // off -> all video on
        #expect(t.tracks.map(\.isTargeted) == [true, true, true, true, false])
        t.toggleTarget(ids[1], shift: true)                       // on -> all video off
        #expect(t.tracks.map(\.isTargeted) == [false, false, false, true, false])
    }

    @Test func optionClickTargetsOnlyThatTrackOfItsKind() {
        var (t, ids) = tl()
        t.toggleTarget(ids[1], option: true)
        #expect(t.tracks.map(\.isTargeted) == [false, true, false, true, false])
        t.toggleTarget(ids[1], option: true)
        #expect(t.tracks.map(\.isTargeted) == [false, true, false, true, false])   // already solo: unchanged
    }
}
