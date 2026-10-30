import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQText
@testable import SQPlayback

/// Maintainer bug 2026-10-08: "caption animations leave a moment with no caption between two captions". Two captions
/// that touch (or sit up to two frames apart) hand over: every frame from the first caption's second frame to the
/// second caption's end shows a caption, for every built-in animation and every text-animator effect, on a cold text
/// cache in playback order (one tick per frame) and again warm.
@Suite(.serialized) @MainActor struct CaptionHandoverPlaybackTests {
    static let fd = Time(1, 30)
    static let animators: [(id: String, animator: TextAnimator)] = [
        ("handover-fade", TextAnimator(effect: .fade, unit: .word, duration: Time(3, 10), stagger: Time(1, 10))),
        ("handover-pop", TextAnimator(effect: .pop, unit: .word, easing: .overshoot, duration: Time(3, 10), stagger: Time(1, 10))),
        ("handover-slide", TextAnimator(effect: .slide, unit: .character, duration: Time(1, 5), stagger: Time(1, 30))),
        ("handover-blur", TextAnimator(effect: .blur, unit: .line, duration: Time(1, 5), stagger: Time(1, 10))),
        ("handover-typewriter", TextAnimator(effect: .typewriter, unit: .character, duration: .zero, stagger: Time(1, 30))),
    ]

    /// Caption A on frames 3..<15, caption B 12 frames long starting `gap` frames after A ends.
    static func timeline(animation: String, gap: Int64, karaoke: Bool) throws -> Timeline {
        let fd = Self.fd
        let format = SequenceFormat(width: 540, height: 960, frameDuration: fd)
        // A text clip far off canvas only gives the sequence its length.
        let style = TextStyle(fontName: "Helvetica-Bold", size: 20, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "i", style: style), animations: nil)
        let id = UUID()
        var clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, generator: ref)
        clip.animation.position = AnimatedProperty(Vec2(5000, 5000))
        var tl = Timeline(name: "s", format: format, tracks: [Track(kind: .video, clips: [clip])])
        let a = TimeRange(start: fd * 3, end: fd * 15), b = TimeRange(start: fd * (15 + gap), end: fd * (27 + gap))
        let track = try tl.replaceCaptions([
            CaptionItem(lines: ["alpha beta"], range: a, styleRef: "tiktok", animationRef: animation),
            CaptionItem(lines: ["gamma delta"], range: b, styleRef: "tiktok", animationRef: animation),
        ])
        if karaoke { try tl.setCaptionKaraoke(KaraokeStyle(), track: track) }
        return tl
    }

    /// One pass in playback order over `frames` frames: one tick per frame, then the clock moves on by one frame.
    func pass(_ engine: PlaybackEngine, _ clock: ManualClock, _ device: MTLDevice, frames: Int) throws -> [Double] {
        engine.pause()
        engine.seek(to: .zero)
        _ = engine.tick()
        engine.play()
        var sums: [Double] = []
        for f in 0..<frames {
            #expect(engine.tick(), "frame \(f) not presented")
            let tex = try #require(engine.lastRenderedTexture)
            sums.append(try #require(bottomHalfSum(tex, device: device)))
            clock.advance(by: Self.fd)
        }
        return sums
    }

    func withLooks<T>(_ body: ([String]) throws -> T) rethrows -> T {
        let style = CaptionPresetLibrary.builtIn.style(for: "tiktok")
        var ids = CaptionPresetLibrary.builtIn.animationIDs.filter { !$0.hasPrefix("look-") }
        for a in Self.animators {
            ids.append(CaptionLookRegistry.shared.register(CaptionLook(style: style, animation: KeyframeTemplate(textAnimator: a.animator)),
                                                           id: a.id).animationRef)
        }
        defer { for a in Self.animators { CaptionLookRegistry.shared.unregister(id: a.id) } }
        return try body(ids)
    }

    @Test func touchingCaptionsShowACaptionOnEveryFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: clock)
        try withLooks { ids in
            #expect(ids.count >= 15)
            for gap in [Int64(0), 1, 2] {
                for (animation, karaoke) in ids.map({ ($0, false) }) + [("fade", true), ("pop", true), (ids[ids.count - 2], true)] {
                    engine.setTimeline(try Self.timeline(animation: animation, gap: gap, karaoke: karaoke))
                    let last = 27 + Int(gap)
                    TextGenerator.clearCache()
                    let cold = try pass(engine, clock, device, frames: last + 2)
                    let warm = try pass(engine, clock, device, frames: last + 2)
                    let rest = try #require(warm.max())
                    #expect(rest > 1000, "\(animation): nothing drawn at all")
                    for f in 4..<last {
                        #expect(cold[f] > rest * 0.01, "\(animation) gap \(gap) karaoke \(karaoke): no caption on frame \(f) (cold)")
                        #expect(warm[f] > rest * 0.01, "\(animation) gap \(gap) karaoke \(karaoke): no caption on frame \(f) (warm)")
                    }
                    #expect(cold[last] < rest * 0.001 && warm[last + 1] < rest * 0.001, "\(animation): caption after the end")
                }
            }
        }
    }

    /// A caption with nothing near it keeps its whole in and out; a cross-fade never gets brighter than one caption.
    @Test func isolatedCaptionsKeepTheirAnimationAndAFadeNeverDoubles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: clock)
        // Three frames apart: no hand-over. The gap is empty and the second caption fades in from nothing.
        engine.setTimeline(try Self.timeline(animation: "fade", gap: 3, karaoke: false))
        let apart = try pass(engine, clock, device, frames: 32)
        let rest = try #require(apart.max())
        for f in [0, 2, 3, 15, 16, 17, 18, 30] { #expect(apart[f] < rest * 0.001, "frame \(f) should be empty") }
        #expect(apart[19] > rest * 0.01 && apart[19] < rest * 0.5)
        engine.setTimeline(try Self.timeline(animation: "fade-out", gap: 3, karaoke: false))
        let out = try pass(engine, clock, device, frames: 32)
        #expect(out[3] > rest * 0.6 && out[14] < rest * 0.5 && out[14] > rest * 0.01 && out[15] < rest * 0.001)
        // Touching: the first caption fades out under the second one fading in.
        engine.setTimeline(try Self.timeline(animation: "fade", gap: 0, karaoke: false))
        let touching = try pass(engine, clock, device, frames: 29)
        #expect(touching[3] < rest * 0.001)                         // the first caption of the run still fades in from nothing
        for f in 9..<27 { #expect(touching[f] > rest * 0.6 && touching[f] < rest * 1.3, "frame \(f): \(touching[f] / rest)") }
    }
}

/// Sum of the color channels over the lower half (every second row and column) of the composite (where the captions sit).
private func bottomHalfSum(_ texture: MTLTexture, device: MTLDevice) -> Double? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let p = buf.contents().assumingMemoryBound(to: Float16.self)
    var sum: Float = 0
    for y in stride(from: h / 2, to: h, by: 2) {
        let row = y * w * 4
        for x in stride(from: 0, to: w * 4, by: 8) { sum += Float(p[row + x]) + Float(p[row + x + 1]) + Float(p[row + x + 2]) }
    }
    return Double(sum)
}
