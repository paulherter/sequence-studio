import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

private let fd = Time(1, 30)

/// Q-PERF2 recs 1-3 at engine level (headless, manual clock): idle detection + wake hook, cadence, power policy.
@Suite(.serialized) @MainActor struct IdlePowerEngineTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func makeEngine() async throws -> (PlaybackEngine, ManualClock, Timeline) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec()
        spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30)
        let url = try await TestClipWriter.write(spec)
        let media = UUID()
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]), clock: clock)
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60), start: .zero, mediaDuration: fd * 60)
        let tl = Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])
        engine.setTimeline(tl)
        return (engine, clock, tl)
    }

    private func settle(_ engine: PlaybackEngine) async {
        for _ in 0..<20 { engine.tick(); await engine.waitForDecodes() }
        engine.tick()
    }

    @Test func idleAfterTheFrameIsUpAndWokenByEveryChange() async throws {
        let (engine, _, tl) = try await makeEngine()
        let wakes = Counter()
        engine.loop.setWaker { wakes.hit() }
        #expect(!engine.loop.isIdle)                     // nothing presented yet
        engine.seek(to: .zero)
        #expect(wakes.value >= 1)
        await settle(engine)
        #expect(engine.loop.isIdle)
        #expect(engine.loop.cadence().idle)

        var w = wakes.value
        engine.seek(to: fd * 10)
        #expect(wakes.value > w && !engine.loop.isIdle)
        await settle(engine)
        #expect(engine.loop.isIdle)

        w = wakes.value
        engine.setTimeline(tl)                           // an edit
        #expect(wakes.value > w && !engine.loop.isIdle)
        await settle(engine)

        w = wakes.value
        engine.redraw()
        #expect(wakes.value > w)
        await settle(engine)

        w = wakes.value
        engine.beginScrub()
        #expect(wakes.value > w)
        await settle(engine)
        #expect(!engine.loop.isIdle)                     // scrubbing keeps ticking
        engine.endScrub()
        await settle(engine)
        #expect(engine.loop.isIdle)

        w = wakes.value
        engine.play()
        #expect(wakes.value > w && !engine.loop.isIdle)  // playing never idles
        let c = engine.loop.cadence()
        #expect(c.range == FramePacing.Range(minimum: 30, maximum: 60, preferred: 30))
        #expect(!c.idle)
        engine.pause()
        await settle(engine)
        #expect(engine.loop.isIdle)
        #expect(engine.loop.cadence().range == FramePacing.interactive)
    }

    @Test func seriousHeatCapsTheViewerDecodeButKeepsTheUsersChoice() async throws {
        let (engine, _, _) = try await makeEngine()
        let wakes = Counter()
        engine.loop.setWaker { wakes.hit() }
        engine.powerPolicy = PowerPolicy(thermal: .serious, lowPower: false)
        #expect(wakes.value >= 1)
        #expect(engine.quality == .full)
        #expect(engine.effectiveQuality == .half)
        #expect(engine.loop.state.withLock { $0.quality } == .half)
        #expect(engine.loop.powerPolicy.halvesPrefetch)
        engine.quality = .quarter
        #expect(engine.loop.state.withLock { $0.quality } == .quarter)
        engine.quality = .full
        engine.powerPolicy = .normal
        #expect(engine.loop.state.withLock { $0.quality } == .full)
        #expect(!engine.loop.powerPolicy.halvesPrefetch)
    }

    @Test func memoryPressureAndIdleTrimTheIntermediatePool() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let src = ManualPressureSource()
        let loop = try RenderLoop(device: device, resolver: StaticMediaResolver(demuxers: [:]), clock: ManualClock(),
                                  cache: FrameCache(), pressure: src)
        #expect(src.isStarted)
        let trims = TrimLog()
        loop.trimPool = { trims.add($0) }
        src.fire(.normal)
        src.fire(.warning)
        src.fire(.critical)
        #expect(trims.values == [RenderLoop.trimmedPoolBytes, 0])

        loop.idleTrimDelay = .milliseconds(20)
        loop.scheduleIdleTrim()                          // no timeline: idle -> trims after the delay
        for _ in 0..<SQTiming.polls(200) where trims.values.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(trims.values == [RenderLoop.trimmedPoolBytes, 0, RenderLoop.trimmedPoolBytes])

        loop.idleTrimDelay = .milliseconds(50)
        loop.scheduleIdleTrim()
        loop.invalidate()                                // woke up before the delay: no trim
        try await Task.sleep(for: .milliseconds(200))
        #expect(trims.values.count == 3)
    }

    private final class TrimLog: @unchecked Sendable {
        private let lock = NSLock(); private var v: [Int] = []
        func add(_ n: Int) { lock.withLock { v.append(n) } }
        var values: [Int] { lock.withLock { v } }
    }
}
