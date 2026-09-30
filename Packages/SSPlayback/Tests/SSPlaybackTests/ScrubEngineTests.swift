import Testing
import Foundation
import Metal
import CoreMedia
import SSCore
import SSMedia
import SSMediaTestSupport
@testable import SSPlayback

// E-12: PlaybackEngine drives ScrubAudio (ManualAudio fake), plus a real-device smoke test.

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

private actor ScrubVideoClip {
    static let shared = ScrubVideoClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 60
        spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

private func sine() -> MemoryAudioSource {
    MemoryAudioSource(mono: (0..<(3 * 48_000)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) })
}

private func renderVoice(_ v: ScrubVoice, _ frames: Int) -> [Float] {
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { l.deallocate(); r.deallocate() }
    _ = v.render(left: l, right: r, count: frames)
    return Array(UnsafeBufferPointer(start: l, count: frames))
}
private func peak(_ x: [Float]) -> Float { x.map(abs).max() ?? 0 }

@MainActor
private struct ScrubRig {
    let engine: PlaybackEngine
    let audio: ManualAudio
    let scrub: ScrubAudio
    let video: UUID, sound: UUID

    static func make(failsToPrepare: Bool = false) async throws -> ScrubRig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: try await ScrubVideoClip.shared.get())
        let video = UUID(), sound = UUID()
        let src = sine()
        let scrub = ScrubAudio(resolver: { _ in src }, inline: true)
        let audio = ManualAudio(failsToPrepare: failsToPrepare, scrub: scrub)
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [video: demuxer]),
                                        clock: ManualClock(), audio: audio)
        return ScrubRig(engine: engine, audio: audio, scrub: scrub, video: video, sound: sound)
    }

    func timeline(audio: Bool = true, muted: Bool = false) -> Timeline {
        let v = Clip(name: "V", media: video, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                     start: .zero, mediaDuration: fd * 60)
        var tracks = [Track(kind: .video, clips: [v])]
        if audio {
            let a = Clip(name: "A", media: sound, kind: .audio, source: TimeRange(start: .zero, duration: fd * 60), start: .zero)
            tracks.append(Track(kind: .audio, clips: [a], isMuted: muted))
        }
        return Timeline(name: "S", format: format, tracks: tracks)
    }

    func drag(to t: Time) { audio.advanceTime(nanoseconds: 8_000_000); engine.scrub(to: t) }
}

@Suite(.serialized) @MainActor struct ScrubEngineTests {
    @Test func beginScrubEndDriveGrains() async throws {
        let rig = try await ScrubRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline())
        e.beginScrub()
        #expect(rig.audio.isPrepared)                          // scrub brings the output up (user action, like play)
        rig.drag(to: Time(1, 2)); rig.drag(to: Time(1, 2) + Time(1, 120))
        #expect(rig.scrub.submittedGrains == 2)
        #expect(rig.scrub.lastGrain?.reverse == false)
        #expect(peak(renderVoice(rig.scrub.voice, 1024)) > 0.3)
        rig.drag(to: Time(1, 4))
        #expect(rig.scrub.lastGrain?.reverse == true)          // dragging left: reversed grain
        e.endScrub()
        let tail = renderVoice(rig.scrub.voice, 4800)
        #expect(tail.suffix(4800 - 240).allSatisfy { $0 == 0 })  // stopped: 5 ms fade, then silence
        rig.drag(to: Time(1, 1))                               // a seek outside a scrub gesture plays nothing
        #expect(rig.scrub.submittedGrains == 3)
        #expect(e.rate.isPaused && !rig.audio.isPlaying)       // the play path was never started
    }

    @Test func playCancelsScrubAudio() async throws {
        let rig = try await ScrubRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline())
        e.beginScrub()
        rig.drag(to: Time(1, 2))
        e.play()                                               // pending grain dropped, scrub over
        #expect(renderVoice(rig.scrub.voice, 4800).allSatisfy { $0 == 0 })
        #expect(rig.scrub.voice.freeSlots == ScrubVoice.slotCount)
        #expect(e.usesAudioClock && rig.audio.isPlaying)       // the play path owns the output
        rig.drag(to: Time(1, 1))
        #expect(rig.scrub.submittedGrains == 1)                // no scrub gesture any more
        e.pause()
    }

    @Test func stepPlaysAGrainInStepDirection() async throws {
        let rig = try await ScrubRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline())
        e.seek(to: Time(1, 1))
        e.step(1)
        #expect(rig.scrub.submittedGrains == 1 && rig.scrub.lastGrain?.reverse == false)
        #expect(rig.scrub.lastGrain?.start == 49_600)
        #expect(peak(renderVoice(rig.scrub.voice, 2400)) > 0.3)
        e.step(-1)
        #expect(rig.scrub.submittedGrains == 2 && rig.scrub.lastGrain?.reverse == true)
        #expect(rig.scrub.lastGrain?.start == 49_600)          // end of frame 30, read backwards
        e.seek(to: .zero)
        e.step(-1)                                             // clamped at 0: no motion, no grain
        #expect(rig.scrub.submittedGrains == 2)
    }

    @Test func noGrainsWhenNothingIsAudible() async throws {
        let rig = try await ScrubRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline(muted: true))
        e.beginScrub(); rig.drag(to: Time(1, 2)); e.endScrub()
        e.step(1)
        e.setTimeline(rig.timeline(audio: false))
        e.beginScrub(); rig.drag(to: Time(1, 3)); e.endScrub()
        #expect(rig.scrub.submittedGrains == 0 && !rig.audio.isPrepared)
    }

    @Test func noGrainsWhenTheOutputCannotStart() async throws {
        let rig = try await ScrubRig.make(failsToPrepare: true)
        let e = rig.engine
        e.setTimeline(rig.timeline())
        e.beginScrub(); rig.drag(to: Time(1, 2)); e.endScrub()
        e.step(1)
        #expect(rig.scrub.submittedGrains == 0 && e.audioUnavailable)
    }
}

// MARK: Real AVAudioEngine (skips without an output device)

private actor ScrubAudioClip {
    static let shared = ScrubAudioClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 150
        spec.frameDuration = TestClipSpec.fps(30)
        spec.audioClicks = (0..<5).map { CMTime(value: CMTimeValue($0), timescale: 1) }
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

@Suite(.serialized) struct ScrubAudioSmokeTests {
    /// Generated E-01 clip with audio: 1 s forward drag, 1 s backward drag at mouse-event rate on the real output,
    /// then a few steps. No underrun, no dropped request, grains reach the hardware.
    @Test(.enabled(if: AudioEngine.hasOutputDevice(), "no audio output device"))
    func scrubsTwoSecondsOnTheRealOutput() async throws {
        let url = try await ScrubAudioClip.shared.get()
        let media = UUID()
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
        let engine = AudioEngine(media: StaticMediaResolver(audio: [media: src]))
        defer { engine.shutdown() }
        let clip = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        engine.setTimeline(Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [clip])]), sequences: [:])
        try engine.prepare()
        let scrub = try #require(engine.scrubAudio)
        var pos = Time(1, 1)
        scrub.begin(at: pos, hostNanos: engine.hostNanoseconds())
        for k in 0..<120 {                                     // 2 s at ~60 events/s
            pos = pos + (k < 60 ? Time(1, 60) : Time(-1, 60))
            scrub.scrub(to: pos, hostNanos: engine.hostNanoseconds())
            try await Task.sleep(for: .milliseconds(16))
        }
        scrub.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(scrub.voice.grainsStarted > 20, "grains rendered by the hardware: \(scrub.voice.grainsStarted)")
        #expect(scrub.droppedRequests == 0)
        #expect(engine.underrunCount == 0)
        #expect(engine.feeder.failedReads.load(ordering: .relaxed) == 0)
        #expect(scrub.failedReads == 0)
        print("[E-12] real output: \(scrub.submittedGrains) requests, \(scrub.producedGrains) grains mixed, \(scrub.voice.grainsStarted) played")
    }
}
