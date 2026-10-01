import Foundation
import Testing
import SQCore
@testable import SQEditorUI

/// The glyph must follow the interpolation the user chose in the right-click menu.
@Suite struct KeyGlyphChoiceTests {
    func track() -> (KeyframeTrack<Double>, [Keyframe<Double>]) {
        let ks = [Keyframe(time: Time(0, 1), value: 0.0), Keyframe(time: Time(2, 1), value: 5.0), Keyframe(time: Time(4, 1), value: 9.0)]
        return (KeyframeTrack(keys: ks), ks)
    }

    @Test func easeInOnKeyWithLinearNeighbourReadsAsCircle() {
        var (tr, ks) = track()
        tr.apply(KeyInterpolationChoice.easeIn.curve, to: [ks[1].id], side: .in)
        let g = KeyGlyph.glyphs(of: tr)
        #expect(g[1].glyph.incoming == .eased)
        #expect(g[1].glyph.shape == .circle)
    }

    @Test func easeOutShowsOnTheOutgoingSide() {
        var (tr, ks) = track()
        tr.apply(KeyInterpolationChoice.easeOut.curve, to: [ks[0].id], side: .out)
        let g = KeyGlyph.glyphs(of: tr)
        #expect(g[0].glyph.outgoing == .eased)
        #expect(g[1].glyph.incoming == .linear)       // the neighbour's in side did not change
    }

    @Test func bezierIsACircleHoldIsASquareLinearIsADiamond() {
        var (tr, ks) = track()
        let all = Set(ks.map(\.id))
        tr.apply(KeyInterpolationChoice.bezier.curve, to: all)
        #expect(KeyGlyph.glyphs(of: tr).allSatisfy { $0.glyph.shape == .circle })
        tr.apply(KeyInterpolationChoice.hold.curve, to: [ks[0].id], side: .out)
        #expect(KeyGlyph.glyphs(of: tr)[0].glyph.shape == .square)
        tr.apply(KeyInterpolationChoice.linear.curve, to: all)
        #expect(KeyGlyph.glyphs(of: tr).allSatisfy { $0.glyph.shape == .diamond })
    }
}
