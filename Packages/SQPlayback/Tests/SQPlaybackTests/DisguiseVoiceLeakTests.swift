import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// A crossfade on the cut next to a disguised range must not play the range's source through the neighbor's handle.
/// Three clips lie end to end over one recording: a tone inside the middle range, silence outside it. The outer clips
/// read their own media id, so the test can swap what they would find in their handles: the tone (the real case) or
/// silence. With Disguise Voice on the middle clip both renders must be the same samples: the outer clips add nothing
/// from the range.
@Suite struct DisguiseVoiceLeakTests {
    private static let rate: Int64 = 48_000
    private static let fd = Time(1, 30)                        // 1600 samples
    private static func t(_ n: Int64) -> Time { Time(n, rate) }
    private static let range = TimeRange(start: t(8_000), end: t(16_000))
    private static let inner = UUID(), outer = UUID()

    private static func tone() -> MemoryAudioSource {
        var s = [Float](repeating: 0, count: 24_000)
        for i in 8_000..<16_000 { s[i] = 0.5 * Float(sin(2 * Double.pi * 200 * Double(i) / Double(rate))) }
        return MemoryAudioSource(mono: s)
    }

    private static func timeline(disguised: Bool) throws -> Timeline {
        func clip(_ media: UUID, _ a: Int64, _ b: Int64) -> Clip {
            Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: t(a), end: t(b)), start: t(a))
        }
        let c = [clip(outer, 0, 8_000), clip(inner, 8_000, 16_000), clip(outer, 16_000, 24_000)]
        var tl = Timeline(name: "t", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .audio, clips: c)])
        if disguised { _ = try tl.disguiseVoice(range: range, clips: [c[1].id]) }
        for k in 0..<2 {
            _ = try tl.addTransition(point: .cut(outgoing: c[k].id, incoming: c[k + 1].id), kind: .constantPower,
                                     track: tl.tracks[0].id, duration: t(3_200))
        }
        return tl
    }

    private static func feeder(_ tl: Timeline, leakable: Bool) -> AudioFeeder {
        let innerSource = tone()
        let outerSource = leakable ? tone() : MemoryAudioSource(mono: [Float](repeating: 0, count: 24_000))
        let outerID = outer
        return AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 15), blockFrames: 1024) { id in
            id == outerID ? outerSource : innerSource
        }
    }

    /// Scrub path: `mix` with clip effects.
    private static func mixed(_ tl: Timeline, leakable: Bool, from: Int64 = 0, count: Int = 24_576) -> [Float] {
        let f = feeder(tl, leakable: leakable)
        var l = [Float](repeating: 9, count: count), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            f.mix(timeline: tl, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: true) } }
        return l
    }

    /// Playback and export path: through the ring.
    private static func played(_ tl: Timeline, leakable: Bool, from: Int64 = 0, count: Int = 24_576) -> [Float] {
        let f = feeder(tl, leakable: leakable)
        f.seek(to: from, reverse: false)
        _ = f.fill(maxBlocks: (count + 1023) / 1024)
        var l = [Float](repeating: 9, count: count), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: count) } }
        return l
    }

    private static func difference(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) } }
    private static func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }

    @Test func withoutTheEffectTheNeighborsPlayTheirHandles() throws {
        // Control: the same cut without Disguise Voice does read the range through the outer clips' handles.
        let tl = try Self.timeline(disguised: false)
        #expect(Self.difference(Self.mixed(tl, leakable: true), Self.mixed(tl, leakable: false)) > 0.1)
        #expect(Self.difference(Self.played(tl, leakable: true), Self.played(tl, leakable: false)) > 0.1)
    }

    @Test func outerClipsAddNothingFromTheRangeWhenScrubbing() throws {
        let tl = try Self.timeline(disguised: true)
        let out = Self.mixed(tl, leakable: true)
        #expect(Self.difference(out, Self.mixed(tl, leakable: false)) == 0)
        #expect(Self.peak(out[11_000..<15_000]) > 0.05)           // the disguised clip itself is heard
        #expect(Self.peak(out[0..<6_400]) == 0 && Self.peak(out[20_000..<24_000]) == 0)
    }

    @Test func outerClipsAddNothingFromTheRangeInPlaybackAndExport() throws {
        let tl = try Self.timeline(disguised: true)
        let out = Self.played(tl, leakable: true)
        #expect(Self.difference(out, Self.played(tl, leakable: false)) == 0)
        #expect(Self.peak(out[11_000..<15_000]) > 0.05)
    }

    @Test func outerClipsAddNothingAfterASeekIntoEitherFade() throws {
        let tl = try Self.timeline(disguised: true)
        for from: Int64 in [7_000, 8_000, 9_000, 15_000, 16_000, 17_000] {
            #expect(Self.difference(Self.mixed(tl, leakable: true, from: from, count: 2_048),
                                    Self.mixed(tl, leakable: false, from: from, count: 2_048)) == 0)
            #expect(Self.difference(Self.played(tl, leakable: true, from: from, count: 2_048),
                                    Self.played(tl, leakable: false, from: from, count: 2_048)) == 0)
        }
    }
}
