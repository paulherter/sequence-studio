import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

@Suite struct TimelineTakeMenuTests {
    private func timeline(takes: Int, inOut: TimeRange?) throws -> (Timeline, Clip) {
        var tracks: [Track] = []
        var first: Clip?
        for _ in 0..<takes {
            let c = Clip(name: "t", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
            first = first ?? c
            var t = Track(kind: .audio); try t.overwrite(c); tracks.append(t)
        }
        var tl = Timeline(name: "x", frameDuration: Time(1, 30), tracks: tracks)
        tl.inOut = inOut
        return (tl, first!)
    }

    private func useTake(_ tl: Timeline, _ id: Clip.ID) -> TimelineMenuItem? {
        TimelineContextMenu.items(timeline: tl, selection: [id], clipboardHasClips: false).first { $0.action == .useTake }
    }

    @Test func enabledWithRangeAndOtherTake() throws {
        let (tl, c) = try timeline(takes: 2, inOut: TimeRange(start: Time(2, 1), duration: Time(3, 1)))
        #expect(useTake(tl, c.id)?.isEnabled == true)
    }

    @Test func disabledWithoutRangeOrOtherTake() throws {
        let (noRange, c1) = try timeline(takes: 2, inOut: nil)
        #expect(useTake(noRange, c1.id)?.isEnabled == false)
        let (single, c2) = try timeline(takes: 1, inOut: TimeRange(start: .zero, duration: Time(3, 1)))
        #expect(useTake(single, c2.id)?.isEnabled == false)
    }
}
