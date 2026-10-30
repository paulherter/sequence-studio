import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The drawn Effect Controls offer their `help(at:)` to the host's tooltip seam on every move.
@MainActor @Suite struct EffectControlsTipTests {
    @Test func moveOffersTheRowHelp() throws {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let m = EffectControlsModel()
        m.setClip(c)
        m.collapsedSections = []
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 420, height: 2000)
        let points = stride(from: 0.0, to: 2000.0, by: 4.0).flatMap { y in
            stride(from: 0.0, to: 420.0, by: 6.0).map { CGPoint(x: $0, y: y) } }
        let at = try #require(points.first { p.help(at: $0) != nil })
        let hover = HostHover()
        HostHover.$current.withValue(hover) {
            let e = InputEvent.mouseMoved(x: Float(at.x), y: Float(at.y))
            hover.beginEvent(e)
            p.handle(e, scale: 1)
            hover.endEvent(e, now: 0)
        }
        #expect(hover.tooltip.text == p.help(at: at))
    }
}
