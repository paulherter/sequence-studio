import Foundation
import Testing
import SQCore
import SQDrawKit
@testable import SQDrawMonitor

@MainActor
@Suite struct MonitorHeaderTipsTests {
    func panel(_ mode: MonitorMode) -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: mode)
        m.duration = Time(250, 25)
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        return p
    }

    @Test func headerPopupsCarryTheMacTips() {
        let p = panel(.program)
        #expect(p.headerTip(.zone) == "Platform Safe Zone")
        #expect(p.headerTip(.zoom) == "Zoom: Fit, or 10 to 800 %")
        #expect(p.headerTip(.quality) == "Playback Quality")
        #expect(p.headerTip(.options) == "More")
        #expect(p.headerTip(.content) == "Open Sequences")
        #expect(panel(.source).headerTip(.content) == "Source Clips")
    }

    @Test func movingOverTheOptionsButtonOffersItsTip() throws {
        let p = panel(.program)
        let r = try #require(p.headerControls.first { $0.0 == .options }?.1)
        #expect(p.headerTip(at: CGPoint(x: r.midX, y: r.midY)) == "More")
        #expect(p.headerTip(at: CGPoint(x: -5, y: -5)) == nil)
        let hover = HostHover()
        let e = InputEvent.mouseMoved(x: Float(r.midX), y: Float(r.midY))
        HostHover.$current.withValue(hover) {
            hover.beginEvent(e)
            _ = p.handle(e)
            hover.endEvent(e, now: 1)
        }
        #expect(hover.tooltip.text == "More")
    }
}
