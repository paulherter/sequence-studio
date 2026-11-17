import Foundation
import Testing
import SQCore
@testable import SQAudioFX

func noise(_ amp: Float, _ count: Int, _ seed: UInt64) -> [Float] {
    var s = seed &* 6364136223846793005 &+ 1442695040888963407
    return (0..<count).map { _ in
        s = s &* 6364136223846793005 &+ 1442695040888963407
        let u = Float((s >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
        return (u * 2 - 1) * amp
    }
}
func sine(_ f: Double, _ db: Double, _ n: Int, _ rate: Int = 48000) -> [Float] {
    let a = pow(10, db / 20)
    return (0..<n).map { Float(a * sin(2 * .pi * f * Double($0) / Double(rate))) }
}
nonisolated(unsafe) var lines: [String] = []
func record(_ name: String, _ y: [[Float]]) {
    var h: UInt64 = 0xcbf29ce484222325
    for c in y { for v in c { for b in 0..<4 { h ^= UInt64((v.bitPattern >> (8 * UInt32(b))) & 0xFF); h = h &* 0x100000001b3 } } }
    var vals: [String] = []
    for c in y { var idx = Array(0..<min(8, c.count)); idx += stride(from: 1013, to: c.count, by: 1013); vals += idx.map { String(format: "%.9g", c[$0]) } }
    lines.append("\(name)\t\(String(h, radix: 16))\t\(y.count)x\(y[0].count)\t" + vals.joined(separator: " "))
}
func blocks(_ x: [[Float]], _ block: Int, _ f: (UnsafeMutablePointer<UnsafeMutablePointer<Float>>, Int, Int) -> Void) -> [[Float]] {
    var out = x
    let total = x[0].count
    let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: x.count)
    for c in 0..<x.count { ptrs[c] = .allocate(capacity: block) }
    var pos = 0, k = 0
    while pos < total {
        let n = min(block, total - pos)
        for c in 0..<x.count { for i in 0..<n { ptrs[c][i] = x[c][pos + i] } }
        f(ptrs, n, k)
        for c in 0..<x.count { for i in 0..<n { out[c][pos + i] = ptrs[c][i] } }
        pos += n; k += 1
    }
    for c in 0..<x.count { ptrs[c].deallocate() }
    ptrs.deallocate()
    return out
}

@Suite struct Dump {
    @Test func dump() throws {
        let n2 = [noise(0.4, 48000, 7), noise(0.4, 48000, 8)]
        let hot = [noise(1.5, 48000, 3), noise(1.5, 48000, 4)]
        let tone: [[Float]] = [0, 1].map { c in zip(sine(220, -12, 48000), sine(3100 + 100 * Double(c), -18, 48000)).map { $0 + $1 } }
        let harm: [Float] = (0..<96000).map { i in
            var v = 0.0
            for h in 1...10 { v += sin(2 * Double.pi * 140 * Double(h) * Double(i) / 48000 + Double(h) * 0.7) / Double(h) }
            return Float(0.2 * v)
        }
        var mb = MultibandCompressor(settings: TrackAudioPreset.voice.compressor, sampleRate: 48000, channels: 2)
        var y = n2; mb.process(&y); record("multiband_voice", y)
        var mb2 = MultibandCompressor(settings: TrackAudioPreset.music.compressor, sampleRate: 44100, channels: 2)
        y = tone; mb2.process(&y); record("multiband_music_44k", y)
        let la = LookaheadLimiter(sampleRate: 48000, channels: 2)
        record("lookahead", blocks(hot, 480) { p, n, _ in la.process(p, channels: 2, frames: n) })
        var ml = MasterLimiter(sampleRate: 48000, ceilingDB: -3, releaseMs: 100, holdMs: 5, attackMs: 2)
        var l = hot[0], r = hot[1]
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in ml.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 48000) } }
        record("master_limiter", [l, r])
        let gate = NoiseGateStage(sampleRate: 48000)
        record("noise_gate", blocks(tone, 480) { p, n, k in gate.process(p, channels: 2, frames: n, thresholdFrom: -30 + Double(k % 3), to: -34, attackMs: 2, releaseMs: 80, rangeFrom: 40, to: 46, holdMs: 30) })
        let dl = DelayStage(sampleRate: 48000, channels: 2)
        record("delay", blocks(n2, 480) { p, n, k in dl.process(p, channels: 2, frames: n, timeFrom: 120 + Double(k), to: 121 + Double(k), feedbackFrom: 0.4, to: 0.45, mixFrom: 0.3, to: 0.35) })
        let rv = ReverbStage(sampleRate: 48000, channels: 2)
        record("reverb", blocks(n2, 480) { p, n, _ in rv.process(p, channels: 2, frames: n, room: 0.6, damping: 0.4, mixFrom: 0.3, to: 0.4) })
        let dh = DeHumStage(sampleRate: 48000, channels: 2)
        record("dehum", blocks(tone, 480) { p, n, _ in dh.process(p, channels: 2, frames: n, frequencyHz: 220, q: 8, gainDB: -24, harmonics: 3, slope: 0.6, listen: false) })
        let lc = LowCutStage(sampleRate: 48000, channels: 2)
        record("lowcut3", blocks(n2, 480) { p, n, _ in lc.process(p, channels: 2, frames: n, frequencyHz: 180, order: 3) })
        let hc = HighCutStage(sampleRate: 48000, channels: 2)
        record("highcut2", blocks(n2, 480) { p, n, _ in hc.process(p, channels: 2, frames: n, frequencyHz: 5000, order: 2) })
        let lev = DialogueLevelerStage(sampleRate: 48000)
        let vals = AudioLevelerValues(preset: 3, reduceLoud: true, liftSoft: true, background: true, outputGainDB: 2)
        record("leveler", blocks(tone, 480) { p, n, _ in lev.process(p, channels: 2, frames: n, values: vals, depth: 0.8) })
        let nt = NotchStage(sampleRate: 48000, channels: 2)
        record("notch", blocks(tone, 480) { p, n, k in nt.process(p, channels: 2, frames: n, from: (hz: 900 + 10 * Double(k % 5), q: 12, depthDB: 30), to: (hz: 910 + 10 * Double(k % 5), q: 14, depthDB: 28)) })
        let ge = GraphicEQStage(channels: 2)
        var gv = AudioGraphicEQValues(); gv[2] = 6; gv[5] = -4; gv[8] = 3
        var gv2 = gv; gv2[5] = -8; gv2.outputDB = 1.5
        record("graphic_eq", blocks(n2, 480) { p, n, k in ge.process(p, channels: 2, frames: n, from: k % 2 == 0 ? gv : gv2, to: k % 2 == 0 ? gv2 : gv, sampleRate: 48000) })
        var de = DeEsser(sampleRate: 48000, channelCount: 2)
        de.configure(centerHz: 6500, range: 0); de.setSpeed(0)
        var dy = [tone[0], tone[1]]
        for c in 0..<2 { dy[c] = zip(dy[c], sine(6500, -15, 48000)).map { $0 + $1 } }
        de.process(&dy); record("deesser_narrow", dy)
        let ps = PitchShiftStage(channels: 1)
        record("pitch_up5", blocks([harm], 512) { p, n, _ in ps.process(p, channels: 1, frames: n, from: 5, to: 5, preserveFormants: true, enabled: true) })
        let ps2 = PitchShiftStage(channels: 1)
        record("pitch_down7_free", blocks([harm], 512) { p, n, _ in ps2.process(p, channels: 1, frames: n, from: -7, to: -7, preserveFormants: false, enabled: true) })
        let dv = DisguiseVoiceStage(sampleRate: 48000, channels: 1, id: UUID(uuidString: "5B0C1E7A-2A4D-4F0B-9C55-0E6F3A1D7B21")!)
        nonisolated(unsafe) var pos: Int64 = 0
        record("disguise_low", blocks([harm], 512) { p, n, _ in dv.process(p, channels: 1, frames: n, voice: 0, at: Time(pos, 48000), enabled: true); pos += Int64(n) })
        try (lines.joined(separator: "\n") + "\n").write(toFile: ProcessInfo.processInfo.environment["DUMP_OUT"]!, atomically: true, encoding: .utf8)
    }
}
