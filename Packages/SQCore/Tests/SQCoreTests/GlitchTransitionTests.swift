import Foundation
import Testing
@testable import SQCore

@Suite struct GlitchTransitionTests {
    private func eval(_ i: Int, _ n: Int = 10) -> TransitionRender {
        TransitionRender.evaluate(kind: .glitch, direction: .left, softness: 0, motionBlur: 0, easing: .linear, frameIndex: i, frames: n)
    }

    @Test func isAVideoMotionTransitionWithoutBlurOrDirection() {
        #expect(TransitionKind.glitch.isMotion && TransitionKind.glitch.trackKind == .video)
        #expect(!TransitionKind.glitch.usesMotionBlur && !TransitionKind.glitch.usesDirection)
        #expect(TransitionKind.kinds(for: .video).contains(.glitch))
        #expect(TransitionKind.glitch.name == "Glitch")
    }

    @Test func deterministicFromProgress() {
        for i in 0..<10 { #expect(eval(i) == eval(i)) }
        #expect(eval(3) != eval(4))
    }

    @Test func intensityIsABellAndCutHappensAtHalf() {
        let g = (0..<11).map { eval($0, 11).glitch }
        #expect(g.allSatisfy { $0.intensity >= 0 && $0.intensity <= 1 })
        let peak = g.map(\.intensity).max()!
        #expect(peak == g[5].intensity)
        #expect(g[0].intensity < g[5].intensity && g[10].intensity < g[5].intensity)
        #expect(g.map(\.mix).prefix(5).allSatisfy { $0 < 0.5 } && g.map(\.mix).suffix(5).allSatisfy { $0 > 0.5 })
        #expect(eval(0).compose == .glitch)
    }

    @Test func sliceOffsetsAreDeterministicBoundedAndSparse() {
        typealias G = TransitionRender.Glitch
        var active = 0
        for band in 0..<G.bands {
            let a = G.sliceShift(band: band, seed: 7, intensity: 1)
            #expect(a == G.sliceShift(band: band, seed: 7, intensity: 1))
            #expect(abs(a) <= G.maxShift)
            if a != 0 { active += 1 }
            #expect(G.sliceShift(band: band, seed: 7, intensity: 0) == 0)
        }
        #expect(active > 0 && active < G.bands)
        let other = (0..<G.bands).map { G.sliceShift(band: $0, seed: 8, intensity: 1) }
        let same = (0..<G.bands).map { G.sliceShift(band: $0, seed: 7, intensity: 1) }
        #expect(other != same)
    }

    @Test func rgbSplitScalesWithIntensity() {
        #expect(TransitionRender.Glitch.rgbSplit(intensity: 0) == 0)
        #expect(TransitionRender.Glitch.rgbSplit(intensity: 1) == TransitionRender.Glitch.maxSplit)
    }
}
