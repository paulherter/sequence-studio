import Foundation
import SQUIKit
import Testing
@testable import SQDrawKit

@Suite("LoudnessMeterCanvas") struct LoudnessMeterCanvasTests {
    @Test func holdKeepsPeakAndResetClearsIt() {
        var m = LoudnessMeter()
        m.update(LoudnessReading(shortTermLUFS: -14, truePeakDB: -3), at: 0)
        m.update(LoudnessReading(shortTermLUFS: -15, truePeakDB: -20), at: 0.5)
        #expect(m.peakHold.valueDB == -3)
        m.resetPeak()
        #expect(m.peakHold.valueDB == -.infinity)
    }

    @Test func clearLiveKeepsIntegrated() {
        var m = LoudnessMeter()
        m.update(LoudnessReading(momentaryLUFS: -10, shortTermLUFS: -12, integratedLUFS: -16), at: 0)
        m.clearLive()
        #expect(m.reading.momentaryLUFS == nil && m.reading.shortTermLUFS == nil && m.reading.integratedLUFS == -16)
    }

    @Test func overTargetBarsTurnYellowInBothStyles() {
        let t = DrawTheme()
        for style in [LoudnessMeter.Style.rows, .columns] {
            var m = LoudnessMeter(style: style)
            m.update(LoudnessReading(momentaryLUFS: -6, shortTermLUFS: -20, integratedLUFS: -20, truePeakDB: 0.5), at: 0)
            var c = Canvas(width: 300, height: 200, atlas: nil, scale: 1)
            let w: CGFloat = style == .rows ? 300 : LoudnessMeter.columnsWidth
            m.draw(&c, in: CGRect(x: 0, y: 0, width: w, height: 200), theme: t)
            let colors = Set(c.list.quads.map { (q: DrawQuad) -> DrawColor in q.color })
            let red = DrawTheme.color(t.palette.red)
            #expect(colors.contains(t.yellow) && colors.contains(t.accent) && colors.contains(red), "\(style)")
        }
    }
}
