import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@Suite struct EffectControlsLayoutTests {
    @Test func collapsedSectionHidesRows() {
        let rows = EffectControlsLayout.rows(sections: [.motion, .opacity], collapsed: [.motion], expanded: [])
        #expect(rows.map(\.kind) == [.section(.motion), .section(.opacity), .property(.opacity)])
        #expect(rows[1].y == ControlsMetrics.section + ControlsMetrics.sectionGap)
    }

    @Test func expandedPropertyInsertsGraphBelow() {
        let rows = EffectControlsLayout.rows(sections: [.opacity], collapsed: [], expanded: [.opacity])
        #expect(rows.map(\.kind) == [.section(.opacity), .property(.opacity), .graph(.opacity)])
        #expect(rows[2].y == rows[1].y + rows[1].height)
        #expect(rows[2].height == EffectControlsLayout.graphHeight(.opacity))
        #expect(EffectControlsLayout.totalHeight(rows) == rows[2].y + rows[2].height)
    }

    // Variant A: every opened row is one 120 pt graph row, vectors too.
    @Test func openedRowIsOneGraphHeight() {
        #expect(EffectControlsLayout.graphHeight(.position) == ControlsMetrics.graph)
        #expect(EffectControlsLayout.graphHeight(.rotation) == ControlsMetrics.graph)
        #expect(ControlsMetrics.graph == 120 && SpeedGraphGeometry.defaultHeight == ControlsMetrics.graph)
    }

    // Design v9 (`--h-row`): section headers and rows share one height (26) whatever the row holds, and the sections of
    // the Controls list touch (`.ksec`, a line between them, no gap). Heights from `ControlsGrid`.
    @Test func rowHeightsFollowTheGrid() {
        let rows = EffectControlsLayout.rows(sections: [.motion, .speed, .volume], collapsed: [], expanded: [], blendModeRow: true)
        #expect(ControlsGrid.headerHeight == 26 && ControlsGrid.rowHeight == 26 && ControlsMetrics.sectionGap == 0)
        for r in rows {
            if case .section = r.kind { #expect(r.height == ControlsGrid.headerHeight) } else { #expect(r.height == ControlsGrid.rowHeight) }
        }
        // Rows of one section touch, and so do two sections.
        for (a, b) in zip(rows, rows.dropFirst()) {
            if case .section = b.kind { #expect(b.y - (a.y + a.height) == ControlsMetrics.sectionGap) } else { #expect(b.y == a.y + a.height) }
        }
    }

    // Rows holding a capsule (popup / button, 22 high) keep the v9 row pitch: two stacked controls are 4 pt apart.
    @Test func capsuleRowsKeepAGapBetweenPills() {
        #expect(ControlsGrid.rowHeight - ControlsGrid.controlHeight == Theme.Spacing.xs)
        #expect(Theme.Metrics.quietButton == ControlsGrid.controlHeight)
        let rows = EffectControlsLayout.rows(sections: [.motion, .opacity], collapsed: [], expanded: [], blendModeRow: true)
        for r in rows where r.kind == .blendMode { #expect(r.height - Theme.Metrics.quietButton == Theme.Spacing.xs) }
        let id = ClipEffect.ID()
        let sections: [EffectSection] = [.effect(id, kind: ClipEffect.stabilizeKind)]
        let st = EffectControlsLayout.rows(sections: sections, collapsed: [], expanded: [], stabilizers: [id: .standard])
        let pills = st.filter { if case .stabilizeAnalyze = $0.kind { return true }; if case .property(let p) = $0.kind, case .fx(_, _, ClipEffect.stabilizeMethodKey) = p { return true }; return false }
        #expect(pills.count == 2)
        for r in pills { #expect(r.height - Theme.Metrics.quietButton == Theme.Spacing.xs) }
    }

    @Test func roundedCornersHasRadiusRow() {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        c.roundedCorners = .roundedCorners()
        let section = EffectSection.roundedCorners(of: c)
        let rows = EffectControlsLayout.rows(sections: [section], collapsed: [], expanded: [])
        #expect(rows.map(\.kind) == [.section(section), .property(.radius(of: c))])
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

    @Test func valueColumnsShareOneLeftEdge() {
        #expect(ControlsMetrics.valueColumn(0) == ControlsMetrics.valueX)
        #expect(ControlsMetrics.valueColumn(1) - ControlsMetrics.valueColumn(0) == ControlsMetrics.valueWidth + ControlsGrid.gap)
        #expect(ControlsMetrics.valueX > ControlsMetrics.labelX)
    }
}
