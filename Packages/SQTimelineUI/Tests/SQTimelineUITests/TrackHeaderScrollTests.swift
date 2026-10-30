import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// Vertical scroll only moves the header rows; their buttons and symbols are rebuilt only when the track changes.
@MainActor @Suite struct TrackHeaderScrollTests {
    private static let fd = Time(1, 24)

    private func view() -> TimelineView {
        let tracks = (0..<16).map { i -> Track in
            let kind: TrackKind = i < 8 ? .video : .audio
            let clips = (0..<5).map { n in
                Clip(name: "C", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Self.fd * 24), start: Self.fd * Int64(n * 30))
            }
            return Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: false)
        }
        return TimelineView(timeline: Timeline(name: "t", frameDuration: Self.fd, tracks: tracks), frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
    }

    @Test func verticalScrollMovesHeadersWithoutReapplying() throws {
        let v = view()
        let ids = v.timeline.tracks.map(\.id)
        let before = ids.map { v.headerView(for: $0)!.contentApplyCount }
        let y0 = try #require(v.headerView(for: ids[0])).frame.minY
        for _ in 0..<10 { v.scroll(byX: 0, y: 5) }
        #expect(v.geometry.scrollY == 50)
        #expect(ids.map { v.headerView(for: $0)!.contentApplyCount } == before)
        // Headers follow their rows.
        for row in v.layoutRows() { #expect(v.headerView(for: row.track)!.frame.minY == row.y) }
        #expect(v.headerView(for: ids[0])!.frame.minY == y0 - 50)
    }

    @Test func changedTrackReappliesOnlyThatHeader() {
        let v = view()
        let ids = v.timeline.tracks.map(\.id)
        let before = ids.map { v.headerView(for: $0)!.contentApplyCount }
        var t = v.timeline
        t.tracks[9].isMuted = true
        v.setTimeline(t)
        let after = ids.map { v.headerView(for: $0)!.contentApplyCount }
        for i in ids.indices { #expect(after[i] == before[i] + (i == 9 ? 1 : 0), "track \(i)") }
    }

    @Test func symbolImagesAreCached() {
        let a = TrackHeaderView.symbolImage(.volume, description: "Mute")
        let b = TrackHeaderView.symbolImage(.volume, description: "Mute")
        #expect(a != nil && a === b)
    }
}
