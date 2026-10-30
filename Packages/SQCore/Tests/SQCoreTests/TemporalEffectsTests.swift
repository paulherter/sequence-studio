import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 25)

private func clip(_ kinds: [String] = [], _ values: [String: [String: Double]] = [:]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
    for k in kinds {
        var e = ClipEffect.make(kind: k)!
        for (key, v) in values[k] ?? [:] { e.parameters[key] = AnimatedProperty(v) }
        c.effects.append(e)
    }
    return c
}

private func movingPosition() -> AnimatedProperty<Vec2> {
    AnimatedProperty(.zero, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: .zero), Keyframe(time: s(1), value: Vec2(100, 0))]))
}

private let canvas = SequenceFormat(width: 640, height: 360, frameDuration: fd)

@Suite struct TemporalEffectsTests {
    // MARK: Catalog and evaluation

    @Test func catalogOffersTheThreeEffectsWithTheirRanges() throws {
        let nr = try #require(EffectCatalog.spec(for: ClipEffect.videoDenoiseKind))
        #expect(nr.title == "Video Denoise")
        #expect(EffectCatalog.param(ClipEffect.videoDenoiseKind, ClipEffect.framesEachSideKey)?.range == 0...5)
        #expect(EffectCatalog.param(ClipEffect.deflickerKind, ClipEffect.framesEachSideKey)?.defaultValue == 3)
        // Motion Analysis defaults to Fast (the source manual names both; decided in DECISIONS "Temporal effects").
        #expect(EffectCatalog.param(ClipEffect.deflickerKind, ClipEffect.analysisKey)?.defaultValue == 0)
        #expect(EffectCatalog.param(ClipEffect.motionBlurKind, ClipEffect.amountKey)?.range == 0...100)
    }

    @Test func denoiseAndDeflickerEvaluateIntoOneTemporalFilter() throws {
        let c = clip([ClipEffect.videoDenoiseKind, ClipEffect.deflickerKind],
                     [ClipEffect.videoDenoiseKind: [ClipEffect.framesEachSideKey: 4, ClipEffect.qualityKey: 1],
                      ClipEffect.deflickerKind: [ClipEffect.framesEachSideKey: 6, ClipEffect.analysisKey: 1, ClipEffect.strengthKey: 50]])
        let fx = c.effects(at: s(1))
        let t = try #require(fx.temporal)
        #expect(t.denoise?.framesEachSide == 4 && t.denoise?.best == true)
        #expect(t.deflicker == .init(framesEachSide: 6, local: true, strength: 0.5))
        #expect(t.radius == 6)
        // The temporal filter runs before the chain: it is not an effect segment, so the plain path stays plain.
        #expect(fx.segments.isEmpty && fx.isIdentity)
    }

    @Test func disabledOrZeroEffectsGiveNoFilter() {
        var c = clip([ClipEffect.deflickerKind], [ClipEffect.deflickerKind: [ClipEffect.strengthKey: 0]])
        #expect(c.effects(at: s(1)).temporal == nil)
        c = clip([ClipEffect.videoDenoiseKind])
        c.effects[0].enabled = false
        #expect(c.effects(at: s(1)).temporal == nil)
        // Keep Original 100 % is the original frame.
        c = clip([ClipEffect.videoDenoiseKind], [ClipEffect.videoDenoiseKind: [ClipEffect.keepOriginalKey: 100]])
        #expect(c.effects(at: s(1)).temporal == nil)
    }

    @Test func spatialOnlyDenoiseNeedsNoNeighbours() throws {
        let c = clip([ClipEffect.videoDenoiseKind], [ClipEffect.videoDenoiseKind: [ClipEffect.framesEachSideKey: 0, ClipEffect.spatialLumaKey: 30]])
        let t = try #require(c.effects(at: s(1)).temporal)
        #expect(t.radius == 0 && t.denoise?.isSpatial == true)
    }

    @Test func fastModeClampsTheWindowAndQuality() {
        let f = TemporalFilter(denoise: .init(framesEachSide: 5, best: true, motionSearch: 2),
                               deflicker: .init(framesEachSide: 8, local: true))
        let fast = f.degraded(.fast)
        #expect(fast.denoise?.framesEachSide == 1 && fast.denoise?.best == false && fast.denoise?.motionSearch == 0)
        #expect(fast.deflicker?.framesEachSide == 2 && fast.deflicker?.local == false)
        #expect(fast.radius == 2)
        #expect(f.degraded(.exact) == f)
    }

    // MARK: Frame window and history

    @Test func windowStaysInsideTheClipsSourceFrames() {
        let n = TemporalWindow.neighbours(center: 10, radius: 3, lower: 8, upper: 30)
        #expect(n.before == [9, 8] && n.after == [11, 12, 13])
        #expect(TemporalWindow.neighbours(center: 10, radius: 0, lower: 0, upper: 30) == ([], []))
        #expect(TemporalWindow.span(center: 30, radius: 2, lower: 0, upper: 30) == 28...30)
    }

    @Test func historyKeepsOnlyTheNeededWindows() {
        let a = UUID(), b = UUID()
        var h = FrameHistory<Int>()
        for i in 0..<20 { h[a, i] = i; h[b, i] = i }
        h.keep([a: [TemporalWindow.span(center: 10, radius: 2, lower: 0, upper: 99)]])
        #expect(h.count == 5 && h[a, 8] == 8 && h[a, 12] == 12 && h[a, 7] == nil && h[b, 10] == nil)
    }

    // MARK: Motion Blur effect

    @Test func motionBlurEffectBlursKeyedMotion() throws {
        var c = clip([ClipEffect.motionBlurKind], [ClipEffect.motionBlurKind: [ClipEffect.amountKey: 100]])
        c.animation.position = movingPosition()
        let mb = try #require(c.motionBlur(at: Time(1, 2), frameDuration: fd, format: canvas))
        #expect(mb.transforms.count == 16)
        // Amount 100 = a 360 degree shutter: one full frame (4 px at 100 px/s, 25 fps), centered.
        #expect(abs(mb.transforms.first!.position.x - 48) < 1e-6 && abs(mb.transforms.last!.position.x - 52) < 1e-6)
    }

    @Test func directionMovesTheShutterWindow() throws {
        func ends(_ side: Double) throws -> (Double, Double) {
            var c = clip([ClipEffect.motionBlurKind], [ClipEffect.motionBlurKind: [ClipEffect.amountKey: 100, ClipEffect.blurDirectionModeKey: side]])
            c.animation.position = movingPosition()
            let mb = try #require(c.motionBlur(at: Time(1, 2), frameDuration: fd, format: canvas))
            return (mb.transforms.first!.position.x, mb.transforms.last!.position.x)
        }
        let prev = try ends(1), next = try ends(2)
        #expect(abs(prev.0 - 46) < 1e-6 && abs(prev.1 - 50) < 1e-6)
        #expect(abs(next.0 - 50) < 1e-6 && abs(next.1 - 54) < 1e-6)
    }

    @Test func smoothnessScalesTheSampleCount() throws {
        func count(_ smooth: Double, amount: Double = 50) -> Int? {
            var c = clip([ClipEffect.motionBlurKind], [ClipEffect.motionBlurKind: [ClipEffect.amountKey: amount, ClipEffect.smoothnessKey: smooth]])
            c.animation.position = movingPosition()
            return c.motionBlur(at: Time(1, 2), frameDuration: fd, format: canvas)?.transforms.count
        }
        #expect(count(0) == 4 && count(1) == 8 && count(2) == 16)
        #expect(count(2, amount: 100) == 32)
        #expect(count(1, amount: 0) == nil)
    }

    @Test func motionBlurOnAStillClipCostsNothing() {
        let c = clip([ClipEffect.motionBlurKind], [ClipEffect.motionBlurKind: [ClipEffect.amountKey: 100]])
        #expect(c.motionBlur(at: Time(1, 2), frameDuration: fd, format: canvas) == nil)
        #expect(c.effects(at: Time(1, 2)) == .none)
    }

    @Test func widestShutterWinsBetweenMotionAndTheEffect() throws {
        var c = clip([ClipEffect.motionBlurKind], [ClipEffect.motionBlurKind: [ClipEffect.amountKey: 25, ClipEffect.blurDirectionModeKey: 2]])
        c.animation.position = movingPosition()
        c.animation.shutterAngle = AnimatedProperty(360)
        let mb = try #require(c.motionBlur(at: Time(1, 2), frameDuration: fd, format: canvas))
        // Motion's 360 degree shutter (centered) beats the effect's 90 degrees toward the next frame.
        #expect(abs(mb.transforms.first!.position.x - 48) < 1e-6)
    }

    @Test func motionBlurReachesTheLayerRequest() throws {
        var c = clip([ClipEffect.motionBlurKind])
        c.animation.position = movingPosition()
        let tl = Timeline(name: "S", format: canvas, tracks: [Track(kind: .video, clips: [c])])
        let mb = try #require(tl.videoLayers(at: Time(1, 2))[0].motionBlur)
        #expect(mb.transforms.count == 8)    // Amount 50 = 180 degrees
    }

    @Test func thinningKeepsTheEndsAndSpreadsEvenly() {
        let ts = (0..<16).map { i -> ClipTransform in var t = ClipTransform.identity; t.position = Vec2(Double(i), 0); return t }
        let mb = MotionBlurSamples(format: canvas, transforms: ts).thinned(to: 8)
        #expect(mb.transforms.map(\.position.x) == [0, 2, 4, 6, 9, 11, 13, 15])
        #expect(MotionBlurSamples(format: canvas, transforms: Array(ts.prefix(6))).thinned(to: 8).transforms.count == 6)
    }
}
