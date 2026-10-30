import Foundation
import Testing
import SQCore
@testable import SQTranscribe

@Suite struct CaptionTimingTests {
    func preset(minMs: Int64 = 0, gapMs: Int64 = 0) -> CaptionPreset {
        CaptionPreset(maxCharsPerLine: 20, maxLines: 2, maxDuration: t(6000), minDuration: t(minMs),
                      pauseBreak: t(800), styleRef: "s", animationRef: "a", gap: t(gapMs))
    }
    func cap(_ a: Int64, _ b: Int64) -> Caption {
        Caption(lines: ["x"], range: TimeRange(start: t(a), end: t(b)), firstWordID: UUID(), lastWordID: UUID(),
                wordIndices: 0..<1, styleRef: "s", animationRef: "a")
    }
    func ranges(_ c: [Caption]) -> [[Int64]] {
        c.map { [$0.range.start.value * 1000 / $0.range.start.timescale, $0.range.end.value * 1000 / $0.range.end.timescale] }
    }

    @Test func shortCaptionIsExtendedIntoTheSilenceAfterIt() {
        let r = CaptionSegmenter.applyTiming([cap(0, 300), cap(3000, 3200)], preset: preset(minMs: 1000))
        #expect(ranges(r) == [[0, 1000], [3000, 4000]])
    }

    @Test func extensionStopsAtTheNextCaptionMinusGap() {
        let r = CaptionSegmenter.applyTiming([cap(0, 300), cap(700, 900)], preset: preset(minMs: 1000, gapMs: 100))
        #expect(ranges(r)[0] == [0, 600])           // wanted 1000, next starts at 700, 100 ms gap
        #expect(ranges(r)[1] == [700, 1700])
    }

    @Test func gapShortensAnEndThatTouchesTheNext() {
        let r = CaptionSegmenter.applyTiming([cap(0, 1000), cap(1000, 2000)], preset: preset(gapMs: 100))
        #expect(ranges(r) == [[0, 900], [1000, 2000]])
    }

    @Test func gapNeverEmptiesACaption() {
        let r = CaptionSegmenter.applyTiming([cap(0, 50), cap(60, 2000)], preset: preset(gapMs: 100))
        #expect(ranges(r)[0] == [0, 50])            // would become empty: left alone
    }

    @Test func nothingChangesWithoutMinDurationAndGap() {
        let c = [cap(0, 300), cap(300, 600)]
        #expect(CaptionSegmenter.applyTiming(c, preset: preset()) == c)
    }

    @Test func gapIsFrameBasedWhenBuiltFromFrames() {
        let f = Time(1001, 30000)
        #expect(CaptionPreset.standard.with(gapFrames: 2, frameDuration: f).gap == f * 2)
    }

    @Test func optionsSetTheLimits() {
        let p = CaptionPreset.standard.with(maxCharsPerLine: 20, lines: 1, minDuration: Time(3, 2))
        #expect(p.maxCharsPerLine == 20 && p.maxLines == 1 && p.minDuration == Time(3, 2))
        #expect(CaptionPreset.standard.with(lines: 5).maxLines == 2)   // single or double only
        #expect(CaptionPreset.standard.with(maxCharsPerLine: 2).maxCharsPerLine == 8)
    }

    @Test func oldPresetJSONHasNoGap() throws {
        let json = #"{"maxCharsPerLine":30,"maxLines":2,"maxDuration":{"value":6,"timescale":1},"minDuration":{"value":1,"timescale":1},"pauseBreak":{"value":4,"timescale":5},"styleRef":"default","animationRef":"none"}"#
        let p = try JSONDecoder().decode(CaptionPreset.self, from: Data(json.utf8))
        #expect(p.gap == .zero)
    }
}
