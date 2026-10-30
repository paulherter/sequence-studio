import AppKit
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQTimelineUI

/// Micro benchmark of the scroll/zoom path (same calls as scrollWheel/setZoom) plus one draw into a retina bitmap
/// (1600x400 pt view at 2x = 3200x800 px). 16 tracks (8 V, 8 A) x 60 clips; audio clips show waveforms of 6 two-minute
/// stereo files. Prints `PERF ...` lines (scripts/test.sh shows them): handler and draw ms per step, averaged.
/// Opt-in: `SQ_PERF=1 SQ_TEST_FILTER=TimelineScrollPerfTests scripts/test.sh SQTimelineUI`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1")) struct TimelineScrollPerfTests {
    private static let fd = Time(1, 24)
    static let size = CGSize(width: 1600, height: 400)
    static let scale: CGFloat = 2

    static func timeline(media: [UUID]) -> Timeline {
        var tracks: [Track] = []
        for i in 0..<16 {
            let kind: TrackKind = i < 8 ? .video : .audio
            let clips = (0..<60).map { n in
                Clip(name: "Clip \(i)-\(n)", media: kind == .audio ? media[(i + n) % media.count] : UUID(), kind: kind,
                     source: TimeRange(start: fd * Int64((n * 37) % 2000), duration: fd * 24), start: fd * Int64(n * 30))
            }
            tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: i == 0))
        }
        return Timeline(name: "perf", frameDuration: fd, tracks: tracks)
    }

    /// Two minutes of 48 kHz stereo noise-like peaks with a mip pyramid (base bucket 256, like `WaveformBuilder`).
    static func waveform(seed: Int, seconds: Int = 120) -> WaveformData {
        let rate = 48_000, frames = rate * seconds, base = 256
        var level: [Float] = []
        let n = frames / base
        level.reserveCapacity(n * 4)
        var x = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        for i in 0..<n {
            for _ in 0..<2 {
                x = x &* 1_664_525 &+ 1_013_904_223
                let env = Float(0.3 + 0.6 * abs(sin(Double(i) / 900)))
                let a = env * Float(x >> 8) / Float(1 << 24)
                level += [-a, a]
            }
        }
        var levels = [level]
        while levels.last!.count / 4 > 16 {
            let prev = levels.last!
            var next: [Float] = []
            let buckets = prev.count / 4
            next.reserveCapacity(buckets / 2 * 4)
            for b in stride(from: 0, to: buckets - 1, by: 2) {
                for ch in 0..<2 {
                    let o0 = (b * 2 + ch) * 2, o1 = ((b + 1) * 2 + ch) * 2
                    next += [min(prev[o0], prev[o1]), max(prev[o0 + 1], prev[o1 + 1])]
                }
            }
            levels.append(next)
        }
        return WaveformData(sampleRate: rate, channelCount: 2, totalFrames: frames, baseBucketSize: base, levels: levels)
    }

    static func makeView() -> TimelineView {
        let media = (0..<6).map { _ in UUID() }
        let v = TimelineView(timeline: timeline(media: media), frame: NSRect(origin: .zero, size: size))
        let wf = TimelineWaveforms(builder: { _ in throw CancellationError() })
        for (i, id) in media.enumerated() { wf.setData(waveform(seed: i), for: id) }
        v.waveforms = wf
        v.setZoom(pointsPerSecond: 60)
        return v
    }

    static func newRep() -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    static func render(_ v: TimelineView, into rep: NSBitmapImageRep, dirty: CGRect? = nil) {
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: size.height * scale); cg.scaleBy(x: scale, y: -scale)
        let r = dirty ?? v.bounds
        cg.clip(to: r)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        v.draw(r)
        NSGraphicsContext.restoreGraphicsState()
    }

    struct Stats { var handler: Double = 0; var draw: Double = 0; var n = 0 }

    /// Runs `steps` of (`handler`, full draw) and prints averages.
    static func bench(_ label: String, _ v: TimelineView, rep: NSBitmapImageRep, steps: Int = 120,
                      handler: (Int) -> Void) -> Stats {
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        for i in 0..<10 { handler(i); render(v, into: rep) }            // warm-up
        var s = Stats()
        for i in 0..<steps {
            let t0 = now(); handler(i)
            let t1 = now(); render(v, into: rep)
            let t2 = now()
            s.handler += Double(t1 - t0) / 1e6; s.draw += Double(t2 - t1) / 1e6; s.n += 1
        }
        s.handler /= Double(s.n); s.draw /= Double(s.n)
        print(String(format: "PERF %@: handler %.3f ms, draw %.3f ms, total %.3f ms/step", label, s.handler, s.draw, s.handler + s.draw))
        return s
    }

    @Test func scrollAndZoomStepsStayCheap() async {
        let v = Self.makeView()
        await v.waveforms?.cache.waitForIdle()
        let rep = Self.newRep()
        let h = Self.bench("hscroll (waveforms, 2x)", v, rep: rep) { i in v.scroll(byX: i % 40 < 20 ? 37 : -37, y: 0) }
        let vs = Self.bench("vscroll (16 tracks, 2x)", v, rep: rep) { i in v.scroll(byX: 0, y: i % 20 < 10 ? 6 : -6) }
        await v.waveforms?.cache.waitForIdle()
        let z = Self.bench("zoom 1% (warm buckets, 2x)", v, rep: rep) { i in
            v.setZoom(pointsPerSecond: v.geometry.pointsPerSecond * (i % 8 < 4 ? 1.01 : 0.99), anchorX: 600)
        }
        let wf = v.waveforms
        v.waveforms = nil
        _ = Self.bench("hscroll (no waveforms, 2x)", v, rep: rep) { i in v.scroll(byX: i % 40 < 20 ? 37 : -37, y: 0) }
        v.waveforms = wf
        // Generous ceilings (CI and a parallel test run share the CPU); the PERF lines are the measurement.
        #expect(h.handler + h.draw < 200 && vs.handler + vs.draw < 200 && z.handler + z.draw < 500)
    }

    /// A pinch sweep over many zoom buckets with a cold cache: the waveform path must not stall the draw.
    @Test func coldZoomSweep() {
        let v = Self.makeView()
        v.waveforms?.cache.removeAll()
        let rep = Self.newRep()
        let s = Self.bench("zoom sweep x1.15 (cold buckets, 2x)", v, rep: rep, steps: 40) { i in
            v.setZoom(pointsPerSecond: v.geometry.pointsPerSecond * (i % 40 < 20 ? 1.15 : 1 / 1.15), anchorX: 600)
        }
        #expect(s.handler + s.draw < 200)
    }
}

@MainActor @Suite struct TimelineRowsCacheTests {
    private static let fd = Time(1, 24)

    private func view() -> TimelineView {
        var tracks: [Track] = []
        for i in 0..<6 {
            let kind: TrackKind = i < 3 ? .video : .audio
            let clips = (0..<10).map { n in
                Clip(name: "C", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Self.fd * 24), start: Self.fd * Int64(n * 30))
            }
            tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: false))
        }
        return TimelineView(timeline: Timeline(name: "t", frameDuration: Self.fd, tracks: tracks), frame: NSRect(x: 0, y: 0, width: 800, height: 120))
    }

    @Test func cacheMatchesGeometryAcrossScrollAndLayoutChanges() {
        let v = view()
        #expect(v.layoutRows() == v.geometry.rows(for: v.timeline))
        v.scroll(toY: 40)
        #expect(v.geometry.scrollY > 0)
        #expect(v.layoutRows() == v.geometry.rows(for: v.timeline))
        v.setTrackHeights([v.timeline.tracks[0].id: 80])
        #expect(v.layoutRows() == v.geometry.rows(for: v.timeline))
        var t = v.timeline
        t.tracks.removeLast()
        v.setTimeline(t)
        #expect(v.layoutRows() == v.geometry.rows(for: v.timeline))
        v.setFrameSize(NSSize(width: 800, height: 500))
        #expect(v.layoutRows() == v.geometry.rows(for: v.timeline))
    }

    @Test func firstClipIndexSkipsLeftOfDirtyRect() {
        let v = view()
        let clips = v.timeline.tracks[0].clips
        #expect(TimelineView.firstClipIndex(endingAfter: .zero, in: clips) == 0)
        let t = Self.fd * 30 * 5 + Self.fd * 2       // inside clip 5
        #expect(TimelineView.firstClipIndex(endingAfter: t, in: clips) == 4)   // clip 5 minus one slack
        #expect(TimelineView.firstClipIndex(endingAfter: Self.fd * 10_000, in: clips) == clips.count - 1)
    }
}
