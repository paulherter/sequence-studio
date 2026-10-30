import AppKit
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQTimelineUI

/// Cold (first N) versus warm (repeat) scroll/zoom steps with real-sized waveform data (1 h stereo, 8 audio tracks x 60 clips).
/// Opt-in: `SQ_PERF=1 SQ_TEST_FILTER=TimelineColdStartTests scripts/test.sh SQTimelineUI`.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1")) struct TimelineColdStartTests {
    private static let fd = Time(1, 24)

    /// 1 h stereo 48 kHz, base bucket 256, mip levels down to ~1 bucket per 2 s.
    static func hourOfPeaks() -> WaveformData {
        let frames = 48_000 * 3600, base = 256
        var levels: [[Float]] = []
        var n = frames / base
        for lvl in 0..<10 {
            var l = [Float](); l.reserveCapacity(n * 4)
            for i in 0..<n { let a = Float((i * 7 + lvl) % 100) / 120; l += [-a, a, -a, a] }
            levels.append(l); n /= 2
        }
        return WaveformData(sampleRate: 48_000, channelCount: 2, totalFrames: frames, baseBucketSize: base, levels: levels)
    }

    struct Fixture { var view: TimelineView; var waveforms: TimelineWaveforms; var rep: NSBitmapImageRep }

    static func fixture() async throws -> Fixture {
        let audio = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
        let m = MediaRef(name: "m", path: "/nonexistent/m.wav", fingerprint: MediaFingerprint(size: 1), duration: Time(3600, 1),
                         info: MediaInfo(duration: Time(3600, 1), video: nil, audio: audio))
        var p = Project(name: "p"); p.add(m)
        let tracks = (0..<8).map { i in
            Track(kind: .audio, clips: (0..<60).map { n in
                Clip(name: "Clip \(i)-\(n)", media: m.id, kind: .audio,
                     source: TimeRange(start: Time(Int64(n * 60), 1), duration: Time(60, 1)), start: Time(Int64(n * 60), 1))
            }, name: "A\(i)", isTargeted: false)
        }
        let tl = Timeline(name: "perf", frameDuration: fd, tracks: tracks)
        let data = hourOfPeaks()
        let w = TimelineWaveforms { _ in data }
        let v = TimelineView(timeline: tl, frame: NSRect(x: 0, y: 0, width: 1600, height: 600))
        v.waveforms = w
        w.ensure(timeline: tl, project: p)
        for _ in 0..<SQTiming.polls(200) where w.data[m.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return Fixture(view: v, waveforms: w, rep: rep)
    }

    static func step(_ f: Fixture, _ i: Int) -> Double {
        let t0 = threadCPUNanos()
        if i % 2 == 0 {
            f.view.scroll(byX: 37, y: 0)
        } else {
            // sweeps zoom across many half-octave buckets, then back
            f.view.setZoom(pointsPerSecond: f.view.geometry.pointsPerSecond * (i % 40 < 20 ? 1.25 : 0.8), anchorX: 600)
        }
        guard let base = NSGraphicsContext(bitmapImageRep: f.rep) else { return 0 }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: 600); cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        f.view.draw(f.view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return Double(threadCPUNanos() - t0) / 1e6
    }

    @Test func coldVersusWarmSteps() async throws {
        let f = try await Self.fixture()
        f.view.setZoom(pointsPerSecond: 8)
        let cold = (0..<30).map { Self.step(f, $0) }
        let warm = (0..<30).map { Self.step(f, $0) }
        let avg = { (a: [Double]) in a.reduce(0, +) / Double(a.count) }
        let report = "COLD avg \(avg(cold)) max \(cold.max()!) | WARM avg \(avg(warm)) max \(warm.max()!)\nsteps: "
            + cold.map { String(format: "%.1f", $0) }.joined(separator: " ") + "\n"
        try? report.write(toFile: "/tmp/sq_coldstart.txt", atomically: true, encoding: .utf8)
        #expect(cold.max()! < SQTiming.budget(200))
    }
}

/// Not timing-based (counts logged lines), so it stays in the default run.
@MainActor @Suite struct TimelinePerfLogTests {
    @Test func logsFirstThirtyStepsPerKindWithBreakdown() {
        let v = TimelineView(timeline: Timeline(name: "t", frameDuration: Time(1, 24)), frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        v.perf = TimelinePerf(enabled: true)
        var logged: [String] = []
        v.perf.sink = { logged.append($0) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for i in 0..<40 {
            if i % 2 == 0 { v.scroll(byX: 20, y: 0) } else { v.setZoom(pointsPerSecond: v.geometry.pointsPerSecond * 1.1) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        #expect(logged.count == 40)
        #expect(logged.first?.contains("scroll #1") == true)
        #expect(logged.first?.contains("waveform") == true)
        v.perf.sink = { logged.append($0) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for _ in 0..<40 { v.scroll(byX: 20, y: 0); v.draw(v.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        #expect(v.perf.counts[.scroll] == 30)             // capped
    }

    @Test func disabledLogsNothing() {
        let v = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        v.perf = TimelinePerf(enabled: false)
        v.scroll(byX: 5, y: 0)
        #expect(v.perf.lines.isEmpty)
    }
}

/// CPU time of the calling thread: unlike wall time it does not grow when other processes starve the machine,
/// so the product targets stay unchanged but the tests stop flaking under load.
func threadCPUNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
