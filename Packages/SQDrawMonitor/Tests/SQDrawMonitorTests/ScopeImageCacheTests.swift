import Foundation
import SQDrawKit
import SQGPUKernels
@testable import SQDrawMonitor
import Testing

/// The Scopes card lays out on every window frame; it redraws its scope pictures only when what they show changes
/// (size, scope kind, trace intensity, new counts), not on each layout (the Color page redraw cost, round 6).
@MainActor
@Suite struct ScopeImageCacheTests {
    static func counts() -> ScopeCounts {
        let w = 16, h = 8
        let px = (0..<(w * h)).flatMap { i -> [UInt8] in [UInt8(i * 2 % 256), UInt8(i % 256), 200, 255] }
        return ScopeBinning.compute(rgba: px, width: w, height: h, layout: ScopeLayout(), pixelStride: 1)
    }

    @Test func aSecondLayoutKeepsThePictures() async throws {
        let p = ScopesPanel()
        let r = DrawRect(x: 0, y: 0, w: 320, h: 520)
        p.layout(r, scale: 1)
        p.update(counts: Self.counts(), generation: 1)
        await p.settle()
        let g = p.imageGeneration
        #expect(p.images[0] != nil)
        await p.settle()
        for _ in 0..<5 { p.layout(r, scale: 1) }
        await p.settle()
        #expect(p.imageGeneration == g)
        // A new size, scale, scope kind, intensity or frame draws them again.
        p.layout(DrawRect(x: 0, y: 0, w: 300, h: 520), scale: 1)
        await p.settle()
        #expect(p.imageGeneration == g + 1)
        p.layout(DrawRect(x: 0, y: 0, w: 300, h: 520), scale: 2)
        await p.settle()
        #expect(p.imageGeneration == g + 2)
        p.select(.histogram, at: 0)
        await p.settle()
        #expect(p.imageGeneration == g + 3)
        let d = try #require(UserDefaults(suiteName: "sq.test.scopecache"))
        d.removeObject(forKey: ScopeTraceSettings.defaultsKey)
        let settings = ScopeTraceSettings(defaults: d)
        p.settings = settings
        p.select(.waveform, at: 0)
        await p.settle()
        let g2 = p.imageGeneration
        settings.intensity = 2
        p.layout(DrawRect(x: 0, y: 0, w: 300, h: 520), scale: 2)
        await p.settle()
        #expect(p.imageGeneration == g2 + 1)
        p.update(counts: Self.counts(), generation: 2)
        await p.settle()
        #expect(p.imageGeneration == g2 + 2)
        p.layout(DrawRect(x: 0, y: 0, w: 300, h: 520), scale: 2)
        await p.settle()
        #expect(p.imageGeneration == g2 + 2)
    }

    /// Asks made while a render runs collapse into one more render, and the call itself never draws on the main thread.
    @Test func manyAsksCoalesceAndTheCallReturnsBeforeThePicturesExist() async throws {
        let p = ScopesPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        p.update(counts: Self.counts(), generation: 1)
        #expect(p.images[0] == nil, "renderImages must not draw inline")
        let before = p.imageGeneration
        for g in 2...20 { p.update(counts: Self.counts(), generation: g) }
        await p.settle()
        #expect(p.images[0] != nil)
        #expect(p.imageGeneration - before <= 3, "19 asks drew \(p.imageGeneration - before) times")
        // Clearing while a render runs: the late result is dropped.
        p.update(counts: Self.counts(), generation: 30)
        p.clear()
        await p.settle()
        #expect(p.images[0] == nil)
    }
}
