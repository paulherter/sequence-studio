import Foundation
import SQUIKit
import Testing
@testable import SQDrawKit

@Suite("AudioMeterCanvas") struct AudioMeterCanvasTests {
    @Test func readoutFollowsHeldPeak() {
        var m = AudioMeter()
        #expect(m.readout == "\u{2013}")
        m.update(peaks: [0.5, 0.25], at: 0)
        #expect(m.readout == "\u{2212}6.0")
        m.silence()
        #expect(m.readout == "\u{2013}")
    }

    @Test func monoFoldsToLoudestSide() {
        var m = AudioMeter()
        m.isMono = true
        m.update(peaks: [0.1, 1.0], at: 0)
        #expect(m.channels.count == 1 && m.channels[0].clipped)
        #expect(m.channelNames == ["M"] && m.channels(forBar: 0) == [0, 1])
    }

    @Test func barsFallUntilSettled() {
        var m = AudioMeter()
        m.update(peaks: [1, 1], at: 0)
        let early = m.tick(at: 1), late = m.tick(at: 10)
        #expect(!early && late)
        #expect(m.channels[0].clipped)   // the latch stays
        m.resetClip()
        #expect(!m.channels[0].clipped)
    }

    @Test func clicksMatchMacZones() {
        let m = AudioMeter()
        #expect(m.hit(CGPoint(x: 20, y: 10), height: 300) == .resetClip)
        #expect(m.hit(CGPoint(x: 10, y: 290), height: 300) == .channel(0))
        #expect(m.hit(CGPoint(x: 18, y: 290), height: 300) == .channel(1))
        #expect(m.hit(CGPoint(x: 10, y: 150), height: 300) == .none)
    }

    @Test func drawsGreenLevelAndRedReadoutWhenClipped() {
        var m = AudioMeter()
        m.update(peaks: [1, 0.1], at: 0)
        var c = Canvas(width: 48, height: 300, atlas: nil, scale: 1)
        m.draw(&c, in: CGRect(x: 0, y: 0, width: 48, height: 300), theme: DrawTheme(), labels: [.soloed, .muted])
        let colors = Set(c.list.quads.map { (q: DrawQuad) -> DrawColor in q.color })
        let red = DrawTheme.color(DrawTheme().palette.red)
        #expect(colors.contains(DrawColor(hex: 0x30D158)))
        #expect(colors.contains(red))
    }
}
