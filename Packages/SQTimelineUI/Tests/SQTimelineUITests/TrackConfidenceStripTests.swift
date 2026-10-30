#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

@Suite struct TrackConfidenceStripTests {
    @Test func weakSpansBecomeMergedColumnRanges() {
        // Source time = 10 s over the clip's width; weak from 2 s to 4 s.
        let r = TrackConfidenceStrip.weakRanges(width: 100, step: 2, source: { $0 * 10 }, spans: [.init(start: 2, end: 4)])
        #expect(r.count == 1)
        #expect(abs(r[0].lowerBound - 20) <= 2 && abs(r[0].upperBound - 40) <= 2)
    }

    @Test func reversedClipFlipsTheStrip() {
        let r = TrackConfidenceStrip.weakRanges(width: 100, step: 2, source: { 10 - $0 * 10 }, spans: [.init(start: 2, end: 4)])
        #expect(r.count == 1)
        #expect(abs(r[0].lowerBound - 60) <= 2 && abs(r[0].upperBound - 80) <= 2)
    }

    @Test func noSpansNoRanges() {
        #expect(TrackConfidenceStrip.weakRanges(width: 100, step: 2, source: { $0 }, spans: []).isEmpty)
        #expect(TrackConfidenceStrip.weakRanges(width: 0, step: 2, source: { $0 }, spans: [.init(start: 0, end: 1)]).isEmpty)
    }

    private func clip(reversed: Bool = false) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(seconds: 5), duration: Time(seconds: 10)),
             start: Time(seconds: 100), reversed: reversed)
    }
    private let fd = Time(1, 30)

    @Test func clickInAWeakStretchJumpsToItsStart() {
        // Clip shows source 5...15 at timeline 100...110; weak source 8...9 = timeline 103...104.
        let t = TrackConfidenceStrip.jumpTarget(clip: clip(), spans: [.init(start: 8, end: 9)], at: Time(seconds: 103) + Time(1, 2), frameDuration: fd)
        #expect(t == Time(seconds: 103))
    }

    @Test func clickOutsideAWeakStretchDoesNothing() {
        #expect(TrackConfidenceStrip.jumpTarget(clip: clip(), spans: [.init(start: 8, end: 9)], at: Time(seconds: 106), frameDuration: fd) == nil)
    }

    @Test func spanStartingBeforeTheClipJumpsToTheClipStart() {
        let t = TrackConfidenceStrip.jumpTarget(clip: clip(), spans: [.init(start: 2, end: 7)], at: Time(seconds: 101), frameDuration: fd)
        #expect(t == Time(seconds: 100))
    }

    @Test func reversedClipJumpsToTheEarlierTimelineEdge() {
        // Reversed: source 9 shows near timeline 106, source 8 near 107; the stretch's timeline start is its source end.
        let t = TrackConfidenceStrip.jumpTarget(clip: clip(reversed: true), spans: [.init(start: 8, end: 9)], at: Time(seconds: 106) + Time(1, 2), frameDuration: fd)
        #expect(t != nil)
        #expect(abs(Double(t!.value) / Double(t!.timescale) - 106) < 0.1)
    }

    @Test func hitBandIsTheStripPlusSlack() {
        let clipRect = CGRect(x: 0, y: 10, width: 100, height: 40)
        #expect(TrackConfidenceStrip.hitBand(clipRect: clipRect).contains(CGPoint(x: 50, y: 49)))
        #expect(!TrackConfidenceStrip.hitBand(clipRect: clipRect).contains(CGPoint(x: 50, y: 30)))
    }

    @Test func markersSitAtTheStartOfEachWeakStretch() {
        let m = TrackConfidenceStrip.markerColumns(width: 100, step: 2, source: { $0 * 10 }, spans: [.init(start: 2, end: 4), .init(start: 7, end: 8)])
        #expect(m.count == 2)
        #expect(abs(m[0] - 20) <= 2 && abs(m[1] - 70) <= 2)
    }

    // Clip: source 5...15 s at timeline 100...110 s.
    @Test func nextWeakStartsAreTimelineStretchStartsInsideTheClip() {
        let s = TrackConfidenceStrip.weakStarts(clip: clip(), spans: [.init(start: 2, end: 6), .init(start: 8, end: 9), .init(start: 20, end: 21)], frameDuration: fd)
        // 2...6 overlaps the clip's start (clamped to 100), 8 -> 103, 20 lies outside the clip.
        #expect(s == [Time(seconds: 100), Time(seconds: 103)])
    }

    @Test func nextWeakAcrossClipsIsTheEarliestAfterThePlayhead() {
        let a = clip(), b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds: 10)),
                                 start: Time(seconds: 50))
        let spans: [Clip.ID: [MagicTrackHealth.Span]] = [a.id: [.init(start: 8, end: 9)], b.id: [.init(start: 1, end: 2), .init(start: 6, end: 7)]]
        let next = { (t: Time) in TrackConfidenceStrip.nextWeakStart(after: t, clips: [a, b], spans: { spans[$0.id] }, frameDuration: self.fd) }
        #expect(next(Time(seconds: 0)) == Time(seconds: 51))
        #expect(next(Time(seconds: 51)) == Time(seconds: 56))
        #expect(next(Time(seconds: 60)) == Time(seconds: 103))
        #expect(next(Time(seconds: 103)) == nil)
    }

    @Test func reversedClipWeakStartIsTheEarlierTimelineEdge() {
        let s = TrackConfidenceStrip.weakStarts(clip: clip(reversed: true), spans: [.init(start: 8, end: 9)], frameDuration: fd)
        #expect(s.count == 1)
        #expect(abs(Double(s[0].value) / Double(s[0].timescale) - 106) < 0.1)
    }
}
