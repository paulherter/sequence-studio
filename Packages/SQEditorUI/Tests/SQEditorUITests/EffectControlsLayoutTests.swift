import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@Suite struct EffectControlsLayoutTests {
    @Test func collapsedSectionHidesRows() {
        let rows = EffectControlsLayout.rows(sections: [.motion, .opacity], collapsed: [.motion], expanded: [])
        #expect(rows.map(\.kind) == [.section(.motion), .section(.opacity), .property(.opacity)])
        #expect(rows[1].y == Theme.Metrics.effectControlsRow)
    }

    @Test func expandedPropertyInsertsGraphBelow() {
        let rows = EffectControlsLayout.rows(sections: [.opacity], collapsed: [], expanded: [.opacity])
        #expect(rows.map(\.kind) == [.section(.opacity), .property(.opacity), .graph(.opacity)])
        #expect(rows[2].y == rows[1].y + rows[1].height)
        #expect(rows[2].height == EffectControlsLayout.graphHeight(.opacity))
        #expect(EffectControlsLayout.totalHeight(rows) == rows[2].y + rows[2].height)
    }

    @Test func vectorGraphIsTallerThanScalar() {
        #expect(EffectControlsLayout.graphHeight(.position) > EffectControlsLayout.graphHeight(.rotation))
        #expect(EffectControlsLayout.graphHeight(.scale) == EffectControlsLayout.graphHeight(.rotation))
    }

    @Test func roundedCornersHasRadiusRow() {
        let rows = EffectControlsLayout.rows(sections: [.roundedCorners], collapsed: [], expanded: [])
        #expect(rows.map(\.kind) == [.section(.roundedCorners), .property(.cornerRadius)])
    }

    @Test func rowAt() {
        let rows = EffectControlsLayout.rows(sections: [.motion], collapsed: [], expanded: [])
        #expect(EffectControlsLayout.row(at: 30, in: rows)?.kind == .property(.position))
        #expect(EffectControlsLayout.row(at: -1, in: rows) == nil)
        #expect(EffectControlsLayout.row(at: 10_000, in: rows) == nil)
    }
}

@Suite struct KeyframeLaneGeometryTests {
    let fd = Time(1, 30)
    @Test func mapsEndsAndMiddle() {
        let g = KeyframeLaneGeometry(width: 120, duration: Time(10, 1), inset: 10)
        #expect(g.x(for: .zero) == 10)
        #expect(g.x(for: Time(10, 1)) == 110)
        #expect(g.x(for: Time(5, 1)) == 60)
    }

    @Test func timeAtSnapsToFramesAndClamps() {
        let g = KeyframeLaneGeometry(width: 120, duration: Time(10, 1), inset: 10)
        #expect(g.time(at: 60, frameDuration: fd) == Time(5, 1))
        #expect(g.time(at: -50, frameDuration: fd) == .zero)
        #expect(g.time(at: 900, frameDuration: fd) == Time(10, 1))
        let t = g.time(at: 61, frameDuration: fd)
        #expect(t == t.snapped(to: fd))
    }

    @Test func degenerateDurationDoesNotCrash() {
        let g = KeyframeLaneGeometry(width: 120, duration: .zero, inset: 10)
        #expect(g.x(for: .zero) == 10)
        #expect(g.time(at: 50, frameDuration: fd) == .zero)
    }

    @Test func hitTestPicksNearestWithinRadius() {
        let g = KeyframeLaneGeometry(width: 120, duration: Time(10, 1), inset: 10)
        let times = [Time.zero, Time(5, 1)]
        #expect(g.nearestIndex(toX: 62, in: times, radius: 6) == 1)
        #expect(g.nearestIndex(toX: 80, in: times, radius: 6) == nil)
    }
}
