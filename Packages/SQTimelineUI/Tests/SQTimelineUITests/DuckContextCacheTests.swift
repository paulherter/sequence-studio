import AppKit
import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

/// The duck context is cached across draws (scroll draws every tick); it must equal a fresh compute and follow every change.
@MainActor struct DuckContextCacheTests {
    private static func clip(_ start: Int64, _ len: Int64) -> Clip {
        Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(len, 1)), start: Time(start, 1))
    }
    private static func timeline(dialogue: [(Int64, Int64)]) -> Timeline {
        var d = Track(kind: .audio, clips: dialogue.map { clip($0.0, $0.1) }); d.audioRole = .dialogue
        var m = Track(kind: .audio, clips: [clip(0, 100)]); m.audioRole = .music
        return Timeline(name: "t", frameDuration: Time(1, 30), tracks: [d, m])
    }
    private final class Setting: @unchecked Sendable { var db: Double? = 12 }

    private func view(_ setting: Setting) -> TimelineView {
        let v = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        v.duckCurve = DuckCurveSource(ducking: { setting.db.map { LiveDucking(amountDB: $0, fade: Time(1, 2)) } }, silences: nil)
        v.setTimeline(Self.timeline(dialogue: [(10, 5)]))
        return v
    }

    @Test func cachedContextEqualsFreshCompute() {
        let v = view(Setting())
        let a = v.duckCurveContext(), b = v.duckCurveContext()
        let fresh = v.computeDuckCurveContext()
        #expect(a != nil)
        #expect(a?.ranges == fresh?.ranges && a?.clips == fresh?.clips && a?.ducking == fresh?.ducking)
        #expect(b?.ranges == a?.ranges)
    }

    @Test func recomputedAfterTimelineChange() {
        let v = view(Setting())
        #expect(v.duckCurveContext()?.ranges.count == 1)
        v.setTimeline(Self.timeline(dialogue: [(10, 5), (30, 5)]))
        #expect(v.duckCurveContext()?.ranges.count == 2)
    }

    @Test func recomputedAfterSettingChange() {
        let s = Setting(); let v = view(s)
        #expect(v.duckCurveContext() != nil)
        s.db = nil
        v.refreshDuckCurveIfChanged()
        #expect(v.duckCurveContext() == nil)
    }
}
