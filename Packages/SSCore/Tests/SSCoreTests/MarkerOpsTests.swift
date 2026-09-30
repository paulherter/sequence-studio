import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct MarkerOpsTests {
    func tl() -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30)) }

    @Test func addKeepsSortedAndSnapsToFrame() {
        var t = tl()
        _ = t.addMarker(at: s(5), name: "b")
        _ = t.addMarker(at: Time(1, 61), name: "a")
        #expect(t.markers.map(\.name) == ["a", "b"])
        #expect(t.markers[0].time.snapped(to: Time(1, 30)) == t.markers[0].time)
    }

    @Test func removeMoveRename() {
        var t = tl()
        let a = t.addMarker(at: s(1), name: "a"), b = t.addMarker(at: s(3), name: "b")
        t.moveMarker(a, to: s(4))
        #expect(t.markers.map(\.name) == ["b", "a"])
        t.moveMarker(a, to: s(-2))
        #expect(t.markers.first?.time == .zero)
        t.renameMarker(b, to: "x")
        #expect(t.markers.contains { $0.name == "x" })
        t.removeMarker(a)
        #expect(t.markers.count == 1)
        t.removeMarker(UUID())
        #expect(t.markers.count == 1)
    }

    @Test func updateMarkerClosure() {
        var t = tl()
        let a = t.addMarker(at: s(1))
        #expect(t.updateMarker(a) { $0.name = "n" })
        #expect(t.markers[0].name == "n")
        #expect(!t.updateMarker(UUID()) { _ in })
    }

    @Test func markerAtPlayheadToggle() {
        var t = tl()
        let r1 = t.markAtPlayhead(s(2))
        #expect(!r1.openEdit)
        let r2 = t.markAtPlayhead(s(2))
        #expect(r2.openEdit && r2.id == r1.id)
        #expect(t.markers.count == 1)
        let r3 = t.markAtPlayhead(s(2) + Time(1, 100))
        #expect(r3.openEdit)
        #expect(t.markAtPlayhead(s(3)).openEdit == false)
        #expect(t.markers.count == 2)
    }

    @Test func nextPrevious() {
        var t = tl()
        for n in [2, 4, 6] as [Int64] { _ = t.addMarker(at: s(n)) }
        #expect(t.nextMarker(after: s(2))?.time == s(4))
        #expect(t.nextMarker(after: s(1))?.time == s(2))
        #expect(t.nextMarker(after: s(6)) == nil)
        #expect(t.previousMarker(before: s(4))?.time == s(2))
        #expect(t.previousMarker(before: s(2)) == nil)
        #expect(t.previousMarker(before: s(10))?.time == s(6))
    }

    @Test func inRange() {
        var t = tl()
        for n in [2, 4, 6] as [Int64] { _ = t.addMarker(at: s(n)) }
        #expect(t.markers(in: TimeRange(start: s(2), duration: s(4))).map(\.time) == [s(2), s(4)])
        #expect(t.markers(in: TimeRange(start: s(7), duration: s(1))).isEmpty)
    }

    @Test func rippleShift() {
        var t = tl()
        for n in [1, 4, 6, 9] as [Int64] { _ = t.addMarker(at: s(n)) }
        t.shiftMarkers(from: s(4), by: s(2))
        #expect(t.markers.map(\.time) == [s(1), s(6), s(8), s(11)])
        t.shiftMarkers(from: s(8), by: s(-3))
        #expect(t.markers.map(\.time) == [s(1), s(5), s(5), s(8)])
    }
}
