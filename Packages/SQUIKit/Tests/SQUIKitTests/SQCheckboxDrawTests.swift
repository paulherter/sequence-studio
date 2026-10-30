import AppKit
import Testing
@testable import SQUIKit

/// The check mark must point down-left in every host (plain, flipped parent, layer-backed).
@MainActor
struct SQCheckboxDrawTests {
    final class FlippedHost: NSView { override var isFlipped: Bool { true } }

    /// Renders and returns the lowest white pixel (row 0 is the top) plus the bitmap size.
    private func vertex(in host: NSView) -> (row: Int, col: Int, w: Int, h: Int)? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        var best: (Int, Int)?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85 && c.alphaComponent > 0.5 {
                    best = (y, x)
                }
            }
        }
        guard let b = best else { return nil }
        return (b.0, b.1, rep.pixelsWide, rep.pixelsHigh)
    }

    private func check(host: NSView, layerBacked: Bool = false) {
        host.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
        host.wantsLayer = layerBacked
        let cb = SQCheckbox(title: "", target: nil, action: nil)
        cb.state = .on
        cb.frame = host.bounds
        host.addSubview(cb)
        guard let v = vertex(in: host) else { Issue.record("no white pixels"); return }
        #expect(v.row > v.h / 2, "vertex must be in the lower half, got row \(v.row) of \(v.h)")
        #expect(v.col < v.w / 2 + 2, "vertex lies left of center (short arm left), got col \(v.col) of \(v.w)")
    }

    @Test func plainHost() { check(host: NSView()) }
    @Test func flippedHost() { check(host: FlippedHost()) }
    @Test func layerBackedHost() { check(host: NSView(), layerBacked: true) }
    @Test func layerBackedFlippedHost() { check(host: FlippedHost(), layerBacked: true) }
}
