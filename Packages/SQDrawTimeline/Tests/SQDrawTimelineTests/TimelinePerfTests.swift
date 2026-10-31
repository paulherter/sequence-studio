#if os(macOS)
import AppKit
import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

/// Big sequence: 20 tracks of 500 clips (10 000 clips). Frame cost of the shared panel (sync + tick + draw) and of the Mac
/// `TimelineView`, per scenario. Numbers go to `SQ_PERF_OUT` when `SQ_TIMELINE_BENCH=1`.
@MainActor @Suite(.serialized) struct TimelinePerfTests {
    static let fd = Time(1, 30)
    static let w = 1600, h = 900

    static func big() -> Timeline {
        func track(_ kind: TrackKind, _ n: Int) -> Track {
            Track(kind: kind, clips: (0..<500).map { i in
                Clip(name: "c\(n)-\(i)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * 60), start: fd * Int64(i * 60))
            })
        }
        return Timeline(name: "big", frameDuration: fd, tracks: (0..<10).map { track(.video, $0) } + (0..<10).map { track(.audio, $0) })
    }

    private func ms(_ body: () -> Void) -> Double {
        let d = ContinuousClock().measure(body)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    private func mean(_ xs: [Double]) -> String {
        let s = xs.sorted()
        return String(format: "mean %.2f ms, p95 %.2f ms", xs.reduce(0, +) / Double(xs.count), s[Int(Double(s.count) * 0.95)])
    }

    @Test func tenThousandClips() throws {
        let atlas = try #require(GlyphAtlas())
        let t = Self.big()
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
        var list = DrawList(width: Float(Self.w), height: Float(Self.h))
        func sharedFrame(_ playhead: Time) {
            panel.sync(timeline: t, selection: [], playhead: playhead, selectedTransition: nil, labels: LabelResolver())
            _ = panel.tick()
            list = DrawList(width: Float(Self.w), height: Float(Self.h))
            panel.draw(into: &list, atlas: atlas)
        }
        var out: [String] = []
        out.append("syncOffsets: \(mean((0..<20).map { _ in ms { _ = t.syncOffsets() } }))")
        out.append("clip scan: \(mean((0..<20).map { _ in ms { var n = 0; for tr in t.tracks { for c in tr.clips where c.start.value > 5 { n += 1 } }; _ = n } }))")
        for zoom in [1.5, 60.0] {
            panel.setZoom(pointsPerSecond: zoom); view.setZoom(pointsPerSecond: zoom, motion: false)
            panel.laneCache.invalidate()
            let cold = ms { sharedFrame(.zero) }          // first frame at this zoom: a cache miss
            out.append("  cold frame @\(zoom): \(String(format: "%.2f", cold)) ms")
            let heads = (0..<60).map { Self.fd * Int64($0 * 37) }
            var shared: [Double] = [], appKit: [Double] = [], syncOnly: [Double] = []
            for p in heads {
                shared.append(ms { sharedFrame(p) })
                syncOnly.append(ms { panel.sync(timeline: t, selection: [], playhead: p, selectedTransition: nil, labels: LabelResolver()) })
                view.setPlayhead(p)
                appKit.append(ms { appKitDraw() })
            }
            let rows = panel.rows
            let content = CGRect(x: 156, y: 24, width: panel.size.width - 156, height: panel.size.height - 24)
            func part(_ name: String, _ body: (inout Canvas) -> Void) {
                var xs: [Double] = []
                for _ in 0..<30 {
                    var cv = Canvas(width: Float(Self.w), height: Float(Self.h), atlas: atlas, scale: 1)
                    cv.clip(to: content)
                    let t0 = ContinuousClock.now
                    body(&cv)
                    let d = ContinuousClock.now - t0
                    xs.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                }
                out.append("  part \(name) @\(zoom): \(mean(xs))")
            }
            part("lanes") { panel.drawLanes(&$0, rows: rows, clip: content) }
            part("itemLanes") { panel.drawItemLanes(&$0, rows: rows, clip: content) }
            part("captions") { panel.drawCaptionLanes(&$0, clip: content) }
            part("transitions") { panel.drawTransitions(&$0, rows: rows, clip: content) }
            part("headers") { panel.drawHeaders(&$0, rows: rows) }
            part("ruler") { panel.drawRuler(&$0) }
            out.append("10k clips scrub @\(zoom) pt/s  shared: \(mean(shared)) (sync alone \(mean(syncOnly)))  |  AppKit: \(mean(appKit))")
        }
        out.append("lane cache: \(panel.laneCache.hits) hits, \(panel.laneCache.misses) misses")
        // SQ_TIMELINE_SPIN=<seconds>: keep redrawing cold frames at 1.5 pt/s so `sample <pid>` can profile the miss path.
        if let spin = ProcessInfo.processInfo.environment["SQ_TIMELINE_SPIN"].flatMap(Double.init) {
            panel.setZoom(pointsPerSecond: Double(ProcessInfo.processInfo.environment["SQ_TIMELINE_SPIN_ZOOM"] ?? "") ?? 1.5)
            let end = ContinuousClock.now + .seconds(spin)
            while ContinuousClock.now < end { panel.laneCache.invalidate(); sharedFrame(.zero) }
        }
        if ProcessInfo.processInfo.environment["SQ_TIMELINE_BENCH"] == "1" {
            let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? NSTemporaryDirectory() + "sqtimelineperf.txt"
            try? out.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
#endif
