import Testing
import Foundation
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

private actor VideoClip {
    static let shared = VideoClip()
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

@MainActor
private struct AudioRig {
    let engine: PlaybackEngine
    let host: ManualClock
    let audio: ManualAudio
    let video: UUID, sound: UUID

    static func make(audio: ManualAudio = ManualAudio()) async throws -> AudioRig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: try await VideoClip.shared.get())
        let video = UUID(), sound = UUID()
        let host = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [video: demuxer]),
                                        clock: host, audio: audio)
        engine.waitsForStartFrame = false     // these tests are about the clock/audio hand-over, not frames
        return AudioRig(engine: engine, host: host, audio: audio, video: video, sound: sound)
    }

    func timeline(audio: Bool, muted: Bool = false) -> Timeline {
        let v = Clip(name: "V", media: video, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                     start: .zero, mediaDuration: fd * 60)
        var tracks = [Track(kind: .video, clips: [v])]
        if audio {
            let a = Clip(name: "A", media: sound, kind: .audio, source: TimeRange(start: .zero, duration: fd * 60), start: .zero)
            tracks.append(Track(kind: .audio, clips: [a], isMuted: muted))
        }
        return Timeline(name: "S", format: format, tracks: tracks)
    }
}

@Suite(.serialized) @MainActor struct PlaybackEngineAudioTests {
    @Test func picksTheAudioClockOnlyWhenTheTimelineIsAudible() async throws {
        let rig = try await AudioRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline(audio: false))
        e.play(); e.pause()
        #expect(!e.usesAudioClock && !rig.audio.isPrepared)
        e.setTimeline(rig.timeline(audio: true, muted: true))
        e.play(); e.pause()
        #expect(!e.usesAudioClock && !rig.audio.isPrepared)
        e.setTimeline(rig.timeline(audio: true))
        #expect(!e.usesAudioClock && !rig.audio.isPrepared)          // setTimeline never prepares (may block)
        e.play()
        #expect(e.usesAudioClock && rig.audio.isPrepared && rig.audio.timeline != nil)
        e.pause()
        e.setTimeline(rig.timeline(audio: false))
        #expect(!e.usesAudioClock)
        e.setTimeline(rig.timeline(audio: true))                     // already prepared: switches right away
        #expect(e.usesAudioClock)
    }

    @Test func playsOnTheAudioClockAndFillsMaxAVDrift() async throws {
        let rig = try await AudioRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline(audio: true))
        e.seek(to: .zero)
        await e.waitForDecodes()
        e.tick()
        e.play()
        #expect(rig.audio.isPlaying && rig.audio.lastSeek == .zero && rig.audio.currentRate == .forward)
        rig.host.advance(by: Time(1, 1))                          // host time is ignored now
        rig.audio.render(frames: 2000)                            // 41.67 ms of audio heard -> frame 1
        await e.waitForDecodes()
        e.tick()
        #expect(e.position == fd)
        let drift = e.stats.maxAVDrift
        #expect(drift == Time(2000, 48_000) - fd)                  // audio clock vs presented frame
        #expect(drift > .zero && drift < fd)
        e.pause()
        #expect(!rig.audio.isPlaying && e.rate == .zero)
    }

    @Test func switchingMidPlayHandsThePositionOver() async throws {
        let rig = try await AudioRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline(audio: true))
        e.play()
        rig.audio.render(frames: 48_000 / 2)                       // 0.5 s
        e.setTimeline(rig.timeline(audio: true, muted: true))      // muted: back to the host clock
        #expect(!e.usesAudioClock && !rig.audio.isPlaying)
        #expect(rig.host.now() == Time(1, 2) && rig.host.rate == .forward)
    }

    @Test func fallsBackToTheHostClockWhenTheOutputCannotStart() async throws {
        let rig = try await AudioRig.make(audio: ManualAudio(failsToPrepare: true))
        let e = rig.engine
        e.setTimeline(rig.timeline(audio: true))
        e.play()
        #expect(!e.usesAudioClock && e.audioUnavailable)
        rig.host.advance(by: fd * 2)
        await e.waitForDecodes()
        e.tick()
        #expect(e.position == fd * 2 && e.stats.maxAVDrift == .zero)
        e.pause()
        rig.audio.setFailsToPrepare(false)                            // device back: the next play retries
        e.play()
        #expect(e.usesAudioClock && !e.audioUnavailable)
    }

    @Test func stalledOutputFallsBackToTheHostClockAtTheCurrentPosition() async throws {
        let rig = try await AudioRig.make()
        let e = rig.engine
        e.setTimeline(rig.timeline(audio: true))
        e.play()
        rig.audio.render(frames: 4800)                                // 0.1 s heard
        rig.audio.advanceTime(nanoseconds: 300_000_000)               // then the output stops pulling
        await e.waitForDecodes()
        e.tick()
        #expect(!e.usesAudioClock && e.audioUnavailable && !rig.audio.isPlaying)
        #expect(rig.host.now() == Time(1, 10) && rig.host.rate == .forward)   // continues from the audio position
        rig.host.advance(by: Time(1, 10))
        e.tick()
        #expect(e.position == RenderLoop.gridTime(Time(2, 10), rig.timeline(audio: true)))
        e.pause(); e.play()                                          // retry on the next play
        #expect(e.usesAudioClock && !e.audioUnavailable)
    }
}
