import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@Suite struct KeyGlyphTests {
    func key(_ t: Int64, _ v: Double, _ i: Interpolation = .linear, inH: EaseHandle = .linear, outH: EaseHandle = .linear) -> Keyframe<Double> {
        Keyframe(time: Time(t, 1), value: v, interpolation: i, inHandle: inH, outHandle: outH)
    }
    let ease = EaseHandle(dx: 0.6, dy: 0)

    @Test func linearKeysAreDiamonds() {
        let g = KeyGlyph.glyphs(of: KeyframeTrack(keys: [key(0, 0), key(1, 1), key(2, 0)])).map(\.glyph)
        #expect(g.allSatisfy { $0 == .linear })
    }

    @Test func leftHalfIsIncomingRightHalfOutgoing() {
        // a: ease out only; b: ease in only (from a), linear out; c: end.
        let a = key(0, 0, .bezier, outH: ease)
        let b = key(1, 1, .linear, inH: ease)
        let c = key(2, 0)
        let g = KeyGlyph.glyphs(of: KeyframeTrack(keys: [a, b, c])).map(\.glyph)
        #expect(g[0] == KeyGlyph(incoming: .eased, outgoing: .eased))   // first key mirrors its only side
        #expect(g[1] == KeyGlyph(incoming: .eased, outgoing: .linear))
        #expect(g[2] == KeyGlyph(incoming: .linear, outgoing: .linear))
    }

    @Test func holdIsSquareOnTheOutgoingSideAndIncomingOfNext() {
        let g = KeyGlyph.glyphs(of: KeyframeTrack(keys: [key(0, 0, .hold), key(1, 1), key(2, 2)])).map(\.glyph)
        #expect(g[0].outgoing == .hold)
        #expect(g[1] == KeyGlyph(incoming: .hold, outgoing: .linear))
    }

    @Test func bezierWithLinearHandlesStaysDiamond() {
        let g = KeyGlyph.glyphs(of: KeyframeTrack(keys: [key(0, 0, .bezier), key(1, 1)])).map(\.glyph)
        #expect(g[0] == .linear)
    }

    @Test func summaryMergesPerSide() {
        let m = KeyGlyph.merged([.linear, KeyGlyph(incoming: .linear, outgoing: .eased)])
        #expect(m == KeyGlyph(incoming: .linear, outgoing: .eased))
        let h = KeyGlyph(incoming: .hold, outgoing: .hold)
        #expect(KeyGlyph.merged([h, h]) == h)
    }

    @Test func shapeIsOneSolidShapePerKey() {
        #expect(KeyGlyph.linear.shape == .diamond)
        #expect(KeyGlyph(incoming: .eased, outgoing: .linear).shape == .circle)     // any easing, either side
        #expect(KeyGlyph(incoming: .linear, outgoing: .eased).shape == .circle)
        #expect(KeyGlyph(incoming: .eased, outgoing: .eased).shape == .circle)
        #expect(KeyGlyph(incoming: .hold, outgoing: .hold).shape == .square)
        #expect(KeyGlyph(incoming: .eased, outgoing: .hold).shape == .square)       // hold wins
    }

    @Test func shapesAreCentredAndSimilarInSize() {
        let c = CGPoint(x: 50, y: 12)
        for s in [KeyShape.diamond, .circle, .square] {
            let b = s.bounds(at: c, size: 13)
            #expect(abs(b.midX - 50) < 1e-9 && abs(b.midY - 12) < 1e-9)
            #expect(b.width >= 10 && b.width <= 13)
        }
        #expect(KeyShape.diamond.corners(at: c, size: 13).count == 4)
        #expect(KeyShape.square.corners(at: c, size: 13).count == 4)
        #expect(KeyShape.circle.corners(at: c, size: 13).isEmpty)
    }
}

@Suite struct KeyframeRulerTests {
    @Test func ticksCoverTheClipRangeAndLabelMajors() {
        let fd = Time(1, 30)
        let ticks = KeyframeRulerLayout.ticks(width: 600, duration: Time(10, 1), frameDuration: fd, nominalFPS: 30)
        #expect(ticks.first?.local == .zero && ticks.last!.local <= Time(10, 1))
        #expect(ticks.first?.major == true && ticks.contains { $0.major && $0.local > .zero })
    }

    @Test func seekIsFrameSnappedAndClampedToTheClip() {
        let fd = Time(1, 30), start = Time(5, 1), dur = Time(10, 1)
        let geo = KeyframeLaneGeometry(width: 600, duration: dur)
        #expect(KeyframeRulerLayout.seekTime(atX: -50, width: 600, clipStart: start, duration: dur, frameDuration: fd) == start)
        #expect(KeyframeRulerLayout.seekTime(atX: 9999, width: 600, clipStart: start, duration: dur, frameDuration: fd) == start + dur)
        let mid = KeyframeRulerLayout.seekTime(atX: geo.x(for: Time(5, 1)), width: 600, clipStart: start, duration: dur, frameDuration: fd)
        #expect(mid == Time(10, 1))
    }
}
