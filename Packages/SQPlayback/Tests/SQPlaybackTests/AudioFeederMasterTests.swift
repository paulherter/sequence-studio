import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1, 30))

private func timeline(_ m: UUID, gainDB: Double = 0, role: AudioTag? = nil, target: DeliveryTarget? = nil) -> Timeline {
    var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)), start: .zero)
    c.audioGainDB = gainDB
    var tr = Track(kind: .audio, clips: [c])
    tr.audioRole = role
    var t = Timeline(name: "t", format: fmt, tracks: [tr])
    t.deliveryTarget = target
    return t
}

private func feeder(_ t: Timeline, _ v: Float = 0.5) -> AudioFeeder {
    let src = MemoryAudioSource(mono: [Float](repeating: v, count: 30_000))
    return AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
}

private func played(_ f: AudioFeeder, _ n: Int) -> (l: [Float], r: [Float]) {
    f.seek(to: 0, reverse: false)
    _ = f.fill(maxBlocks: 4)
    var l = [Float](repeating: 0, count: n), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
    return (l, r)
}

@Suite struct AudioFeederMasterTests {
    private let ceiling = Float(GainMath.linear(fromDB: -1))

    @Test func withoutADeliveryTargetTheMixIsNotLimited() {
        let m = UUID()
        let p = played(feeder(timeline(m, gainDB: 6.0206)), 2048)
        #expect(p.l[500...].allSatisfy { abs($0 - 1) < 1e-3 })
    }

    @Test func aDeliveryTargetLimitsTheMasterAtItsTruePeakCeiling() {
        let m = UUID()
        let t = timeline(m, gainDB: 6.0206, target: DeliveryTarget(platform: .youtube))
        let p = played(feeder(t), 2048)
        #expect(p.l.allSatisfy { $0 <= ceiling } && p.r.allSatisfy { $0 <= ceiling })
        #expect(p.l[500...].allSatisfy { abs($0 - ceiling) < 1e-4 })
    }

    @Test func quietMaterialPassesTheLimiterUntouched() {
        let m = UUID()
        let p = played(feeder(timeline(m, target: DeliveryTarget(platform: .tiktok))), 2048)
        #expect(p.l.allSatisfy { $0 == 0.5 })
    }

    @Test func changingTheTargetMovesTheCeiling() {
        let m = UUID()
        let t = timeline(m, gainDB: 6.0206, target: DeliveryTarget(platform: .youtube))
        let f = feeder(t)
        _ = played(f, 1024)
        var t2 = t
        t2.deliveryTarget = DeliveryTarget(platform: .youtube, targetLUFS: -14, truePeakDB: -6.0206)
        f.setTimeline(t2)
        let p = played(f, 2048)
        #expect(p.l[500...].allSatisfy { abs($0 - 0.5) < 1e-3 })
        f.setTimeline(timeline(m, gainDB: 6.0206))
        #expect(played(f, 2048).l[500...].allSatisfy { abs($0 - 1) < 1e-3 })
    }

    @Test func aTrackRoleGivesTheTrackItsVoicedPreset() {
        let m = UUID()
        let t = timeline(m, role: .music)
        let id = t.tracks[0].id
        let f = feeder(t)
        #expect(f.effectivePreset(track: id) == .forRole(.music))
        var t2 = t
        t2.tracks = [{ var x = t.tracks[0]; x.audioRole = .dialogue; return x }()]
        f.setTimeline(t2)
        #expect(f.effectivePreset(track: id) == .forRole(.dialogue))
        t2.tracks = [{ var x = t.tracks[0]; x.audioRole = nil; return x }()]
        f.setTimeline(t2)
        #expect(f.effectivePreset(track: id) == nil)
    }

    @Test func anExplicitPresetWinsOverTheRole() {
        let m = UUID()
        let t = timeline(m, role: .sfx)
        let id = t.tracks[0].id
        let f = feeder(t)
        f.setPreset(track: id, preset: .voice)
        #expect(f.effectivePreset(track: id) == .voice)
        f.setPreset(track: id, preset: nil)
        #expect(f.effectivePreset(track: id) == .forRole(.sfx))
    }

    @Test func theRoleRunsThroughTheTrackFX() {
        // SFX: flat EQ, 0 dB level and makeup, threshold -14 dBFS: a quiet constant stays under it and passes unchanged.
        let m = UUID()
        let plain = played(feeder(timeline(m), 0.05), 4096)
        let sfx = played(feeder(timeline(m, role: .sfx), 0.05), 4096)
        let ratio = Double(sfx.l[3000] / plain.l[3000])
        #expect(abs(GainMath.dB(fromLinear: ratio)) < 0.3)
    }
}

@Suite struct AudioFeederLiveDuckingTests {
    private func twoTracks(_ m: UUID, dialogueStart: Time) -> Timeline {
        let src = TimeRange(start: .zero, duration: Time(20_000, rate))
        var music = Track(kind: .audio, clips: [Clip(name: "m", media: m, kind: .audio, source: src, start: .zero)]); music.audioRole = .music
        var dlg = Track(kind: .audio, clips: [Clip(name: "d", media: UUID(), kind: .audio, source: src, start: dialogueStart)]); dlg.audioRole = .dialogue
        return Timeline(name: "t", format: fmt, tracks: [music, dlg])
    }
    private func play(_ t: Timeline, duck: LiveDucking?, project: ProjectLiveDucking? = nil) -> [Float] {
        let src = MemoryAudioSource(mono: [Float](repeating: 0.3, count: 30_000))
        let silent = MemoryAudioSource(mono: [Float](repeating: 0, count: 30_000))
        let music = t.tracks[0].clips[0].media
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == music ? src : silent }
        f.liveDucking = duck
        f.projectLiveDucking = project
        f.setPreset(track: t.tracks[0].id, preset: .off)   // linear music, so the ratio is exactly the duck gain
        return played(f, 2048).l
    }

    @Test func musicDucksUnderDialogueRoleClipsAndOnlyThen() {
        let m = UUID()
        let t = twoTracks(m, dialogueStart: .zero)
        let plain = play(t, duck: nil), ducked = play(t, duck: LiveDucking(amountDB: 12))
        #expect(plain[1500] != 0)
        #expect(abs(ducked[1500] / plain[1500] - Float(GainMath.linear(fromDB: -12))) < 1e-2)
        let far = twoTracks(m, dialogueStart: Time(60, 1))
        #expect(play(far, duck: LiveDucking(amountDB: 12)) == play(far, duck: nil))
    }

    /// N8b leftover check: the duck also applies while playing in reverse (and in reverse scrub grains, which mix forward).
    @Test func duckAppliesInReversePlay() {
        let t = twoTracks(UUID(), dialogueStart: .zero)
        let src = MemoryAudioSource(mono: [Float](repeating: 0.3, count: 30_000))
        let music = t.tracks[0].clips[0].media
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == music ? src : MemoryAudioSource(mono: [Float](repeating: 0, count: 30_000)) }
        f.liveDucking = LiveDucking(amountDB: 12)
        f.setPreset(track: t.tracks[0].id, preset: .off)
        f.seek(to: 4096, reverse: true); _ = f.fill(maxBlocks: 2)
        var l = [Float](repeating: 0, count: 2048), r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in _ = f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: 2048) } }
        #expect(abs(l[1000] / 0.3 - Float(GainMath.linear(fromDB: -12))) < 1e-2)
    }

    /// N8b: an opted-out music track keeps its level; so does music under an opted-out dialogue track.
    @Test func excludedTracksTakeNoPart() {
        let m = UUID()
        var t = twoTracks(m, dialogueStart: .zero)
        let plain = play(t, duck: nil)
        t.tracks[0].isExcludedFromLiveDucking = true
        #expect(play(t, duck: LiveDucking(amountDB: 12)) == plain)
        t.tracks[0].isExcludedFromLiveDucking = false
        t.tracks[1].isExcludedFromLiveDucking = true
        #expect(play(t, duck: LiveDucking(amountDB: 12)) == plain)
    }

    /// N8b: the project's stored setting wins over Preferences (on with its own amount, or off).
    @Test func projectSettingOverridesPreferences() {
        let t = twoTracks(UUID(), dialogueStart: .zero)
        let plain = play(t, duck: nil)
        #expect(play(t, duck: LiveDucking(amountDB: 12), project: ProjectLiveDucking(isOn: false)) == plain)
        let p18 = play(t, duck: nil, project: ProjectLiveDucking(isOn: true, amountDB: 18))
        #expect(abs(p18[1500] / plain[1500] - Float(GainMath.linear(fromDB: -18))) < 1e-2)
        #expect(play(t, duck: LiveDucking(amountDB: 6), project: ProjectLiveDucking(isOn: true, amountDB: 18)) == p18)
    }

    @Test func settingOffRestoresTheMix() {
        let t = twoTracks(UUID(), dialogueStart: .zero)
        #expect(play(t, duck: LiveDucking(amountDB: 0)) == play(t, duck: nil))
    }

    /// The duck is delay-compensated with its bus: the output lags the timeline by the FX latency, the curve lags with it.
    @Test func duckFollowsTheTimelineNotTheOutputSample() {
        let m = UUID()
        let t = twoTracks(m, dialogueStart: Time(10_000, rate))   // the Dialogue role runs the denoiser: 480 samples latency
        let src = MemoryAudioSource(mono: [Float](repeating: 0.3, count: 30_000))
        let silent = MemoryAudioSource(mono: [Float](repeating: 0, count: 30_000))
        func run(_ d: LiveDucking?) -> (out: [Float], latency: Int) {
            let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == m ? src : silent }
            f.liveDucking = d
            f.setPreset(track: t.tracks[0].id, preset: .off)
            let p = played(f, 3072)
            return (p.l, f.outputLatencySamples)
        }
        let plain = run(nil), ducked = run(LiveDucking(amountDB: 12))
        #expect(plain.latency > 0)
        let live = LiveDucking(amountDB: 12)
        let r = [TimeRange(start: Time(10_000, rate), duration: Time(20_000, rate))]
        for j in [1500, 2200, 2800] {
            let timelineFrame = Int64(j - plain.latency)
            let want = live.gain(at: Time(timelineFrame, rate), ranges: r)
            #expect(abs(ducked.out[j] / plain.out[j] - want) < 2e-2, "j \(j)")
        }
    }

    @Test func scrubMixUsesTheDuckToo() {
        let m = UUID()
        let t = twoTracks(m, dialogueStart: .zero)
        let src = MemoryAudioSource(mono: [Float](repeating: 0.3, count: 30_000))
        let silent = MemoryAudioSource(mono: [Float](repeating: 0, count: 30_000))
        func dry(_ d: LiveDucking?) -> Float {
            let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == m ? src : silent }
            f.liveDucking = d
            var l = [Float](repeating: 0, count: 512), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                f.mix(timeline: t, startFrame: 1000, count: 512, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
            return l[300]
        }
        #expect(abs(dry(LiveDucking(amountDB: 12)) / dry(nil) - Float(GainMath.linear(fromDB: -12))) < 1e-2)
    }
}
