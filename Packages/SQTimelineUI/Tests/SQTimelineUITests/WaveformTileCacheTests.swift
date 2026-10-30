import AppKit
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQTimelineUI
@testable import SQUIKit

/// Waveform outline (one polygon per run of columns) and the per-clip tile cache that scrolling redraws from.
@MainActor @Suite struct WaveformTileCacheTests {
    private static let size = CGSize(width: 700, height: 120)

    private func rep() -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width) * 2, pixelsHigh: Int(Self.size.height) * 2,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    private func render(_ body: (CGContext) -> Void) -> NSBitmapImageRep {
        let r = rep()
        let base = NSGraphicsContext(bitmapImageRep: r)!
        let cg = base.cgContext
        cg.translateBy(x: 0, y: Self.size.height * 2); cg.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body(cg)
        NSGraphicsContext.restoreGraphicsState()
        return r
    }

    /// Pixels whose bytes differ by more than `tolerance` (anti-aliasing rounding).
    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, tolerance: Int = 2) -> Int {
        guard let pa = a.bitmapData, let pb = b.bitmapData else { return -1 }
        var n = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<(a.pixelsWide * 4) where abs(Int(pa[y * a.bytesPerRow + x]) - Int(pb[y * b.bytesPerRow + x])) > tolerance { n += 1 }
        }
        return n
    }

    private func columns(_ n: Int, seed: UInt32) -> [WaveformColumn] {
        var x = seed
        return (0..<n).map { i in
            x = x &* 1_664_525 &+ 1_013_904_223
            let v = Float(x >> 8) / Float(1 << 24)
            let hi: Float = i % 17 == 0 ? 0.001 : v              // tiny columns are skipped by the rect path
            return WaveformColumn(lo: -v * 0.7, hi: hi, clipped: false)
        }
    }

    @Test func outlineFillsTheSamePixelsAsTheColumnRects() {
        for style in [WaveformStyle(), { var s = WaveformStyle(); s.shape = .bipolar; return s }()] {
            for (rect, first) in [(CGRect(x: 10.3, y: 7.5, width: 500, height: 40), 0), (CGRect(x: 0, y: 60, width: 240.6, height: 33), 30)] {
                let cols = [columns(260, seed: 7), columns(260, seed: 99)]
                let a = render { cg in
                    cg.addPath(WaveformPath.path(columns: cols, rect: rect, style: style, firstColumn: first)); cg.setFillColor(.white); cg.fillPath()
                }
                let b = render { cg in
                    cg.addPath(WaveformPath.outline(columns: cols, rect: rect, style: style, firstColumn: first)); cg.setFillColor(.white); cg.fillPath()
                }
                #expect(differing(a, b) == 0, "\(style.shape) \(rect)")
            }
        }
    }

    private static let data: WaveformData = TimelineScrollPerfTests.waveform(seed: 3)

    private func clip(media: UUID, volume: Double = 1) -> Clip {
        var c = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: Time(5, 1), duration: Time(8, 1)), start: Time(1, 1))
        c.animation.volume.value = volume
        return c
    }

    @Test func tilesMatchTheDirectDrawAndAreReusedWhileScrolling() async {
        let media = UUID()
        let peaks = WaveformCache()
        _ = peaks.resampled(media: media, data: Self.data, pointsPerSecond: 160)
        let tiles = WaveformTileCache()
        let c = clip(media: media, volume: 0.6)
        let rect = CGRect(x: -300.4, y: 20, width: 8 * 160, height: 60)        // starts left of the view, wider than a tile
        let visible = CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height)
        let direct = render { _ in
            ClipDrawing.drawWaveform(data: Self.data, media: media, source: c.source, rect: rect, visible: visible, cache: peaks,
                                     volumeDB: TimelineView.volumeDB(of: c))
        }
        let cached = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(differing(direct, cached) == 0)
        let built = tiles.computedTiles
        #expect(built >= 2)
        // Same clip, same width, shifted (horizontal scroll): drawn from the tiles, nothing recomputed.
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect.offsetBy(dx: 37, dy: 0), visible: visible, cache: peaks, in: cg) }
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect.offsetBy(dx: -12, dy: 9), visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles == built)
        // A thin strip (playhead) reuses the tiles too.
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: CGRect(x: 300, y: 0, width: 2, height: 120), cache: peaks, in: cg) }
        #expect(tiles.computedTiles == built)
        // Volume changed: recomputed. Zoom (width) changed: recomputed.
        _ = render { cg in tiles.draw(clip: clip(media: media, volume: 0.3), data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles > built)
        let afterVolume = tiles.computedTiles
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width * 1.1, height: rect.height),
                                      visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles > afterVolume)
    }

    @Test func fallbackTilesAreRebuiltOnceTheExactBucketArrives() async {
        let media = UUID()
        let peaks = WaveformCache()
        let tiles = WaveformTileCache()
        let c = clip(media: media)
        let rect = CGRect(x: 10, y: 10, width: 8 * 90, height: 50)
        let visible = CGRect(origin: .zero, size: Self.size)
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }  // cold: mip read
        let cold = tiles.computedTiles
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles == cold)                                    // still cold: the fallback picture stays
        await peaks.waitForIdle()                                               // the draw queued the bucket build
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles > cold)
        let warm = tiles.computedTiles
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles == warm)
    }

    /// A reused fallback tile keeps its upgrade pending: if the exact bucket is gone again (evicted before the redraw that
    /// would have used it), the next draw asks for it again instead of keeping the fallback picture forever.
    @Test func reusedFallbackTileRequestsTheExactBucketAgain() async {
        let media = UUID()
        let peaks = WaveformCache()
        let tiles = WaveformTileCache()
        let c = clip(media: media)
        let rect = CGRect(x: 10, y: 10, width: 8 * 90, height: 50)
        let visible = CGRect(origin: .zero, size: Self.size)
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }  // cold: fallback
        await peaks.waitForIdle()
        peaks.removeAll()                                                       // evicted before the view redrew
        let started = peaks.buildsStarted
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(peaks.buildsStarted > started)
        await peaks.waitForIdle()
        let cold = tiles.computedTiles
        _ = render { cg in tiles.draw(clip: c, data: Self.data, rect: rect, visible: visible, cache: peaks, in: cg) }
        #expect(tiles.computedTiles > cold)                                     // now exact
    }

    @Test func constantVolumeIsEvaluatedOnce() {
        let c = clip(media: UUID(), volume: 0.5)
        let f = TimelineView.volumeDB(of: c)
        #expect(abs(f(0) - AudioGain.db(fromLinear: 0.5)) < 1e-9)
        #expect(f(0) == f(3.7))
    }
}
