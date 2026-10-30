import Foundation
import Testing
@testable import SQCore

// Emphasis presets (docs/research/USAGE-PREMIERE.md): Punch-In, Camera Shake, RGB Split Hit, Pop 0-120-100, Whip Blur In / Out,
// RGB Glitch, Ghost Frame. They reuse live effects and keyframes; every value stays editable after one click.

private let frame = Vec2(1920, 1080)
private func clip(seconds: Int64 = 4) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
}
private func preset(_ name: String) -> EffectStackPreset { MotionPresets.builtIn(named: name)! }
private func scale(_ c: Clip, _ t: Time) -> Double { c.renderTransform(at: t, frame: frame).scale.x }

@Suite struct EmphasisPresetTests {
    static let names = ["Punch-In", "Camera Shake", "RGB Split Hit", "Pop 0-120-100", "Whip Blur In", "Whip Blur Out", "RGB Glitch", "Ghost Frame"]

    @Test func allListedWithKnownEffects() {
        for n in Self.names {
            let p = MotionPresets.builtIn(named: n)
            #expect(p != nil, "\(n) listed")
            guard let p else { continue }
            #expect(!p.effects.isEmpty && p.preset.motionProperties.isEmpty, "\(n): effects only")
            #expect(p.effects.allSatisfy { EffectCatalog.spec(for: $0.kind) != nil }, "\(n): known kinds")
        }
        #expect(Set(MotionPresets.builtIns.map(\.id)).count == MotionPresets.builtIns.count)
    }

    @Test func punchInScalesToAbout118WithEase() {
        var c = clip(); c.applyPreset(preset("Punch-In").preset)
        #expect(abs(scale(c, .zero) - 1) < 1e-9)
        #expect(abs(scale(c, Time(3, 1)) - 1.18) < 1e-6, "holds the punched-in size")
        let mid = scale(c, Time(1, 10))
        #expect(mid > 1.09 && mid < 1.18, "ease-out: past the halfway point at half the time")
    }

    @Test func popGoesZeroToOneTwentyToOneHundredInTenFrames() {
        var c = clip(); c.applyPreset(preset("Pop 0-120-100").preset)
        #expect(scale(c, .zero) < 0.01)
        #expect(abs(scale(c, Time(4, 30)) - 1.2) < 0.01, "peak at frame 4")
        #expect(abs(scale(c, Time(10, 30)) - 1.0) < 1e-6, "settled at frame 10")
        #expect(abs(scale(c, Time(3, 1)) - 1.0) < 1e-9)
    }

    @Test func cameraShakeHoldsScale115WithShutter360AndKeepsShaking() {
        var c = clip(); c.applyPreset(preset("Camera Shake").preset)
        #expect(abs(scale(c, Time(2, 1)) - 1.15) < 1e-6)
        let a = c.renderTransform(at: Time(11, 10), frame: frame), b = c.renderTransform(at: Time(23, 10), frame: frame)
        #expect(a.position != b.position, "shakes for the whole clip")
        #expect(c.effects.contains { $0.stageShutterAngle(atLocal: Time(1, 1)) == 360 })
    }

    @Test func whipBlurInPeaksAtTheStartAndEndsClear() throws {
        var c = clip(); c.applyPreset(preset("Whip Blur In").preset)
        let blur = try #require(c.effects.first { $0.kind == ClipEffect.gaussianBlurKind })
        #expect(blur.parameters[ClipEffect.blurrinessKey]!.value(atLocal: .zero) == 1000)
        #expect(blur.parameters[ClipEffect.blurrinessKey]!.value(atLocal: Time(3, 1)) == 0)
        #expect(blur.parameters[ClipEffect.repeatEdgePixelsKey]?.value == 1, "edge pixels repeated, no gaps")
    }

    @Test func whipBlurOutFollowsTheClipEnd() throws {
        for secs in [2, 9] as [Int64] {
            var c = clip(seconds: secs); c.applyPreset(preset("Whip Blur Out").preset)
            let blur = try #require(c.effects.first { $0.kind == ClipEffect.gaussianBlurKind })
            let p = blur.parameters[ClipEffect.blurrinessKey]!
            #expect(p.value(atLocal: .zero) == 0)
            #expect(p.value(atLocal: Time(secs, 1)) == 1000, "peak on the last frame of a \(secs) s clip")
        }
    }

    @Test func rgbGlitchStartsAndEndsClean() throws {
        var c = clip(); c.applyPreset(preset("RGB Glitch").preset)
        let mosaic = try #require(c.effects.first { $0.kind == ClipEffect.mosaicKind })
        let cols = mosaic.parameters[ClipEffect.mosaicColumnsKey]!, rows = mosaic.parameters[ClipEffect.mosaicRowsKey]!
        #expect(cols.value(atLocal: .zero) == 500 && rows.value(atLocal: .zero) == 500)
        #expect(cols.value(atLocal: Time(15, 100)) == 20 && rows.value(atLocal: Time(15, 100)) == 10)
        #expect(cols.value(atLocal: Time(3, 1)) >= 4000, "no mosaic left after the glitch")
        let split = try #require(c.effects.first { $0.kind == ClipEffect.rgbSplitKind })
        #expect(split.parameters[ClipEffect.rgbSplitAmountKey]!.value(atLocal: Time(3, 1)) == 0)
    }

    @Test func applyingTwiceStacksWithFreshIDs() {
        var c = clip(); let p = preset("RGB Split Hit").preset
        c.applyPreset(p); c.applyPreset(p)
        #expect(c.effects.count == 2 && c.effects[0].id != c.effects[1].id)
    }
}
