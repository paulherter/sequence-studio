import Foundation
#if canImport(simd)
import simd
#endif
import Testing
import SQCore
@testable import SQRender

/// Color Range (HSL secondary) maths on the tone signal.
@Suite struct HSLSecondaryStageTests {
    static let orange = SIMD3<Float>(0.8, 0.5, 0.3)    // hue about 24 degrees, skin-like
    static let blue = SIMD3<Float>(0.2, 0.3, 0.8)
    static let grey = SIMD3<Float>(0.5, 0.5, 0.5)

    static func stage(_ f: (inout HSLSecondary) -> Void) -> PreparedHSLSecondary {
        var r = HSLSecondary(); f(&r)
        return PreparedHSLSecondary(r, gamut: .rec709)
    }

    @Test func defaultRangeSelectsSkinTonesOnly() {
        let s = Self.stage { _ in }
        #expect(s.mask(Self.orange) > 0.99)
        #expect(s.mask(Self.blue) == 0)
        #expect(s.mask(Self.grey) == 0, "grays have no hue")
    }

    @Test func invertSelectsEverythingElse() {
        let s = Self.stage { $0.invert = true }
        #expect(s.mask(Self.orange) < 0.01)
        #expect(s.mask(Self.blue) == 1)
    }

    @Test func allHuesIncludesGreysButLumaRangeStillLimits() {
        let s = Self.stage { $0.hueWidth = 360; $0.satMin = 0; $0.lumMin = 60; $0.softness = 0 }
        #expect(s.mask(Self.grey) == 0, "luma 0.5 is below the 60 % floor")
        #expect(s.mask(SIMD3(repeating: 0.8)) == 1)
    }

    @Test func fullLumaRangeKeepsOverRangeValues() {
        let s = Self.stage { $0.hueWidth = 360; $0.satMin = 0; $0.softness = 0 }
        #expect(s.mask(SIMD3(repeating: 1.3)) == 1, "luma max 100 % has no upper limit (super-whites stay in)")
        #expect(s.mask(SIMD3(repeating: -0.1)) == 1, "luma min 0 % has no lower limit")
        let capped = Self.stage { $0.hueWidth = 360; $0.satMin = 0; $0.softness = 0; $0.lumMax = 90; $0.lumMin = 10 }
        #expect(capped.mask(SIMD3(repeating: 1.3)) == 0)
        #expect(capped.mask(SIMD3(repeating: -0.1)) == 0)
    }

    @Test func softnessWidensTheEdge() {
        let px = SIMD3<Float>(0.8, 0.6, 0.3)          // hue about 34 degrees: just outside a 20-degree wide range at 25
        let hard = Self.stage { $0.hueWidth = 10; $0.softness = 0 }
        let soft = Self.stage { $0.hueWidth = 10; $0.softness = 100 }
        #expect(hard.mask(px) == 0)
        #expect(soft.mask(px) > 0.5)
    }

    @Test func hueWrapsAroundRed() {
        let s = Self.stage { $0.hueCenter = 355; $0.hueWidth = 30; $0.softness = 0 }
        #expect(s.mask(SIMD3(0.8, 0.25, 0.2)) == 1, "a hue of a few degrees lies within 340…10")
    }

    @Test func correctionAppliesOnlyInsideTheRange() {
        let s = Self.stage { $0.saturation = 0; $0.softness = 0 }
        let o = s.apply(Self.orange, pre: false)
        #expect(abs(o.x - o.y) < 1e-4 && abs(o.y - o.z) < 1e-4, "selected orange is desaturated to gray")
        #expect(s.apply(Self.blue, pre: false) == Self.blue)
        // Exposure brightens, temperature warms.
        let e = Self.stage { $0.exposure = 1; $0.temperature = 50; $0.softness = 0 }
        let w = e.apply(Self.orange, pre: false)
        #expect(w.x / w.z > Self.orange.x / Self.orange.z)
        #expect(simd_dot(Gamut.rec709.lumaRow, w) > simd_dot(Gamut.rec709.lumaRow, Self.orange))
    }

    @Test func pipelineSkipsAQualifierWithoutCorrection() {
        var c = ClipColor.default
        c.effects[0].hslSecondary = HSLSecondary()
        #expect(ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil).isIdentity)
        c.effects[0].hslSecondary?.hueShift = 30
        #expect(!ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil).isIdentity)
    }

    /// Render-path wiring: a clip's Color Range reaches the pipeline stage list and changes the pixels it selects only.
    @Test func clipColorRangeDrivesTheRenderPipeline() {
        var c = ClipColor.default
        var r = HSLSecondary(); r.saturation = 0; r.softness = 0
        c.effects[0].hslSecondary = r
        let p = ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil)
        #expect(p.stages.contains { if case .hslSecondary = $0.kind { true } else { false } })
        let o = p.process(Self.orange)
        #expect(abs(o.x - o.y) < 1e-3 && abs(o.y - o.z) < 1e-3, "selected orange is desaturated through the pipeline")
        let plain = ColorPipeline(source: p.source, ops: []).process(Self.blue)
        #expect(p.process(Self.blue) == plain, "unselected blue is untouched")
        // A disabled Color Range leaves the pipeline empty.
        c.effects[0].setEnabled(.hslSecondary, false)
        #expect(ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil).isIdentity)
    }
}
