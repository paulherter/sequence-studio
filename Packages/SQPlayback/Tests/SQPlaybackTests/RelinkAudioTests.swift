import Testing
import Foundation
import Metal
import Synchronization
import SQCore
import SQMedia
@testable import SQPlayback

private let fd = Time(1, 30)

private final class SourceBox: Sendable {
    private let s = Mutex<any AudioSource>(MemoryAudioSource(mono: [Float](repeating: 0.5, count: 6 * 48_000)))
    func set(_ v: Float) { s.withLock { $0 = MemoryAudioSource(mono: [Float](repeating: v, count: 6 * 48_000)) } }
    var current: any AudioSource { s.withLock { $0 } }
}

@Suite(.serialized) @MainActor struct RelinkAudioTests {
    private func peak(_ v: ScrubVoice) -> Float {
        var l = [Float](repeating: 0, count: 2000), r = l
        _ = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            v.render(left: lp.baseAddress!, right: rp.baseAddress!, count: 2000) } }
        return l.map { abs($0) }.max() ?? 0
    }

    // Relink while playing must switch the sound too, including the scrub mixer's cached sources.
    @Test func scrubMixerReopensASourceAfterMediaChanged() {
        let media = UUID(), box = SourceBox()
        let clip = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: .zero, duration: Time(6, 1)), start: .zero)
        let tl = Timeline(name: "S", frameDuration: fd, tracks: [Track(kind: .audio, clips: [clip])])
        let s = ScrubAudio(resolver: { _ in box.current }, inline: true)
        s.setTimeline(tl, sequences: [:])
        func grainPeak(from pos: Int64) -> Float {
            s.begin(at: Time(pos, 48_000), hostNanos: 0)
            s.scrub(to: Time(pos + 200, 48_000), hostNanos: 100_000)
            let p = peak(s.voice)
            for _ in 0..<20 { _ = peak(s.voice) }                      // let the grain and its tail finish
            return p
        }
        #expect(grainPeak(from: 48_000) > 0.4)                       // old file: 0.5
        box.set(0.1)                                                 // the media now points at another file
        #expect(grainPeak(from: 96_000) > 0.4, "still the cached old source without the call")
        s.mediaChanged([media])
        #expect(grainPeak(from: 144_000) < 0.2, "the new file after mediaChanged")
    }

    @Test func engineForwardsMediaChangedToPlaybackAndScrubAudio() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scrub = ScrubAudio(resolver: { _ in MemoryAudioSource(mono: [0]) }, inline: true)
        let audio = ManualAudio(scrub: scrub)
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock(), audio: audio)
        let id = UUID()
        engine.mediaChanged([id])
        #expect(audio.changedMedia == [[id]])
    }
}
