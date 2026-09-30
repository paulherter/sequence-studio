import Testing
import Foundation
import SSCore
import SSMedia
import SSAudioFX
@testable import SSPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1001, 30_000))
private func frames(_ n: Int64) -> Time { Time(n, rate) }

private func clip(_ media: UUID, len: Int64, at start: Int64 = 0, volume: Double = 1) -> Clip {
    var c = Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: .zero, duration: frames(len)), start: frames(start))
    c.animation.volume = AnimatedProperty(volume)
    return c
}
private func feeder(_ t: Timeline, _ sources: [UUID: any AudioSource], block: Int = 1024,
                    presets: [UUID: TrackAudioPreset] = [:]) -> AudioFeeder {
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 15), blockFrames: block) { id in
        guard let s = sources[id] else { throw MediaError.unreadable }
        return s
    }
    f.setTracks(presets)
    return f
}
private func popAll(_ f: AudioFeeder, _ n: Int) -> [Float] {
    var l = [Float](repeating: 0, count: n), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
    return l
}
private func impulse(_ n: Int, at i: Int, _ v: Float) -> MemoryAudioSource {
    var a = [Float](repeating: 0, count: n); a[i] = v; return MemoryAudioSource(mono: a)
}
private func ramp(_ n: Int) -> MemoryAudioSource { MemoryAudioSource(mono: (0..<n).map { Float($0) + 1 }) }
private func sine(_ n: Int) -> MemoryAudioSource {
    MemoryAudioSource(mono: (0..<n).map { Float(0.8 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) })
}

private let squash = TrackAudioPreset(
    id: "t.squash", name: "squash",
    compressor: MultibandCompressorSettings(
        crossoversHz: [120, 700, 3000],
        bands: Array(repeating: .init(thresholdDB: -40, ratio: 10, attackMs: 1, releaseMs: 50), count: 4)),
    noiseReduction: 0)
/// Denoiser present (latency 480) but practically dry.
private let nearlyDry = TrackAudioPreset(id: "t.dn", name: "dn", compressor: .neutral, noiseReduction: 1e-9)
private let fullDenoise = TrackAudioPreset(id: "t.dn1", name: "dn1", compressor: .neutral, noiseReduction: 1)

@Suite struct AudioFeederFXTests {
    @Test func presetAppliesToItsOwnTrackOnly() {
        let a = UUID(), b = UUID()
        let ta = Track(kind: .audio, clips: [clip(a, len: 4096)]), tb = Track(kind: .audio, clips: [clip(b, len: 4096)])
        let src: [UUID: any AudioSource] = [a: sine(4096), b: ramp(4096)]
        func render(_ tracks: [Track], _ presets: [UUID: TrackAudioPreset]) -> [Float] {
            let t = Timeline(name: "t", format: fmt, tracks: tracks)
            let f = feeder(t, src, presets: presets)
            f.seek(to: 0, reverse: false); f.fill(maxBlocks: 4)
            return popAll(f, 4096)
        }
        let both = render([ta, tb], [ta.id: squash])
        let aFx = render([ta], [ta.id: squash]), aDry = render([ta], [:]), bOnly = render([tb], [:])
        #expect(zip(aFx, aDry).contains { abs($0 - $1) > 0.05 }, "preset must change track A")
        for i in 0..<4096 { #expect(abs(both[i] - (aFx[i] + bOnly[i])) < 1e-4, "frame \(i)") }
    }

    @Test func clipVolumeIsAppliedExactlyOnce() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 2048, volume: 0.5)])
        let t = Timeline(name: "t", format: fmt, tracks: [tr])
        let f = feeder(t, [m: ramp(2048)], presets: [tr.id: .off])
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 2)
        #expect(popAll(f, 2048) == (0..<2048).map { (Float($0) + 1) * 0.5 })
    }

    @Test func blockSizeLargerThanDefaultIsSupportedByFX() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 8192)])
        let t = Timeline(name: "t", format: fmt, tracks: [tr])
        let f = feeder(t, [m: ramp(8192)], block: 4096, presets: [tr.id: squash])
        f.seek(to: 0, reverse: false)
        #expect(f.fill(maxBlocks: 2) == 2)
    }

    @Test func noDenoiserMeansNoLatency() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 100)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(100)], presets: [tr.id: squash])
        #expect(f.outputLatencySamples == 0)
    }

    @Test func denoisedAndPlainTrackClicksStayAligned() {
        let a = UUID(), b = UUID()
        let td = Track(kind: .audio, clips: [clip(a, len: 4096)]), tn = Track(kind: .audio, clips: [clip(b, len: 4096)])
        let t = Timeline(name: "t", format: fmt, tracks: [td, tn])
        let f = feeder(t, [a: impulse(4096, at: 1000, 1), b: impulse(4096, at: 1000, 0.5)], presets: [td.id: nearlyDry])
        #expect(f.outputLatencySamples == 0)                     // latency changes apply at the next seek only
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 4)
        #expect(f.outputLatencySamples == 480 && f.flushed.latency == 480)
        let o = popAll(f, 4096)
        #expect(abs(o[1480] - 1.5) < 1e-4)                       // both clicks land together, delayed by the max latency
        #expect(o.enumerated().allSatisfy { $0.offset == 1480 || abs($0.element) < 1e-4 })
    }

    @Test func trackAddedLaterStillGetsCompensationDelay() {
        let a = UUID(), b = UUID()
        let td = Track(kind: .audio, clips: [clip(a, len: 4096)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [td]), [a: impulse(4096, at: 1000, 1), b: impulse(4096, at: 1000, 0.5)],
                       presets: [td.id: nearlyDry])
        let tn = Track(kind: .audio, clips: [clip(b, len: 4096)])
        f.setTimeline(Timeline(name: "t", format: fmt, tracks: [td, tn]))     // no setTracks call
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 4)
        #expect(abs(popAll(f, 4096)[1480] - 1.5) < 1e-4)
    }

    @Test func reverseBypassesDenoiserButKeepsLatencyAndOrder() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 4000)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(4000)], block: 1000, presets: [tr.id: fullDenoise])
        f.seek(to: 3000, reverse: true); f.fill(maxBlocks: 3)
        let o = popAll(f, 3000)
        #expect(o[0..<480].allSatisfy { $0 == 0 })
        for k in 0..<2520 { #expect(o[480 + k] == Float(2999 - k) + 1, "k=\(k)") }    // dry, time-descending, delayed 480
    }

    @Test func forwardAfterReverseUsesTheDenoiserAgain() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 4000)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(4000)], block: 1000, presets: [tr.id: fullDenoise])
        f.seek(to: 3000, reverse: true); f.fill(maxBlocks: 1)
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 1)
        let o = popAll(f, 1000)
        #expect(o[0..<480].allSatisfy { $0 == 0 })
        #expect(zip(o[480..<1000], (0..<520).map { Float($0) + 1 }).contains { abs($0 - $1) > 1e-3 }, "denoiser is active again")
    }

    @Test func seekResetsFXAndDelayState() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 1000)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(1000)], block: 1000, presets: [tr.id: nearlyDry])
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 1)
        f.seek(to: 5000, reverse: false); f.fill(maxBlocks: 1)       // silence after the seek
        #expect(popAll(f, 1000).allSatisfy { $0 == 0 }, "no tail of the old position may leak through the latency line")
    }

    @Test func setPresetChangesOneTrackLive() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 4096)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: sine(4096)], block: 1024)
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 2)
        let dry = popAll(f, 2048)
        f.setPreset(track: tr.id, preset: squash)
        f.fill(maxBlocks: 2)
        let wet = popAll(f, 2048)
        let ref = (2048..<4096).map { Float(0.8 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        #expect(zip(dry, (0..<2048).map { Float(0.8 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }).allSatisfy { abs($0 - $1) < 1e-5 })
        #expect(zip(wet, ref).contains { abs($0 - $1) > 0.05 })
    }

    @Test func seekReportsFlushEpochForClockRebase() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 4096)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(4096)], block: 1024)
        let g = f.seek(to: 0, reverse: false)
        #expect(f.flushed.generation != g)                      // feeder thread has not seen it yet
        f.fill(maxBlocks: 1)
        #expect(f.flushed.generation == g)
        #expect(f.flushed.epoch == 1)
        _ = popAll(f, 100)
        #expect(f.ring.consumedAtEpoch.epoch == f.flushed.epoch)
    }

    private func nestedFixture() -> (outer: Timeline, inner: Timeline, media: UUID, outerTrack: Track) {
        let m = UUID()
        let inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m, len: 2000, volume: 0.5)])])
        var nest = Clip(name: "n", media: inner.id, kind: .audio,
                        source: TimeRange(start: frames(100), duration: frames(1000)), start: frames(50), sequence: inner.id)
        nest.animation.volume = AnimatedProperty(0.5)
        let ot = Track(kind: .audio, clips: [nest])
        return (Timeline(name: "outer", format: fmt, tracks: [ot]), inner, m, ot)
    }

    @Test func nestedAudioPlaysWithInnerVolumeAndNestGain() {
        let n = nestedFixture()
        let f = feeder(n.outer, [n.media: ramp(2000)])
        f.setTimeline(n.outer, sequences: [n.inner.id: n.inner])
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 2)
        let o = popAll(f, 2048)
        #expect(o[0..<50].allSatisfy { $0 == 0 })
        for fr in 50..<1050 { #expect(o[fr] == Float(fr + 50 + 1) * 0.25, "frame \(fr)") }   // inner 0.5 x nest 0.5
        #expect(o[1050...].allSatisfy { $0 == 0 })
    }

    @Test func nestedAudioFollowsTheOuterTracksPresetAndMute() {
        let n = nestedFixture()
        let f = feeder(n.outer, [n.media: ramp(2000)], presets: [n.outerTrack.id: nearlyDry])
        f.setTimeline(n.outer, sequences: [n.inner.id: n.inner])
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 2)
        #expect(f.outputLatencySamples == 480)
        let o = popAll(f, 2048)
        for fr in 50..<1050 { #expect(abs(o[fr + 480] - Float(fr + 50 + 1) * 0.25) < 1e-3, "frame \(fr)") }
        var muted = n.outer; muted.tracks[0].isMuted = true
        f.setTimeline(muted)
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 2)
        #expect(popAll(f, 2048).allSatisfy { $0 == 0 })
    }

    @Test func threadedPresetChurnSeeksAndFadingConsumer() async throws {
        let a = UUID(), b = UUID()
        let ta = Track(kind: .audio, clips: [clip(a, len: 200_000)]), tb = Track(kind: .audio, clips: [clip(b, len: 200_000)])
        let t = Timeline(name: "t", format: fmt, tracks: [ta, tb])
        let ring = RingBuffer(capacity: 1 << 13, fadeFrames: 240)
        let f = AudioFeeder(timeline: t, ring: ring, blockFrames: 512) { id in id == a ? sine(200_000) : ramp(200_000) }
        f.seek(to: 0, reverse: false); f.start()
        let consumer = Task.detached {
            var l = [Float](repeating: 0, count: 256), r = l
            let end = Date().addingTimeInterval(0.4)
            while Date() < end {
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                    _ = ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 256) } }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        for i in 0..<40 {
            f.setPreset(track: ta.id, preset: i % 3 == 0 ? nearlyDry : (i % 3 == 1 ? squash : nil))
            if i % 5 == 0 { f.seek(to: Int64(i) * 1000, reverse: i % 10 == 0) }
            try await Task.sleep(for: .milliseconds(8))
        }
        await consumer.value
        f.stop()
        #expect(ring.consumedAtEpoch.epoch > 0)
        #expect(f.flushed.epoch >= ring.consumedAtEpoch.epoch)
    }

    @Test func latencyChangeWaitsForNextSeekAndIsPublishedWithTheFlush() {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 4096)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(4096)], block: 1024)
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 1)
        f.setPreset(track: tr.id, preset: nearlyDry)            // would add 480 samples mid-play
        f.fill(maxBlocks: 1)
        #expect(f.outputLatencySamples == 0)
        #expect(popAll(f, 2048) == (0..<2048).map { Float($0) + 1 })   // no gap, no skipped audio
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 1)
        #expect(f.outputLatencySamples == 480 && f.flushed.latency == 480)
        let o = popAll(f, 1024)
        #expect(o[0..<480].allSatisfy { $0 == 0 })
        #expect(abs(o[480] - 1) < 1e-3)
        f.setPreset(track: tr.id, preset: nil)                  // removing it keeps M until the next seek
        f.fill(maxBlocks: 1)
        #expect(f.outputLatencySamples == 480)
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 1)
        #expect(f.outputLatencySamples == 0 && f.flushed.latency == 0)
    }

    @Test func concurrentSettersLeaveTheLatestSetPublished() async {
        let m = UUID()
        let tr = Track(kind: .audio, clips: [clip(m, len: 4096)])
        let f = feeder(Timeline(name: "t", format: fmt, tracks: [tr]), [m: ramp(4096)])
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<4 { g.addTask { for k in 0..<50 { f.setPreset(track: tr.id, preset: (k + i) % 2 == 0 ? squash : nil) } } }
        }
        f.setPreset(track: tr.id, preset: nearlyDry)
        f.seek(to: 0, reverse: false); f.fill(maxBlocks: 1)
        #expect(f.outputLatencySamples == 480)
    }
}
