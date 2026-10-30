import Foundation
import Testing
@testable import SQCore

// W6.1: one track-targeting rule for Cmd+K, Up/Down and X (selection > targeted > all), and ripple clamps that
// report themselves as `.clamped(reason)`.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil, media: Int64? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)),
         start: s(start), link: link, mediaDuration: media.map(s))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, targeted: Bool = false, locked: Bool = false) throws -> Track {
    var t = Track(kind: kind, isLocked: locked, isTargeted: targeted)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func ends(_ t: Track) -> [Time] { t.clips.map(\.timeline.end) }

/// V1 [0,4) [4,8), V2 [1,3) [3,6) (targeted when `target`), V3 [2,7).
private struct Rig {
    var tl: Timeline
    let v1a: Clip, v2b: Clip, v3: Clip
    init(target: Bool = false) throws {
        let v1a = clip(0, 4), v1b = clip(4, 4), v2a = clip(1, 2), v2b = clip(3, 3), v3 = clip(2, 5)
        tl = timeline(try track([v1a, v1b]), try track([v2a, v2b], targeted: target), try track([v3]))
        self.v1a = v1a; self.v2b = v2b; self.v3 = v3
    }
    var ids: [Track.ID] { tl.tracks.map(\.id) }
}

@Suite struct EditTargetRuleTests {
    // MARK: The rule

    @Test func selectionWinsOverTargeting() throws {
        let rig = try Rig(target: true)
        let t = rig.tl.editTargets(selection: [rig.v3.id])
        #expect(t.source == .selection && t.tracks == [rig.ids[2]])
    }

    @Test func targetedWhenNothingSelected() throws {
        let rig = try Rig(target: true)
        let t = rig.tl.editTargets(selection: [])
        #expect(t.source == .targeted && t.tracks == [rig.ids[1]])
    }

    @Test func allTracksWhenNothingSelectedOrTargeted() throws {
        let rig = try Rig()
        let t = rig.tl.editTargets(selection: [])
        #expect(t.source == .all && t.tracks == rig.ids)
    }

    @Test func selectionOfUnknownClipsFallsThrough() throws {
        let rig = try Rig(target: true)
        #expect(rig.tl.editTargets(selection: [UUID()]).source == .targeted)
    }

    @Test func linkedPartnersAreNotAddedByTheRule() throws {
        // The rule takes the selection as given; linked selection is the session's job.
        let l = UUID()
        let v = clip(0, 4, link: l), a = clip(0, 4, kind: .audio, link: l)
        let tl = timeline(try track([v]), try track([a], kind: .audio))
        #expect(tl.editTargets(selection: [v.id]).tracks == [tl.tracks[0].id])
    }

    // MARK: Cmd+K

    @Test func addEditCutsOnSelectedTracksOnly() throws {
        var rig = try Rig(target: true)
        let made = try rig.tl.addEdit(at: s(5), selection: [rig.v3.id])
        #expect(made.count == 1)
        #expect(rig.tl.tracks[2].clips.count == 2)
        #expect(rig.tl.tracks[0].clips.count == 2 && rig.tl.tracks[1].clips.count == 2)
    }

    @Test func addEditCutsOnTargetedTracksWithoutSelection() throws {
        var rig = try Rig(target: true)
        try rig.tl.addEdit(at: s(5), selection: [])
        #expect(rig.tl.tracks.map(\.clips.count) == [2, 3, 1])
    }

    @Test func addEditCutsOnAllTracksWithoutSelectionOrTargets() throws {
        var rig = try Rig()
        try rig.tl.addEdit(at: s(5), selection: [])
        #expect(rig.tl.tracks.map(\.clips.count) == [3, 3, 2])
    }

    @Test func addEditSkipsLockedTracksInScope() throws {
        var tl = timeline(try track([clip(0, 4)]), try track([clip(0, 4)], locked: true))
        try tl.addEdit(at: s(2), selection: [])
        #expect(tl.tracks.map(\.clips.count) == [2, 1])
    }

    @Test func addEditOnlyLockedScopeThrows() throws {
        let c = clip(0, 4)
        var tl = timeline(try track([c], locked: true), try track([clip(0, 4)]))
        #expect(throws: EditError.trackLocked) { try tl.addEdit(at: s(2), selection: [c.id]) }
        #expect(tl.tracks.map(\.clips.count) == [1, 1])
    }

    // MARK: Up / Down

    @Test func editPointsFollowSelectedTracks() throws {
        let rig = try Rig(target: true)
        #expect(rig.tl.editPoints(selection: [rig.v3.id]) == [s(2), s(7)])
    }

    @Test func editPointsFollowTargetedTracksWithoutSelection() throws {
        let rig = try Rig(target: true)
        #expect(rig.tl.editPoints(selection: []) == [s(1), s(3), s(6)])
    }

    @Test func editPointsCoverAllTracksWithoutSelectionOrTargets() throws {
        let rig = try Rig()
        #expect(rig.tl.editPoints(selection: []) == rig.tl.editPoints())
        #expect(rig.tl.editPoints(selection: []) == [s(0), s(1), s(2), s(3), s(4), s(6), s(7), s(8)])
    }

    @Test func editPointsIncludeLockedTracks() throws {
        let tl = timeline(try track([clip(0, 4)]), try track([clip(1, 2)], locked: true))
        #expect(tl.editPoints(selection: []) == [s(0), s(1), s(3), s(4)])
    }

    // MARK: X

    @Test func markClipUsesSelectedTracks() throws {
        let rig = try Rig(target: true)
        #expect(rig.tl.markClipRange(at: s(5), selection: [rig.v3.id]) == r(2, 7))
    }

    @Test func markClipUsesTargetedTracksWithoutSelection() throws {
        let rig = try Rig(target: true)
        #expect(rig.tl.markClipRange(at: s(5), selection: []) == r(3, 6))
    }

    @Test func markClipUsesAllTracksWithoutSelectionOrTargets() throws {
        let rig = try Rig()
        #expect(rig.tl.markClipRange(at: s(5), selection: []) == r(2, 8))
    }

    @Test func markClipNilWhenScopeHasNoClipUnderPlayhead() throws {
        let rig = try Rig(target: true)
        #expect(rig.tl.markClipRange(at: s(7), selection: []) == nil)       // V2 ends at 6
    }

    // MARK: Q / W stay on all unlocked tracks

    @Test func rippleTrimToPlayheadIgnoresTargetingWithNilTracks() throws {
        // Q/W behavior is unchanged by W6.1: `tracks: nil` trims every unlocked track, targeted or not.
        var tl = timeline(try track([clip(0, 4)], targeted: true), try track([clip(0, 4)]))
        try tl.rippleTrimToPlayhead(.tail, at: s(2), tracks: nil)
        let trimmed = tl.tracks.map { ends($0) }
        #expect(trimmed == [[s(2)], [s(2)]])
    }

    // MARK: Labels

    @Test func trackLabelsCountPerKind() throws {
        let tl = timeline(try track([]), try track([], kind: .audio), try track([]), try track([], kind: .audio))
        let labels = tl.tracks.map { tl.trackLabel($0.id) }
        #expect(labels == ["V1", "A1", "V2", "A2"])
        #expect(tl.trackLabel(UUID()) == nil)
    }
}

@Suite struct RippleClampOutcomeTests {
    @Test func qUnclampedIsApplied() throws {
        var tl = timeline(try track([clip(0, 4), clip(4, 2)]))
        let r = try tl.rippleTrimToPlayheadOutcome(.head, at: s(1), tracks: nil)
        #expect(r.moved == s(1) && r.outcome == .applied)
    }

    @Test func qClampedByOtherTrackReportsReason() throws {
        let a = clip(0, 10, media: 20)
        var tl = timeline(try track([a]), try track([clip(0, 3), clip(4, 2)]))
        let r = try tl.rippleTrimToPlayheadOutcome(.head, at: s(3), tracks: [tl.tracks[0].id])
        #expect(r.moved == s(1))
        #expect(r.outcome == .clamped(.clipOnTrack(tl.tracks[1].id, shortfall: s(2))))
        #expect(tl.describe(r.outcome.clampReason!) == "limited by clip on V2")
    }

    @Test func wClampedByOtherTrackReportsReason() throws {
        var tl = timeline(try track([clip(0, 4, media: 10), clip(4, 2)]), try track([clip(0, 3), clip(4, 1)]))
        let r = try tl.rippleTrimToPlayheadOutcome(.tail, at: s(1), tracks: [tl.tracks[0].id])
        #expect(r.moved == s(-1))
        #expect(r.outcome == .clamped(.clipOnTrack(tl.tracks[1].id, shortfall: s(2))))
    }

    @Test func rippleDeleteUnclampedIsApplied() throws {
        let a = clip(0, 2)
        var tl = timeline(try track([a, clip(2, 2)]), try track([clip(5, 1)]))
        let r = try tl.rippleDeleteOutcome([a.id])
        #expect(r.closed == s(2) && r.outcome == .applied)
    }

    @Test func rippleDeleteClampedByOtherTrackReportsReason() throws {
        // V2 [0,1) and [2,3): its later clip can move only 1 s left, so the 2 s gap closes by 1 s.
        let a = clip(0, 2)
        var tl = timeline(try track([a, clip(2, 2)]), try track([clip(0, 1), clip(2, 1)]))
        let r = try tl.rippleDeleteOutcome([a.id])
        #expect(r.closed == s(1))
        #expect(r.outcome == .clamped(.clipOnTrack(tl.tracks[1].id, shortfall: s(1))))
        #expect(tl.describe(r.outcome.clampReason!) == "limited by clip on V2")
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }

    @Test func extractUnclampedIsApplied() throws {
        var tl = timeline(try track([clip(0, 8)]))
        let res = try tl.extractOutcome(r(2, 4), tracks: [tl.tracks[0].id])
        #expect(res.closed == s(2) && res.outcome == .applied)
    }

    @Test func extractClampedByOtherTrackReportsReason() throws {
        var tl = timeline(try track([clip(0, 8)]), try track([clip(0, 3), clip(4, 2)]))
        let res = try tl.extractOutcome(r(2, 4), tracks: [tl.tracks[0].id])
        #expect(res.closed == s(1))
        #expect(res.outcome == .clamped(.clipOnTrack(tl.tracks[1].id, shortfall: s(1))))
    }

    @Test func clampedOutcomeExposesReasonAppliedDoesNot() {
        let id = UUID()
        #expect(EditOutcome.applied.clampReason == nil)
        #expect(EditOutcome.clamped(.clipOnTrack(id, shortfall: s(1))).clampReason == .clipOnTrack(id, shortfall: s(1)))
    }
}
