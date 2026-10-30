import Foundation
import Testing
import SQCore
import SQDrawKit
import SQUIKit
@testable import SQDrawMonitor

@MainActor
@Suite struct MonitorTipTests {
    private func tip(_ p: MonitorPanel, over r: CGRect) -> String? {
        let hover = HostHover()
        HostHover.$current.withValue(hover) {
            let e = InputEvent.mouseMoved(x: Float(r.midX), y: Float(r.midY))
            hover.beginEvent(e)
            _ = p.handle(e)
            hover.endEvent(e, now: 0)
        }
        return hover.tooltip.text
    }

    @Test func transportButtonsOfferTheMacTips() throws {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        m.duration = Time(250, 25)
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        let play = try #require(p.footer.buttons.first { $0.0 == .playPause }?.1)
        #expect(tip(p, over: play)?.hasPrefix("Play") == true)
        m.isPlaying = true
        let mark = try #require(p.footer.buttons.first { $0.0 == .markIn }?.1)
        #expect(tip(p, over: mark) == KeyboardListing.tip("Mark In", .markIn))
        #expect(MonitorAction.playPause.buttonTitle(playing: true) == "Pause")
    }
}
