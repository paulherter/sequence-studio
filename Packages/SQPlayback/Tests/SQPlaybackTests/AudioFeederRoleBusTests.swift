import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let rate: Int64 = 48_000

/// Two audio tracks (dialogue, music), a constant source each, so the role bus gains are checkable by ratio.
private func setup(_ gains: [AudioTag: Double]) -> AudioFeeder {
    let a = UUID(), b = UUID()
    func clip(_ m: UUID) -> Clip {
        Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)), start: .zero)
    }
    var t1 = Track(kind: .audio, clips: [clip(a)]); t1.audioRole = .dialogue
    var t2 = Track(kind: .audio, clips: [clip(b)]); t2.audioRole = .music
    let tl = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [t1, t2])
    let sa = MemoryAudioSource(mono: [Float](repeating: 0.3, count: 30_000))
    let sb = MemoryAudioSource(mono: [Float](repeating: 0.1, count: 30_000))
    let f = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == a ? sa : sb }
    f.roleBusGainsDB = gains
    return f
}

private func played(_ f: AudioFeeder, _ n: Int) -> [Float] {
    f.seek(to: 0, reverse: false)
    _ = f.fill(maxBlocks: 4)
    var l = [Float](repeating: 0, count: n), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
    return l
}

@Suite struct AudioFeederRoleBusTests {
    @Test func zeroDBBusesAreBitIdenticalToNoBuses() {
        let base = played(setup([:]), 3000)
        let zero = played(setup([.dialogue: 0, .music: 0, .sfx: 0]), 3000)
        #expect(base == zero)
        #expect(base.contains { $0 != 0 })
    }

    @Test func busGainScalesTheRoleSumOnly() {
        let dialogueOnly = played(setup([.music: -100]), 3000)
        let both = played(setup([:]), 3000)
        let down = played(setup([.dialogue: -6.0206, .music: -100]), 3000)
        let musicOnly = played(setup([.dialogue: -100]), 3000)
        for i in [1000, 2000] {
            #expect(abs(down[i] - dialogueOnly[i] * 0.5) < 1e-3)
            #expect(abs(both[i] - dialogueOnly[i] - musicOnly[i]) < 1e-3)
            #expect(musicOnly[i] != 0)
        }
    }

    @Test func playedTwiceIsBitEqual() {
        let gains: [AudioTag: Double] = [.dialogue: -3, .music: -9]
        #expect(played(setup(gains), 2048) == played(setup(gains), 2048))
    }

    /// The first change from 0 dB ramps across the block (no hard step at its first sample).
    @Test func firstChangeRampsFromUnity() {
        let f = setup([:])
        f.seek(to: 0, reverse: false); _ = f.fill(maxBlocks: 1)
        f.roleBusGainsDB = [.dialogue: -12, .music: -12]
        _ = f.fill(maxBlocks: 1)
        var l = [Float](repeating: 0, count: 2048), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 2048) } }
        // Second block starts at the unity level and ends below it.
        #expect(abs(l[1024] - l[1023]) < 0.01)
        #expect(l[2047] < l[1024] * 0.5)
    }

    /// A reused feeder after seek matches a fresh one: no stale ramp state.
    @Test func seekResetsRoleGainState() {
        let f = setup([.dialogue: -12])
        _ = played(f, 2048)
        f.roleBusGainsDB = [:]
        let reused = played(f, 2048)
        #expect(reused == played(setup([:]), 2048))
    }
}
