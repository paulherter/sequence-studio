import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI
@testable import SQTimelineUI

/// Cost of the caption track at 2,000 captions / 20,000 words: a full content render (nothing cached) at three zoom
/// levels, and proof that a playhead tick renders no content at all while the words are on screen.
@MainActor @Suite(.serialized) struct CaptionTrackDrawCostTests {
    private static let size = CGSize(width: 1500, height: 300)
    private static let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    /// 2,000 captions of 3 s, ten timed words each (20,000 words), back to back: 6,000 s.
    static func bigTimeline() -> Timeline {
        var t = Timeline(name: "captions", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [], name: "V1")])
        t.captionTracks = [CaptionTrack(items: (0..<2000).map { n in
            CaptionItem(lines: [words.map { "\($0)\(n % 37)" }.joined(separator: " ")],
                        range: TimeRange(start: Time(Int64(n * 3), 1), end: Time(Int64(n * 3 + 3), 1)),
                        words: words.enumerated().map { i, w in
                            CaptionWord(text: "\(w)\(n % 37)", range: TimeRange(start: Time(Int64(i * 3), 10), end: Time(Int64(i * 3 + 3), 10)))
                        })
        })]
        return t
    }

    private func draw(_ v: TimelineView) {
        let w = Int(Self.size.width), h = Int(Self.size.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let cg = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Median milliseconds of a draw with nothing cached.
    private func fullDraw(_ v: TimelineView, runs: Int = 9) -> Double {
        var ms: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            v.contentCache.invalidateAll()
            let d = clock.measure { draw(v) }
            ms.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        return ms.sorted()[runs / 2]
    }

    @Test func fullRenderStaysCheapAtTwentyThousandWords() {
        let v = TimelineView(timeline: Self.bigTimeline(), frame: NSRect(origin: .zero, size: Self.size))
        var report: [String] = []
        // 0.25 pt/s: every caption is on screen. 40 pt/s: blocks. 200 pt/s: word boxes. The last two from the middle of
        // the track, so anything that walks the track from its start shows up.
        for (zoom, x) in [(0.25, 0.0), (40.0, 120_000.0), (200.0, 600_000.0)] {
            v.setZoom(pointsPerSecond: zoom)
            v.scroll(toX: x)
            draw(v)                                  // warm text caches: the steady state is what a session pays
            let ms = fullDraw(v)
            report.append(String(format: "%.2f pt/s: %.3f ms", zoom, ms))
            #expect(ms < 40, "full caption render at \(zoom) pt/s took \(ms) ms")
        }
        try? report.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "sq-caption-draw-cost.txt", atomically: true, encoding: .utf8)
    }

    @Test func playheadTickRendersNoContentWithWordsOnScreen() {
        let v = TimelineView(timeline: Self.bigTimeline(), frame: NSRect(origin: .zero, size: Self.size))
        v.setZoom(pointsPerSecond: 200)
        v.scroll(toX: 600_000)
        draw(v)
        let area = v.contentCache.renderedArea
        for f in 0..<30 {
            v.setPlayhead(Time(Int64(3000 * 30 + f), 30))
            draw(v)
        }
        #expect(v.contentCache.renderedArea == area)
    }

    /// Text is shaped once per distinct word: scrolling back over words already seen lays nothing out.
    @Test func scrollingOverSeenWordsShapesNoText() {
        let v = TimelineView(timeline: Self.bigTimeline(), frame: NSRect(origin: .zero, size: Self.size))
        v.setZoom(pointsPerSecond: 200)
        for k in 0..<20 { v.scroll(toX: 600_000 + CGFloat(k) * 300); draw(v) }
        let shaped = CaptionWordDrawing.shapedCount
        for k in (0..<20).reversed() { v.scroll(toX: 600_000 + CGFloat(k) * 300); draw(v) }
        #expect(CaptionWordDrawing.shapedCount == shaped)
    }
}
