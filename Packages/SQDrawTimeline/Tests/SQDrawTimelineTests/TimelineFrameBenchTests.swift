import AppKit
import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

/// Frame cost of the shared timeline panel vs the AppKit TimelineView on the same sequence: a playhead scrub and a zoom
/// sweep (CPU time to build the frame; the GPU/blit side is not in it). Numbers go to `SQ_PERF_OUT` (default
/// `$TMPDIR/sqtimelineframe.txt`) when `SQ_TIMELINE_BENCH=1`; otherwise only a loose upper bound runs.
@MainActor @Suite(.serialized) struct TimelineFrameBenchTests {
    private static let fd = Time(1, 30)
    private static let w = 1400, h = 320

    /// 4 video + 4 audio tracks of 150 clips of 2 s.
    static func sequence() -> Timeline {
        func track(_ kind: TrackKind, _ n: Int) -> Track {
            Track(kind: kind, clips: (0..<150).map { i in
                Clip(name: "c\(n)-\(i)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * 60), start: fd * Int64(i * 60))
            })
        }
        return Timeline(name: "bench", frameDuration: fd, tracks: (0..<4).map { track(.video, $0) } + (0..<4).map { track(.audio, $0) })
    }

    private func ms(_ body: () -> Void) -> Double {
        let d = ContinuousClock().measure(body)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func stats(_ xs: [Double]) -> String {
        let s = xs.sorted()
        return String(format: "mean %.2f ms, p95 %.2f ms, max %.2f ms", xs.reduce(0, +) / Double(xs.count), s[Int(Double(s.count) * 0.95)], s.last!)
    }

    @Test func scrubAndZoomFrameCost() {
        let t = Self.sequence()
        var panel = TimelinePanel()
        panel.layout(DrawRect(x: 0, y: 0, w: Float(Self.w), h: Float(Self.h)), scale: 1)
        panel.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let view = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: Self.w, height: Self.h))
        var bytes = [UInt8](repeating: 0, count: Self.w * Self.h * 4)
        func appKitDraw() {
            bytes.withUnsafeMutableBytes { buf in
                let cg = CGContext(data: buf.baseAddress, width: Self.w, height: Self.h, bitsPerComponent: 8, bytesPerRow: Self.w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.translateBy(x: 0, y: CGFloat(Self.h)); cg.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        func sharedFrame(_ playhead: Time) {
            panel.sync(timeline: t, selection: [], playhead: playhead, selectedTransition: nil, labels: LabelResolver())
            _ = panel.tick()
            var list = DrawList(width: Float(Self.w), height: Float(Self.h))
            panel.draw(into: &list, atlas: nil)
        }
        var out: [String] = []
        for zoom in [8.0, 60.0] {
            panel.setZoom(pointsPerSecond: zoom); view.setZoom(pointsPerSecond: zoom, motion: false)
            let heads = (0..<90).map { Self.fd * Int64($0 * 7) }
            var shared: [Double] = [], appKit: [Double] = []
            for p in heads {
                shared.append(ms { sharedFrame(p) })
                view.setPlayhead(p)
                appKit.append(ms { appKitDraw() })
            }
            out.append("scrub @\(zoom) pt/s  shared: \(stats(shared))  |  AppKit: \(stats(appKit))")
            #expect(shared.sorted()[shared.count / 2] < 200)
        }
        var zs: [Double] = [], za: [Double] = []
        for i in 0..<60 {
            let z = 4 * pow(1.06, Double(i))
            zs.append(ms { panel.setZoom(pointsPerSecond: z); sharedFrame(.zero) })
            za.append(ms { view.setZoom(pointsPerSecond: z, motion: false); appKitDraw() })
        }
        out.append("zoom sweep  shared: \(stats(zs))  |  AppKit: \(stats(za))")
        if ProcessInfo.processInfo.environment["SQ_TIMELINE_BENCH"] == "1" {
            let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? NSTemporaryDirectory() + "sqtimelineframe.txt"
            try? out.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
