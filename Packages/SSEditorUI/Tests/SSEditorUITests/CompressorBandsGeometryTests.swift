import Testing
import CoreGraphics
@testable import SSEditorUI

@Suite struct CompressorBandsGeometryTests {
    let g = CompressorBandsGeometry(width: 600)

    @Test func logAxisEndpointsAndRoundTrip() {
        #expect(abs(g.x(forHz: 20)) < 1e-9)
        #expect(abs(g.x(forHz: 20000) - 600) < 1e-9)
        #expect(abs(g.x(forHz: 632.455532) - 300) < 0.01) // geometric mean
        for hz in [50.0, 120, 900, 4500, 16000] {
            #expect(abs(g.hz(forX: g.x(forHz: hz)) - hz) < 1e-6 * hz)
        }
    }

    @Test func bandRangesTileTheAxis() {
        let r = g.bandRanges(crossoversHz: [120, 900, 4500])
        #expect(r.count == 4)
        #expect(r[0].lowerBound == 0 && abs(r[3].upperBound - 600) < 1e-9)
        for i in 0..<3 { #expect(r[i].upperBound == r[i + 1].lowerBound) }
    }

    @Test func hitTestPicksNearestHandle() {
        let c = [120.0, 900, 4500]
        #expect(g.handleIndex(at: g.x(forHz: 900) + 3, crossoversHz: c) == 1)
        #expect(g.handleIndex(at: g.x(forHz: 900) + 30, crossoversHz: c) == nil)
    }

    @Test func dragKeepsOrder() {
        let c = [120.0, 900, 4500]
        let hz = g.draggedHz(index: 0, toX: g.x(forHz: 3000), crossoversHz: c)
        #expect(hz < 900 && hz > CrossoverRules.minHz)
        #expect(g.draggedHz(index: 2, toX: -50, crossoversHz: c) > 900)
    }

    @Test func gainReductionBarHeight() {
        #expect(CompressorBandsGeometry.barFraction(gainReductionDB: 0) == 0)
        #expect(CompressorBandsGeometry.barFraction(gainReductionDB: 12) == 0.5)
        #expect(CompressorBandsGeometry.barFraction(gainReductionDB: 99) == 1)
        #expect(CompressorBandsGeometry.barFraction(gainReductionDB: -3) == 0)
    }
}
