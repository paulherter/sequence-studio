import AVFoundation
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

/// Poster / thumbnail cost per variant (docs/PLAYBACK-PERF.md "Import: posters"). A measurement, not a check: it runs only
/// with `SQ_POSTER_BENCH=<report file>` and writes its lines there (scripts/test.sh prints failures only).
private enum PosterBench {
    static let height = 216
    static let clock = ContinuousClock()

    /// `count` copies of one synthetic clip, each under its own URL (nothing is shared between two posters).
    static func clips(_ codec: TestClipSpec.Codec, _ w: Int, _ h: Int, count: Int) async throws -> [URL] {
        var s = TestClipSpec(); s.codec = codec; s.width = w; s.height = h; s.frameCount = 48
        let first = try await TestClipWriter.write(s)
        var all = [first]
        for i in 1..<count {
            let u = first.deletingLastPathComponent().appendingPathComponent("copy\(i).mov")
            try FileManager.default.copyItem(at: first, to: u)
            all.append(u)
        }
        return all
    }

    static func generator(_ url: URL, exact: Bool, sized: Bool) async throws -> AVAssetImageGenerator {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if exact { gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero }
        if sized {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            gen.maximumSize = CGSize(width: (CGFloat(height) * abs(shown.width) / abs(shown.height)).rounded(), height: CGFloat(height))
        }
        return gen
    }

    /// Best of `rounds`: average milliseconds per clip of `body` over `urls`, one at a time.
    static func perClip(_ urls: [URL], rounds: Int = 3, _ body: (URL) async throws -> Void) async rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<rounds {
            let t0 = clock.now
            for u in urls { try await body(u) }
            best = min(best, SQTiming.ms(clock.now - t0) / Double(urls.count))
        }
        return best
    }

    static func ms(_ v: Double) -> String { String(format: "%.1f", v) }

    static func cpuNow() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
    }

    /// Process CPU milliseconds per clip (best of `rounds`); the bench runs alone, so this is the posters' own CPU.
    static func cpuPerClip(_ urls: [URL], rounds: Int = 3, _ body: (URL) async throws -> Void) async rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<rounds {
            let t0 = cpuNow()
            for u in urls { try await body(u) }
            best = min(best, (cpuNow() - t0) / Double(urls.count))
        }
        return best
    }

    static func viaHandler(_ g: AVAssetImageGenerator, _ t: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { c in
            g.generateCGImageAsynchronously(for: t) { image, _, error in
                if let image { c.resume(returning: image) } else { c.resume(throwing: error ?? CancellationError()) }
            }
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_POSTER_BENCH"] != nil))
func posterBench() async throws {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SQ_POSTER_BENCH"] ?? "/dev/null")
    var lines: [String] = []
    let poster = CMTime(value: 6, timescale: 30)          // frame 6 of a 12-frame GOP: what a short clip's poster asks for
    let formats: [(String, TestClipSpec.Codec, Int, Int)] = [("h264-1080p", .h264, 1920, 1080), ("hevc10-2160p", .hevcMain10, 3840, 2160)]
    for (name, codec, w, h) in formats {
        let urls = try await PosterBench.clips(codec, w, h, count: 8)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        _ = try await PosterBench.generator(urls[0], exact: false, sized: true).image(at: poster)   // warm the decoder stack

        // What ships: Thumbnailer, a fresh one per round (no cache hit), with and without a chosen pixel aspect.
        // Interleaved rounds, so load drift hits both alike; the ratio is the median of the per-round ratios.
        var plain = Double.infinity, shaped = Double.infinity, ratios: [Double] = []
        for _ in 0..<8 {
            let a = try await PosterBench.perClip(urls, rounds: 1) { u in
                _ = try await Thumbnailer(pressure: nil).thumbnail(media: UUID(), url: u, at: poster, height: PosterBench.height, exact: false)
            }
            let b = try await PosterBench.perClip(urls, rounds: 1) { u in
                _ = try await Thumbnailer(pressure: nil).thumbnail(media: UUID(), url: u, at: poster, height: PosterBench.height, exact: false,
                                                                   pixelAspect: .square)
            }
            plain = min(plain, a); shaped = min(shaped, b); ratios.append(b / a)
        }
        let shipped = plain, shippedAspect = shaped
        lines.append("\(name) thumbnailer with aspect / without, median of 8 rounds: " + String(format: "%.3f", ratios.sorted()[4]))
        let tolerant = try await PosterBench.perClip(urls) { u in
            _ = try await PosterBench.generator(u, exact: false, sized: true).image(at: poster)
        }
        let exact = try await PosterBench.perClip(urls) { u in
            _ = try await PosterBench.generator(u, exact: true, sized: true).image(at: poster)
        }
        let unsized = try await PosterBench.perClip(urls) { u in
            _ = try await PosterBench.generator(u, exact: false, sized: false).image(at: poster)
        }
        let open = try await PosterBench.perClip(urls) { u in _ = try await PosterBench.generator(u, exact: false, sized: true) }
        let secondAsset = try await PosterBench.perClip(urls) { u in
            let t = try await AVURLAsset(url: u).loadTracks(withMediaType: .video).first
            _ = try await t?.load(.formatDescriptions); _ = try await t?.load(.preferredTransform)
        }
        let batchOfOne = try await PosterBench.perClip(urls) { u in
            for await r in try await PosterBench.generator(u, exact: false, sized: true).images(for: [poster]) { _ = try r.image }
        }
        let handler = try await PosterBench.perClip(urls) { u in
            _ = try await PosterBench.viaHandler(try await PosterBench.generator(u, exact: false, sized: true), poster)
        }
        let cpuImageAt = try await PosterBench.cpuPerClip(urls) { u in
            _ = try await PosterBench.generator(u, exact: false, sized: true).image(at: poster)
        }
        let cpuBatch = try await PosterBench.cpuPerClip(urls) { u in
            for await r in try await PosterBench.generator(u, exact: false, sized: true).images(for: [poster]) { _ = try r.image }
        }
        let cpuHandler = try await PosterBench.cpuPerClip(urls) { u in
            _ = try await PosterBench.viaHandler(try await PosterBench.generator(u, exact: false, sized: true), poster)
        }
        lines.append("\(name) single request ms: image(at:) \(PosterBench.ms(tolerant)), images(for: [t]) \(PosterBench.ms(batchOfOne)), "
            + "completion handler \(PosterBench.ms(handler)); CPU ms: image(at:) \(PosterBench.ms(cpuImageAt)), "
            + "images(for: [t]) \(PosterBench.ms(cpuBatch)), completion handler \(PosterBench.ms(cpuHandler))")
        lines.append("\(name) per poster ms: thumbnailer \(PosterBench.ms(shipped)), with aspect \(PosterBench.ms(shippedAspect)), "
            + "tolerant \(PosterBench.ms(tolerant)), exact \(PosterBench.ms(exact)), no maximumSize \(PosterBench.ms(unsized)), "
            + "open only \(PosterBench.ms(open)), second asset \(PosterBench.ms(secondAsset))")

        // Several frames of one clip (hover scrub, clip frames): a generator per frame, one generator, one batch.
        let times = (0..<8).map { CMTime(value: Int64($0) * 6, timescale: 30) }
        for isExact in [false, true] {
            let fresh = try await PosterBench.perClip([urls[0]]) { u in
                for t in times { _ = try await PosterBench.generator(u, exact: isExact, sized: true).image(at: t) }
            }
            let reused = try await PosterBench.perClip([urls[0]]) { u in
                let g = try await PosterBench.generator(u, exact: isExact, sized: true)
                for t in times { _ = try await g.image(at: t) }
            }
            let batch = try await PosterBench.perClip([urls[0]]) { u in
                let g = try await PosterBench.generator(u, exact: isExact, sized: true)
                for await r in g.images(for: times) { _ = try r.image }
            }
            lines.append("\(name) 8 frames of one clip (\(isExact ? "exact" : "tolerant")) ms per frame: generator each "
                + "\(PosterBench.ms(fresh / 8)), one generator \(PosterBench.ms(reused / 8)), images(for:) \(PosterBench.ms(batch / 8))")
        }

        // Two frames of each clip (the Color page Clips list: poster + the clip's first frame), the only burst a caller
        // makes today. One after the other, and all 8 clips at width 4 (16 single jobs against 8 jobs of a pair).
        let pair = [poster, CMTime(value: 30, timescale: 30)]
        var pairSerial: [Double] = [], pairWide: [Double] = [], singleBest = Double.infinity, batchBest = Double.infinity
        var singleWide = Double.infinity, batchWide = Double.infinity, shippedRatios: [Double] = []
        for _ in 0..<8 {
            let a = try await PosterBench.perClip(urls, rounds: 1) { u in
                for t in pair { _ = try await PosterBench.generator(u, exact: false, sized: true).image(at: t) }
            }
            let b = try await PosterBench.perClip(urls, rounds: 1) { u in
                for await r in try await PosterBench.generator(u, exact: false, sized: true).images(for: pair) { _ = try r.image }
            }
            singleBest = min(singleBest, a); batchBest = min(batchBest, b); pairSerial.append(b / a)
            let limiter = AsyncLimiter(width: 4)
            var t0 = PosterBench.clock.now
            try await withThrowingTaskGroup(of: Void.self) { g in
                for u in urls {
                    for t in pair {
                        g.addTask { try await limiter.runThrowing { _ = try await PosterBench.generator(u, exact: false, sized: true).image(at: t) } }
                    }
                }
                try await g.waitForAll()
            }
            let c = SQTiming.ms(PosterBench.clock.now - t0)
            t0 = PosterBench.clock.now
            try await withThrowingTaskGroup(of: Void.self) { g in
                for u in urls {
                    g.addTask {
                        try await limiter.runThrowing {
                            for await r in try await PosterBench.generator(u, exact: false, sized: true).images(for: pair) { _ = try r.image }
                        }
                    }
                }
                try await g.waitForAll()
            }
            let d = SQTiming.ms(PosterBench.clock.now - t0)
            singleWide = min(singleWide, c); batchWide = min(batchWide, d); pairWide.append(d / c)
            // What ships: the Thumbnailer, two single requests per clip against one `thumbnails(at:)` per clip.
            let one = Thumbnailer(limiter: AsyncLimiter(width: 4), pressure: nil)
            t0 = PosterBench.clock.now
            try await withThrowingTaskGroup(of: Void.self) { g in
                for u in urls {
                    let id = UUID()
                    for t in pair { g.addTask { _ = try await one.thumbnail(media: id, url: u, at: t, height: PosterBench.height, exact: false) } }
                }
                try await g.waitForAll()
            }
            let e = SQTiming.ms(PosterBench.clock.now - t0)
            let both = Thumbnailer(limiter: AsyncLimiter(width: 4), pressure: nil)
            t0 = PosterBench.clock.now
            await withTaskGroup(of: Void.self) { g in
                for u in urls {
                    g.addTask { _ = await both.thumbnails(media: UUID(), url: u, at: pair, height: PosterBench.height, exact: false) }
                }
            }
            let f = SQTiming.ms(PosterBench.clock.now - t0)
            shippedRatios.append(f / e)
        }
        lines.append("\(name) 2 frames of one clip ms per frame: generator each \(PosterBench.ms(singleBest / 2)), images(for:) "
            + "\(PosterBench.ms(batchBest / 2)), batch / single median of 8 rounds " + String(format: "%.3f", pairSerial.sorted()[4])
            + "; 8 clips x 2 frames at width 4, wall ms: single \(PosterBench.ms(singleWide)), batch \(PosterBench.ms(batchWide)), "
            + "median ratio " + String(format: "%.3f", pairWide.sorted()[4])
            + "; Thumbnailer thumbnails(at:) / two thumbnail calls, median " + String(format: "%.3f", shippedRatios.sorted()[4]))

        // Across clips: wall time for all 8 posters at a given width.
        var widths: [String] = []
        for width in [1, 2, 4, 6, 8] {
            let limiter = AsyncLimiter(width: width)
            var best = Double.infinity
            for _ in 0..<3 {
                let t0 = PosterBench.clock.now
                try await withThrowingTaskGroup(of: Void.self) { g in
                    for u in urls {
                        g.addTask { try await limiter.runThrowing { _ = try await PosterBench.generator(u, exact: false, sized: true).image(at: poster) } }
                    }
                    try await g.waitForAll()
                }
                best = min(best, SQTiming.ms(PosterBench.clock.now - t0))
            }
            widths.append("\(width): \(PosterBench.ms(best))")
        }
        lines.append("\(name) 8 posters wall ms by width: " + widths.joined(separator: ", "))
    }
    try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
}
