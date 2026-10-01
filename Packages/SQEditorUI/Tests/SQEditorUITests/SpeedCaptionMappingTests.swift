import Foundation
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct SpeedCaptionMappingTests {
    private func captions() -> [Caption] {
        let w = TranscriptWord(text: "hello", range: TimeRange(start: s(11), duration: Time(1, 2)))
        return CaptionSegmenter.segment(Transcript(language: "en-US", words: [w]), preset: .standard)
    }

    @Test func spedUpClipMapsCaptionsThroughTheSpeed() throws {
        // Source 10..18 at 200 % = 4 s on the timeline from 100.
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(8)), start: s(100),
                        speed: ClipSpeed(percent: 200))
        let caps = captions()
        let items = CaptionMapping.items(caps, for: clip)
        let src = try #require(caps.first?.range)
        let item = try #require(items.first)
        #expect(item.range.start == s(100) + Time((src.start - s(10)).value, (src.start - s(10)).timescale * 2))
        #expect(item.range.duration == Time(src.duration.value, src.duration.timescale * 2))
        #expect(clip.timeline.intersection(item.range) == item.range)
    }

    @Test func reversedClipMirrorsTheCaptionSpan() throws {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(8)), start: s(100),
                        reversed: true)
        let caps = captions()
        let src = try #require(caps.first?.range)
        let item = try #require(CaptionMapping.items(caps, for: clip).first)
        #expect(item.range.end == s(100) + (s(18) - src.start))
        #expect(item.range.duration == src.duration)
    }
}
