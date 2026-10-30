import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// Rows that stretch to fill the panel must leave nothing to scroll vertically: the zoom bar at the bottom is not part of
/// the track area. Regression: stretching filled the whole view height, the 16 pt zoom bar then counted as overflow, so a
/// horizontal swipe also moved the tracks up and down.
@MainActor @Suite struct TimelineVerticalDriftTests {
    private static let fd = Time(1, 24)

    private func view(video: Int, audio: Int, captions: Int = 0, height: CGFloat) -> TimelineView {
        let tracks = (0..<(video + audio)).map { i -> Track in
            let kind: TrackKind = i < video ? .video : .audio
            let clips = (0..<20).map { n in
                Clip(name: "C", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Self.fd * 24), start: Self.fd * Int64(n * 30))
            }
            return Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: false)
        }
        var t = Timeline(name: "t", frameDuration: Self.fd, tracks: tracks)
        t.captionTracks = (0..<captions).map { _ in CaptionTrack() }
        return TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1200, height: height))
    }

    @Test func stretchedRowsEndAboveTheZoomBar() {
        for h: CGFloat in [200, 260, 333, 400] {
            let v = view(video: 2, audio: 2, height: h)
            let bottom = v.layoutRows().last!.maxY
            #expect(abs(bottom - (h - ZoomScrollBar.height)) < 0.5, "height \(h): rows end at \(bottom)")
        }
        let tall = view(video: 2, audio: 2, height: 900)               // rows capped: they end higher up
        #expect(tall.layoutRows().last!.maxY < 900 - ZoomScrollBar.height)
    }

    @Test func horizontalScrollNeverChangesScrollYWhenRowsAreStretched() {
        for (video, audio, captions, h) in [(2, 2, 0, CGFloat(300)), (3, 3, 1, 420), (1, 1, 0, 180), (4, 4, 2, 611)] {
            let v = view(video: video, audio: audio, captions: captions, height: h)
            for i in 0..<20 {
                v.scroll(byX: 40, y: i % 2 == 0 ? 7 : 3)        // diagonal-ish swipe
                #expect(v.geometry.scrollY == 0, "\(video)V \(audio)A \(captions)C in \(h) pt")
            }
            // A user height on one track also stretches the others (overrides set).
            v.setTrackHeights([v.timeline.tracks[0].id: 60])
            v.scroll(byX: 40, y: 9)
            #expect(v.geometry.scrollY == 0, "with a height override, \(h) pt")
        }
    }

    @Test func realOverflowStillScrollsVertically() {
        let v = view(video: 8, audio: 8, height: 300)
        v.scroll(byX: 0, y: 30)
        #expect(v.geometry.scrollY == 30)
    }
}
