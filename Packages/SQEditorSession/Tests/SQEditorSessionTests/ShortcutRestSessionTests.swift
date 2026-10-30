import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
@MainActor private func makeSession(_ clips: [Clip], markers: [Marker] = []) -> EditorSession {
    var v = Track(kind: .video)
    for c in clips { try! v.overwrite(c) }
    var t = Timeline(name: "Main", frameDuration: fd, tracks: [v, Track(kind: .audio)])
    t.markers = markers
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

@MainActor @Suite struct ShortcutRestSessionTests {
    @Test func toggleAllTargetsTurnsAllOnThenAllOffAndUndoes() {
        let ses = makeSession([clip(0, 2)])
        #expect(ses.canToggleAllTargets)
        let before = ses.activeTimeline!.tracks.map(\.isTargeted)
        #expect(ses.toggleAllTargets())
        let turnedOn = before.contains(false)
        #expect(ses.activeTimeline!.tracks.allSatisfy { $0.isTargeted == turnedOn })
        #expect(ses.toggleAllTargets())
        #expect(ses.activeTimeline!.tracks.allSatisfy { $0.isTargeted != turnedOn })
        ses.undo()
        #expect(ses.activeTimeline!.tracks.allSatisfy { $0.isTargeted == turnedOn })
    }

    @Test func selectEdgeNeedsASelectionAndPicksTheRequestedSide() {
        let a = clip(0, 2), b = clip(2, 2)
        let ses = makeSession([a, b])
        #expect(!ses.canSelectEdgeOfSelection)
        #expect(ses.edgeSelectionOfSelection(.head) == nil)
        ses.select(clips: [a.id])
        #expect(ses.canSelectEdgeOfSelection)
        #expect(ses.edgeSelectionOfSelection(.head)?.edges == [EdgeRef(clip: a.id, edge: .head)])
        #expect(ses.edgeSelectionOfSelection(.tail)?.edges == [EdgeRef(clip: a.id, edge: .tail)])
        #expect(ses.edgeSelectionOfSelection(.head)?.ripple == false)
    }

    @Test func markerAtPlayheadFindsPointAndRangeMarkers() {
        let point = Marker(time: s(3)), range = Marker(time: s(6), duration: s(3))
        let ses = makeSession([clip(0, 10)], markers: [point, range])
        #expect(!ses.canEditMarkerAtPlayhead)
        ses.seek(to: s(3))
        #expect(ses.markerAtPlayhead() == point.id)
        ses.seek(to: s(4))
        #expect(ses.markerAtPlayhead() == nil)
        ses.seek(to: s(7))
        #expect(ses.markerAtPlayhead() == range.id)
        ses.seek(to: s(9))
        #expect(ses.markerAtPlayhead() == nil)
    }

    @Test func toggleVideoTargetsLeavesAudioAlone() {
        let ses = makeSession([clip(0, 2)])
        #expect(ses.canToggleTargets(of: .video))
        let before = ses.activeTimeline!.tracks.filter { $0.kind == .audio }.map(\.isTargeted)
        let videoOn = ses.activeTimeline!.tracks.filter { $0.kind == .video }.allSatisfy(\.isTargeted)
        ses.toggleTargets(of: .video)
        #expect(ses.activeTimeline!.tracks.filter { $0.kind == .video }.allSatisfy { $0.isTargeted == !videoOn })
        #expect(ses.activeTimeline!.tracks.filter { $0.kind == .audio }.map(\.isTargeted) == before)
        ses.toggleTargets(of: .video)
        #expect(ses.activeTimeline!.tracks.filter { $0.kind == .video }.allSatisfy { $0.isTargeted == videoOn })
    }

    @Test func playFromStartRestartsPlayback() {
        let ses = makeSession([clip(0, 10)])
        ses.seek(to: s(5))
        ses.playFromStart()
        #expect(ses.isPlaying)
        #expect(ses.playhead == .zero)
    }

    @Test func toggleTrackTargetHitsTheNthTrackOfAKindAndUndoes() {
        let ses = makeSession([clip(0, 2)])
        let id = ses.activeTimeline!.tracks.first { $0.kind == .video }!.id
        let was = ses.activeTimeline!.track(id)!.isTargeted
        #expect(ses.canToggleTrackTarget(.video, 1))
        #expect(!ses.canToggleTrackTarget(.video, 2))
        #expect(!ses.toggleTrackTarget(.video, 2))
        #expect(ses.toggleTrackTarget(.video, 1))
        #expect(ses.activeTimeline!.track(id)!.isTargeted == !was)
        ses.undo()
        #expect(ses.activeTimeline!.track(id)!.isTargeted == was)
    }

    @Test func toggleLockOfTargetsLocksAndUnlocksTargetedTracks() {
        let ses = makeSession([clip(0, 2)])
        let ids = ses.activeTimeline!.tracks.map(\.id)
        ses.toggleTargets(of: .video)
        let targeted = ses.activeTimeline!.tracks.filter(\.isTargeted).map(\.id)
        #expect(ses.canToggleLockOfTargets == !targeted.isEmpty)
        guard !targeted.isEmpty else { return }
        #expect(ses.toggleLockOfTargets())
        #expect(ids.allSatisfy { ses.activeTimeline!.track($0)!.isLocked == targeted.contains($0) })
        #expect(ses.toggleLockOfTargets())
        #expect(ses.activeTimeline!.tracks.allSatisfy { !$0.isLocked })
    }
}
