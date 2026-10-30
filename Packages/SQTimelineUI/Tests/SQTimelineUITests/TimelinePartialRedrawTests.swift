import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// Scrubbing only dirties a thin strip around the playhead; the strip must repaint exactly what a full redraw would.
/// Regression: the fx badge was placed against the dirty strip instead of the whole content area, so every scrub step
/// stamped a sliver of the badge over the clip name until the next full redraw (zoom).
@MainActor @Suite struct TimelinePartialRedrawTests {
    private static let fd = Time(1, 24)
    private static let size = CGSize(width: 1200, height: 400)

    private func view() -> TimelineView {
        var tracks: [Track] = []
        for i in 0..<4 {
            let kind: TrackKind = i < 2 ? .video : .audio
            let clips = (0..<12).map { n -> Clip in
                var c = Clip(name: "Footage \(i)-\(n)", media: UUID(), kind: kind,
                             source: TimeRange(start: .zero, duration: Self.fd * 48), start: Self.fd * Int64(n * 50))
                if kind == .video { c.blendMode = .multiply }          // any applied effect shows the fx badge
                return c
            }
            tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: i == 0))
        }
        let tl = Timeline(name: "t", frameDuration: Self.fd, tracks: tracks)
        return TimelineView(timeline: tl, frame: NSRect(origin: .zero, size: Self.size))
    }

    private func render(_ v: TimelineView, into rep: NSBitmapImageRep, dirty: CGRect) {
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: Self.size.height); cg.scaleBy(x: 1, y: -1)
        cg.clip(to: dirty)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        v.draw(dirty)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func newRep() -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width), pixelsHigh: Int(Self.size.height),
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    private func differingBytes(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard let pa = a.bitmapData, let pb = b.bitmapData else { return -1 }
        var n = 0
        for y in 0..<Int(Self.size.height) {
            for x in 0..<(Int(Self.size.width) * 4) where pa[y * a.bytesPerRow + x] != pb[y * b.bytesPerRow + x] { n += 1 }
        }
        return n
    }

    @Test func playheadStripRepaintsLikeAFullRedraw() {
        let v = view()
        let full = CGRect(origin: .zero, size: Self.size)
        let incremental = newRep()
        v.setPlayhead(Self.fd * 10)
        render(v, into: incremental, dirty: full)
        for f in [13, 17, 25, 21, 40, 33, 48, 12] {                // back and forth, like scrubbing
            let old = v.geometry.x(for: v.playhead)
            v.setPlayhead(Self.fd * Int64(f))
            let new = v.geometry.x(for: v.playhead)
            for x in [old, new] {                                  // AppKit rounds dirty rects out to whole pixels
                render(v, into: incremental, dirty: CGRect(x: x - 1, y: TimelineGeometry.rulerHeight, width: 2, height: Self.size.height).integral)
            }
            let reference = newRep()
            render(v, into: reference, dirty: full)
            #expect(differingBytes(incremental, reference) == 0, "playhead at frame \(f)")
        }
    }
}
