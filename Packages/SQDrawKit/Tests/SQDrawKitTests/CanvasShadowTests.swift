import Foundation
import Testing
@testable import SQDrawKit

@Suite struct CanvasShadowTests {
    static func picture(opaqueAbove: Bool) -> (DrawList, RGBAImage) {
        var c = Canvas(width: 300, height: 220, atlas: nil, scale: 1)
        let card = CGRect(x: 60, y: 40, width: 180, height: 120)
        c.shadow(roundedRect: card, radius: 10, blur: 24, dy: 8, DrawColor(0, 0, 0, 0.35), opaqueAbove: opaqueAbove)
        c.fill(roundedRect: card, radius: 10, DrawColor(hex: 0x2A2A2E))
        return (c.list, SoftwareRenderer.render(c.list, width: 300, height: 220, clear: DrawColor(hex: 0x505050), atlas: nil))
    }

    /// Under an opaque card the shadow layers are rings: the same picture, no full-card fills.
    @Test func ringShadowUnderAnOpaqueCardLooksTheSame() {
        let (full, a) = Self.picture(opaqueAbove: false)
        let (rings, b) = Self.picture(opaqueAbove: true)
        #expect(rings.quads.filter { $0.stroke > 0 }.count == 24 && full.quads.allSatisfy { $0.stroke == 0 })
        let worst = zip(a.pixels, b.pixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2)
    }
}
