import Foundation
import Testing
@testable import SQCore

@Suite struct BeatMarkerTests {
    private let frame = Time(1, 30)
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private func timeline() -> Timeline { Timeline(name: "t", frameDuration: frame, tracks: []) }
    private let range = TimeRange(start: Time(10, 1), duration: Time(10, 1))

    @Test func addsCyanBeatMarkersAtFrameSnappedTimes() {
        var tl = timeline()
        let n = tl.replaceBeatMarkers(in: range, with: [Time(21, 2), Time(10003, 1000)])
        #expect(n == 2)
        #expect(tl.markers.map(\.name) == ["Beat", "Beat"])
        #expect(tl.markers.allSatisfy { $0.color == .cyan })
        #expect(tl.markers[0].time == Time(10003, 1000).snapped(to: frame))
    }

    @Test func aSecondRunReplacesTheFirstAndKeepsOtherMarkers() {
        var tl = timeline()
        let mine = tl.addMarker(at: s(12), name: "Drop")
        let outside = tl.addMarker(at: s(30), name: "Beat")      // a beat marker outside the range stays
        tl.replaceBeatMarkers(in: range, with: [s(10), s(11), s(13)])
        tl.replaceBeatMarkers(in: range, with: [s(10), s(12), s(14)])
        #expect(tl.markers.filter { $0.name == "Beat" && range.contains($0.time) }.map(\.time) == [s(10), s(14)])
        #expect(tl.markers.contains { $0.id == mine && $0.name == "Drop" })
        #expect(tl.markers.contains { $0.id == outside })
    }

    @Test func beatsOutsideTheRangeAreDropped() {
        var tl = timeline()
        #expect(tl.replaceBeatMarkers(in: range, with: [s(9), s(10), s(19), s(20), s(25)]) == 2)
    }

    @Test func noBeatsStillClearsTheOldOnes() {
        var tl = timeline()
        tl.replaceBeatMarkers(in: range, with: [s(10), s(11)])
        #expect(tl.replaceBeatMarkers(in: range, with: []) == 0)
        #expect(tl.markers.isEmpty)
    }
}
