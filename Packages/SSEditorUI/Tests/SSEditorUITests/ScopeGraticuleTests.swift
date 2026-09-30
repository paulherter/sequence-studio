import Foundation
import Testing
import SSRender
@testable import SSEditorUI

@Suite struct ScopeGraticuleTests {
    @Test func ireLines() {
        let l = ScopeGraticule.ireLines
        #expect(l.map(\.ire) == Array(stride(from: 0, through: 100, by: 10)))
        #expect(l.first!.y == 1 && l.last!.y == 0)          // 0 IRE bottom, 100 IRE top
        #expect(abs(l[5].y - 0.5) < 1e-12)                  // 50 IRE
        #expect(l.filter(\.isMajor).map(\.ire) == [0, 50, 100])
    }

    @Test func vectorscopeTargetsMatchBT709() {
        let t = ScopeGraticule.vectorscopeTargets(amplitude: 0.75)
        #expect(t.map(\.name) == ["R", "Mg", "B", "Cy", "G", "Yl"])
        for target in t {
            let c = ScopesReference.cbcr(SIMD3<Float>(Float(target.rgb.x), Float(target.rgb.y), Float(target.rgb.z)))
            #expect(abs(target.center.x - (Double(c.x) + 0.5)) < 1e-6)
            #expect(abs(target.center.y - (0.5 - Double(c.y))) < 1e-6)
        }
        // 100% red: Cr = +0.5 (straight up), Cb = -0.2126/1.8556.
        let r = ScopeGraticule.vectorscopeTargets(amplitude: 1)[0]
        #expect(abs(r.center.y - 0.0) < 1e-9)
        #expect(abs(r.center.x - (0.5 - 0.2126 / 1.8556)) < 1e-9)
        // 75 % is three quarters of the way from the centre.
        let r75 = t[0]
        #expect(abs((0.5 - r75.center.y) - 0.75 * 0.5) < 1e-9)
        // Blue is right of centre, Yellow is left of centre.
        #expect(t[2].center.x > 0.5 && t[5].center.x < 0.5)
    }

    @Test func skinToneLine() {
        #expect(ScopeGraticule.skinToneAngleDegrees == 123)
        let e = ScopeGraticule.skinToneLineEnd
        #expect(e.x < 0.5 && e.y < 0.5)                      // upper left of centre
        #expect(abs(((e.x - 0.5) * (e.x - 0.5) + (e.y - 0.5) * (e.y - 0.5)).squareRoot() - 0.5) < 1e-9)
        // Lies between R (angle ~103 deg) and Yl (~167 deg).
        func angle(_ p: SIMD2<Double>) -> Double { atan2(0.5 - p.y, p.x - 0.5) * 180 / .pi }
        let t = ScopeGraticule.vectorscopeTargets(amplitude: 1)
        #expect(angle(t[0].center) < 123 && angle(t[5].center) > 123)
    }

    @Test func plotRects() {
        let v = ScopeGraticule.plotRect(.vectorscope, in: (width: 300, height: 200), labelMargin: 28)
        #expect(v.width == v.height && v.height == 200 && v.x == 50)
        let w = ScopeGraticule.plotRect(.waveform, in: (width: 300, height: 200), labelMargin: 28)
        #expect(w.x == 28 && w.width == 272 && w.height == 200)
        let h = ScopeGraticule.plotRect(.histogram, in: (width: 300, height: 200), labelMargin: 28)
        #expect(h.x == 0 && h.width == 300)
    }

    @Test func histogramVerticals() {
        #expect(ScopeGraticule.histogramVerticals == [0, 0.25, 0.5, 0.75, 1])
    }
}
