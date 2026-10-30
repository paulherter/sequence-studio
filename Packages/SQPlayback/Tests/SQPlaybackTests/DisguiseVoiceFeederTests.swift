import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// Disguise Voice counts samples on an absolute grid and starts over when the position it is told jumps. The feeder has to
/// tell it positions in the stream it really hears: priming chunks before the block, and output time (not inner sequence
/// time) inside a retimed nest. Otherwise every start, or every block, looks like a jump and the clip is silent.
@Suite struct DisguiseVoiceFeederTests {
    private static let rate: Int64 = 48_000
    private static let fmt = SequenceFormat(frameDuration: Time(1, 30))
    private static func t(_ n: Int64) -> Time { Time(n, rate) }

    /// A steady voiced sound: 150 Hz with harmonics.
    private static let voice: [Float] = (0..<48_000).map { i in
        let x = 2 * Double.pi * 150 * Double(i) / Double(rate)
        return Float(0.2 * sin(x) + 0.1 * sin(2 * x) + 0.06 * sin(3 * x) + 0.03 * sin(5 * x))
    }

    private static func disguised(_ media: UUID, frames: Int64) -> Clip {
        var c = Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: .zero, duration: t(frames)), start: .zero)
        _ = c.addEffect(kind: ClipEffect.audioDisguiseVoiceKind)
        return c
    }

    private static func played(_ tl: Timeline, seqs: [Timeline.ID: Timeline] = [:], from: Int64, count: Int) -> [Float] {
        let src = MemoryAudioSource(mono: voice)
        let f = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 15), blockFrames: 1024) { _ in src }
        f.setTimeline(tl, sequences: seqs)
        f.seek(to: from, reverse: false)
        _ = f.fill(maxBlocks: (count + 1023) / 1024)
        var l = [Float](repeating: 9, count: count), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: count) } }
        return l
    }

    private static func mixed(_ tl: Timeline, seqs: [Timeline.ID: Timeline] = [:], from: Int64, count: Int) -> [Float] {
        let src = MemoryAudioSource(mono: voice)
        let f = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
        f.setTimeline(tl, sequences: seqs)
        var l = [Float](repeating: 9, count: count), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            f.mix(timeline: tl, sequences: seqs, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!,
                  clipEffects: true) } }
        return l
    }

    private static func rms(_ x: ArraySlice<Float>) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot() }

    /// Largest relative difference in level between two renders, in windows of 1024 samples. The partials' phases are
    /// accumulated from the start of the stream, so a render that starts later is the same sound (same seeded curves on
    /// the same grid, same level and spectrum), not the same samples: levels are what can be compared, and they move with the phases (a quarter to a third in one
    /// window was measured). A start that is thrown away shows as a window with no level at all (difference 1).
    private static func levelDifference(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
        let x = Array(a), y = Array(b)
        var worst: Float = 0
        for i in stride(from: 0, to: min(x.count, y.count) - 1023, by: 1024) {
            let p = rms(x[i..<i + 1024]), q = rms(y[i..<i + 1024])
            worst = max(worst, abs(p - q) / max(q, 1e-4))
        }
        return worst
    }

    /// Every 512 samples of `x` carry sound (a vocoder that keeps starting over stays silent).
    private static func soundsThroughout(_ x: ArraySlice<Float>, floor: Float = 0.01) -> Bool {
        stride(from: x.startIndex, to: x.endIndex - 511, by: 512).allSatisfy { rms(x[$0..<$0 + 512]) > floor }
    }

    @Test(arguments: [8_192, 8_300] as [Int64])
    func seekIntoADisguisedClipSoundsAtOnceAndMatchesTheRenderFromTheStart(seek: Int64) {
        let tl = Timeline(name: "t", format: Self.fmt, tracks: [Track(kind: .audio, clips: [Self.disguised(UUID(), frames: 40_000)])])
        let full = Self.played(tl, from: 0, count: 20_480)
        #expect(Self.soundsThroughout(full[4_096..<20_480]))
        for out in [Self.played(tl, from: seek, count: 8_192), Self.mixed(tl, from: seek, count: 8_192)] {
            #expect(Self.rms(out[0..<256]) > 0.01)                      // no silent start
            #expect(Self.soundsThroughout(out[0..<8_192]))
            let s = Int(seek)
            // From the first sample on at the level of the render from the clip's start (no fade-in, no gap).
            #expect(Self.levelDifference(out[0..<8_192], full[s..<(s + 8_192)]) < 0.5)
            #expect(abs(Self.rms(out[0..<8_192]) / Self.rms(full[s..<(s + 8_192)]) - 1) < 0.15)
        }
    }

    /// A nest of a sequence that holds the disguised clip, played at `num/den` of its speed, forwards or backwards.
    private static func nest(num: Int64, den: Int64, reversed: Bool) -> (Timeline, [Timeline.ID: Timeline]) {
        let inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .audio, clips: [disguised(UUID(), frames: 40_000)])])
        var n = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: t(16_000 * num / den)),
                     start: .zero, sequence: inner.id)
        n.speed = ClipSpeed(num: num, den: den); n.reversed = reversed
        n.source = TimeRange(start: .zero, duration: t(16_000 * num / den))
        return (Timeline(name: "outer", format: fmt, tracks: [Track(kind: .audio, clips: [n])]), [inner.id: inner])
    }

    @Test(arguments: [(2, 1, false), (1, 2, false), (1, 1, true), (2, 1, true)] as [(Int64, Int64, Bool)])
    func disguisedClipInARetimedNestKeepsSounding(num: Int64, den: Int64, reversed: Bool) {
        let (tl, seqs) = Self.nest(num: num, den: den, reversed: reversed)
        let full = Self.played(tl, seqs: seqs, from: 0, count: 12_288)
        #expect(Self.soundsThroughout(full[4_096..<12_288]))
        let seek = Self.played(tl, seqs: seqs, from: 5_000, count: 6_144)
        #expect(Self.rms(seek[0..<256]) > 0.01)
        #expect(Self.soundsThroughout(seek[0..<6_144]))
        #expect(Self.levelDifference(seek[0..<6_144], full[5_000..<11_144]) < 0.5)
        #expect(abs(Self.rms(seek[0..<6_144]) / Self.rms(full[5_000..<11_144]) - 1) < 0.15)
        let scrub = Self.mixed(tl, seqs: seqs, from: 5_000, count: 6_144)
        #expect(Self.soundsThroughout(scrub[0..<6_144]))
    }

    // MARK: every nest level's chain runs

    /// What one nest clip carries: nothing, an EQ (switched on or off) or Disguise Voice.
    enum Level: String, Sendable { case plain, eq, eqOff, disguise }

    /// A plain clip in the innermost sequence, wrapped in one nest clip per entry of `levels` (outermost first).
    private static func tower(_ levels: [Level], gainDB: Double = 0) -> (Timeline, [Timeline.ID: Timeline]) {
        var seqs: [Timeline.ID: Timeline] = [:]
        let plain = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: t(40_000)), start: .zero)
        var current = Timeline(name: "s", format: fmt, tracks: [Track(kind: .audio, clips: [plain])])
        for level in levels.reversed() {
            seqs[current.id] = current
            var n = Clip(name: "n", media: current.id, kind: .audio, source: TimeRange(start: .zero, duration: t(40_000)),
                         start: .zero, sequence: current.id)
            n.audioGainDB = gainDB
            switch level {
            case .plain: break
            case .eq: _ = n.addEffect(kind: ClipEffect.audioEQKind)
            case .eqOff:
                _ = n.addEffect(kind: ClipEffect.audioEQKind)
                n.effects[n.effects.count - 1].enabled = false
            case .disguise: _ = n.addEffect(kind: ClipEffect.audioDisguiseVoiceKind)
            }
            current = Timeline(name: "s", format: fmt, tracks: [Track(kind: .audio, clips: [n])])
        }
        return (current, seqs)
    }

    /// Every 1024 samples of `x` are another sound than `dry`: the difference is as loud as the dry voice itself.
    private static func differsThroughout(_ x: ArraySlice<Float>, from dry: ArraySlice<Float>) -> Bool {
        let a = Array(x), b = Array(dry)
        return stride(from: 0, to: min(a.count, b.count) - 1023, by: 1024).allSatisfy { i in
            let diff = zip(a[i..<i + 1024], b[i..<i + 1024]).map { $0 - $1 }
            return rms(diff[...]) > 0.5 * rms(b[i..<i + 1024]) && rms(b[i..<i + 1024]) > 0.01
        }
    }

    /// A disguised nest clip below another nest clip with audio effects (on or switched off), two and three levels deep:
    /// the voice never comes out as it went in, in playback, after a seek (first hop included) and in scrub.
    @Test(arguments: [[.eq, .disguise], [.eqOff, .disguise], [.eq, .eq, .disguise], [.eqOff, .plain, .disguise],
                      [.eq, .disguise, .eq], [.plain, .eq, .disguise], [.disguise, .eq]] as [[Level]])
    func disguisedNestBelowAnEffectedNestNeverPlaysDry(levels: [Level]) {
        let (tl, seqs) = Self.tower(levels)
        let (dryTL, drySeqs) = Self.tower(levels.map { $0 == .disguise ? .plain : $0 })
        let dry = Self.played(dryTL, seqs: drySeqs, from: 0, count: 20_480)
        #expect(Self.soundsThroughout(dry[1_024..<20_480]))
        let full = Self.played(tl, seqs: seqs, from: 0, count: 20_480)
        #expect(Self.soundsThroughout(full[4_096..<20_480]))
        #expect(Self.differsThroughout(full[4_096..<20_480], from: dry[4_096..<20_480]))
        for out in [Self.played(tl, seqs: seqs, from: 8_192, count: 8_192), Self.mixed(tl, seqs: seqs, from: 8_192, count: 8_192)] {
            #expect(Self.rms(out[0..<256]) > 0.01)
            #expect(Self.soundsThroughout(out[0..<8_192]))
            #expect(Self.differsThroughout(out[0..<8_192], from: dry[8_192..<16_384]))
            #expect(abs(Self.rms(out[0..<8_192]) / Self.rms(full[8_192..<16_384]) - 1) < 0.15)
        }
    }

    /// Without Disguise Voice the nested levels change nothing: a switched-off EQ on every level plays the voice as it is,
    /// each nest clip's Audio Gain applied once.
    @Test(arguments: [[.eqOff, .eqOff, .eqOff], [.eqOff, .plain, .eqOff], [.plain, .eqOff, .eqOff]] as [[Level]])
    func effectedNestLevelsKeepTheLevel(levels: [Level]) {
        let (tl, seqs) = Self.tower(levels, gainDB: -6)
        let (dryTL, drySeqs) = Self.tower([.plain, .plain, .plain], gainDB: -6)
        let a = Self.played(tl, seqs: seqs, from: 0, count: 8_192), b = Self.played(dryTL, seqs: drySeqs, from: 0, count: 8_192)
        #expect(Self.rms(b[1_024...]) > 0.01)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-4 })
    }
}
