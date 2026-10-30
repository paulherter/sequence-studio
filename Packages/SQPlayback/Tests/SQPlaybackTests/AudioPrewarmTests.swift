import Testing
import Foundation
import Metal
import SQCore
import SQMedia
@testable import SQPlayback

private let fd = Time(1, 30)

@Suite(.serialized) @MainActor struct AudioPrewarmTests {
    private func audibleTimeline() -> Timeline {
        let clip = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(6, 1)), start: .zero)
        return Timeline(name: "S", frameDuration: fd, tracks: [Track(kind: .audio, clips: [clip])])
    }

    private func waitPrepared(_ audio: ManualAudio) async -> Bool {
        for _ in 0..<200 { if audio.isPrepared { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return audio.isPrepared
    }

    @Test func prewarmBringsTheOutputUpOffTheMainThreadWhenOptedIn() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let audio = ManualAudio()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock(), audio: audio)
        engine.prewarmsAudio = true
        engine.setTimeline(audibleTimeline())
        #expect(await waitPrepared(audio))
    }

    @Test func noPrewarmByDefault() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let audio = ManualAudio()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock(), audio: audio)
        engine.setTimeline(audibleTimeline())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!audio.isPrepared)
    }

    @Test func silentTimelineIsNotPrewarmed() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let audio = ManualAudio()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock(), audio: audio)
        engine.prewarmsAudio = true
        engine.setTimeline(Timeline(name: "S", frameDuration: fd, tracks: []))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!audio.isPrepared)
    }
}
