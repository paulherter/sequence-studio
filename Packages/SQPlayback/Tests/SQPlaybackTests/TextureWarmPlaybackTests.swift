import CoreMedia
import Foundation
import Metal
import Synchronization
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// Texture warm (PLAYBACK-PERF "Playback: render-thread tick CPU"): while playing, the next frame's plane textures are made
// off the render thread, so the draw wraps (almost) no pixel buffer itself.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

private actor Clips {
    static let shared = Clips()
    private var urls: [URL]?
    func get() async throws -> [URL] {
        if let urls { return urls }
        var spec = TestClipSpec(); spec.frameCount = 90
        let r = [try await TestClipWriter.write(spec), try await TestClipWriter.write(spec)]
        urls = r
        return r
    }
}

/// Two stacked 90-frame clips (the upper at half size, so both are drawn), paused complete at frame 0.
@MainActor private func twoLayerEngine(_ clock: ManualClock) async throws -> PlaybackEngine {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let spec = TestClipSpec()
    let a = UUID(), b = UUID()
    let urls = try await Clips.shared.get()
    let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: urls[0]), b: try await AVDemuxer(url: urls[1])], audio: [:])
    let engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
    engine.quality = .full
    engine.waitsForStartFrame = false
    let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(90)), start: .zero)
    var upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: .zero, duration: f(90)), start: .zero)
    upper.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
    let tl = Timeline(name: "warm", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                      tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
    engine.setTimeline(tl)
    engine.seek(to: .zero)
    for _ in 0..<200 {
        _ = engine.tick()
        await engine.waitForDecodes()
        if let p = engine.lastTickProfile, p.presented, p.missing == 0, p.noFrame == 0 { break }
    }
    return engine
}

/// Plays `ticks` display ticks of `fd` wall time each; returns complete two-layer frames and the counter deltas.
@MainActor private func play(_ engine: PlaybackEngine, _ clock: ManualClock, rate: PlaybackRate, ticks: Int)
    async -> (frames: Int, drawn: Int, warmed: Int) {
    engine.play(rate)
    let start = engine.loop.planeTextureCounts()
    var frames = 0
    for _ in 0..<ticks {
        await engine.waitForDecodes()
        _ = engine.loop.planeTextureCounts()            // the warm of the last tick is done
        clock.advance(by: fd)
        if engine.tick(), let p = engine.lastTickProfile, p.presented, p.layers == 2, p.missing == 0 { frames += 1 }
    }
    let end = engine.loop.planeTextureCounts()
    return (frames, end.drawn - start.drawn, end.warmed - start.warmed)
}

@Suite(.serialized) @MainActor struct TextureWarmPlaybackTests {
    @Test func playingDrawsWarmedTextures() async throws {
        let clock = ManualClock()
        let engine = try await twoLayerEngine(clock)
        let r = await play(engine, clock, rate: .init(1, 1), ticks: 40)
        #expect(r.frames >= 35)
        // Two layers of two planes per frame: the warm made them, the draws (nearly) none (the first frames have no step).
        #expect(r.warmed >= 4 * (r.frames - 2), "\(r)")
        #expect(r.drawn <= 8, "\(r)")
        #expect(engine.stats.droppedFrames == 0)
    }

    @Test func doubleSpeedWarmsTheFrameItReallyShowsNext() async throws {
        // 2x: every tick moves two grid frames, so the guess is t + 2 frames, not t + 1.
        let clock = ManualClock()
        let engine = try await twoLayerEngine(clock)
        let r = await play(engine, clock, rate: .init(2, 1), ticks: 35)
        #expect(r.frames >= 25, "\(r)")
        #expect(r.drawn <= 8, "\(r)")
        #expect(r.warmed >= 4 * (r.frames - 2), "\(r)")
        #expect(engine.stats.droppedFrames == 0)
    }

    @Test func aTickWhileTheWarmStillRunsSkipsItsWarmAndDrawsItself() async throws {
        let clock = ManualClock()
        let engine = try await twoLayerEngine(clock)
        _ = await play(engine, clock, rate: .init(1, 1), ticks: 4)     // steps known, warms running
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }                      // never leave the warm queue blocked
        let blocked = Atomic<Bool>(false), entered = Atomic<Bool>(false)
        engine.loop.textureWarmHook = {
            guard !blocked.exchange(true, ordering: .relaxed) else { return }
            entered.store(true, ordering: .releasing)
            release.wait()
        }
        await engine.waitForDecodes()
        clock.advance(by: fd)
        #expect(engine.tick())                          // starts the warm that blocks
        for _ in 0..<5000 where !entered.load(ordering: .acquiring) { try await Task.sleep(for: .milliseconds(1)) }
        let didEnter = entered.load(ordering: .acquiring)
        #expect(didEnter)
        let skippedBefore = engine.loop.textureWarmsSkipped.load(ordering: .relaxed)
        let drawnBefore = engine.loop.planeTexturesDrawn
        await engine.waitForDecodes()
        clock.advance(by: fd)
        #expect(engine.tick())
        let p = try #require(engine.lastTickProfile)
        #expect(p.presented && p.layers == 2 && p.missing == 0)
        let skipped = engine.loop.textureWarmsSkipped.load(ordering: .relaxed)
        #expect(skipped == skippedBefore + 1)
        // The frame the blocked warm did not reach was wrapped by the draw.
        #expect(engine.loop.planeTexturesDrawn > drawnBefore)
        release.signal()
        engine.loop.textureWarmHook = nil
        let r = await play(engine, clock, rate: .init(1, 1), ticks: 10)
        #expect(r.frames >= 8 && r.warmed > 0, "\(r)")
        #expect(engine.stats.droppedFrames == 0)
    }

    @Test func warmStepsGuessFromWhatWasShown() {
        var w = RenderLoop.WarmSteps()
        let fd = Time(1, 30)
        #expect(w.next(after: .zero, forward: true, playing: true, frame: fd).isEmpty)          // no step yet
        #expect(w.next(after: fd * 2, forward: true, playing: true, frame: fd) == [fd * 4])     // 2x
        #expect(w.next(after: fd * 3, forward: true, playing: true, frame: fd) == [fd * 4, fd * 5])  // uneven: both
        #expect(w.next(after: fd * 2, forward: false, playing: true, frame: fd).isEmpty)        // direction change
        #expect(w.next(after: fd, forward: false, playing: true, frame: fd) == [.zero])
        #expect(w.next(after: fd * 40, forward: false, playing: true, frame: fd).isEmpty)       // a seek
        #expect(w.next(after: fd * 41, forward: true, playing: false, frame: fd).isEmpty)       // paused
        #expect(w.next(after: fd * 42, forward: true, playing: true, frame: fd).isEmpty)        // starts over
    }
}
