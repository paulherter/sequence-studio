import Foundation
import Metal
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQExport

/// W7.3: captions play text animators (per character / word / line) and the full block animation (position, rotation)
/// in the export burn-in, from the same SQCore `AnimationSet` the Program monitor plays (`TextGenerator`).
@Suite struct CaptionAnimatorBurnInTests {
    let range = TimeRange(start: Time(1, 1), end: Time(3, 1))
    let text = "one two three"
    let w = 540, h = 960

    func setup(_ anim: KeyframeTemplate) -> (CaptionBurnIn, CaptionPresetLibrary, Caption) {
        let base = CaptionPresetLibrary.builtIn
        let lib = base.adding(CaptionLook(style: base.style(for: "tiktok"), animation: anim), id: "w73")
        let c = Caption(lines: [text], range: range, styleRef: CaptionLook.styleID(for: "w73"),
                        animationRef: CaptionLook.animationID(for: "w73"))
        return (CaptionBurnIn(captions: [c], library: lib), lib, c)
    }

    /// The units the monitor animates: the caption's own layout (`CaptionLayout` box at this canvas).
    func units(_ lib: CaptionPresetLibrary, _ c: Caption) -> TextUnits {
        let t = CaptionLayout.template(text: text, style: lib.style(for: c.styleRef), canvasWidth: Double(w), canvasHeight: Double(h))
        return TextUnits.segment(TextLayout.layout(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height))
    }

    @Test func wordAnimatorMatchesTheMonitor() throws {
        let anim = KeyframeTemplate(textAnimator: TextAnimator(effect: .pop, unit: .word, easing: .overshoot,
                                                               duration: Time(3, 10), stagger: Time(1, 10)))
        let (burn, lib, c) = setup(anim)
        let u = units(lib, c)
        #expect(u.wordCount == 3)
        let set = try #require(AnimationSet(single: anim))
        var animated = 0
        for f in 0..<60 {
            let t = range.start + Time(Int64(f), 30)
            let s = try #require(burn.state(at: t, canvasWidth: w, canvasHeight: h))
            let expected = try #require(set.characterStates(units: u, clipTime: t - range.start, clipDuration: range.duration))
            if expected.allSatisfy(\.isRest) { #expect(s.characterStates == nil, "frame \(f)") }
            else { #expect(s.characterStates == expected, "frame \(f)"); animated += 1 }
        }
        #expect(animated >= 10)                                   // 0.5 s of word pops
        // Without a canvas there is no layout: the block state alone (old callers).
        #expect(burn.state(at: range.start)?.characterStates == nil)
    }

    @Test func blockOffsetAndRotationReachTheBurnIn() throws {
        let anim = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 80, .linear), (Time(1, 2), 0, .linear)]),
            AnimationTrack(property: "rotation", keys: [(.zero, -10, .linear), (Time(1, 2), 0, .linear)]),
        ], duration: Time(1, 2))
        let (burn, _, _) = setup(anim)
        let s = try #require(burn.state(at: range.start + Time(1, 4)))
        #expect(s.offset == Vec2(0, 40) && s.rotation == -5)
        let rest = try #require(burn.state(at: range.start + Time(1, 1)))
        #expect(rest.offset == .zero && rest.rotation == 0 && rest.opacity == 1 && rest.scale == 1)
    }

    @Test func typewriterBurnsInOnlyTheStartedLetters() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let anim = KeyframeTemplate(textAnimator: TextAnimator(effect: .typewriter, unit: .character, duration: .zero,
                                                               stagger: Time(1, 10)))
        let (burn, _, _) = setup(anim)
        func inked(at t: Time) throws -> Int {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let tex = try #require(device.makeTexture(descriptor: d))
            let cb = try #require(queue.makeCommandBuffer())
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = tex; clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            cb.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
            try burn.encode(at: t, into: tex, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [Float16](repeating: 0, count: w * h * 4)
            tex.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return stride(from: 3, to: px.count, by: 4).filter { px[$0] > 0.5 }.count
        }
        let three = try inked(at: range.start + Time(25, 100))     // "one" started (3 letters)
        let all = try inked(at: range.start + Time(19, 10))        // every letter
        #expect(three > 0)
        #expect(Double(three) < Double(all) * 0.5)
    }

    /// W7.3 decision: a caption shorter than its end-anchored look plays the look's tail, like the Program monitor
    /// (out starts at max(clip - out, 0)). Before W7.3 the burn-in faded 0.5 -> 0 here; now it fades 1 -> 0.5.
    @Test func shortCaptionPlaysTheEndAnchoredLookLikeTheMonitor() throws {
        let fadeOut = KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)]),
        ], duration: Time(1, 5), anchor: .end)
        let base = CaptionPresetLibrary.builtIn
        let lib = base.adding(CaptionLook(style: base.style(for: "tiktok"), animation: fadeOut), id: "short")
        let short = TimeRange(start: Time(1, 1), end: Time(1, 1) + Time(1, 10))
        let c = Caption(lines: [text], range: short, styleRef: CaptionLook.styleID(for: "short"),
                        animationRef: CaptionLook.animationID(for: "short"))
        let burn = CaptionBurnIn(captions: [c], library: lib)
        let set = try #require(AnimationSet(single: fadeOut))
        let first = try #require(burn.state(at: short.start))
        #expect(first.opacity == 1)
        let mid = try #require(burn.state(at: short.start + Time(1, 20)))
        #expect(abs(mid.opacity - 0.75) < 1e-9)
        for f in 0..<10 {
            let local = Time(Int64(f), 100)
            let s = try #require(burn.state(at: short.start + local))
            #expect(s.opacity == set.sample(clipTime: local, clipDuration: short.duration).opacity, "frame \(f)")
        }
    }

    /// The caption's layout (CoreText) runs once per caption and canvas, not on every exported frame.
    @Test func animatorCaptionLaysOutOnce() throws {
        let anim = KeyframeTemplate(textAnimator: TextAnimator(effect: .pop, unit: .word, easing: .overshoot,
                                                               duration: Time(3, 10), stagger: Time(1, 10)))
        let (burn, _, _) = setup(anim)
        for f in 0..<60 { _ = burn.state(at: range.start + Time(Int64(f), 30), canvasWidth: w, canvasHeight: h) }
        #expect(burn.layoutRuns == 1)
        _ = burn.state(at: range.start, canvasWidth: h, canvasHeight: w)   // another canvas lays out again
        #expect(burn.layoutRuns == 2)
    }
}
