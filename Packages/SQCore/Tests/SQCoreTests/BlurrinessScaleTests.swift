import Foundation
import Testing
@testable import SQCore

/// Gaussian Blur Blurriness is Premiere's number: the effect turns it into a Gaussian sigma (px) itself, so an imported
/// Premiere value is passed 1:1 and looks the same.
@Suite struct BlurrinessScaleTests {
    private func clip(_ blurriness: Double) -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let id = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        c.setParameter(id, ClipEffect.blurrinessKey, to: blurriness)
        return c
    }

    @Test func blurrinessIsPremiereScaleSigmaIsMeasuredRatio() {
        #expect(ClipEffect.gaussianSigmaPerBlurriness == 0.35)
        #expect(abs(ClipEffect.gaussianSigma(blurriness: 200) - 70) < 1e-9)
        #expect(abs(clip(200).effects(at: Time(1, 1)).blur - 70) < 1e-9)
        #expect(clip(0).effects(at: Time(1, 1)).blur == 0)
    }

    @Test func rangeCoversPremiere() {
        let p = EffectCatalog.param(ClipEffect.gaussianBlurKind, ClipEffect.blurrinessKey)
        #expect(p?.range.upperBound == 3_000)
    }

    @Test func builtInLooksKeepTheirSigma() {
        // Blurred Fill and the motion recipes were tuned in sigma 40; in Premiere units that is ~115.
        #expect(abs(ClipEffect.gaussianSigma(blurriness: BlurredFillOptions().blur) - 40) < 0.5)
    }
}
