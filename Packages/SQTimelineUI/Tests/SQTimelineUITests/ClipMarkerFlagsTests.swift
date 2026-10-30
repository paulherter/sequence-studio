import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

@MainActor
@Suite struct ClipMarkerFlagsTests {
    private let fd = Time(1, 30)

    private func setup() throws -> (Timeline, Clip, TimelineGeometry) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(4, 1)),
                     start: Time(1, 1), mediaDuration: Time(20, 1))
        c.markers = [Marker(time: Time(3, 1), name: "m")]            // at sequence time 2 s
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        let tl = Timeline(name: "T", frameDuration: fd, tracks: [tr])
        return (tl, c, TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
    }

    @Test func hitFindsTheFlagInTheBottomStrip() throws {
        let (tl, c, g) = try setup()
        let row = try #require(g.rows(for: tl).first)
        let x = g.x(for: Time(2, 1))
        let hit = ClipMarkerFlags.hit(at: CGPoint(x: x + 2, y: row.maxY - 4), in: tl, geometry: g)
        #expect(hit?.clip == c.id)
        #expect(hit?.marker == c.markers?.first?.id)
        #expect(hit?.time == Time(2, 1))
    }

    @Test func hitMissesAwayFromTheFlagOrTheStrip() throws {
        let (tl, _, g) = try setup()
        let row = try #require(g.rows(for: tl).first)
        let x = g.x(for: Time(2, 1))
        #expect(ClipMarkerFlags.hit(at: CGPoint(x: x + 30, y: row.maxY - 4), in: tl, geometry: g) == nil)
        #expect(ClipMarkerFlags.hit(at: CGPoint(x: x, y: row.y + 4), in: tl, geometry: g) == nil)
    }

    @Test func clipMarkersAreSnapTargets() throws {
        let (tl, c, g) = try setup()
        let near = Time(5, 2)                          // 2.5 s, half a second from the flag at 2 s
        let drag = ClipMarkerFlags.Hit(clip: c.id, marker: UUID(), time: near)
        let r = ClipMarkerFlags.target(time: Time(2, 1) + fd, dragging: drag, in: tl, playhead: nil, snapping: true, geometry: g)
        #expect(r.time == Time(2, 1))
        let off = ClipMarkerFlags.target(time: Time(2, 1) + fd, dragging: drag, in: tl, playhead: nil, snapping: false, geometry: g)
        #expect(off.time == Time(2, 1) + fd)
    }

    @Test func menuOffersAddClipMarkerForOneClipAndNewRows() throws {
        let (tl, c, _) = try setup()
        let on = TimelineContextMenu.items(timeline: tl, selection: [c.id], clipboardHasClips: false)
        #expect(on.first { $0.action == .addClipMarker }?.isEnabled == true)
        #expect(on.first { $0.action == .revealInProject }?.isEnabled == true)
        let none = TimelineContextMenu.items(timeline: tl, selection: [], clipboardHasClips: false)
        #expect(none.first { $0.action == .addClipMarker }?.isEnabled == false)
        #expect(none.first { $0.action == .unnest }?.isEnabled == false)
    }

    @Test func trackHeaderListsMoveRowsWhenGiven() {
        let rows = TimelineSideMenus.trackHeader(track: Track(kind: .video, name: "V1"), addVideo: {}, addAudio: {}, delete: {},
                                                 rename: {}, moveUp: {}, moveDown: {}, mix: {}, toggleDucking: {})
        let titles = rows.map { $0.kind == .separator ? "-" : $0.title }
        #expect(titles.contains("Move Track Up") && titles.contains("Move Track Down"))
    }
}
