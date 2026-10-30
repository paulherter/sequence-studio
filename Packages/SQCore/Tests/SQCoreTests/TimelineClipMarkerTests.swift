import Foundation
import Testing
@testable import SQCore

@Suite struct TimelineClipMarkerTests {
    private let fd = Time(1, 30)

    private func setup(start: Time = Time(10, 1)) throws -> (Timeline, Clip.ID) {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(4, 1)), start: start,
                     mediaDuration: Time(20, 1))
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        return (Timeline(name: "T", frameDuration: fd, tracks: [tr]), c.id)
    }

    @Test func addStoresSourceTime() throws {
        var t = try setup()
        let added = t.0.addClipMarker(to: t.1, at: Time(11, 1), name: "a", color: .red)
        let id = try #require(added)
        let c = try #require(t.0.tracks[0].clips.first)
        #expect(c.markers?.first?.id == id)
        #expect(c.markers?.first?.time == Time(3, 1))
        #expect(t.0.clipMarkerTimes() == [Time(11, 1)])
    }

    @Test func addOutsideTheClipFails() throws {
        var t = try setup()
        let late = t.0.addClipMarker(to: t.1, at: Time(15, 1))
        let early = t.0.addClipMarker(to: t.1, at: Time(9, 1))
        #expect(late == nil && early == nil)
        #expect(t.0.tracks[0].clips[0].markers == nil)
    }

    @Test func moveClampsIntoTheClip() throws {
        var t = try setup()
        let added = t.0.addClipMarker(to: t.1, at: Time(11, 1))
        let id = try #require(added)
        let r1 = t.0.moveClipMarker(id, on: t.1, to: Time(12, 1))
        #expect(r1)
        #expect(t.0.clipMarkerTimes() == [Time(12, 1)])
        let r2 = t.0.moveClipMarker(id, on: t.1, to: Time(99, 1))
        #expect(r2)
        #expect(t.0.clipMarkerTimes() == [Time(14, 1) - fd])
    }

    @Test func updateKeepsPositionAndRemoveClearsTheList() throws {
        var t = try setup()
        let added = t.0.addClipMarker(to: t.1, at: Time(11, 1))
        let id = try #require(added)
        let r1 = t.0.updateClipMarker(id, on: t.1) { $0.name = "x"; $0.time = .zero }
        #expect(r1)
        #expect(t.0.tracks[0].clips[0].markers?.first?.name == "x")
        #expect(t.0.clipMarkerTimes() == [Time(11, 1)])
        let r2 = t.0.removeClipMarker(id, on: t.1)
        #expect(r2)
        #expect(t.0.tracks[0].clips[0].markers == nil)
    }
}
