import CoreMedia
import Foundation
import Metal
import Testing
import SQAnalysis
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// Playback cost of a clip with a tracked Magic mask (the maintainer's report: about 1 FPS with a subject mask on his face, smooth
// again once the mask is removed). One tick per frame over a 1080p clip, with and without the mask.

private let fd = Time(1, 30)
private let frames = 60

private func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
private func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
private func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }
private func s(_ v: Double) -> String { String(format: "%.2f", v) }

@Suite(.serialized) @MainActor struct MagicMaskPlaybackCostTests {
    /// A 1080p clip, and one with a Magic mask whose mattes (`matteWidth` wide, a face-sized ellipse) are stored for every frame.
    private func scene(matteWidth: Int, feather: Double) async throws -> (engine: PlaybackEngine, clock: ManualClock,
                                                                          plain: Timeline, masked: Timeline, key: String) {
        var spec = TestClipSpec()
        spec.width = 1920; spec.height = 1080; spec.frameCount = frames
        let url = try await TestClipWriter.write(spec)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]),
                                        clock: clock)
        engine.quality = .full
        engine.waitsForStartFrame = false
        let plainClip = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * Int64(frames)), start: .zero)
        var clip = plainClip
        let added = clip.magicClick(nil, at: Vec2(0.5, 0.4), subtract: false, sourceTime: .zero)
        let id = try #require(added)
        clip.updateMask(id) { $0.feather = AnimatedProperty(feather) }
        let key = try #require(clip.mask(id)?.magic?.cacheKey(media: media))
        let mw = matteWidth, mh = matteWidth * 9 / 16
        for i in 0..<frames {
            var v = [Float](repeating: 0, count: mw * mh)
            let cx = Double(mw) * (0.4 + 0.2 * Double(i) / Double(frames)), cy = Double(mh) * 0.4, r = Double(mh) * 0.2
            for y in 0..<mh { for x in 0..<mw where hypot(Double(x) - cx, Double(y) - cy) < r { v[y * mw + x] = 1 } }
            MagicMatteStore.shared.put(SubjectMatte(width: mw, height: mh, values: v), key: key, pts: Double(i) / 30)
        }
        func tl(_ c: Clip) -> Timeline {
            Timeline(name: "t", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [Track(kind: .video, clips: [c])])
        }
        return (engine, clock, tl(plainClip), tl(clip), key)
    }

    /// ms per tick of one playback pass from frame 0, and the mattes the render thread decoded itself.
    private func pass(_ engine: PlaybackEngine, _ clock: ManualClock) async -> (tick: [Double], build: [Double], encode: [Double], gpu: [Double], inline: Int) {
        engine.pause()
        engine.seek(to: .zero)
        for _ in 0..<50 {
            _ = engine.tick()
            await engine.waitForDecodes()
            if let p = engine.lastTickProfile, p.presented, p.missing == 0, p.noFrame == 0 { break }
        }
        let inline0 = MagicMatteStore.shared.inlineDecodes
        engine.play(.forward)
        var tick: [Double] = [], build: [Double] = [], encode: [Double] = [], gpu: [Double] = []
        let wall = ContinuousClock()
        for _ in 0..<frames - 2 {
            await engine.waitForDecodes()
            var shown = false
            tick.append(ms(wall.measure { shown = engine.tick() }))
            if shown, let p = engine.lastTickProfile {
                build.append(ms(p.build)); encode.append(ms(p.encode)); gpu.append(ms(p.gpuWait))
            }
            clock.advance(by: fd)
        }
        engine.pause()
        return (tick, build, encode, gpu, MagicMatteStore.shared.inlineDecodes - inline0)
    }

    /// ms per tick of seeks to every frame while paused (scrubbing, the settled-frame path).
    private func scrub(_ engine: PlaybackEngine) async -> [Double] {
        engine.pause()
        var out: [Double] = []
        let wall = ContinuousClock()
        for f in 0..<frames - 2 {
            engine.seek(to: fd * Int64(f))
            await engine.waitForDecodes()
            out.append(ms(wall.measure { _ = engine.tick() }))
        }
        return out
    }

    @Test(arguments: [[960, 0], [960, 10], [1920, 10]])
    func aMagicMaskCostsLittleOverThePlainClip(_ args: [Int]) async throws {
        let sc = try await scene(matteWidth: args[0], feather: Double(args[1]))
        defer { MagicMatteStore.shared.remove(key: sc.key) }
        sc.engine.setTimeline(sc.plain)
        _ = await pass(sc.engine, sc.clock)
        let plain = await pass(sc.engine, sc.clock)
        let plainScrub = await scrub(sc.engine)
        sc.engine.setTimeline(sc.masked)
        let masked = await pass(sc.engine, sc.clock)
        let masked2 = await pass(sc.engine, sc.clock)
        let maskedScrub = await scrub(sc.engine)
        print("PERF magic mask matte \(args[0]) feather \(args[1]): plain tick \(s(mean(plain.tick))) p95 \(s(p95(plain.tick))) "
            + "build \(s(mean(plain.build))) | masked p1 tick \(s(mean(masked.tick))) p95 \(s(p95(masked.tick))) "
            + "build \(s(mean(masked.build))) encode \(s(mean(masked.encode))) gpuWait \(s(mean(masked.gpu))) inline \(masked.inline) | p2 tick \(s(mean(masked2.tick))) inline \(masked2.inline) "
            + "| scrub plain \(s(mean(plainScrub))) masked \(s(mean(maskedScrub)))")
        #expect(mean(masked2.tick) < mean(plain.tick) + 8, "masked \(mean(masked2.tick)) ms vs plain \(mean(plain.tick)) ms")
        #expect(mean(maskedScrub) < mean(plainScrub) + 15, "scrub masked \(mean(maskedScrub)) ms vs plain \(mean(plainScrub)) ms")
    }
}
