import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)

/// 200 touching clips of 60 frames on one video track and 200 on one audio track, 50 cut transitions on each.
private func bigTimeline() throws -> Timeline {
    var v = Track(kind: .video), a = Track(kind: .audio)
    for i in 0..<200 {
        try v.overwrite(Clip(name: "v\(i)", media: UUID(), kind: .video, source: TimeRange(start: fd * 30, duration: fd * 60), start: fd * Int64(60 * i), mediaDuration: fd * 400))
        try a.overwrite(Clip(name: "a\(i)", media: UUID(), kind: .audio, source: TimeRange(start: fd * 30, duration: fd * 60), start: fd * Int64(60 * i), mediaDuration: fd * 400))
    }
    var t = Timeline(name: "t", frameDuration: fd, tracks: [v, a])
    for k in 0..<50 {
        let i = k * 4 + 1
        try t.addTransition(kind: .crossDissolve, track: v.id, outgoing: v.clips[i].id, incoming: v.clips[i + 1].id, duration: fd * 20)
        try t.addTransition(kind: .constantPower, track: a.id, outgoing: a.clips[i].id, incoming: a.clips[i + 1].id, duration: fd * 20)
    }
    return t
}

/// The big timeline evaluates to layers and segments at every sampled frame (always runs).
@Suite struct TransitionBigTimelineTests {
    @Test func bigTimelineYieldsLayersAndSegments() throws {
        let t = try bigTimeline()
        let range = TimeRange(start: .zero, duration: Time(1024, 48_000))
        var layers = 0, segs = 0
        for f in stride(from: 0, to: 3000, by: 100) {
            layers += t.videoLayers(at: fd * Int64(f * 4 + 10)).count
            segs += t.audioSegments(in: TimeRange(start: fd * Int64(f * 4 + 10) + range.start, duration: range.duration)).count
        }
        #expect(layers > 0 && segs > 0)
    }
}

/// Opt-in: `SQ_PERF=1 SQ_TEST_FILTER=TransitionPerfTests scripts/test.sh SQCore`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1")) struct TransitionPerfTests {
    /// Measurement only (printed): cost of what the prefetch and render loops ask per frame.
    @Test func evaluationCostWith200ClipsAnd50Transitions() throws {
        let t = try bigTimeline()
        let clock = ContinuousClock()
        let frames = 3000
        var layers = 0
        let video = clock.measure {
            for f in 0..<frames { layers += t.videoLayers(at: fd * Int64(f * 4 + 10)).count }
        }
        let range = TimeRange(start: .zero, duration: Time(1024, 48_000))
        var segs = 0
        let audio = clock.measure {
            for f in 0..<frames { segs += t.audioSegments(in: TimeRange(start: fd * Int64(f * 4 + 10) + range.start, duration: range.duration)).count }
        }
        func us(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e12 / Double(frames) + Double(d.components.seconds) * 1e6 / Double(frames) }
        NSLog("transition eval cost (200 clips, 50 transitions per track): videoLayers %.1f us/call, audioSegments %.1f us/call", us(video), us(audio))
        #expect(layers > 0 && segs > 0)
    }
}
