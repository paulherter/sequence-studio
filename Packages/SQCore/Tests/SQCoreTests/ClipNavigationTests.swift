import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}

@Suite struct ClipNavigationTests {
    func timeline() throws -> (Timeline, [Clip]) {
        var t = Timeline(name: "t", frameDuration: Time(1, 30))
        let v = [clip(0, 2), clip(2, 3), clip(8, 2)]
        var track = Track(kind: .video)
        for c in v { try track.overwrite(c) }
        t.tracks = [track]
        return (t, v)
    }

    @Test func neighbourClipWalksTheSameTrack() throws {
        let (t, v) = try timeline()
        #expect(t.neighbourClip(of: v[0].id, forward: true) == v[1].id)
        #expect(t.neighbourClip(of: v[1].id, forward: true) == v[2].id)   // across a gap
        #expect(t.neighbourClip(of: v[2].id, forward: true) == nil)
        #expect(t.neighbourClip(of: v[2].id, forward: false) == v[1].id)
        #expect(t.neighbourClip(of: v[0].id, forward: false) == nil)
        #expect(t.neighbourClip(of: UUID(), forward: true) == nil)
    }

    @Test func extentCoversTheSelection() throws {
        let (t, v) = try timeline()
        #expect(t.extent(of: [v[1].id]) == TimeRange(start: s(2), duration: s(3)))
        #expect(t.extent(of: [v[0].id, v[2].id]) == TimeRange(start: s(0), duration: s(10)))
        #expect(t.extent(of: []) == nil)
        #expect(t.extent(of: [UUID()]) == nil)
    }

    @Test func clearMarkerRemovesOnlyTheOneOnThatFrame() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30))
        _ = t.addMarker(at: s(1)); _ = t.addMarker(at: s(2))
        #expect(t.clearMarker(at: Time(45, 30)) == nil)        // 1.5 s: no marker there
        #expect(t.clearMarker(at: s(1)) != nil)
        #expect(t.markers.map(\.time) == [s(2)])
        #expect(t.clearMarker(at: s(1)) == nil)
    }

    @Test func clearAllMarkersCountsAndEmpties() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30))
        #expect(t.clearAllMarkers() == 0)
        _ = t.addMarker(at: s(1)); _ = t.addMarker(at: s(2))
        #expect(t.clearAllMarkers() == 2)
        #expect(t.markers.isEmpty)
    }
}
