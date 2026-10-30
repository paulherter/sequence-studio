import Foundation
import Testing
@testable import SQCore

/// The confidence strip of a tracked Magic mask: weak frames found from the stored matte areas alone.
@Suite struct MagicTrackHealthTests {
    private func samples(_ areas: [Double], fps: Double = 24) -> [MagicTrackHealth.Sample] {
        areas.enumerated().map { .init(pts: Double($0.offset) / fps, area: $0.element) }
    }

    @Test func steadyTrackHasNoWeakSpans() {
        #expect(MagicTrackHealth.weakSpans(samples(Array(repeating: 0.2, count: 48))).isEmpty)
        #expect(MagicTrackHealth.weakSpans(samples((0..<48).map { 0.2 + Double($0) * 0.001 })).isEmpty)
    }

    @Test func tooFewFramesSayNothing() {
        #expect(MagicTrackHealth.weakSpans(samples([0.2])).isEmpty)
        #expect(MagicTrackHealth.weakSpans([]).isEmpty)
    }

    @Test func aShrunkenMatteIsWeakAndMerged() {
        var a = Array(repeating: 0.2, count: 48)
        for i in 20...23 { a[i] = 0.02 }
        let spans = MagicTrackHealth.weakSpans(samples(a))
        #expect(spans.count == 1)
        #expect(abs(spans[0].start - 20.0 / 24) < 1e-9)
        #expect(abs(spans[0].end - 25.0 / 24) < 1e-9)       // the jump back to normal at 24 is flagged too
    }

    @Test func aSuddenJumpIsWeakEvenWhenLarge() {
        var a = Array(repeating: 0.1, count: 30)
        for i in 22..<30 { a[i] = 0.3 }                      // the matte tripled at frame 22: it grabbed something else
        let spans = MagicTrackHealth.weakSpans(samples(a))
        #expect(spans.count == 1)
        #expect(abs(spans[0].start - 22.0 / 24) < 1e-9)
    }

    @Test func aGapInTheStoredFramesIsWeak() {
        var s = samples(Array(repeating: 0.2, count: 40))
        s.removeSubrange(18..<22)
        let spans = MagicTrackHealth.weakSpans(s)
        #expect(spans.count == 1)
        #expect(spans[0].start <= 17.0 / 24 + 1e-9 && spans[0].end >= 22.0 / 24 - 1e-9)
    }

    /// Frames stored empty (subject not found) are weak, also when most of the track is empty (median 0).
    @Test func emptyFramesAreWeakEvenWhenMostAreEmpty() {
        var a = Array(repeating: 0.0, count: 24)
        for i in 0..<8 { a[i] = 0.2 }
        let spans = MagicTrackHealth.weakSpans(samples(a))
        #expect(spans.count == 1)
        #expect(abs(spans[0].start - 8.0 / 24) < 1e-9 && abs(spans[0].end - 1) < 1e-9)
    }

    @Test func weakFractionOfASpan() {
        let spans = [MagicTrackHealth.Span(start: 1, end: 2), .init(start: 3, end: 3.5)]
        #expect(MagicTrackHealth.weakSeconds(spans) == 1.5)
        #expect(MagicTrackHealth.next(after: 2, in: spans) == 3)
        #expect(MagicTrackHealth.next(after: 3.5, in: spans) == nil)
    }
}

/// Where weak stretches begin on the timeline (Go to Next Weak Tracking).
@Suite struct MagicTrackHealthTimelineTests {
    private let fd = Time(1, 30)
    // Clip: source 5...15 s at timeline 100...110 s.
    private func clip(reversed: Bool = false) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(seconds: 5), duration: Time(seconds: 10)),
             start: Time(seconds: 100), reversed: reversed)
    }

    @Test func weakStartsAreTimelineStretchStartsInsideTheClip() {
        let s = MagicTrackHealth.weakStarts(clip: clip(), spans: [.init(start: 2, end: 6), .init(start: 8, end: 9), .init(start: 20, end: 21)], frameDuration: fd)
        #expect(s == [Time(seconds: 100), Time(seconds: 103)])
    }

    @Test func nextWeakAcrossClipsIsTheEarliestAfterThePlayhead() {
        let a = clip(), b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds: 10)),
                                 start: Time(seconds: 50))
        let spans: [Clip.ID: [MagicTrackHealth.Span]] = [a.id: [.init(start: 8, end: 9)], b.id: [.init(start: 1, end: 2), .init(start: 6, end: 7)]]
        let next = { (t: Time) in MagicTrackHealth.nextWeakStart(after: t, clips: [a, b], spans: { spans[$0.id] }, frameDuration: self.fd) }
        #expect(next(Time(seconds: 0)) == Time(seconds: 51))
        #expect(next(Time(seconds: 51)) == Time(seconds: 56))
        #expect(next(Time(seconds: 60)) == Time(seconds: 103))
        #expect(next(Time(seconds: 103)) == nil)
    }

    @Test func reversedClipWeakStartIsTheEarlierTimelineEdge() {
        let s = MagicTrackHealth.weakStarts(clip: clip(reversed: true), spans: [.init(start: 8, end: 9)], frameDuration: fd)
        #expect(s.count == 1)
        #expect(abs(Double(s[0].value) / Double(s[0].timescale) - 106) < 0.1)
    }
}
