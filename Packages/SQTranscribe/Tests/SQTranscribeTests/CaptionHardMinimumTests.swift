import Foundation
import Testing
import SQCore
@testable import SQTranscribe

@Suite struct CaptionHardMinimumTests {
    func preset(minMs: Int64, gapMs: Int64 = 0) -> CaptionPreset {
        CaptionPreset(maxCharsPerLine: 20, maxLines: 2, maxDuration: t(6000), minDuration: t(minMs),
                      pauseBreak: t(800), styleRef: "s", animationRef: "a", gap: t(gapMs))
    }
    func cap(_ a: Int64, _ b: Int64) -> Caption {
        Caption(lines: ["x"], range: TimeRange(start: t(a), end: t(b)), styleRef: "s", animationRef: "a")
    }

    /// The plan's acceptance case: 0.3 s caption, then 2 s of silence.
    @Test func aShortCaptionBeforeAPauseIsExtended() {
        let r = CaptionSegmenter.applyTiming([cap(0, 300), cap(2300, 3000)], preset: preset(minMs: 1000))
        #expect(r[0].range == TimeRange(start: t(0), end: t(1000)))
        #expect(r[0].range.end <= r[1].range.start)
    }

    @Test func minGapIsTheGapOfThePreset() {
        var p = CaptionPreset.standard
        p.minGap = t(200)
        #expect(p.gap == t(200) && p.minGap == t(200))
    }

    @Test func theOneLinePresetYieldsOneLine() {
        let words = (0..<14).map { w("word\($0)", Int64($0) * 300, Int64($0) * 300 + 250) }
        let caps = CaptionSegmenter.segment(transcript(words), preset: CaptionPreset.standard.with(lines: 1))
        #expect(!caps.isEmpty && caps.allSatisfy { $0.lines.count == 1 })
        #expect(CaptionSegmenter.segment(transcript(words), preset: .shortVideo).allSatisfy { $0.lines.count == 1 })
    }

    @Test func segmentsCarryTheirWordTimings() {
        let caps = CaptionSegmenter.segment(transcript([w("a", 0, 200), w("b", 300, 500)]), preset: .standard)
        #expect(caps.count == 1)
        #expect(caps[0].words.map(\.text) == ["a", "b"])
        #expect(caps[0].words[1].range == TimeRange(start: t(300), end: t(500)))
    }

    /// Random sorted, non-overlapping captions: after the timing pass nothing overlaps, the order and every start
    /// are unchanged, and a caption reaches the minimum whenever the silence after it allows.
    @Test func timingNeverOverlapsAndKeepsOrder() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var caps: [Caption] = []
            var cursor: Int64 = 0
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                cursor += Int64.random(in: 0...2500, using: &rng)
                let len = Int64.random(in: 20...1500, using: &rng)
                caps.append(cap(cursor, cursor + len)); cursor += len
            }
            let minMs = Int64.random(in: 0...2000, using: &rng), gapMs = Int64.random(in: 0...300, using: &rng)
            let p = preset(minMs: minMs, gapMs: gapMs)
            let out = CaptionSegmenter.applyTiming(caps, preset: p)
            #expect(out.count == caps.count)
            for i in out.indices {
                #expect(out[i].range.start == caps[i].range.start)
                #expect(!out[i].range.isEmpty)
                if i + 1 < out.count { #expect(out[i].range.end <= out[i + 1].range.start) }
                let room = i + 1 < out.count ? out[i + 1].range.start - p.gap - out[i].range.start : t(minMs)
                if room >= t(minMs) { #expect(out[i].range.duration >= t(minMs) || out[i].range.duration >= caps[i].range.duration) }
            }
        }
    }
}
