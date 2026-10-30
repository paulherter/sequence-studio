import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

// AUDIO-FX-PRO: Multiband Compressor + 5-band Parametric EQ on the one mix path playback and export share. Export builds its
// feeder with 1024-frame blocks, playback with whatever the engine uses: the result must not depend on the block size.

private let rate: Int64 = 48_000

private func timeline(_ m: UUID, enabled: Bool = true) -> Timeline {
    var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(40_000, rate)), start: .zero)
    let mb = c.addEffect(kind: ClipEffect.audioMultibandKind)!, eq = c.addEffect(kind: ClipEffect.audioParametricEQKind)!
    c.setParameter(mb, ClipEffect.mbThresholdKey(3), to: -30)
    c.setParameter(mb, ClipEffect.mbRatioKey(3), to: 4)
    c.setParameter(eq, ClipEffect.peqKey("b3", "Gain"), to: -6)
    c.setParameter(eq, ClipEffect.peqKey("hp", "On"), to: 1)
    for i in c.effects.indices { c.effects[i].enabled = enabled }
    return Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .audio, clips: [c])])
}

private let tone = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 1450 * Double($0) / 48_000)) }

private func play(_ t: Timeline, block: Int, count: Int = 12_000) -> [Float] {
    let src = MemoryAudioSource(mono: tone)
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 15), blockFrames: block) { _ in src }
    f.seek(to: 0, reverse: false)
    _ = f.fill(maxBlocks: count / block + 2)
    var l = [Float](repeating: 0, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: count) } }
    return l
}

@Suite struct AudioFeederVoiceChainTests {
    @Test func theChainShapesThePlayedClip() {
        let m = UUID()
        let wet = play(timeline(m), block: 1024), dry = play(timeline(m, enabled: false), block: 1024)
        let peakWet = wet[8000...].map { abs($0) }.max()!, peakDry = dry[8000...].map { abs($0) }.max()!
        #expect(abs(peakDry - 0.5) < 1e-3)
        #expect(peakWet < peakDry * 0.35)       // compressed 13+ dB and the peak band takes 6 dB off
    }

    @Test func playbackAndExportBlockSizesGiveTheSameSound() {
        let m = UUID(), t = timeline(m)
        let export = play(t, block: 1024), playback = play(t, block: 512)
        #expect(export.count == playback.count)
        var worst: Float = 0
        for i in 0..<export.count { worst = max(worst, abs(export[i] - playback[i])) }
        #expect(worst < 1e-4)
    }
}
