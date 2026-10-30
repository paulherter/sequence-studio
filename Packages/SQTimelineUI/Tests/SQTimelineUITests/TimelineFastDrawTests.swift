import AppKit
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQTimelineUI

/// The 2x draw-cost fast paths (clip chrome cut at device pixels, cache bitmap in the destination's layout copied out by rows)
/// must draw what the plain drawing draws: two identical views, one with the fast paths off, drawn side by side through
/// scrolls and zooms, at 1x and 2x, on and off the pixel grid, into RGBA and BGRA bitmaps. CoreGraphics rasterizes a cut
/// rounded end a few levels differently from the whole path at the corners (antialiasing only), so channels may differ by
/// `tolerance`; anything visible (a missing or misplaced shape, a wrong color) is far above it.
/// Serialized: the fast-path switch is a static, and parallel arguments would interleave at their awaits.
@MainActor @Suite(.serialized) struct TimelineFastDrawTests {
    static let tolerance = 20   // the board edge is white 22 % at 0.5 pt (was 11 % at 1 pt): a corner pixel differs by up to ~18 levels

    /// Largest channel difference of two equally sized bitmaps.
    /// Compares 8-byte words first and looks at the bytes of differing words only: a byte loop over multi-MB bitmaps in a
    /// debug build ran for over a minute on the main actor and starved every other test (looked like a stall).
    static func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        precondition(a.count == b.count)
        var m = 0
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                let words = pa.count / 8
                let wa = pa.bindMemory(to: UInt64.self), wb = pb.bindMemory(to: UInt64.self)
                for w in 0..<words where wa[w] != wb[w] {
                    for k in (w * 8)..<(w * 8 + 8) { m = max(m, abs(Int(pa[k]) - Int(pb[k]))) }
                }
                for k in (words * 8)..<pa.count { m = max(m, abs(Int(pa[k]) - Int(pb[k]))) }
            }
        }
        return m
    }

    /// One clip's chrome over random rects, rows on and off the pixel grid, both scales, clamped by the visible range.
    @Test func cutChromeMatchesWholePathChrome() {
        func render(scale: CGFloat, rect: CGRect, visible: CGRect, selected: Bool, style: ClipStyle, offline: Bool, fast: Bool) -> [UInt8] {
            let w = Int(120 * scale), h = Int(60 * scale)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buf in
                let cg = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: scale, y: -scale)
                ClipDrawing.usePixelCuts = fast
                defer { ClipDrawing.usePixelCuts = true }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                ClipDrawing.draw(name: "Name", rect: rect, visible: visible, style: style, isSelected: selected, isOffline: offline)
                NSGraphicsContext.restoreGraphicsState()
            }
            return bytes
        }
        var g = SeededGenerator(seed: 7)
        var worst = 0, bad: [String] = []
        for i in 0..<1500 {
            let scale: CGFloat = i % 3 == 0 ? 1 : 2
            let x = CGFloat(Double.random(in: -60...110, using: &g)), wdt = CGFloat(Double.random(in: 0.2...300, using: &g))
            let (y, hgt): (CGFloat, CGFloat) = i % 2 == 0 ? [(4, 26), (4, 32), (10, 33.5), (2.5, 33.5), (5, 22), (3, 44), (1, 52)][i % 7]
                : (CGFloat(Double.random(in: 0...10, using: &g)), CGFloat(Double.random(in: 12...55, using: &g)))
            let vis = CGRect(x: CGFloat(Double.random(in: -10...40, using: &g)).rounded(), y: 0, width: 80, height: 60)
            let style: ClipStyle = [.video, .audio, .caption, .label(LabelColor.allCases[i % LabelColor.allCases.count])][i % 4]
            let r = CGRect(x: x, y: y, width: wdt, height: hgt)
            let args = (scale, r, vis, i % 2 == 0, style, i % 11 == 0)
            let m = Self.maxDiff(render(scale: args.0, rect: args.1, visible: args.2, selected: args.3, style: args.4, offline: args.5, fast: false),
                                 render(scale: args.0, rect: args.1, visible: args.2, selected: args.3, style: args.4, offline: args.5, fast: true))
            worst = max(worst, m)
            if m > Self.tolerance, bad.count < 10 { bad.append("s\(scale) \(r) vis \(vis.minX) sel \(args.3) \(style): \(m)") }
        }
        #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
        #expect(worst <= Self.tolerance)
    }

    /// Deterministic random numbers (SplitMix64) so a failing rect reproduces.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
    private static let fd = Time(1, 24)
    private static let size = CGSize(width: 700, height: 300)
    private static let media = (0..<3).map { n in UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n))! }

    private static func waveforms() -> TimelineWaveforms {
        let wf = TimelineWaveforms(builder: { _ in throw CancellationError() })
        for (i, id) in media.enumerated() { wf.setData(TimelineScrollPerfTests.waveform(seed: i, seconds: 15), for: id) }
        return wf
    }

    private func view(_ wf: TimelineWaveforms, height: CGFloat?) -> TimelineView {
        var tracks: [Track] = []
        var selected: Set<Clip.ID> = []
        for i in 0..<4 {
            let kind: TrackKind = i < 2 ? .video : .audio
            var start: Int64 = 0
            let clips = (0..<14).map { n -> Clip in
                let len = Int64(7 + (n * 37 + i * 11) % 150)                     // frames: thin to wider than the view
                let id = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", i * 100 + n))!
                var c = Clip(name: "Clip \(i)-\(n) with a long name", media: kind == .audio ? Self.media[(i + n) % 3] : id, kind: kind,
                             source: TimeRange(start: Self.fd * Int64(n * 11), duration: Self.fd * len), start: Self.fd * start)
                if n == 4 { c.isEnabled = false }
                if kind == .audio, n % 3 == 0 { c.animation.volume.value = 0.5 }
                if n % 5 == 1 { selected.insert(c.id) }
                start += len + Int64(n % 4 == 0 ? 5 : 0)
                return c
            }
            tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: i == 0))
        }
        var t = Timeline(name: "fast", frameDuration: Self.fd, tracks: tracks)
        t.captionTracks = [CaptionTrack(items: (0..<20).map { n in
            CaptionItem(lines: ["Caption number \(n) runs long"], range: TimeRange(start: Time(Int64(n * 4), 1), end: Time(Int64(n * 4 + 3), 1)))
        })]
        let v = TimelineView(timeline: t, frame: NSRect(origin: .zero, size: Self.size))
        v.waveforms = wf
        if let height { v.setTrackHeights(Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, height) })) }
        v.setSelection(selected)
        v.setOfflineMedia([tracks[0].clips[2].media, Self.media[1]])
        return v
    }

    private func render(_ v: TimelineView, scale: CGFloat, offset: CGFloat, bgra: Bool, fast: Bool) -> [UInt8] {
        let w = Int(Self.size.width * scale), h = Int(Self.size.height * scale)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = bgra ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                        : CGImageAlphaInfo.premultipliedLast.rawValue
        let space = bgra ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buf in
            let cg = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!
            cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: offset, y: offset)                           // fractional panel origin: off the pixel grid
            ClipDrawing.usePixelCuts = fast
            v.contentCache.fastOutput = fast
            defer { ClipDrawing.usePixelCuts = true }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        return bytes
    }

    @Test(arguments: [(1.0, 0.0), (2.0, 0.0), (2.0, 0.25), (1.0, 0.5), (2.0, 0.5)])
    func fastPathsDrawTheSameBytes(scale: Double, offset: Double) async {
        let wf = Self.waveforms()
        var failures: [String] = []
        var copies = 0, renders = 0
        for height: CGFloat? in [nil, 70, 33.5, 22] {
            for bgra in [false, true] {
                // `warm` draws each step first (whole view, no content cache) until its draw asks for no more waveform
                // builds: the compared views then draw from the same settled peaks, exact tiles in both.
                let plain = view(wf, height: height), fast = view(wf, height: height), warm = view(wf, height: height)
                warm.contentCache.isEnabled = false
                for cache in [true, false] {
                    plain.contentCache.isEnabled = cache; fast.contentCache.isEnabled = cache
                    var step = 0
                    func both(_ change: (TimelineView) -> Void) async {
                        change(warm); change(plain); change(fast)
                        var settled = false
                        for _ in 0..<SQTiming.polls(8) where !settled {
                            let n = wf.cache.buildsStarted
                            _ = render(warm, scale: scale, offset: offset, bgra: bgra, fast: false)
                            settled = wf.cache.buildsStarted == n
                            await wf.cache.waitForIdle()
                        }
                        let n0 = wf.cache.buildsStarted
                        let a = render(plain, scale: scale, offset: offset, bgra: bgra, fast: false)
                        let b = render(fast, scale: scale, offset: offset, bgra: bgra, fast: true)
                        step += 1
                        let label = "s\(scale) o\(offset) h \(height.map { "\($0)" } ?? "default") bgra \(bgra) cache \(cache) step \(step)"
                        if !settled || wf.cache.buildsStarted != n0 { failures.append("\(label): waveform cache did not settle") }
                        let m = Self.maxDiff(a, b)
                        guard m > Self.tolerance else { return }
                        let i = a.indices.first { abs(Int(a[$0]) - Int(b[$0])) == m }!
                        let w = Int(Self.size.width * scale)
                        failures.append("\(label): max diff \(m) at (\(i / 4 % w), \(i / 4 / w)) \(a[i]) vs \(b[i]), out \(fast.contentCache.lastPath)")
                    }
                    await both { $0.setZoom(pointsPerSecond: 40); $0.scroll(toX: 0); $0.scroll(toY: 0) }
                    for _ in 0..<3 { await both { $0.scroll(byX: 37, y: 0) } }
                    await both { $0.scroll(byX: 0, y: 9) }
                    for z in [13.7, 97.31, 260.5] { await both { $0.setZoom(pointsPerSecond: z, anchorX: 333) } }
                    await both { $0.scroll(byX: 13.5, y: 0) }
                }
                copies += fast.contentCache.directCopies; renders += fast.contentCache.directRenders
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(12).joined(separator: "\n"))")
        // Off the pixel grid (a fractional device origin) the cache is not pixel-aligned with the destination: image draw.
        // On the grid zoom steps render straight into the destination and scroll steps go out by row copies.
        if (scale * offset).rounded() == scale * offset { #expect(copies > 0); #expect(renders > 0) }
    }
}
