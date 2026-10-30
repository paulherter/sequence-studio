import AppKit
import Foundation
import SQCore
import SQUIKit
import Testing
@testable import SQTimelineUI

@MainActor
@Suite struct TimelineAccessibilityTests {
    private let fd = Time(1, 30)

    private func setup() throws -> (Timeline, Clip, TimelineGeometry) {
        let c = Clip(name: "Interview", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                     start: Time(1, 1), mediaDuration: Time(20, 1))
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        return (Timeline(name: "T", frameDuration: fd, tracks: [tr]), c, TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
    }

    @Test func trackAndClipLabelsCarryNameAndTimes() throws {
        let (tl, c, g) = try setup()
        let items = TimelineAccessibility.tracks(timeline: tl, rows: g.rows(for: tl), geometry: g, viewWidth: 800,
                                                 selection: [c.id], position: { "P\($0.value)/\($0.timescale)" },
                                                 length: { "L\($0.value)/\($0.timescale)" })
        let t = try #require(items.first)
        #expect(t.label.hasPrefix("Video track "))
        #expect(t.label.contains("1 clip"))
        let clip = try #require(t.clips.first)
        #expect(clip.label == "Interview, from P1/1, length L4/1")
        #expect(clip.selected)
        #expect(clip.frame.minX == g.x(for: Time(1, 1)))
        #expect(clip.frame.width == g.width(of: Time(4, 1)))
    }

    @Test func offlineAndLockedAreSpoken() throws {
        var (tl, c, g) = try setup()
        tl.tracks[0].isLocked = true
        let items = TimelineAccessibility.tracks(timeline: tl, rows: g.rows(for: tl), geometry: g, viewWidth: 800,
                                                 selection: [], offline: [c.media], position: { _ in "0" }, length: { _ in "0" })
        #expect(items[0].label.contains("locked"))
        #expect(items[0].clips[0].label.hasSuffix("media offline"))
        #expect(!items[0].clips[0].selected)
    }

    @Test func viewExposesTrackGroupsWithClipChildren() throws {
        let (tl, _, _) = try setup()
        let view = TimelineView(timeline: tl)
        let groups = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        let group = try #require(groups.first { $0.accessibilityLabel()?.hasPrefix("Video track") == true })
        #expect(group.accessibilityChildren()?.count == 1)
        #expect(view.accessibilityRole() == .group)
        #expect(view.accessibilityLabel() == "Timeline")
    }
}
