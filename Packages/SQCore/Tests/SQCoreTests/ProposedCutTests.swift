import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ d: Int64) -> TimeRange { TimeRange(start: s(a), duration: s(d)) }

private func makeTimeline() -> (Timeline, Clip) {
    let m = UUID(), link = UUID()
    let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
    let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
    var vt = Track(kind: .video), at = Track(kind: .audio)
    try! vt.overwrite(v); try! at.overwrite(a)
    return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: [vt, at]), a)
}

@Suite struct ProposedCutTests {
    @Test func proposeAddsTypedRangeMarkersAndReplacesOldOnes() {
        var (tl, _) = makeTimeline()
        let user = tl.addMarker(at: s(1), name: "mine")
        tl.proposeCuts([r(2, 1), r(6, 2)], kind: .silence)
        let p = tl.proposedCuts
        #expect(p.map(\.range) == [r(2, 1), r(6, 2)])
        #expect(p.allSatisfy { $0.kind == .silence })
        #expect(tl.markers.first { $0.id == p[0].id }?.isProposedCut == true)
        tl.proposeCuts([r(9, 1)], kind: .silence)                        // a new scan replaces the earlier proposals only
        #expect(tl.proposedCuts.map(\.range) == [r(9, 1)])
        #expect(tl.markers.contains { $0.id == user && !$0.isProposedCut })
    }

    @Test func rejectRemovesOneMarkerOnly() {
        var (tl, _) = makeTimeline()
        tl.proposeCuts([r(2, 1), r(6, 2)], kind: .silence)
        tl.rejectProposedCut(tl.proposedCuts[0].id)
        #expect(tl.proposedCuts.map(\.range) == [r(6, 2)])
        tl.rejectAllProposedCuts()
        #expect(tl.proposedCuts.isEmpty && tl.markers.isEmpty)
    }

    @Test func acceptAllRipplesAndLeavesNoProposals() throws {
        var (tl, a) = makeTimeline()
        tl.proposeCuts([r(2, 1), r(6, 2)], kind: .silence)
        let removed = try tl.acceptProposedCuts(nil, around: [a.id])
        #expect(removed == s(3))
        #expect(tl.tracks.map(\.end) == [s(17), s(17)])
        #expect(tl.proposedCuts.isEmpty)
    }

    @Test func acceptOneKeepsTheOthersAtShiftedPositions() throws {
        var (tl, a) = makeTimeline()
        tl.proposeCuts([r(2, 1), r(6, 2), r(12, 2)], kind: .silence)
        let ps = tl.proposedCuts
        let user = tl.addMarker(at: s(10), name: "mine")
        let removed = try tl.acceptProposedCuts([ps[1].id], around: [a.id])     // the 6-8 s cut
        #expect(removed == s(2))
        #expect(tl.proposedCuts.map(\.range) == [r(2, 1), r(10, 2)])           // the later one moved earlier by 2 s
        #expect(tl.markers.first { $0.id == user }?.time == s(8))               // ordinary markers ripple too
        #expect(tl.tracks.map(\.end) == [s(18), s(18)])
    }

    @Test func acceptWithLockedTrackFailsAndChangesNothing() {
        var (tl, a) = makeTimeline()
        tl.tracks[1].isLocked = true
        tl.proposeCuts([r(2, 1)], kind: .silence)
        let before = tl
        #expect(throws: EditError.self) { try tl.acceptProposedCuts(nil, around: [a.id]) }
        #expect(tl == before)
    }

    @Test func proposedCutsSurviveCodableAsPlainMarkers() throws {
        var (tl, _) = makeTimeline()
        tl.proposeCuts([r(2, 1)], kind: .silence)
        let back = try JSONDecoder().decode(Marker.self, from: JSONEncoder().encode(tl.markers[0]))
        #expect(back.isProposedCut && back.duration == s(1))
    }

    @Test func totalIsTheSumOfProposals() {
        var (tl, _) = makeTimeline()
        tl.proposeCuts([r(2, 1), r(6, 2)], kind: .silence)
        #expect(tl.proposedCutTotal == s(3))
    }

    @Test func reviewRowsAndSummaryText() {
        let cut = Timeline.ProposedCut(id: UUID(), range: TimeRange(start: Time(72, 5), duration: Time(7, 5)), kind: .silence)
        #expect(cut.rowTitle == "0:14.4   1.4 s")
        let scene = Timeline.ProposedCut(id: UUID(), range: TimeRange(start: Time(75, 1), duration: .zero), kind: .scene)
        #expect(scene.rowTitle == "1:15.0   scene change")
        #expect(Timeline.ProposedCut.reviewSummary(count: 0, checked: 0, removed: .zero) == "No proposed cuts.")
        #expect(Timeline.ProposedCut.reviewSummary(count: 5, checked: 3, removed: Time(21, 5)) == "3 of 5 checked, 4.2 s will be removed.")
    }
}
