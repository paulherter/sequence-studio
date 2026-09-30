import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

@Suite struct TrackStretchTests {
    private func timeline(video: Int = 1, audio: Int = 1) -> Timeline {
        Timeline(name: "t", frameDuration: fd,
                 tracks: (0..<video).map { _ in Track(kind: .video) } + (0..<audio).map { _ in Track(kind: .audio) })
    }

    @Test func waterFillingRespectsCapsAndSum() {
        let h = TimelineGeometry.stretchedHeights(base: [32, 26], caps: [200, 120], weights: [3, 2], extra: 100)
        #expect(abs(h.reduce(0, +) - 158) < 0.01)
        #expect(zip(h, [140, 100]).allSatisfy { $0 <= $1 + 0.001 })
        // Not enough room: only the headroom is used.
        let full = TimelineGeometry.stretchedHeights(base: [32, 26], caps: [200, 120], weights: [3, 2], extra: 1000)
        #expect(full == [200, 120])
    }

    @Test func noViewportHeightMeansNoStretch() {
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        let rows = g.rows(for: timeline())
        #expect(rows.map(\.height) == [32, 26])
    }

    @Test func rowsFillDefaultPanelHeight() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        let t = timeline(video: 2, audio: 2)
        for panel: CGFloat in [260, 300, 360] {
            g.viewportHeight = panel
            let rows = g.rows(for: t)
            #expect(abs(rows.last!.maxY - panel) < 0.5)               // no dead space below the last row
            #expect(rows.allSatisfy { $0.height >= 20 })
        }
        g.viewportHeight = 1000                                        // huge panel: capped, the rest is empty
        #expect(g.rows(for: t).last!.maxY < 1000)
    }

    @Test func allTracksGrowEvenlyPerKind() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        let t = timeline(video: 4, audio: 4)
        let small = g.rows(for: t).map(\.height)
        #expect(small == [32, 32, 32, 32, 26, 26, 26, 26])
        g.viewportHeight = 420
        let rows = g.rows(for: t)
        #expect(abs(rows.last!.maxY - 420) < 0.5)
        #expect(Set(rows.filter { $0.kind == .video }.map { Int($0.height.rounded()) }).count == 1)
        #expect(Set(rows.filter { $0.kind == .audio }.map { Int($0.height.rounded()) }).count == 1)
        #expect(rows.allSatisfy { $0.height > (($0.kind == .video) ? 32 : 26) })
    }

    @Test func smallPanelKeepsDefaultsAndScrolls() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        g.viewportHeight = 60
        #expect(g.rows(for: timeline()).map(\.height) == [32, 26])
    }

    @Test func userHeightsStayFixed() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        let t = timeline()
        g.heightOverrides[t.tracks[0].id] = 50
        g.viewportHeight = 300
        let rows = g.rows(for: t)
        #expect(rows[0].height == 50)
        #expect(rows[1].height > 26)
    }

    @Test func hitTestUsesStretchedRows() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        g.viewportHeight = 300
        let t = timeline()
        let rows = g.rows(for: t)
        if case .gap(let id, _) = g.hitTest(CGPoint(x: 400, y: rows[1].maxY - 2), in: t) { #expect(id == t.tracks[1].id) } else { Issue.record("not a gap") }
    }
}
