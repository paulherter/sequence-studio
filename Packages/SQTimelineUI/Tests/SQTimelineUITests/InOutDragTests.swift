import AppKit
import CoreGraphics
import Testing
import SQCore
@testable import SQTimelineUI

struct InOutDragTests {
    private let fd = Time(1, 24)
    private var geometry: TimelineGeometry { TimelineGeometry(frameDuration: fd, pointsPerFrame: 4) }
    private var range: TimeRange { TimeRange(start: fd * 48, end: fd * 96) }

    @Test func partsByPosition() {
        let g = geometry
        let x0 = g.x(for: range.start), x1 = g.x(for: range.end)
        #expect(InOutDrag.part(atX: x0 + 1, range: range, geometry: g) == .start)
        #expect(InOutDrag.part(atX: x1 - 1, range: range, geometry: g) == .end)
        #expect(InOutDrag.part(atX: (x0 + x1) / 2, range: range, geometry: g) == .body)
        #expect(InOutDrag.part(atX: x0 - 100, range: range, geometry: g) == nil)
        #expect(InOutDrag.part(atX: x1 + 100, range: range, geometry: g) == nil)
    }

    @Test func trimmingKeepsOneFrame() {
        let r = InOutDrag.target(part: .start, original: range, downTime: .zero, time: fd * 500, frameDuration: fd)
        #expect(r.end == range.end && r.duration == fd)
        let e = InOutDrag.target(part: .end, original: range, downTime: .zero, time: .zero, frameDuration: fd)
        #expect(e.start == range.start && e.duration == fd)
        #expect(InOutDrag.target(part: .start, original: range, downTime: .zero, time: fd * -9, frameDuration: fd).start == .zero)
    }

    @Test func bodyMovesWithoutResizingAndStopsAtZero() {
        let m = InOutDrag.target(part: .body, original: range, downTime: fd * 60, time: fd * 70, frameDuration: fd)
        #expect(m.start == fd * 58 && m.duration == range.duration)
        let z = InOutDrag.target(part: .body, original: range, downTime: fd * 60, time: fd * -100, frameDuration: fd)
        #expect(z.start == .zero && z.duration == range.duration)
    }
}

struct RulerMenuEntryTests {
    @Test func entriesCarryTheMappedKeysAndClearNeedsARange() {
        let map = CommandMap.premiereDefault
        let none = RulerRangeEntry.entries(hasInOut: false, map: map)
        #expect(none.map(\.title) == ["Mark In", "Mark Out", "Remove In and Out"])
        #expect(none.map(\.isEnabled) == [true, true, false])
        #expect(none[0].key == "i" && none[1].key == "o")
        #expect(none[2].key == "x" && none[2].modifiers == [.option])
        #expect(RulerRangeEntry.entries(hasInOut: true, map: map)[2].isEnabled)
    }
}
