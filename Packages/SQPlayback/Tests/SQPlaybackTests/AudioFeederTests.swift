import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1001, 30_000))

/// Source whose frame i holds `i + 1 + offset` (never 0, exactly representable).
private func ramp(_ n: Int, offset: Float = 0) -> MemoryAudioSource {
    MemoryAudioSource(mono: (0..<n).map { Float($0) + 1 + offset })
}
private func frames(_ n: Int64) -> Time { Time(n, rate) }
private func clip(_ media: UUID, src: Int64 = 0, len: Int64, at start: Time, volume: Double = 1) -> Clip {
    var c = Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: frames(src), duration: frames(len)), start: start)
    c.animation.volume = AnimatedProperty(volume)
    return c
}
private func feeder(_ t: Timeline, _ sources: [UUID: any AudioSource], block: Int = 1024, ring: Int = 1 << 14) -> AudioFeeder {
    AudioFeeder(timeline: t, ring: RingBuffer(capacity: ring), blockFrames: block) { id in
        guard let s = sources[id] else { throw MediaError.unreadable }
        return s
    }
}
private func mixed(_ f: AudioFeeder, _ t: Timeline, from: Int64, count: Int) -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
    return (l, r)
}
private func popAll(_ f: AudioFeeder, _ n: Int) -> [Float] {
    var l = [Float](repeating: 0, count: n), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
    return l
}

@Suite struct AudioFeederTests {
    @Test func clipBoundariesAreSampleExact() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, src: 10, len: 50, at: frames(100))])])
        let f = feeder(t, [m: ramp(1000)])
        let o = mixed(f, t, from: 0, count: 256)
        for i in 0..<256 {
            let expected: Float = (100..<150).contains(i) ? Float(i - 100 + 10) + 1 : 0
            #expect(o.l[i] == expected && o.r[i] == expected, "frame \(i)")
        }
    }

    @Test func nonGridClipStartRoundsConsistentlyAcrossBlocks() {
        // 1001/30000 s = 1601.6 frames: first sample at or after the start is frame 1602, source offset rounds to 10.
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio,
            clips: [clip(m, src: 10, len: 3000, at: Time(1001, 30_000))])])
        let big = feeder(t, [m: ramp(5000)], block: 4096)
        let whole = mixed(big, t, from: 0, count: 4096).l
        #expect(whole[1601] == 0)
        #expect(whole[1602] != 0)
        let small = feeder(t, [m: ramp(5000)], block: 1000)
        var pieces: [Float] = []
        for s in stride(from: Int64(0), to: 4000, by: 1000) { pieces += mixed(small, t, from: s, count: 1000).l }
        #expect(pieces == Array(whole[0..<4000]))
        // Source mapping is gapless: consecutive frames inside the clip advance by exactly 1.
        let inside = whole[1602..<4096]
        #expect(zip(inside, inside.dropFirst()).allSatisfy { $1 - $0 == 1 })
    }

    @Test func forwardFillDeliversContiguousBlocks() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 5000, at: .zero)])])
        let f = feeder(t, [m: ramp(5000)], block: 1000)
        f.seek(to: 500, reverse: false)
        #expect(f.fill(maxBlocks: 3) == 3)
        #expect(f.position == 3500)
        #expect(popAll(f, 3000) == (500..<3500).map { Float($0) + 1 })
    }

    @Test func reverseBlocksRunBackwardsAndAreReversed() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 4000, at: .zero)])])
        let f = feeder(t, [m: ramp(4000)], block: 1000)
        f.seek(to: 3000, reverse: true)
        #expect(f.fill(maxBlocks: 3) == 3)
        #expect(f.position == 0)
        #expect(f.fill(maxBlocks: 1) == 0)          // timeline start reached
        // Output sample k is timeline frame 2999 - k, across block seams too.
        #expect(popAll(f, 3000) == (0..<3000).map { Float(2999 - $0) + 1 })
    }

    @Test func reverseLastBlockIsShort() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 4000, at: .zero)])])
        let f = feeder(t, [m: ramp(4000)], block: 1000)
        f.seek(to: 1500, reverse: true)
        #expect(f.fill() == 2)                        // 1000 + 500
        #expect(popAll(f, 1500) == (0..<1500).map { Float(1499 - $0) + 1 })
    }

    @Test func muteAndSolo() {
        let a = UUID(), b = UUID()
        let src: [UUID: any AudioSource] = [a: ramp(1000), b: ramp(1000, offset: 1000)]
        func tl(muteA: Bool = false, soloB: Bool = false, muteB: Bool = false) -> Timeline {
            Timeline(name: "t", format: fmt, tracks: [
                Track(kind: .audio, clips: [clip(a, len: 100, at: .zero)], isMuted: muteA),
                Track(kind: .audio, clips: [clip(b, len: 100, at: .zero)], isMuted: muteB, isSolo: soloB)])
        }
        let both = tl()
        #expect(mixed(feeder(both, src), both, from: 0, count: 4).l == [1002, 1004, 1006, 1008])   // (i+1) + (i+1001)
        let muted = tl(muteA: true)
        #expect(mixed(feeder(muted, src), muted, from: 0, count: 2).l == [1001, 1002])
        let solo = tl(soloB: true)
        #expect(mixed(feeder(solo, src), solo, from: 0, count: 2).l == [1001, 1002])
        let soloMuted = tl(soloB: true, muteB: true)        // mute beats solo
        #expect(mixed(feeder(soloMuted, src), soloMuted, from: 0, count: 2).l == [0, 0])
    }

    @Test func constantClipVolumeIsApplied() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 100, at: .zero, volume: 0.5)])])
        let o = mixed(feeder(t, [m: ramp(100)]), t, from: 0, count: 4)
        #expect(o.l == [0.5, 1, 1.5, 2] && o.r == o.l)
    }

    @Test func animatedVolumeFollowsKeyframes() {
        let m = UUID()
        var c = clip(m, len: 1024, at: .zero)
        let kt = KeyframeTrack<Double>(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: frames(1024), value: 1.0)])
        c.animation.volume = AnimatedProperty(1, track: kt)
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
        let src = MemoryAudioSource(mono: [Float](repeating: 1, count: 1024))
        let o = mixed(feeder(t, [m: src]), t, from: 0, count: 1024).l
        #expect(o[0] == 0)
        #expect(abs(o[512] - 0.5) < 0.01)
        #expect(abs(o[1023] - 1023.0 / 1024) < 0.01)
        #expect(zip(o, o.dropFirst()).allSatisfy { $1 >= $0 })
    }

    @Test func failingSourceIsSilenceNotFatal() {
        let ok = UUID(), bad = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [
            Track(kind: .audio, clips: [clip(bad, len: 100, at: .zero)]),
            Track(kind: .audio, clips: [clip(ok, len: 100, at: .zero)])])
        let f = feeder(t, [ok: ramp(100)])
        #expect(mixed(f, t, from: 0, count: 2).l == [1, 2])
        #expect(f.failedReads.load(ordering: .relaxed) >= 1)
    }

    @Test func sourceShorterThanClipZeroFillsTail() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 100, at: .zero)])])
        let o = mixed(feeder(t, [m: ramp(3)]), t, from: 0, count: 6).l
        #expect(o == [1, 2, 3, 0, 0, 0])
    }

    @Test func threadFeedsRing() async throws {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 100_000, at: .zero)])])
        let f = feeder(t, [m: ramp(100_000)], block: 512, ring: 4096)
        f.seek(to: 0, reverse: false)
        f.start()
        var got: [Float] = []
        let deadline = Date().addingTimeInterval(20)
        while got.count < 20_000, Date() < deadline {
            var l = [Float](repeating: 0, count: 256), r = l
            let n = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 256) } }
            got += l[0..<n]
            if n == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        f.stop()
        #expect(got.count >= 20_000)
        #expect(got == (0..<got.count).map { Float($0) + 1 })
    }

    @Test func seekWhilePausedFreesTheRing() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 100_000, at: .zero)])])
        let f = feeder(t, [m: ramp(100_000)], block: 1000, ring: 4000)
        f.seek(to: 0, reverse: false)
        f.fill()
        #expect(f.ring.availableToWrite < 1000)
        f.seek(to: 50_000, reverse: false)          // nothing consumed, consumer paused
        #expect(f.fill(maxBlocks: 1) == 1)           // feeder thread applies the flush itself, then refills
        #expect(f.ring.availableToRead == 1000)
        f.fill(maxBlocks: 1)
        #expect(popAll(f, 2000) == (50_000..<52_000).map { Float($0) + 1 })
    }

    @Test func blockMixedAcrossASeekIsDropped() {
        let m = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 100_000, at: .zero)])])
        let f = feeder(t, [m: ramp(100_000)], block: 1000)
        f.seek(to: 0, reverse: false)
        nonisolated(unsafe) var fired = false
        f.afterMixHook = { if !fired { fired = true; f.seek(to: 7000, reverse: false) } }
        f.fill(maxBlocks: 2)
        #expect(popAll(f, 2000) == (7000..<9000).map { Float($0) + 1 })
    }

    @Test func volumeRampIsIdenticalForSplitAndReverseBlocks() {
        let m = UUID()
        var c = clip(m, len: 2000, at: .zero)
        let kt = KeyframeTrack<Double>(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: frames(2000), value: 1.0)])
        c.animation.volume = AnimatedProperty(1, track: kt)
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
        let src = MemoryAudioSource(mono: [Float](repeating: 1, count: 2000))
        let whole = mixed(feeder(t, [m: src], block: 2000), t, from: 0, count: 2000).l
        let split = feeder(t, [m: src], block: 300)
        var pieces: [Float] = []
        for s in stride(from: Int64(0), to: 2000, by: 300) { pieces += mixed(split, t, from: s, count: Int(min(300, 2000 - s))).l }
        #expect(pieces == whole)
        let rev = feeder(t, [m: src], block: 300)
        rev.seek(to: 2000, reverse: true)
        rev.fill()
        #expect(popAll(rev, 2000) == whole.reversed())
    }
}
