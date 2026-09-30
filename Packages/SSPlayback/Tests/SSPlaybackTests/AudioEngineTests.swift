import Testing
import Foundation
import AVFoundation
import CoreMedia
import SSCore
import SSMedia
import SSMediaTestSupport
@testable import SSPlayback

// MARK: Render core (headless)

private func sine(_ range: Range<Int>, phase: Double, amp: Float = 0.5) -> [Float] {
    range.map { amp * Float(sin(2 * Double.pi * 440 * Double($0) / 48_000 + phase)) }
}
private func push(_ r: RingBuffer, _ a: [Float]) {
    _ = a.withUnsafeBufferPointer { p in r.push(left: p.baseAddress!, right: p.baseAddress!, count: a.count) }
}
/// One render call; returns (left samples, silence flag).
private func render(_ c: AudioRenderCore, _ n: Int) -> ([Float], Bool) {
    var l = [Float](repeating: 9, count: n), r = l
    let s = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        c.render(left: lp.baseAddress!, right: rp.baseAddress!, count: n, hostNanos: 0) } }
    return (l, s)
}
/// Feeder stand-in: a seek bumps the generation; `flush` = the feeder applying it (ring flush, then the lock-free gate).
private final class FakeFeeder {
    let ring: RingBuffer, gate = FlushGeneration(), core: AudioRenderCore
    var gen = 0
    init(fade: Int = 240) { ring = RingBuffer(capacity: 1 << 14, fadeFrames: fade); core = AudioRenderCore(ring: ring, flushGeneration: gate, fadeFrames: fade) }
    func seek() { gen += 1; core.beginPriming(generation: gen) }
    func flush() { ring.flush(); gate.value.store(gen, ordering: .releasing) }
}
private func maxStep(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }

@Suite struct AudioRenderCoreTests {
    /// Start, seek (phase jump by pi), rate change (flush, other phase), stop: the output never steps by more than a sine's
    /// own slope plus the 5 ms ramp's slope. Without the fades a pi jump steps by up to 1.0.
    @Test func noStepAboveThresholdAcrossStartSeekRateChangeAndStop() {
        let f = FakeFeeder(), ring = f.ring, core = f.core
        var out: [Float] = []
        // start: engine seeks (priming), feeder flushes and pushes, output starts
        f.seek(); f.flush(); push(ring, sine(0..<4096, phase: 0))
        core.playing.store(true, ordering: .releasing)
        for _ in 0..<4 { out += render(core, 512).0 }
        // seek while playing: one render before the feeder reacts plays old material
        f.seek()
        out += render(core, 512).0
        f.flush(); push(ring, sine(10_000..<14_096, phase: .pi))
        for _ in 0..<4 { out += render(core, 512).0 }
        // rate change = new anchor, same path
        f.seek(); f.flush(); push(ring, sine(30_000..<34_096, phase: 1.3))
        for _ in 0..<4 { out += render(core, 512).0 }
        // stop: 5 ms fade-out, then silence
        core.playing.store(false, ordering: .releasing)
        let (a, s1) = render(core, 512), (b, s2) = render(core, 512)
        out += a + b
        #expect(!s1 && s2 && b.allSatisfy { $0 == 0 })
        #expect(a[240...].allSatisfy { $0 == 0 })
        let natural = Float(0.5 * 2 * Double.pi * 440 / 48_000)
        #expect(maxStep(out) < natural + 0.012, "max step \(maxStep(out))")
        #expect(core.underrunCount == 0)
    }

    @Test func primingWaitsSilentlyAndIsNotAnUnderrun() {
        let f = FakeFeeder(), ring = f.ring, core = f.core
        core.playing.store(true, ordering: .releasing)
        f.seek()
        #expect(render(core, 512).1)                              // feeder has not flushed: silence (was not playing)
        f.flush(); push(ring, [Float](repeating: 1, count: 100))
        #expect(render(core, 512).1)                              // flushed, less than one render call queued
        #expect(ring.consumedFrames == 0 && core.underrunCount == 0)
        push(ring, [Float](repeating: 1, count: 1000))
        let (o, silent) = render(core, 512)
        #expect(!silent && o[511] == 1 && ring.consumedFrames == 512)
    }

    @Test func shortageWhilePlayingCountsAnUnderrun() {
        let f = FakeFeeder(fade: 0), ring = f.ring, core = f.core
        f.seek(); f.flush(); push(ring, [Float](repeating: 1, count: 600))
        core.playing.store(true, ordering: .releasing)
        _ = render(core, 512)
        #expect(core.underrunCount == 0)
        let (o, _) = render(core, 512)
        #expect(core.underrunCount == 1 && o[87] == 1 && o[88] == 0)
    }

    /// A stale flush (older generation) must not end priming: its audio would leak in before the new seek's flush.
    @Test func primingWaitsForThisGenerationsFlushNotAnyFlush() {
        let f = FakeFeeder(fade: 0), ring = f.ring, core = f.core
        f.seek(); f.flush(); push(ring, [Float](repeating: 1, count: 2000))
        core.playing.store(true, ordering: .releasing)
        _ = render(core, 512)
        f.seek()                                                  // generation 2 requested
        f.gen -= 1; f.flush(); f.gen += 1                         // a stale flush (generation 1) lands after the seek
        let (o, _) = render(core, 512)                            // still priming: the (empty) old path, not an underrun
        #expect(o.allSatisfy { $0 == 0 } && core.underrunCount == 0)
        f.flush(); push(ring, [Float](repeating: 3, count: 2000))
        #expect(render(core, 512).0.allSatisfy { $0 == 3 })
        #expect(core.underrunCount == 0)
    }

    /// beginPriming racing the render thread's completion is never lost.
    @Test func newerPrimingDuringPrimingIsKept() {
        let f = FakeFeeder(fade: 0), ring = f.ring, core = f.core
        core.playing.store(true, ordering: .releasing)
        f.seek(); f.flush(); push(ring, [Float](repeating: 1, count: 600))
        f.seek()                                                  // second seek before the first was primed
        #expect(render(core, 512).1)                              // generation 1's flush does not complete priming
        f.flush(); push(ring, [Float](repeating: 2, count: 1000))
        #expect(render(core, 512).0.allSatisfy { $0 == 2 })
    }

    @Test func renderStampsFeedTheClock() {
        let f = FakeFeeder(fade: 0), ring = f.ring, core = f.core
        f.seek(); f.flush(); push(ring, [Float](repeating: 1, count: 2000))
        core.playing.store(true, ordering: .releasing)
        var l = [Float](repeating: 0, count: 300), r = l
        _ = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            core.render(left: lp.baseAddress!, right: rp.baseAddress!, count: 300, hostNanos: 1234) } }
        #expect(core.lastRender == AudioRenderStamp(frames: 300, quantum: 300, hostNanos: 1234))
    }

    @Test func meterMeasuresPeakAndRMSPerChannel() {
        let m = AudioMeterStore()
        let l: [Float] = [0.5, -0.5, 0.5, -0.5], r: [Float] = [0, 0, 0, -1]
        l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in m.measure(lp.baseAddress!, rp.baseAddress!, count: 4) } }
        let s = m.snapshot
        #expect(s.left == AudioMeterLevel(peak: 0.5, rms: 0.5) && s.right == AudioMeterLevel(peak: 1, rms: 0.5) && s.sequence == 1)
    }
}

// MARK: Real AVAudioEngine (skips without an output device)

private func hasOutputDevice() -> Bool { AudioEngine.hasOutputDevice() }
private let longTests = ProcessInfo.processInfo.environment["SS_LONG_TESTS"] == "1"
private func secs(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

/// 10 s generated clip (E-01 writer) with a stereo 48 kHz audio track (one click per second).
private actor AudioClip {
    static let shared = AudioClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 300
        spec.frameDuration = TestClipSpec.fps(30)
        spec.audioClicks = (0..<10).map { CMTime(value: CMTimeValue($0), timescale: 1) }
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

private func makeEngine() async throws -> (AudioEngine, AudioClock) {
    let url = try await AudioClip.shared.get()
    let media = UUID()
    let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
    let engine = AudioEngine(media: StaticMediaResolver(audio: [media: src]))
    let clip = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
    engine.setTimeline(Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [clip])]), sequences: [:])
    try engine.prepare()
    return (engine, AudioClock(audio: engine))
}

/// Plays at `rate` from `start` for `seconds` (after a 0.3 s priming margin) and checks the clock's speed.
private func run(_ engine: AudioEngine, _ clock: AudioClock, rate: PlaybackRate, from start: Time, seconds: Double) async throws {
    clock.start(at: start, rate: rate)
    try await Task.sleep(for: .milliseconds(300))
    let w0 = ContinuousClock.now, p0 = clock.now()
    try await Task.sleep(for: .seconds(seconds))
    let w1 = ContinuousClock.now, p1 = clock.now()
    let wall = Double((w1 - w0).components.seconds) + Double((w1 - w0).components.attoseconds) * 1e-18
    let r = Double(rate.num) / Double(rate.den)
    let expected = r * wall, got = secs(p1 - p0)
    #expect(abs(got - expected) <= 0.05 * abs(expected) + 0.03 * abs(r) + 0.02, "rate \(r): moved \(got) s, expected \(expected) s")
    let tp = engine.timePitchSettings
    #expect(tp.pitch == 0 && tp.rate == Float(abs(r)) && tp.bypass == (abs(r) == 1))
    let lat = engine.latencyParts
    #expect((lat.timePitch == 0) == (abs(r) == 1))              // TimePitch latency counts only while engaged
    print("[E-11] rate \(r): output latency device \(lat.device) + TimePitch \(lat.timePitch) frames @48k")
}

@Suite(.serialized) struct AudioEngineSmokeTests {
    @Test(.enabled(if: hasOutputDevice(), "no audio output device"))
    func playsAtAllRatesWithoutUnderruns() async throws {
        let (engine, clock) = try await makeEngine()
        defer { engine.shutdown() }
        try await run(engine, clock, rate: .forward, from: Time(1, 1), seconds: 1)
        try await run(engine, clock, rate: PlaybackRate(2), from: Time(1, 1), seconds: 1)
        try await run(engine, clock, rate: PlaybackRate(8), from: .zero, seconds: 1)
        try await run(engine, clock, rate: .reverse, from: Time(9, 1), seconds: 1)
        try await run(engine, clock, rate: PlaybackRate(1, 4), from: Time(2, 1), seconds: 1)
        // Device configuration change: engine restarts, clock re-seeks at its position and keeps running.
        clock.start(at: Time(3, 1), rate: .forward)
        try await Task.sleep(for: .milliseconds(300))
        let before = clock.now()
        engine.handleConfigurationChange()
        try await Task.sleep(for: .milliseconds(500))
        let after = clock.now()
        #expect(secs(after - before) > 0.3 && secs(after - before) < 0.6, "moved \(secs(after - before)) s across the restart")
        #expect(!clock.sample().stalled)
        clock.stop()
        #expect(engine.underrunCount == 0)
        #expect(engine.meterSnapshot().sequence > 0)
        #expect(engine.feeder.failedReads.load(ordering: .relaxed) == 0)
    }

    /// Opt-in (SS_LONG_TESTS=1): 60 s real time, 12 s per rate, no underruns.
    @Test(.enabled(if: longTests && hasOutputDevice(), "set SS_LONG_TESTS=1"))
    func sixtySecondsWithoutUnderruns() async throws {
        let (engine, clock) = try await makeEngine()
        defer { engine.shutdown() }
        try await run(engine, clock, rate: .forward, from: .zero, seconds: 11.7)
        try await run(engine, clock, rate: PlaybackRate(2), from: .zero, seconds: 11.7)
        try await run(engine, clock, rate: PlaybackRate(8), from: .zero, seconds: 11.7)
        try await run(engine, clock, rate: .reverse, from: Time(20, 1), seconds: 11.7)
        try await run(engine, clock, rate: PlaybackRate(1, 4), from: Time(1, 1), seconds: 11.7)
        clock.stop()
        #expect(engine.underrunCount == 0)
    }
}
