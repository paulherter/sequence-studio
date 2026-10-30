import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ blurs: [(Double, Bool?)]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
    for (v, edge) in blurs {
        let id = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        c.setParameter(id, ClipEffect.blurrinessKey, to: v)
        if let edge { c.setParameter(id, ClipEffect.repeatEdgePixelsKey, to: edge ? 1 : 0) }
    }
    return c
}

@Suite struct BlurRepeatEdgeTests {
    @Test func catalogHasRepeatEdgePixelsCheckboxOffByDefault() {
        let p = EffectCatalog.param(ClipEffect.gaussianBlurKind, ClipEffect.repeatEdgePixelsKey)
        #expect(p != nil && p?.kind == .checkbox && p?.defaultValue == 0)
        #expect(p?.title == "Repeat Edge Pixels")
    }

    @Test func defaultBlurDoesNotRepeatEdges() {
        let e = clip([(5, nil)]).effects(at: s(1))
        #expect(e.segments.count == 2 && e.segments[0].blurAfter == ClipEffect.gaussianSigma(blurriness: 5) && !e.segments[0].blurRepeatsEdges)
        #expect(e == ClipEffects(blur: ClipEffect.gaussianSigma(blurriness: 5)))                    // existing looks unchanged
    }

    @Test func repeatEdgePixelsIsCarriedOnTheBlurSegment() {
        let e = clip([(5, true)]).effects(at: s(1))
        #expect(e.segments.count == 2 && e.segments[0].blurAfter == ClipEffect.gaussianSigma(blurriness: 5) && e.segments[0].blurRepeatsEdges)
    }

    @Test func twoBlursMergeOnlyWithTheSameEdgeMode() {
        let same = clip([(3, true), (4, true)]).effects(at: s(1))
        #expect(same.segments.count == 2 && abs(same.segments[0].blurAfter - ClipEffect.gaussianSigma(blurriness: 5)) < 1e-12 && same.segments[0].blurRepeatsEdges)
        let mixed = clip([(3, true), (4, false)]).effects(at: s(1))
        #expect(mixed.segments.count == 3 && mixed.segments[0].blurRepeatsEdges && !mixed.segments[1].blurRepeatsEdges)
    }

    @Test func zeroBlurWithRepeatEdgesIsStillIdentity() {
        #expect(clip([(0, true)]).effects(at: s(1)).isIdentity)
    }
}
