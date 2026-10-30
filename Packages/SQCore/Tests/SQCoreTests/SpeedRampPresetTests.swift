import Foundation
import Testing
@testable import SQCore

@Suite struct SpeedRampPresetTests {
    private let fd = Time(1, 30)
    private func f(_ n: Int64) -> Time { Time(n, 30) }
    private func clip(frames: Int64 = 150) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(300), duration: f(frames)), start: .zero, mediaDuration: f(3000))
    }
    private func peak(_ k: SpeedKeys) -> Double { k.segments.map { max($0.from.percent, $0.to.percent) / 100 }.max() ?? 0 }

    @Test func everyPresetPeaksBetween250And300PercentAndKeepsTheSource() {
        let base = SpeedKeys.of(clip())
        for p in SpeedRampPreset.allCases {
            let k = p.keys(for: base, frameDuration: fd, peakAt: nil)
            #expect(peak(k) >= 2.5 && peak(k) <= 3.0, "\(p)")
            #expect(k.segments.count > 1)
            let h = k.hull
            // The whole source range stays in use (up to the frame rounding of the segment lengths).
            #expect(abs(Rational(h.duration).double - 5.0) < 0.15, "\(p)")
            #expect(h.start == f(300))
            #expect(k.segments.allSatisfy { $0.duration >= fd })
        }
    }

    @Test func eachRampIsAnEaseInOutSCurve() {
        let k = SpeedRampPreset.crest.keys(for: SpeedKeys.of(clip()), frameDuration: fd, peakAt: nil)
        let ramps = k.segments.filter(\.isRamp)
        #expect(!ramps.isEmpty)
        #expect(ramps.allSatisfy { $0.ease != nil })
    }

    @Test func hitOnBeatPutsThePeakOnTheBeat() {
        let base = SpeedKeys.of(clip())
        for p in SpeedRampPreset.allCases {
            for b in [f(35), f(45), f(55)] {
                let k = p.keys(for: base, frameDuration: fd, peakAt: b)
                let t = k.peakTime
                #expect(abs(Rational(t - b).double) <= 2.0 / 30, "\(p) beat \(b) got \(t)")
            }
        }
    }

    @Test func reversedClipsStayReversed() {
        var c = clip()
        c.reversed = true
        let k = SpeedRampPreset.punch.keys(for: SpeedKeys.of(c), frameDuration: fd, peakAt: nil)
        #expect(k.segments.allSatisfy { $0.reversed })
        #expect(k.origin == f(450))
    }

    @Test func applyingThroughTheTimelineWorksAndStaysConsistent() throws {
        let c = clip()
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let before = tl
        let keys = SpeedRampPreset.surge.keys(for: SpeedKeys.of(c), frameDuration: fd, peakAt: nil)
        try tl.editSpeedKeys(c.id, keepingKeys: true) { _ in keys }
        let after = tl.tracks[0].clips[0]
        #expect(after.speedKeys != nil)
        #expect(after.speedKeys?.segments.count == keys.segments.count)
        #expect(tl != before)
        #expect(tl.tracks[0].isConsistent)
    }
}
