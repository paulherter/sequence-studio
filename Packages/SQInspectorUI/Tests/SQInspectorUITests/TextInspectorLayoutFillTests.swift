import Foundation
import Testing
import SQText
@testable import SQInspectorUI

/// Shrink to box, list and gradient fill switches of the Text inspector.
@MainActor @Suite struct TextInspectorLayoutFillTests {
    func make() -> TextInspectorModel {
        TextInspectorModel(style: TextStyle(fontName: "Helvetica", size: 40, color: .white),
                           animations: AnimationSet(in: nil, out: nil), library: .builtIn, fontFamilies: { ["Helvetica"] })
    }

    @Test func autoFitAndListToggle() {
        let m = make()
        m.setAutoFit(true)
        #expect(m.style.autoFit == true && m.autoFitEnabled)
        m.setAutoFit(false)
        #expect(m.style.autoFit == nil)
        m.setList(.numbered)
        #expect(m.style.list == .numbered)
        m.setList(nil)
        #expect(m.style.list == nil)
    }

    @Test func gradientStartsFromTheFillAndIsRemembered() throws {
        let m = make()
        m.setGradientEnabled(true)
        let g = try #require(m.style.gradient)
        #expect(g.start == .white && g.end == .black && g.angle == 90)
        m.setGradientAngle(45)
        m.setGradientEnd(RGBAColor(red: 1, green: 0, blue: 0))
        m.setGradientEnabled(false)
        #expect(m.style.gradient == nil)
        m.setGradientEnabled(true)
        #expect(m.style.gradient?.angle == 45 && m.style.gradient?.end == RGBAColor(red: 1, green: 0, blue: 0))
    }
}
