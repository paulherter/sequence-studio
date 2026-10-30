import Foundation
import Testing
import SQCore
@testable import SQAudioFX

// AUDIO-PERF: golden output of every DSP stage on the mix path. The hashes were taken from the code BEFORE the performance
// pass (PLAYBACK-PERF.md "Audio mix"): speed-ups of these stages must leave every output sample bit-identical, so the export
// mix of an existing project does not change. A deliberate sound change updates the constants (and must say so in DECISIONS).
// Float bits of `exp`/`log10` come from the system libm: if a macOS update moves them, regenerate from the old code first.

private func fnv(_ x: [[Float]]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for ch in x { for v in ch { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 } }
    return h
}

/// Stereo test program: two different tones plus noise, with a loud burst and a quiet stretch so detectors, attacks and
/// releases all move; 3 blocks of 1024 so state carries across blocks and the last one is short.
private func programme(frames: Int = 3 * 1024 - 300) -> [[Float]] {
    let n1 = Sig.noise(amplitude: 0.1, count: frames, seed: 7), n2 = Sig.noise(amplitude: 0.1, count: frames, seed: 9)
    func ch(_ f: Double, _ n: [Float]) -> [Float] {
        (0..<frames).map { i in
            let t = Double(i) / 48_000
            let env: Double = i % 2048 < 700 ? 1.0 : 0.08
            let sib = 0.15 * sin(2 * Double.pi * 7000 * t) * (i % 1500 < 400 ? 1 : 0)
            return Float(env * 0.5 * sin(2 * Double.pi * f * t) + sib) + n[i]
        }
    }
    return [ch(220, n1), ch(330, n2)]
}

/// Runs the chain over the program in 1024 blocks. `end`: end-of-block steps (parameter ramps), nil = constant.
private func runChain(_ layout: [AudioFXSlot], _ steps: [AudioFXStage], _ end: [AudioFXStage]? = nil, mono: Bool = false) throws -> [[Float]] {
    var x = programme()
    if mono { x = [x[0]] }
    let chain = try ClipAudioFXChain(layout: layout, channelCount: x.count, maxFrames: 1024)
    func mk(_ s: [AudioFXStage]) -> [AudioFXStep] { zip(layout, s).map { AudioFXStep(id: $0.id, enabled: true, stage: $1) } }
    let st = mk(steps), en = end.map(mk)
    var out = [[Float]](repeating: [], count: x.count)
    var i = 0
    while i < x[0].count {
        let k = min(1024, x[0].count - i)
        var b = x.map { Array($0[i..<(i + k)]) }
        chain.process(&b, steps: st, endSteps: en)
        for c in 0..<x.count { out[c] += b[c] }
        i += k
    }
    return out
}

private func slot(_ kind: String) -> AudioFXSlot { AudioFXSlot(id: UUID(), kind: kind) }

private let multiband = AudioMultibandValues(
    outputGainDB: 1.5, crossoverHz: SIMD3(150, 900, 4500), thresholdDB: SIMD4(-26, -24, -28, -30), ratio: SIMD4(3, 4, 2.5, 6),
    attackMs: SIMD4(12, 6, 3, 1), releaseMs: SIMD4(160, 110, 80, 60), gainDB: SIMD4(1, 0, -1.5, 2))
private func peq(_ shift: Double = 0) -> AudioParametricEQValues {
    AudioParametricEQValues(
        hp: .init(on: true, hz: 80 + shift), lowShelf: .init(on: true, hz: 150, gainDB: 3 + shift, q: 0.7),
        b1: .init(on: true, hz: 250, gainDB: -4, q: 1.2), b2: .init(on: false, hz: 500, gainDB: 5, q: 1),
        b3: .init(on: true, hz: 1500, gainDB: 3 - shift, q: 2), b4: .init(on: true, hz: 4000, gainDB: 0, q: 1),
        b5: .init(on: true, hz: 9000, gainDB: -3, q: 1.5), highShelf: .init(on: true, hz: 8000, gainDB: 2, q: 0.7),
        lp: .init(on: true, hz: 16_000))
}

/// Golden hashes by name (see the note at the top). A mismatch prints the new value.
private let golden: [String: UInt64] = [
    "g1": 8398948139810837663,    // multiband stereo (240-sample look-ahead limiter since 2026-10-05)
    "g2": 8173815504435813099,    // multiband mono
    "g3": 16635156747326214837,   // multiband ramped gains
    "g4": 753659815056379588,     // PEQ static
    "g5": 14441854550440882969,   // PEQ ramped
    "g6": 3918483395290092990,    // PEQ bands switching off
    "g7": 15369827075827449448,   // de-esser
    "g7b": 12422406863694300724,  // de-esser ramped
    "g8": 3428604445133585753,    // limiter stereo
    "g9": 12331799509732643193,   // limiter mono
    "g8b": 2187604484738751472,   // compressor
    "g10": 7667907272028441358,   // EQ 3-band
    "g11": 12456208154073406901,  // RNNoise
    "g12": 3037855953359192952,   // voice chain
    "g13": 17578199567119854605,  // master limiter
    "g14": 2887069576232113923,   // multiband + look-ahead limiter stereo (2026-10-05)
    "g15": 13523157477322524125,  // multiband + limiter mono
    "role-dialogue": 6379397567080759287,
    "role-music": 15929293746310735560,
    "role-sfx": 3926817595397176002,
]
private func check(_ name: String, _ h: UInt64, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(golden[name] == h, "\(name) = 0x\(String(h, radix: 16))", sourceLocation: sourceLocation)
}

@Suite struct GoldenOutputTests {
    @Test func multibandStereoAndMono() throws {
        let l = [slot(ClipEffect.audioMultibandKind)]
        check("g1", fnv(try runChain(l, [.multiband(multiband)])))
        check("g2", fnv(try runChain(l, [.multiband(multiband)], mono: true)))
        var m2 = multiband; m2.outputGainDB = -2; m2.gainDB = SIMD4(0, 2, 0, -1)       // ramped gains
        check("g3", fnv(try runChain(l, [.multiband(multiband)], [.multiband(m2)])))
    }

    /// Multiband with its output limiter on (attack 0, no solo / bypass): taken before band solo / bypass / limiter attack
    /// existed, so the default path stays bit-identical.
    @Test func multibandWithLimiter() throws {
        let l = [slot(ClipEffect.audioMultibandKind)]
        var m = multiband; m.limiterOn = true; m.limiterThresholdDB = -12; m.limiterMarginDB = -1; m.limiterReleaseMs = 300
        check("g14", fnv(try runChain(l, [.multiband(m)])))
        check("g15", fnv(try runChain(l, [.multiband(m)], mono: true)))
    }

    @Test func parametricEQStaticAndRamped() throws {
        let l = [slot(ClipEffect.audioParametricEQKind)]
        check("g4", fnv(try runChain(l, [.parametricEQ(peq())])))
        check("g5", fnv(try runChain(l, [.parametricEQ(peq())], [.parametricEQ(peq(2))])))
        var off = peq(); off.b3.on = false; off.hp.on = false                          // bands switching off fade out
        check("g6", fnv(try runChain(l, [.parametricEQ(peq())], [.parametricEQ(off)])))
    }

    @Test func deEsserLimiterCompressorEQGate() throws {
        check("g7", fnv(try runChain([slot(ClipEffect.audioDeEsserKind)], [.deEsser(reductionDB: 8, sensitivity: 0.6)])))
        check("g7b", fnv(try runChain([slot(ClipEffect.audioDeEsserKind)], [.deEsser(reductionDB: 8, sensitivity: 0.6)],
                                      [.deEsser(reductionDB: 4, sensitivity: 0.3)])))
        check("g8", fnv(try runChain([slot(ClipEffect.audioLimiterKind)], [.limiter(inputDB: 6, ceilingDB: -3)])))
        check("g9", fnv(try runChain([slot(ClipEffect.audioLimiterKind)], [.limiter(inputDB: 6, ceilingDB: -3)], mono: true)))
        check("g8b", fnv(try runChain([slot(ClipEffect.audioCompressorKind)],
                                      [.compressor(thresholdDB: -24, ratio: 4, attackMs: 8, releaseMs: 120, makeupDB: 3)])))
        let eq = AudioEQValues(lowGainDB: 3, lowHz: 120, midGainDB: -4, midHz: 1200, midQ: 1.4, highGainDB: 2, highHz: 7000)
        check("g10", fnv(try runChain([slot(ClipEffect.audioEQKind)], [.eq(eq)])))
    }

    @Test func noiseReductionRNNoise() throws {
        check("g11", fnv(try runChain([slot(ClipEffect.audioNoiseReductionKind)], [.noiseReduction(amount: 0.7)])))
    }

    @Test func fullVoiceChain() throws {
        let kinds = [ClipEffect.audioNoiseReductionKind, ClipEffect.audioParametricEQKind, ClipEffect.audioMultibandKind,
                     ClipEffect.audioDeEsserKind, ClipEffect.audioLimiterKind]
        let steps: [AudioFXStage] = [.noiseReduction(amount: 0.6), .parametricEQ(peq()), .multiband(multiband),
                                     .deEsser(reductionDB: 8, sensitivity: 0.5), .limiter(inputDB: 3, ceilingDB: -2)]
        check("g12", fnv(try runChain(kinds.map(slot), steps)))
    }

    /// Track-level preset path (RealtimeAudioFX: volume, RNNoise, 4-band compressor, de-esser), every role.
    @Test func trackRolePresets() throws {
        for role in AudioTag.allCases {
            let preset = TrackAudioPreset.forRole(role)
            let fx = try RealtimeAudioFX(preset: preset, volume: VolumeAutomation(staticDB: -2), channelCount: 2, maxFrames: 1024,
                                         denoiser: preset.noiseReduction > 0)
            let x = programme()
            var out = [[Float]](repeating: [], count: 2)
            var i = 0
            while i < x[0].count {
                let k = min(1024, x[0].count - i)
                var b = x.map { Array($0[i..<(i + k)]) }
                let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
                for c in 0..<2 { ptrs[c] = .allocate(capacity: k); ptrs[c].initialize(from: b[c], count: k) }
                fx.process(ptrs, frameCount: k, timelineSample: Int64(i))
                for c in 0..<2 { b[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: k)); ptrs[c].deallocate(); out[c] += b[c] }
                ptrs.deallocate()
                i += k
            }
            check("role-\(role.rawValue)", fnv(out))
        }
    }

    @Test func masterLimiter() {
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -1)
        var x = programme().map { $0.map { $0 * 2.2 } }
        var l = x[0], r = x[1]
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            lim.process(left: lp.baseAddress!, right: rp.baseAddress!, count: lp.count) } }
        x = [l, r]
        check("g13", fnv(x))
    }
}
