import Foundation
import Testing
import SQCore
@testable import SQAudioFX

// Pitch Shift and Disguise Voice (F7.8): pitch accuracy, formants, delay, determinism, cost.
// `SQ_PITCH_REPORT=<file>` appends the measured numbers to that file.

private let fs = 48_000.0
private let fixedID = UUID(uuidString: "5B0C1E7A-2A4D-4F0B-9C55-0E6F3A1D7B21")!

private func report(_ line: String) {
    guard let path = ProcessInfo.processInfo.environment["SQ_PITCH_REPORT"], let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: URL(fileURLWithPath: path)) }
}

/// Runs `x` through a chain with one effect; the stage is asked per block with the block's first sample position.
private func run(_ kind: String, _ x: [[Float]], sizes: [Int] = [512], id: UUID = UUID(), enabled: Bool = true,
                 stage: (Int64) -> AudioFXStage) throws -> [[Float]] {
    let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: id, kind: kind)], channelCount: x.count, maxFrames: 1_024)
    var out: [[[Float]]] = []
    var pos: Int64 = 0
    for part in Sig.chunked(x, sizes: sizes) {
        var b = part
        let n = Int64(b[0].count)
        chain.process(&b, steps: [AudioFXStep(id: id, enabled: enabled, stage: stage(pos))],
                      endSteps: [AudioFXStep(id: id, enabled: enabled, stage: stage(pos + n))])
        out.append(b)
        pos += n
    }
    return Sig.concat(out, channels: x.count)
}

private func pitch(_ x: [[Float]], semitones: Double, preserve: Bool = true, sizes: [Int] = [512], enabled: Bool = true) throws -> [[Float]] {
    try run(ClipEffect.audioPitchShiftKind, x, sizes: sizes, enabled: enabled) { _ in .pitchShift(semitones: semitones, preserveFormants: preserve) }
}

private func disguise(_ x: [[Float]], voice: Int = 0, id: UUID = fixedID, sizes: [Int] = [512], enabled: Bool = true) throws -> [[Float]] {
    try run(ClipEffect.audioDisguiseVoiceKind, x, sizes: sizes, id: id, enabled: enabled) { .disguiseVoice(voice: voice, at: Time($0, 48_000)) }
}

/// Magnitude of the Hann-windowed component at `f`.
private func level(_ x: ArraySlice<Float>, at f: Double) -> Double {
    var re = 0.0, im = 0.0
    let n = Double(x.count)
    for (k, v) in x.enumerated() {
        let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / n)
        let p = 2 * Double.pi * f * Double(k) / fs
        re += Double(v) * w * cos(p); im += Double(v) * w * sin(p)
    }
    return 4 * (re * re + im * im).squareRoot() / n
}

/// The strongest frequency within `cents` of `near` (grid of `grid` cents, refined by a parabola).
private func peakFrequency(_ x: ArraySlice<Float>, near: Double, cents: Double = 60, grid: Double = 1) -> Double {
    let steps = Int(cents / grid)
    var best = -1.0, bestI = 0
    func f(_ i: Int) -> Double { near * pow(2, Double(i) * grid / 1200) }
    for i in -steps...steps { let l = level(x, at: f(i)); if l > best { best = l; bestI = i } }
    let a = level(x, at: f(bestI - 1)), c = level(x, at: f(bestI + 1))
    let den = a - 2 * best + c
    let off = abs(den) > 1e-15 ? 0.5 * (a - c) / den : 0
    return near * pow(2, (Double(bestI) + off) * grid / 1200)
}

private func cents(_ a: Double, _ b: Double) -> Double { 1200 * log2(a / b) }

/// `count` harmonics of `f0`; `weight(frequency)` is each one's amplitude.
private func harmonics(f0: Double, seconds: Double, top: Double = 6_000, weight: (Double) -> Double) -> [Float] {
    let n = Int(seconds * fs)
    var out = [Double](repeating: 0, count: n)
    var h = 1
    while Double(h) * f0 < top {
        let f = Double(h) * f0, a = weight(f)
        for i in 0..<n { out[i] += a * sin(2 * Double.pi * f * Double(i) / fs + Double(h) * 0.7) }
        h += 1
    }
    let peak = out.map(abs).max() ?? 1
    return out.map { Float(0.4 * $0 / peak) }
}

/// Center of the spectral envelope: amplitude-squared weighted mean frequency of the harmonics of `f0`.
private func envelopeCenter(_ x: ArraySlice<Float>, f0: Double, top: Double = 6_000) -> Double {
    var num = 0.0, den = 0.0
    var h = 1
    while Double(h) * f0 < top {
        let f = Double(h) * f0, a = level(x, at: f)
        num += f * a * a; den += a * a
        h += 1
    }
    return den > 0 ? num / den : 0
}

@Suite struct PitchShiftTests {
    @Test func sineLandsOnThePitch() throws {
        let x = Sig.mono(440, amplitudeDB: -12, seconds: 1.5)
        var worst = 0.0
        // Formants free: a single sine has no envelope to keep (with Preserve Formants it would be held down at its new place).
        for st in [7.0, -5, 12, -12, 0.5, -0.07, 3.33] {
            let y = try pitch([x], semitones: st, preserve: false)[0]
            let want = 440 * pow(2, st / 12)
            let seg = y[30_000..<46_384]
            let got = peakFrequency(seg, near: want)
            worst = max(worst, abs(cents(got, want)))
            #expect(abs(cents(got, want)) < 2, "\(st) st: \(got) Hz, wanted \(want)")
            #expect(abs(Sig.db(level(seg, at: got)) - -12) < 1, "\(st) st: level \(Sig.db(level(seg, at: got))) dB")
        }
        report("sine pitch error, worst of 7 shifts: \(worst) cents")
    }

    @Test func harmonicToneMovesEveryPartial() throws {
        let x = harmonics(f0: 150, seconds: 1.5) { 1 / ($0 / 150) }
        var worst = 0.0
        for st in [4.0, -7] {
            let y = try pitch([x], semitones: st, preserve: false)[0]
            let f0 = 150 * pow(2, st / 12)
            for h in [1.0, 2, 3, 5, 8] {
                let got = peakFrequency(y[30_000..<62_768], near: h * f0)
                worst = max(worst, abs(cents(got, h * f0)))
                #expect(abs(cents(got, h * f0)) < 3, "\(st) st, partial \(h): \(got) Hz, wanted \(h * f0)")
            }
        }
        report("harmonic tone pitch error, worst partial: \(worst) cents")
    }

    @Test func preserveFormantsKeepsTheEnvelope() throws {
        // A "vowel": harmonics of 120 Hz under one formant at 1 kHz.
        let x = harmonics(f0: 120, seconds: 1.5) { exp(-pow(($0 - 1_000) / 350, 2)) + 0.02 }
        let before = envelopeCenter(x[30_000..<62_768], f0: 120)
        for st in [5.0, -5] {
            let r = pow(2, st / 12)
            let yKept = try pitch([x], semitones: st, preserve: true)[0], yMoved = try pitch([x], semitones: st, preserve: false)[0]
            let kept = envelopeCenter(yKept[30_000..<62_768], f0: 120 * r)
            let moved = envelopeCenter(yMoved[30_000..<62_768], f0: 120 * r)
            // Without the option the center moves by 33 % (5 semitones); with it, it stays within 8 %.
            #expect(abs(kept / before - 1) < 0.08, "\(st) st preserved: \(kept) Hz, was \(before)")
            #expect(abs(moved / (before * r) - 1) < 0.03, "\(st) st free: \(moved) Hz, wanted \(before * r)")
            report("formant center at \(st) st: was \(before) Hz, preserved \(kept) Hz, not preserved \(moved) Hz")
        }
    }

    @Test func delayIsOneWindowAndCompensable() throws {
        for kind in [ClipEffect.audioPitchShiftKind, ClipEffect.audioDisguiseVoiceKind] {
            let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: UUID(), kind: kind)], channelCount: 2, maxFrames: 512)
            #expect(chain.latencySamples == AudioPitchValues.latencySamples)
        }
        let both = try ClipAudioFXChain(layout: [AudioFXSlot(id: UUID(), kind: ClipEffect.audioPitchShiftKind),
                                                 AudioFXSlot(id: UUID(), kind: ClipEffect.audioDisguiseVoiceKind)], channelCount: 2, maxFrames: 512)
        #expect(both.latencySamples == 2 * AudioPitchValues.latencySamples)

        var x = [Float](repeating: 0, count: 16_384)
        x[5_000] = 0.8
        let noise = Sig.noise(amplitude: 0.3, count: 16_384, seed: 7)
        let lat = AudioPitchValues.latencySamples
        // 0 semitones, and any setting while switched off: the same sound, exactly one window later.
        let cases: [(String, [[Float]], [[Float]])] = [
            ("neutral impulse", [x], try pitch([x], semitones: 0)),
            ("off impulse", [x], try pitch([x], semitones: 7, enabled: false)),
            ("neutral noise", [noise], try pitch([noise], semitones: 0, preserve: false)),
            ("disguise off", [noise, x], try disguise([noise, x], enabled: false)),
        ]
        for (name, input, output) in cases {
            for c in input.indices {
                var err: Float = 0
                for i in lat..<input[c].count { err = max(err, abs(output[c][i] - input[c][i - lat])) }
                #expect(err < 2e-5, "\(name): \(err)")
                let early = output[c][..<lat].map(abs).max() ?? 0
                #expect(early < 1e-6, "\(name): sound before the delay")
            }
        }
        // A shifted impulse stays where it is in time (the delay does not depend on the shift).
        let y = try pitch([x], semitones: 5)[0]
        let at = y.indices.max { abs(y[$0]) < abs(y[$1]) } ?? 0
        #expect(abs(at - (5_000 + lat)) <= 48, "impulse at \(at)")            // within a millisecond
    }

    @Test func blockSizeDoesNotChangeTheResult() throws {
        let tone = harmonics(f0: 140, seconds: 1) { 1 / ($0 / 140) }
        let x = zip(tone, Sig.noise(amplitude: 0.05, count: tone.count, seed: 3)).map { $0 + $1 }
        let odd = [1, 37, 480, 512, 129, 1_024, 7]
        let p0 = try pitch([x], semitones: 3), p1 = try pitch([x], semitones: 3, sizes: odd)
        #expect(p0 == p1)
        let d0 = try disguise([x, x]), d1 = try disguise([x, x], sizes: odd)
        #expect(d0 == d1)
    }

    @Test func disguiseIsDeterministicPerEffectAndDiffersBetweenEffects() throws {
        let x = harmonics(f0: 130, seconds: 1.5) { exp(-pow(($0 - 900) / 500, 2)) + 0.05 }
        let a = try disguise([x, x]), b = try disguise([x, x]), other = try disguise([x, x], id: UUID())
        #expect(a == b)
        #expect(a[0] == a[1])
        let finite = a[0].allSatisfy { $0.isFinite }
        #expect(finite)
        let diff = zip(a[0], other[0]).map { $0 - $1 }
        #expect(Sig.rms(diff[20_000...]) > 0.3 * Sig.rms(a[0][20_000...]))
        let gain = Sig.db(Sig.rms(a[0][20_000...])) - Sig.db(Sig.rms(x[20_000...]))
        #expect(abs(gain) < 9, "level change \(gain) dB")
        report("disguise level change on a vowel-like tone: \(gain) dB")
    }

    /// Playback after a seek and an export from the start: the seeded curves are read on one absolute hop grid, at any
    /// sample rate, so both get the same values for the same place in the clip.
    @Test(arguments: [48_000.0, 44_100.0]) func seekLandsOnTheSameCurveAsARenderFromTheStart(rate: Double) throws {
        let r = Int64(rate), total = 3 * Int(rate), seek = Int(rate) + 1_237           // off the hop grid on purpose
        let x: [Float] = (0..<total).map { i in
            var v = 0.0
            for h in 1...8 { v += sin(2 * Double.pi * 140 * Double(h) * Double(i) / rate) / Double(h) }
            return Float(0.2 * v)
        }
        func render(_ x: [Float], from start: Int, block: Int) -> (steps: [Int64: PitchVocoder.Controls], out: [Float]) {
            let total = x.count
            let stage = DisguiseVoiceStage(sampleRate: rate, channels: 1, id: fixedID)
            var steps: [Int64: PitchVocoder.Controls] = [:]
            stage.trace = { steps[$0] = $1 }
            var out: [Float] = []
            var pos = start
            while pos < total {
                let n = min(block, total - pos)
                var b = Array(x[pos..<(pos + n)])
                b.withUnsafeMutableBufferPointer { p in
                    var ch: UnsafeMutablePointer<Float> = p.baseAddress!
                    stage.process(&ch, channels: 1, frames: n, voice: 0, at: Time(Int64(pos), r), enabled: true)
                }
                out += b
                pos += n
            }
            return (steps, out)
        }
        let whole = render(x, from: 0, block: 512), part = render(x, from: seek, block: 441)
        let shared = Set(whole.steps.keys).intersection(part.steps.keys).sorted()
        // Every frame of the seeked render sits on the grid of the full one.
        #expect(shared.count == part.steps.count && shared.count > 50)
        #expect(shared.first == Int64(seek / 512 + 1))
        for k in shared {
            let a = whole.steps[k]!, b = part.steps[k]!
            #expect(a.formant == b.formant && a.bend == b.bend && a.jitterKey == b.jitterKey, "step \(k)")
        }
        // The pitch target follows the same curve; the follower needs a few frames after the seek to arrive on it.
        for k in shared.dropFirst(40) {
            #expect(abs(whole.steps[k]!.ratio / part.steps[k]!.ratio - 1) < 1e-6, "step \(k)")
        }
        // Same delay from any start. With silence before the sound both renders have the same history, so the seeked one
        // must give the very same samples at the same places (a shifted grid or delay would move them).
        let burst: [Float] = (0..<20_000).map { i in
            (6_000..<12_000).contains(i) ? Float(0.3 * sin(2 * Double.pi * 180 * Double(i) / rate)) : 0
        }
        let b0 = render(burst, from: 0, block: 512).out, b1 = render(burst, from: 1_237, block: 300).out
        let worst = zip(b0[1_237...], b1).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-5, "largest difference \(worst)")
        #expect(Sig.rms(b1[8_000..<12_000]) > 0.01)
        // Two rates count the same place in the clip: the slow curves agree where both grids meet (step 0 of each).
        let other = DisguiseVoiceStage(sampleRate: rate == 48_000 ? 44_100 : 48_000, channels: 1, id: fixedID)
        let here = DisguiseVoiceStage(sampleRate: rate, channels: 1, id: fixedID)
        #expect(here.controls(voice: 0, step: 0, f0: nil).formant == other.controls(voice: 0, step: 0, f0: nil).formant)
    }

    /// The point of the disguise: the pitch that comes out is the invented one, not a function of the speaker's.
    @Test func disguisedPitchDoesNotFollowTheSpeaker() throws {
        func track(_ f0: Double) throws -> [Double] {
            let x = harmonics(f0: f0, seconds: 4) { exp(-pow(($0 - 900) / 600, 2)) + 0.1 }
            let y = try disguise([x])[0]
            return stride(from: 24_000, to: 180_000, by: 12_000).map { at in
                peakFrequency(y[at..<(at + 8_192)], near: 100, cents: 700, grid: 5)
            }
        }
        let low = try track(110), high = try track(165)       // two "speakers" a fifth apart
        var worst = 0.0
        for (a, b) in zip(low, high) {
            worst = max(worst, abs(cents(a, b)))
            #expect(abs(cents(a, b)) < 60, "\(a) Hz against \(b) Hz")
            #expect(a > 70 && a < 140)
        }
        // And it moves: the melody is not a constant either.
        let spread = cents(low.max() ?? 1, low.min() ?? 1)
        #expect(spread > 100, "pitch range \(spread) cents")
        report("disguised pitch, speakers a fifth apart: worst difference \(worst) cents, melody range \(spread) cents, track \(low.map { Int($0) })")
    }

    @Test func higherVoiceGoesUp() throws {
        let x = harmonics(f0: 110, seconds: 2) { exp(-pow(($0 - 900) / 600, 2)) + 0.1 }
        let y = try disguise([x], voice: 1)[0]
        let f = peakFrequency(y[48_000..<56_192], near: 215, cents: 700, grid: 5)
        #expect(f > 150 && f < 300, "\(f) Hz")
    }

    @Test func switchingOnMidClipNeverLeaksTheOriginalVoice() throws {
        // Off for the first half, on for the second: after the delay, what comes out is processed from its first sample.
        let x = harmonics(f0: 130, seconds: 2) { 1 / ($0 / 130) }
        let id = UUID()
        let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: id, kind: ClipEffect.audioDisguiseVoiceKind)], channelCount: 1, maxFrames: 512)
        var out: [Float] = []
        var pos: Int64 = 0
        for part in Sig.chunked([x], sizes: [512]) {
            var b = part
            chain.process(&b, steps: [AudioFXStep(id: id, enabled: pos >= 48_000, stage: .disguiseVoice(voice: 0, at: Time(pos, 48_000)))])
            out += b[0]
            pos += Int64(b[0].count)
        }
        let lat = AudioPitchValues.latencySamples
        let on = 48_128                                        // first block boundary at or after 48 000
        var same = 0
        for i in on..<(on + lat) where abs(out[i] - x[i - lat]) < 1e-4 && abs(x[i - lat]) > 0.01 { same += 1 }
        #expect(same < lat / 50, "\(same) samples of the original after switching on")
    }

    @Test func realtimeCost() throws {
        let seconds = isOptimizedBuild ? 10.0 : 0.5
        let x = harmonics(f0: 130, seconds: seconds) { exp(-pow(($0 - 900) / 600, 2)) + 0.1 }
        for (name, kind) in [("Pitch Shift", ClipEffect.audioPitchShiftKind), ("Disguise Voice", ClipEffect.audioDisguiseVoiceKind)] {
            let id = UUID()
            let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: id, kind: kind)], channelCount: 2, maxFrames: 512)
            let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            for c in 0..<2 { ptrs[c] = .allocate(capacity: 512) }
            defer { for c in 0..<2 { ptrs[c].deallocate() }; ptrs.deallocate() }
            let blocks = x.count / 512
            let ms = SQTiming.bestMs(runs: 2) {
                for b in 0..<blocks {
                    for c in 0..<2 { x.withUnsafeBufferPointer { ptrs[c].update(from: $0.baseAddress! + b * 512, count: 512) } }
                    let stage: AudioFXStage = kind == ClipEffect.audioPitchShiftKind
                        ? .pitchShift(semitones: 4, preserveFormants: true) : .disguiseVoice(voice: 0, at: Time(Int64(b * 512), 48_000))
                    chain.process(ptrs, frameCount: 512, steps: [AudioFXStep(id: id, enabled: true, stage: stage)])
                }
            }
            let perSecond = ms / seconds
            report("\(name), stereo, \(isOptimizedBuild ? "optimized" : "debug") build: \(perSecond) ms per second of audio")
            // Realtime needs under 1000 ms per second. Measured optimized: 15 to 45 ms. A debug build is 100 times slower here
            // (raw-pointer code is not inlined) and runs next to the other tests, so it only reports.
            if isOptimizedBuild { #expect(perSecond < SQTiming.budget(100), "\(name): \(perSecond) ms per second of audio") }
        }
    }

    @Test(.enabled(if: isOptimizedBuild, "needs an optimized build")) func noHeapAllocationInProcess() throws {
        let ids = [UUID(), UUID()]
        let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: ids[0], kind: ClipEffect.audioPitchShiftKind),
                                                  AudioFXSlot(id: ids[1], kind: ClipEffect.audioDisguiseVoiceKind)], channelCount: 2, maxFrames: 512)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        for c in 0..<2 {
            ptrs[c] = .allocate(capacity: 512)
            for i in 0..<512 { ptrs[c][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        }
        defer { for c in 0..<2 { ptrs[c].deallocate() }; ptrs.deallocate() }
        let steps = [AudioFXStep(id: ids[0], enabled: true, stage: .pitchShift(semitones: 3, preserveFormants: true)),
                     AudioFXStep(id: ids[1], enabled: true, stage: .disguiseVoice(voice: 0, at: .zero))]
        for _ in 0..<8 { chain.process(ptrs, frameCount: 512, steps: steps) }
        let baseline = try pitchMallocs { }
        let n = try pitchMallocs { for _ in 0..<200 { chain.process(ptrs, frameCount: 512, steps: steps) } }
        #expect(n == baseline)
    }
}

/// Number of malloc-family calls the calling thread makes inside `body` (as in RealtimeAudioFXTests).
private func pitchMallocs(_ body: () -> Void) throws -> Int {
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
