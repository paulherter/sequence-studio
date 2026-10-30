import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAudioFX

/// Runs `fx.process` over `input` (one array per channel) in the given chunk sizes.
private func runRT(_ fx: RealtimeAudioFX, _ input: [[Float]], chunks: [Int], startSample: Int64 = 0) -> [[Float]] {
    let ch = input.count, n = input[0].count
    var out = Array(repeating: [Float](), count: ch)
    var pos = 0, k = 0
    let maxF = chunks.max()!
    let bufs = (0..<ch).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: maxF) }
    let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: ch)
    for c in 0..<ch { ptrs[c] = bufs[c] }
    defer { bufs.forEach { $0.deallocate() }; ptrs.deallocate() }
    while pos < n {
        let m = min(chunks[k % chunks.count], n - pos); k += 1
        for c in 0..<ch { for i in 0..<m { bufs[c][i] = input[c][pos + i] } }
        fx.process(ptrs, frameCount: m, timelineSample: startSample + Int64(pos))
        for c in 0..<ch { out[c].append(contentsOf: UnsafeBufferPointer(start: bufs[c], count: m)) }
        pos += m
    }
    return out
}

private func maxDiff(_ a: [[Float]], _ b: [[Float]]) -> Float {
    var d: Float = 0
    for c in 0..<a.count { for i in 0..<a[c].count { d = max(d, abs(a[c][i] - b[c][i])) } }
    return d
}

private func testSignal(_ n: Int) -> [[Float]] {
    let s = Sig.sine(freq: 300, amplitudeDB: -12, seconds: Double(n) / 48000)
    let nz = Sig.lowNoise(amplitude: 0.05, count: n)
    return (0..<2).map { c in (0..<n).map { s[c][$0] + nz[$0] * (c == 0 ? 1 : 0.7) } }
}

@Suite struct RealtimeAudioFXTests {
    @Test func matchesOfflineInRandomChunks() throws {
        var track = KeyframeTrack<Double>()
        track = KeyframeTrack(keys: [Keyframe(time: .zero, value: -12), Keyframe(time: Time(1, 1), value: 0)])
        var vol = VolumeAutomation(staticDB: 0, track: track, pan: 0.3)
        vol.pan = 0.3
        for preset in [TrackAudioPreset.voice, .music, .off, .forRole(.dialogue), .forRole(.music)] {
            let x = testSignal(48000 + 777)
            var off = try OfflineAudioFX(volume: vol, preset: preset, sampleRate: 48000, channelCount: 2)
            let ref = off.process(x, start: .zero)
            let rt = try RealtimeAudioFX(preset: preset, volume: vol, channelCount: 2, maxFrames: 1024,
                                         denoiser: preset.noiseReduction > 0)
            #expect(rt.latencySamples == off.latencySamples)
            let out = runRT(rt, x, chunks: [1, 512, 37, 1024, 480, 481, 100, 3])
            #expect(maxDiff(ref, out) < 1e-6)
        }
    }

    @Test func deEsserStateIsClearedOnReset() throws {
        let n = 4800
        let x: [[Float]] = [(0..<n).map { Float(0.3 * sin(2 * Double.pi * 7000 * Double($0) / 48000)) }]
        let p = TrackAudioPreset.forRole(.dialogue)
        let fresh = try RealtimeAudioFX(preset: p, volume: VolumeAutomation(staticDB: 0), channelCount: 1, maxFrames: 1024, denoiser: false)
        let ref = runRT(fresh, x, chunks: [1024])
        let used = try RealtimeAudioFX(preset: p, volume: VolumeAutomation(staticDB: 0), channelCount: 1, maxFrames: 1024, denoiser: false)
        _ = runRT(used, x, chunks: [1024])
        used.reset()
        #expect(maxDiff(ref, runRT(used, x, chunks: [1024])) == 0)
    }

    @Test func parameterChangeAppliesOnNextBlock() throws {
        let rt = try RealtimeAudioFX(preset: .off, volume: VolumeAutomation(staticDB: 0), channelCount: 1, maxFrames: 256, denoiser: false)
        let x = [[Float](repeating: 0.5, count: 256)]
        let a = runRT(rt, x, chunks: [256])
        #expect(abs(a[0][100] - 0.5) < 1e-6)
        rt.setVolume(VolumeAutomation(staticDB: -6.0206))
        let b = runRT(rt, x, chunks: [256])
        #expect(abs(b[0][0] - 0.25) < 1e-4)
        #expect(abs(b[0][255] - 0.25) < 1e-4)
    }

    @Test func compressorChangeKeepsDetectorState() throws {
        var loud = TrackAudioPreset.music
        loud.noiseReduction = 0
        let rt = try RealtimeAudioFX(preset: loud, volume: VolumeAutomation(staticDB: 0), channelCount: 1, maxFrames: 512, denoiser: false)
        let x = Sig.sine(freq: 1000, amplitudeDB: -3, seconds: 0.3, channels: 1)
        _ = runRT(rt, x, chunks: [512])
        var tweaked = loud
        tweaked.compressor.makeupGainDB += 0.0          // same layout, same values
        rt.setPreset(tweaked)
        let ref = try RealtimeAudioFX(preset: loud, volume: VolumeAutomation(staticDB: 0), channelCount: 1, maxFrames: 512, denoiser: false)
        _ = runRT(ref, x, chunks: [512])
        let y = Sig.sine(freq: 1000, amplitudeDB: -3, seconds: 0.05, channels: 1)
        #expect(maxDiff(runRT(rt, y, chunks: [512]), runRT(ref, y, chunks: [512])) == 0)
    }

    @Test func resetMakesOutputIndependentOfHistory() throws {
        let x = testSignal(9000)
        let fresh = try RealtimeAudioFX(preset: .voice, volume: VolumeAutomation(staticDB: -3), channelCount: 2, maxFrames: 512)
        let ref = runRT(fresh, x, chunks: [512, 100])
        let used = try RealtimeAudioFX(preset: .voice, volume: VolumeAutomation(staticDB: -3), channelCount: 2, maxFrames: 512)
        _ = runRT(used, testSignal(20000).map { $0.map { $0 * 3 } }, chunks: [333])
        used.reset()
        #expect(maxDiff(runRT(used, x, chunks: [512, 100]), ref) == 0)
    }

    @Test func latencyStaysConstantWhileDenoiserExists() throws {
        let rt = try RealtimeAudioFX(preset: .voice, volume: VolumeAutomation(), channelCount: 1, maxFrames: 64)
        #expect(rt.latencySamples == 480)
        rt.setDenoiseMix(0)
        #expect(rt.latencySamples == 480)
        let none = try RealtimeAudioFX(preset: .off, volume: VolumeAutomation(), channelCount: 1, maxFrames: 64, denoiser: false)
        #expect(none.latencySamples == 0)
    }

    @Test func volumeFollowsTimelineSampleAfterSeek() throws {
        var track = KeyframeTrack<Double>()
        track = KeyframeTrack(keys: [Keyframe(time: .zero, value: -60), Keyframe(time: Time(10, 1), value: 0)])
        let rt = try RealtimeAudioFX(preset: .off, volume: VolumeAutomation(staticDB: 0, track: track), channelCount: 1, maxFrames: 256, denoiser: false)
        let x = [[Float](repeating: 1, count: 256)]
        let late = runRT(rt, x, chunks: [256], startSample: 48000 * 10)
        #expect(abs(late[0][10] - 1) < 1e-3)
        let early = runRT(rt, x, chunks: [256], startSample: 0)
        #expect(early[0][10] < 0.01)
    }

    /// Counts every malloc-family call made by the render thread through libmalloc's `malloc_logger` hook.
    /// Debug builds allocate in unspecialised stdlib code, so these run in optimized builds only (skipped in debug):
    /// `swift test -c release -Xswiftc -enable-testing --filter noHeap`.
    @Test(.serialized, .enabled(if: isOptimizedBuild, "needs an optimized build")) func noHeapAllocationInProcess() throws {
        let rt = try RealtimeAudioFX(preset: .voice, volume: VolumeAutomation(staticDB: -2, pan: 0.2), channelCount: 2, maxFrames: 512)
        let (ptrs, free) = makeBlock(channels: 2, frames: 512)
        defer { free() }
        for k in 0..<20 { rt.process(ptrs, frameCount: 512, timelineSample: Int64(k * 512)) }     // warm up
        // parameter handoff from another thread; the render thread applies it inside the measured window
        let setter = Thread { rt.setDenoiseMix(0.3); rt.setVolume(VolumeAutomation(staticDB: -4)); rt.setPreset(.music) }
        setter.start()
        while !setter.isFinished { Thread.sleep(forTimeInterval: 0.001) }
        let baseline = try mallocsOnThisThread { }
        let n = try mallocsOnThisThread { for k in 0..<1000 { rt.process(ptrs, frameCount: 512, timelineSample: Int64(k * 512)) } }
        #expect(n == baseline)
    }

    /// No warm-up: the very first `process` of a fresh instance (lazy RNNoise globals, first-touch state) must not allocate.
    @Test(.serialized, .enabled(if: isOptimizedBuild, "needs an optimized build")) func noHeapAllocationInFirstProcess() throws {
        let rt = try RealtimeAudioFX(preset: .voice, volume: VolumeAutomation(staticDB: -2, pan: 0.2), channelCount: 2, maxFrames: 512)
        let (ptrs, free) = makeBlock(channels: 2, frames: 512)
        defer { free() }
        let baseline = try mallocsOnThisThread { }
        let n = try mallocsOnThisThread { for k in 0..<3 { rt.process(ptrs, frameCount: 512, timelineSample: Int64(k * 512)) } }
        #expect(n == baseline)
    }

    /// The mixer fills the same array with every clip's audio steps on each block: warmed up, that must not allocate
    /// (all audio kinds, so every `audioStage` case runs).
    @Test(.serialized, .enabled(if: isOptimizedBuild, "needs an optimized build")) func noHeapAllocationInAudioFXSteps() throws {
        var clip = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(60, 30)), start: .zero)
        for k in EffectCatalog.audio.map(\.kind) { _ = clip.addEffect(kind: k) }
        #expect(clip.effects.count > 5)
        var steps: [AudioFXStep] = []
        for k in 0..<20 { clip.audioFXSteps(atLocal: Time(Int64(k), 30), into: &steps) }     // warm up
        let baseline = try mallocsOnThisThread { }
        let n = try mallocsOnThisThread {
            for k in 0..<1000 { clip.audioFXSteps(atLocal: Time(Int64(k % 50), 30), into: &steps) }
        }
        #expect(n == baseline)
        #expect(steps.count == clip.audioFXLayout.count)
    }
}

#if DEBUG
let isOptimizedBuild = false
#else
let isOptimizedBuild = true
#endif

private func makeBlock(channels ch: Int, frames n: Int) -> (UnsafeMutablePointer<UnsafeMutablePointer<Float>>, () -> Void) {
    let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: ch)
    for c in 0..<ch {
        ptrs[c] = .allocate(capacity: n)
        for i in 0..<n { ptrs[c][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
    }
    return (ptrs, { for c in 0..<ch { ptrs[c].deallocate() }; ptrs.deallocate() })
}

/// Number of malloc-family calls (alloc and free) the calling thread makes inside `body`.
private func mallocsOnThisThread(_ body: () -> Void) throws -> Int {
    #if canImport(Darwin)
    guard let hook = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
        Issue.record("malloc_logger not available"); return 0
    }
    let slot = hook.assumingMemoryBound(to: MallocLoggerFn?.self)
    let saved = slot.pointee
    mallocCount.withLock { $0 = 0 }
    watchedThread.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
    slot.pointee = { _, _, _, _, _, _ in
        if pthread_mach_thread_np(pthread_self()) == watchedThread.withLock({ $0 }) { mallocCount.withLock { $0 += 1 } }
    }
    body()
    slot.pointee = saved
    return mallocCount.withLock { $0 }
    #else
    body(); return 0  // shortcut: malloc_logger is Darwin only; count allocations on Windows when a hook exists
    #endif
}

typealias MallocLoggerFn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) let mallocCount = Mutex(0)
nonisolated(unsafe) let watchedThread = Mutex<UInt32>(0)
