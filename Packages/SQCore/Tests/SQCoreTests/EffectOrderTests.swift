import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ kinds: [(String, [String: Double])]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
    for (k, v) in kinds {
        let id = c.addEffect(kind: k)!
        for (key, val) in v { c.setParameter(id, key, to: val) }
    }
    return c
}

private let rc = (ClipEffect.roundedCornersKind, [ClipEffect.radiusKey: 20.0])
private let crop = (ClipEffect.cropKind, [ClipEffect.cropLeftKey: 10.0])
private func blur(_ v: Double) -> (String, [String: Double]) { (ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: v]) }
private let key = (ClipEffect.ultraKeyKind, [String: Double]())

@Suite struct EffectOrderTests {
    @Test func roundedCornersThenCropDiffersFromCropThenRoundedCorners() {
        let a = clip([rc, crop]).effects(at: s(1)), b = clip([crop, rc]).effects(at: s(1))
        #expect(a != b)
        #expect(a.segments.count == 1 && a.pre.roundFirst && !b.pre.roundFirst)
        #expect(a.pre.cornerRadius == 20 && b.pre.cornerRadius == 20 && abs(a.pre.crop.left - 0.1) < 1e-12)
    }

    @Test func aMaskSequenceOneMaskCannotExpressStartsANewPass() {
        let e = clip([crop, rc, crop]).effects(at: s(1))
        #expect(e.segments.count == 2 && e.segments[0].blurAfter == 0)
        let e2 = clip([rc, crop, rc]).effects(at: s(1))
        #expect(e2.segments.count == 2)
    }

    @Test func repeatableOrdersMergeIntoOnePass() {
        #expect(clip([crop, rc, rc]).effects(at: s(1)).segments.count == 1)
        #expect(clip([rc, crop, crop]).effects(at: s(1)).segments.count == 1)
        #expect(clip([crop, crop]).effects(at: s(1)).segments.count == 1)
    }

    @Test func ultraKeyChokeAndPedestalReachTheKey() {
        let c = clip([(ClipEffect.ultraKeyKind, [ClipEffect.chokeKey: 40, ClipEffect.pedestalKey: 10])])
        let k = c.effects(at: s(1)).keys[0]
        #expect(abs(k.choke - 0.4) < 1e-9 && abs(k.pedestal - 0.1) < 1e-9)
        let d = clip([key]).effects(at: s(1)).keys[0]
        #expect(d.choke == 0 && d.pedestal == 0)                         // defaults: identity
    }

    @Test func ultraKeyMatteOutputReachesTheKey() {
        #expect(clip([key]).effects(at: s(1)).keys[0].matteOutput == false)          // default: Composite
        let m = clip([(ClipEffect.ultraKeyKind, [ClipEffect.keyOutputKey: 1])]).effects(at: s(1)).keys[0]
        #expect(m.matteOutput)
        let spec = EffectCatalog.all.first { $0.kind == ClipEffect.ultraKeyKind }?.params.first { $0.key == ClipEffect.keyOutputKey }
        #expect(spec?.defaultValue == 0)
    }

    @Test func ultraKeyAfterBlurKeysTheBlurredPicture() {
        let before = clip([key, blur(5)]).effects(at: s(1)), after = clip([blur(5), key]).effects(at: s(1))
        #expect(before.segments.count == 2 && before.segments[0].keys.count == 1 && before.segments[1].keys.isEmpty)
        #expect(after.segments.count == 2 && after.segments[0].keys.isEmpty && after.segments[1].keys.count == 1)
        #expect(after.segments[0].blurAfter == ClipEffect.gaussianSigma(blurriness: 5))
    }

    @Test func blursSeparatedByAnEffectStayTwoBlursAndAdjacentOnesMerge() {
        let sep = clip([blur(3), crop, blur(4)]).effects(at: s(1))
        #expect(sep.segments.map(\.blurAfter) == [3, 4, 0].map { ClipEffect.gaussianSigma(blurriness: $0) })
        let adj = clip([blur(3), blur(4)]).effects(at: s(1))
        #expect(adj.segments.count == 2 && abs(adj.segments[0].blurAfter - ClipEffect.gaussianSigma(blurriness: 5)) < 1e-12 && adj.segments[1].blurAfter == 0)
    }

    @Test func zeroValuedEffectsNeverCutTheList() {
        let e = clip([blur(0), crop, (ClipEffect.ultraKeyKind, [ClipEffect.toleranceKey: 0])]).effects(at: s(1))
        #expect(e.segments.count == 1)
        #expect(clip([blur(0)]).effects(at: s(1)) == ClipEffects.none)
    }

    @Test func threeKeysSplitIntoTwoPasses() {
        let e = clip([key, key, key]).effects(at: s(1))
        #expect(e.segments.map(\.keys.count) == [2, 1])
    }
}
