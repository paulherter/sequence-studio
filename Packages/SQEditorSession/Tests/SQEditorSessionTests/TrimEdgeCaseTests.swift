import Foundation
import Testing
import SQCore
@testable import SQEditorSession

// Edit edge cases (zero-length, overlap, linked A/V, locked tracks, disabled clips) across the edit operations.
// Every case checks the same contract: the sequence stays valid (no overlap, no empty clip), a refused edit leaves it
// untouched, and undo/redo restore exactly the before/after state.

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil, enabled: Bool = true) -> Clip {
    var c = Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(dur)), start: s(start))
    c.link = link; c.isEnabled = enabled
    return c
}
private func track(_ kind: TrackKind, _ clips: [Clip], locked: Bool = false, syncLock: Bool = true) -> Track {
    var t = Track(kind: kind, isLocked: locked, syncLock: syncLock)
    for c in clips { try! t.overwrite(c) }
    return t
}

@MainActor private func session(_ tracks: [Track]) -> EditorSession {
    let ss = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: tracks)]),
                           engine: StubProgramEngine())
    ss.setSelectionFollowsPlayhead(false)
    return ss
}

private func valid(_ t: Timeline) -> Bool {
    t.tracks.allSatisfy { tr in
        let cs = tr.clips.sorted { $0.start < $1.start }
        return cs.allSatisfy { $0.timeline.duration > .zero }
            && zip(cs, cs.dropFirst()).allSatisfy { $0.timeline.end <= $1.start }
    }
}

/// Runs `op`, then checks validity and the undo/redo round trip. Returns whether the edit changed anything.
@MainActor @discardableResult
private func check(_ ss: EditorSession, _ op: () -> Void, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
    let before = ss.activeTimeline!.tracks
    let depth = ss.undoName
    op()
    let after = ss.activeTimeline!.tracks
    #expect(valid(ss.activeTimeline!), sourceLocation: sourceLocation)
    guard after != before else { #expect(ss.undoName == depth, sourceLocation: sourceLocation); return false }
    #expect(ss.undo(), sourceLocation: sourceLocation)
    #expect(ss.activeTimeline!.tracks == before, sourceLocation: sourceLocation)
    #expect(ss.redo(), sourceLocation: sourceLocation)
    #expect(ss.activeTimeline!.tracks == after, sourceLocation: sourceLocation)
    return true
}

@MainActor @Suite struct TrimEdgeCaseTests {
    @Test func trimPastZeroLengthIsClampedOrRefused() {
        let a = clip(0, 2), b = clip(2, 2)
        let ss = session([track(.video, [a, b])])
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)]), frames: -500) }
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .head)]), frames: 500) }
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail), EdgeRef(clip: b.id, edge: .head)]), frames: 500) }
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail), EdgeRef(clip: b.id, edge: .head)]), frames: -500) }
    }

    @Test func zeroFrameTrimChangesNothing() {
        let a = clip(0, 2)
        let ss = session([track(.video, [a])])
        #expect(check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)]), frames: 0) } == false)
    }

    @Test func tailGrowIntoNeighborDoesNotOverlap() {
        let a = clip(0, 2), b = clip(2, 2)
        let ss = session([track(.video, [a, b])])
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)]), frames: 20) }
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: b.id, edge: .head)]), frames: -20) }
    }

    @Test func rippleTrimWithLockedTrackKeepsLockedTrackStill() {
        let a = clip(0, 2), b = clip(2, 2)
        let lockedClips = [clip(0, 1), clip(3, 1)]
        let ss = session([track(.video, [a, b]), track(.video, lockedClips, locked: true)])
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)], ripple: true), frames: -15) }
        #expect(ss.activeTimeline!.tracks[1].clips.map(\.start) == lockedClips.map(\.start))
    }

    @Test func trimOnALockedTrackIsRefused() {
        let a = clip(0, 2)
        let ss = session([track(.video, [a], locked: true)])
        #expect(check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)]), frames: -15) } == false)
    }

    @Test func linkedPairTrimsTogetherAndUnlinkedOnlyOne() {
        let l = UUID()
        let v = clip(0, 4, link: l), au = clip(0, 4, kind: .audio, link: l)
        let ss = session([track(.video, [v]), track(.audio, [au])])
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: v.id, edge: .tail)]), frames: -30) }
        #expect(ss.activeTimeline!.tracks.map { $0.clips[0].timeline.end } == [s(3), s(3)])
        ss.undo(); ss.undo()
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: v.id, edge: .tail)], linked: false), frames: -30) }
        #expect(ss.activeTimeline!.tracks.map { $0.clips[0].timeline.end } == [s(3), s(4)])
    }

    @Test func rippleDeleteOfALinkedPairClosesBothTracks() {
        let l = UUID()
        let v = clip(0, 2, link: l), au = clip(0, 2, kind: .audio, link: l)
        let ss = session([track(.video, [v, clip(2, 2)]), track(.audio, [au, clip(2, 2, kind: .audio)])])
        ss.select(clips: [v.id, au.id])          // the view selects a linked pair as a pair
        check(ss) { ss.deleteSelection(ripple: true) }
        #expect(ss.activeTimeline!.tracks.map { $0.clips.map(\.start) } == [[s(0)], [s(0)]])
    }

    @Test func deleteOnLockedTrackIsRefusedAndLiftLeavesGap() {
        let a = clip(0, 2), b = clip(2, 2)
        let ss = session([track(.video, [a, b], locked: true)])
        ss.select(clips: [a.id])
        #expect(check(ss) { ss.deleteSelection(ripple: true) } == false)
        #expect(check(ss) { ss.deleteSelection(ripple: false) } == false)
        let c = clip(0, 2), d = clip(2, 2)
        let ss2 = session([track(.video, [c, d])])
        ss2.select(clips: [c.id])
        check(ss2) { ss2.deleteSelection(ripple: false) }
        #expect(ss2.activeTimeline!.tracks[0].clips.map(\.start) == [s(2)])
    }

    @Test func disabledClipsStillTrimMoveAndDelete() {
        let a = clip(0, 2, enabled: false), b = clip(2, 2)
        let ss = session([track(.video, [a, b])])
        check(ss) { ss.trimEdges(EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)], ripple: true), frames: -15) }
        ss.select(clips: [a.id])
        check(ss) { ss.deleteSelection(ripple: true) }
        #expect(ss.activeTimeline!.tracks[0].clips.map(\.start) == [s(0)])
    }

    @Test func slipAndSlideAtTheLimits() {
        let a = clip(0, 2), b = clip(2, 2), c = clip(4, 2)
        let ss = session([track(.video, [a, b, c])])
        ss.select(clips: [b.id])
        check(ss) { ss.slipSelection(frames: 100_000) }
        check(ss) { ss.slipSelection(frames: -100_000) }
        check(ss) { ss.slideSelection(frames: 100_000) }
        check(ss) { ss.slideSelection(frames: -100_000) }
        check(ss) { ss.slideSelection(frames: 0) }
    }

    @Test func slideOnLockedTrackOrBesideDisabledClipStaysValid() {
        let a = clip(0, 2), b = clip(2, 2, enabled: false), c = clip(4, 2)
        let ss = session([track(.video, [a, b, c])])
        ss.select(clips: [b.id])
        check(ss) { ss.slideSelection(frames: 15) }
        let x = clip(0, 2), y = clip(2, 2)
        let ss2 = session([track(.video, [x, y], locked: true)])
        ss2.select(clips: [y.id])
        #expect(check(ss2) { ss2.slideSelection(frames: -15) } == false)
        #expect(check(ss2) { ss2.slipSelection(frames: 5) } == false)
    }

    @Test func razorAtEdgesAndOnLockedTracks() {
        let a = clip(0, 2), b = clip(2, 2)
        let ss = session([track(.video, [a, b]), track(.video, [clip(0, 4)], locked: true)])
        for at in [Int64(0), 2, 4, 9] {          // clip start, a cut point, the end, empty space
            ss.seek(to: s(at))
            check(ss) { ss.addEditAtPlayhead(allTracks: true) }
        }
        #expect(ss.activeTimeline!.tracks[1].clips.count == 1)
    }

    @Test func pasteOverlapAndAtLockedTrack() {
        let a = clip(0, 2), b = clip(2, 2)
        let ss = session([track(.video, [a, b])])
        ss.select(clips: [a.id]); #expect(ss.copySelection())
        ss.seek(to: s(1))
        check(ss) { ss.pasteClipboard() }                 // overwrites across the cut
        ss.seek(to: s(1))
        check(ss) { ss.pasteClipboard(insert: true) }
        let c = clip(0, 2)
        let ss2 = session([track(.video, [c], locked: true)])
        ss2.select(clips: [c.id]); #expect(ss2.copySelection())
        ss2.seek(to: s(5))
        #expect(check(ss2) { ss2.pasteClipboard() } == false)
    }

    @Test func rangeEditsWithEmptyOrReversedInOut() {
        let a = clip(0, 4)
        let ss = session([track(.video, [a])])
        ss.seek(to: s(1)); ss.markIn(); ss.markOut()      // zero-length range
        check(ss) { ss.liftRange() }
        check(ss) { ss.extractRange() }
        ss.seek(to: s(3)); ss.markIn()
        ss.seek(to: s(1)); ss.markOut()                   // Out before In
        check(ss) { ss.extractRange() }
        let b = clip(0, 4)
        let ss2 = session([track(.video, [b])])
        ss2.seek(to: s(1)); ss2.markIn(); ss2.seek(to: s(3)); ss2.markOut()
        check(ss2) { ss2.extractRange() }
        #expect(ss2.activeTimeline!.tracks[0].clips.map(\.timeline.duration) == [s(1), Time(29, 30)])   // Out is inclusive: the frame at Out goes too
    }

    @Test func rippleDeleteAcrossSyncLockedAndUnlockedTracks() {
        let a = clip(0, 2)
        let ss = session([track(.video, [a, clip(2, 2)]), track(.video, [clip(1, 2), clip(4, 1)], syncLock: false)])
        ss.select(clips: [a.id])
        check(ss) { ss.deleteSelection(ripple: true) }
        #expect(ss.activeTimeline!.tracks[1].clips.map(\.start) == [s(1), s(4)])
    }
}
