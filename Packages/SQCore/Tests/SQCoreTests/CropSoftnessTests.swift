import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ params: [String: Double], kind: String = ClipEffect.cropKind) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
    let id = c.addEffect(kind: kind)!
    for (k, v) in params { c.setParameter(id, k, to: v) }
    return c
}

/// Crop Softness: a soft edge (px of the clip's own frame) on the cropped rectangle.
@Suite struct CropSoftnessTests {
    @Test func softnessIsACropParameterInPixels() {
        let spec = EffectCatalog.param(ClipEffect.cropKind, ClipEffect.cropSoftnessKey)
        #expect(spec?.title == "Softness" && spec?.unit == "px" && spec?.defaultValue == 0)
        #expect(ClipEffect.make(kind: ClipEffect.cropKind)?.parameters[ClipEffect.cropSoftnessKey]?.value == 0)
    }

    @Test func softnessReachesTheMask() {
        let e = clip([ClipEffect.cropLeftKey: 10, ClipEffect.cropSoftnessKey: 12]).effects(at: s(1))
        #expect(e.pre.feather == 12 && abs(e.pre.crop.left - 0.1) < 1e-12)
        #expect(!e.pre.isIdentity)
    }

    @Test func softnessWithoutACropSoftensTheFrameEdge() {
        let e = clip([ClipEffect.cropSoftnessKey: 8]).effects(at: s(1))
        #expect(e.pre.feather == 8 && e.pre.crop.isIdentity && !e.pre.isIdentity)
        #expect(clip([:]).effects(at: s(1)).segments.isEmpty)       // nothing set: identity, no pass
    }

    @Test func twoCropsKeepTheSofterEdge() {
        var c = clip([ClipEffect.cropLeftKey: 10, ClipEffect.cropSoftnessKey: 4])
        let id = c.addEffect(kind: ClipEffect.cropKind)!
        c.setParameter(id, ClipEffect.cropTopKey, to: 20); c.setParameter(id, ClipEffect.cropSoftnessKey, to: 9)
        let e = c.effects(at: s(1))
        #expect(e.segments.count == 1 && e.pre.feather == 9)
    }

    @Test func storedCropWithoutSoftnessReadsZero() throws {
        // A Crop saved before Softness existed has no stored value: it reads the default 0 (no file change).
        var c = clip([ClipEffect.cropLeftKey: 10])
        c.effects[0].parameters[ClipEffect.cropSoftnessKey] = nil
        #expect(c.effects(at: s(1)).pre.feather == 0)
    }
}
