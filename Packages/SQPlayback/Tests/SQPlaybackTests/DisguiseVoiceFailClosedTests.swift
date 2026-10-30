import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

/// Disguise Voice protects a speaker: whatever goes wrong, the original voice must not be heard. A clip whose effect
/// chain cannot be built renders silence (never dry), and a retimed or reversed nest with two effected levels never
/// plays the voice dry. Buffers only, nothing is played.
@Suite struct DisguiseVoiceFailClosedTests {
    private struct BuildFailure: Error {}
    private static let rate: Int64 = 48_000
    private static let fmt = SequenceFormat(frameDuration: Time(1, 30))
    private static func t(_ n: Int64) -> Time { Time(n, rate) }

    private static let voice: [Float] = (0..<96_000).map { i in
        let x = 2 * Double.pi * 150 * Double(i) / Double(rate)
        return Float(0.2 * sin(x) + 0.1 * sin(2 * x) + 0.06 * sin(3 * x) + 0.03 * sin(5 * x))
    }

    private static func rms(_ x: ArraySlice<Float>) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot() }

    private static func feeder(_ tl: Timeline, seqs: [Timeline.ID: Timeline], failing: Bool, blocks: Int = 16) -> AudioFeeder {
        let src = MemoryAudioSource(mono: voice)
        let f = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 15), blockFrames: 1024) { _ in src }
        if failing { f.makeChain = { _, _ in throw BuildFailure() } }
        f.setTimeline(tl, sequences: seqs)
        return f
    }

    private static func mixed(_ tl: Timeline, seqs: [Timeline.ID: Timeline] = [:], failing: Bool, from: Int64 = 0, count: Int) -> [Float] {
        let f = feeder(tl, seqs: seqs, failing: failing)
        var l = [Float](repeating: 9, count: count), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            f.mix(timeline: tl, sequences: seqs, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!,
                  clipEffects: true) } }
        return l
    }

    private static func played(_ tl: Timeline, seqs: [Timeline.ID: Timeline] = [:], failing: Bool = false, from: Int64 = 0, count: Int) -> [Float] {
        let f = feeder(tl, seqs: seqs, failing: failing)
        f.seek(to: from, reverse: false)
        _ = f.fill(maxBlocks: (count + 1023) / 1024)
        var l = [Float](repeating: 9, count: count), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: count) } }
        return l
    }

    private static func disguisedClip() -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Self.t(40_000)), start: .zero)
        _ = c.addEffect(kind: ClipEffect.audioDisguiseVoiceKind)
        return c
    }

    @Test func clipWhoseChainCannotBeBuiltIsSilentNotDry() {
        let tl = Timeline(name: "t", format: Self.fmt, tracks: [Track(kind: .audio, clips: [Self.disguisedClip()])])
        let ok = Self.mixed(tl, failing: false, count: 8_192)
        #expect(Self.rms(ok[4_096...]) > 0.01)                                   // control: it sounds when the chain builds
        #expect(Self.mixed(tl, failing: true, count: 8_192).allSatisfy { $0 == 0 })
        #expect(Self.played(tl, failing: true, count: 8_192).allSatisfy { $0 == 0 })
    }

    @Test func clipWithAnyAudioEffectIsSilentWhenTheChainFails() {
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Self.t(40_000)), start: .zero)
        _ = c.addEffect(kind: ClipEffect.audioEQKind)
        let tl = Timeline(name: "t", format: Self.fmt, tracks: [Track(kind: .audio, clips: [c])])
        #expect(Self.mixed(tl, failing: true, count: 4_096).allSatisfy { $0 == 0 })
    }

    @Test func clipWithoutEffectsIsUnaffectedByTheFactory() {
        let c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Self.t(40_000)), start: .zero)
        let tl = Timeline(name: "t", format: Self.fmt, tracks: [Track(kind: .audio, clips: [c])])
        #expect(Self.rms(Self.mixed(tl, failing: true, count: 4_096)[...]) > 0.01)
    }

    // MARK: retimed / reversed nests with two effected levels

    enum Level: Sendable { case plain, eq, disguise }

    /// A plain clip wrapped in one nest clip per level (outermost first); the nest at `retimeAt` plays at `num/den`, maybe reversed.
    private static func tower(_ levels: [Level], retimeAt: Int, num: Int64, den: Int64, reversed: Bool) -> (Timeline, [Timeline.ID: Timeline]) {
        var seqs: [Timeline.ID: Timeline] = [:]
        let plain = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Self.t(40_000)), start: .zero)
        var current = Timeline(name: "s", format: fmt, tracks: [Track(kind: .audio, clips: [plain])])
        for (i, level) in levels.enumerated().reversed() {
            seqs[current.id] = current
            var n = Clip(name: "n", media: current.id, kind: .audio, source: TimeRange(start: .zero, duration: t(40_000)),
                         start: .zero, sequence: current.id)
            if i == retimeAt { n.speed = ClipSpeed(num: num, den: den); n.reversed = reversed }
            switch level {
            case .plain: break
            case .eq: _ = n.addEffect(kind: ClipEffect.audioEQKind)
            case .disguise: _ = n.addEffect(kind: ClipEffect.audioDisguiseVoiceKind)
            }
            current = Timeline(name: "s", format: fmt, tracks: [Track(kind: .audio, clips: [n])])
        }
        return (current, seqs)
    }

    private static func differsThroughout(_ x: ArraySlice<Float>, from dry: ArraySlice<Float>) -> Bool {
        let a = Array(x), b = Array(dry)
        return stride(from: 0, to: min(a.count, b.count) - 1023, by: 1024).allSatisfy { i in
            let diff = zip(a[i..<i + 1024], b[i..<i + 1024]).map { $0 - $1 }
            return rms(diff[...]) > 0.5 * rms(b[i..<i + 1024]) && rms(b[i..<i + 1024]) > 0.01
        }
    }

    private static func soundsThroughout(_ x: ArraySlice<Float>) -> Bool {
        stride(from: x.startIndex, to: x.endIndex - 511, by: 512).allSatisfy { rms(x[$0..<$0 + 512]) > 0.01 }
    }

    /// Never the dry voice: not in playback from the start, not after a seek, not in scrub; also nothing silent.
    @Test(arguments: [([.eq, .disguise], 0), ([.eq, .disguise], 1), ([.disguise, .eq], 0), ([.disguise, .eq], 1),
                      ([.eq, .plain, .disguise], 1), ([.eq, .eq, .disguise], 0)] as [([Level], Int)],
          [(2, 1, false), (1, 2, false), (1, 1, true), (2, 1, true)] as [(Int64, Int64, Bool)])
    func retimedNestWithTwoEffectedLevelsNeverPlaysDry(case c: ([Level], Int), speed: (Int64, Int64, Bool)) {
        let (levels, at) = c
        let (tl, seqs) = Self.tower(levels, retimeAt: at, num: speed.0, den: speed.1, reversed: speed.2)
        let (dryTL, drySeqs) = Self.tower(levels.map { $0 == .disguise ? .plain : $0 }, retimeAt: at, num: speed.0, den: speed.1, reversed: speed.2)
        let dry = Self.played(dryTL, seqs: drySeqs, count: 16_384)
        #expect(Self.soundsThroughout(dry[2_048..<16_384]))
        let full = Self.played(tl, seqs: seqs, count: 16_384)
        #expect(Self.soundsThroughout(full[4_096..<16_384]))
        #expect(Self.differsThroughout(full[4_096..<16_384], from: dry[4_096..<16_384]))
        let dry2 = Self.played(dryTL, seqs: drySeqs, from: 6_000, count: 6_144)
        for out in [Self.played(tl, seqs: seqs, from: 6_000, count: 6_144), Self.mixed(tl, seqs: seqs, failing: false, from: 6_000, count: 6_144)] {
            #expect(Self.rms(out[0..<256]) > 0.01)
            #expect(Self.soundsThroughout(out[0..<6_144]))
            #expect(Self.differsThroughout(out[0..<6_144], from: dry2[0..<6_144]))
        }
    }

    /// A nest whose chain fails to build is silent as well, retimed or not.
    @Test func failingNestChainIsSilentInARetimedNest() {
        let (tl, seqs) = Self.tower([.eq, .disguise], retimeAt: 0, num: 2, den: 1, reversed: true)
        #expect(Self.mixed(tl, seqs: seqs, failing: true, count: 8_192).allSatisfy { $0 == 0 })
        #expect(Self.played(tl, seqs: seqs, failing: true, count: 8_192).allSatisfy { $0 == 0 })
    }
}
