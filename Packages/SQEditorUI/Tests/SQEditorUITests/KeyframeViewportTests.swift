import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQEditorUI

@Suite struct KeyframeViewportTests {
    let dur = 10.0, minSpan = 0.4

    @Test func fullViewportIsWholeClip() {
        let v = KeyframeViewport.full(duration: dur)
        #expect(v.start == 0 && v.span == 10 && v.isFull(duration: dur))
        #expect(v.handles(duration: dur) == (0, 1))
    }

    @Test func zoomKeepsTheAnchorOnScreen() {
        let v = KeyframeViewport.full(duration: dur).zoomed(by: 2, around: 5, duration: dur, minSpan: minSpan)
        #expect(v.span == 5 && v.start == 2.5)
        // anchor at 25 % of the window stays at 25 %
        let w = KeyframeViewport(start: 2, span: 4).zoomed(by: 2, around: 3, duration: dur, minSpan: minSpan)
        #expect(abs((3 - w.start) / w.span - 0.25) < 1e-9 && w.span == 2)
    }

    @Test func zoomIsClampedToClipAndMinimumSpan() {
        let out = KeyframeViewport(start: 2, span: 4).zoomed(by: 0.01, around: 4, duration: dur, minSpan: minSpan)
        #expect(out.isFull(duration: dur))
        let deep = KeyframeViewport(start: 2, span: 4).zoomed(by: 1000, around: 4, duration: dur, minSpan: minSpan)
        #expect(deep.span == minSpan)
        #expect(KeyframeViewport.full(duration: 0).clamped(duration: 0, minSpan: minSpan).span == 0)
    }

    @Test func panStaysInsideTheClip() {
        let v = KeyframeViewport(start: 2, span: 4)
        #expect(v.panned(by: 1, duration: dur, minSpan: minSpan).start == 3)
        #expect(v.panned(by: 100, duration: dur, minSpan: minSpan).start == 6)
        #expect(v.panned(by: -100, duration: dur, minSpan: minSpan).start == 0)
    }

    @Test func revealScrollsJustEnough() {
        let v = KeyframeViewport(start: 2, span: 4)
        #expect(v.revealing(4, duration: dur, minSpan: minSpan) == v)
        #expect(v.revealing(9, duration: dur, minSpan: minSpan).end > 9)
        #expect(v.revealing(0.5, duration: dur, minSpan: minSpan).start < 0.5)
    }

    @Test func zoomBarHandles() {
        let v = KeyframeViewport(start: 2, span: 4)
        let h = v.handles(duration: dur)
        #expect(abs(h.lo - 0.2) < 1e-9 && abs(h.hi - 0.6) < 1e-9)
        let lower = v.settingLowerHandle(0.4, duration: dur, minSpan: minSpan)   // right edge stays at 6 s
        #expect(lower.start == 4 && lower.end == 6)
        let upper = v.settingUpperHandle(0.9, duration: dur, minSpan: minSpan)   // left edge stays at 2 s
        #expect(upper.start == 2 && abs(upper.end - 9) < 1e-9)
        // handles never cross: stops at the minimum span
        let crossed = v.settingLowerHandle(0.95, duration: dur, minSpan: minSpan)
        #expect(abs(crossed.span - minSpan) < 1e-9 && crossed.end == 6)
        let centred = v.centered(onFraction: 0.5, duration: dur, minSpan: minSpan)
        #expect(centred.start == 3 && centred.span == 4)
    }

    @Test func zoomBarGeometryMapsAndHitTests() {
        let g = KeyframeZoomBarGeometry(width: 300)
        #expect(g.fraction(atX: g.x(forFraction: 0.37)) - 0.37 < 1e-9)
        #expect(g.x(forFraction: -1) == g.x(forFraction: 0))
        let v = KeyframeViewport(start: 2, span: 4)
        let xl = g.x(forFraction: 0.2), xh = g.x(forFraction: 0.6)
        #expect(g.part(atX: xl, viewport: v, duration: 10) == .lower)
        #expect(g.part(atX: xh + 3, viewport: v, duration: 10) == .upper)
        #expect(g.part(atX: (xl + xh) / 2, viewport: v, duration: 10) == .body)
        #expect(g.part(atX: g.x(forFraction: 0.9), viewport: v, duration: 10) == .track)
    }

    @Test func laneGeometryFollowsTheViewport() {
        let vp = KeyframeViewport(start: 2, span: 4)
        let g = KeyframeLaneGeometry(width: 420, duration: Time(10, 1), inset: 10, viewport: vp)
        #expect(g.x(seconds: 2) == 10 && g.x(seconds: 6) == 410)
        #expect(g.x(for: Time(4, 1)) == 210)
        #expect(abs(g.pointsPerSecond - 100) < 1e-9)
        #expect(g.time(at: 210, frameDuration: Time(1, 30)) == Time(4, 1))
        #expect(g.time(at: -500, frameDuration: Time(1, 30)) == .zero)            // still clamped to the clip
        // No viewport: the old whole-clip mapping.
        let full = KeyframeLaneGeometry(width: 120, duration: Time(10, 1), inset: 10)
        #expect(full.x(for: Time(5, 1)) == 60)
    }

    @Test func rulerTicksOnlyCoverTheVisibleWindow() {
        let fd = Time(1, 30)
        let vp = KeyframeViewport(start: 100, span: 2)
        let g = KeyframeLaneGeometry(width: 620, duration: Time(600, 1), inset: 10, viewport: vp)
        let ticks = KeyframeRulerLayout.ticks(geometry: g, frameDuration: fd, nominalFPS: 30)
        #expect(!ticks.isEmpty && ticks.count < 200)                               // not one per frame of a 10 min clip
        #expect(ticks.allSatisfy { $0.local >= Time(99, 1) && $0.local <= Time(103, 1) })
        #expect(ticks.contains { $0.major })
    }

    // MARK: Snapping, split, scroll

    @Test func snapSticksToTheNearestCandidateWithinTheThreshold() {
        let keys = [Time(1, 1), Time(3, 1)]
        #expect(KeyframeSnap.snapped(Time(31, 30), candidates: keys, thresholdSeconds: 0.1) == Time(1, 1))
        #expect(KeyframeSnap.snapped(Time(2, 1), candidates: keys, thresholdSeconds: 0.1) == Time(2, 1))
        #expect(KeyframeSnap.snapped(Time(5, 2), candidates: keys, thresholdSeconds: 0.6) == Time(3, 1))
        #expect(KeyframeSnap.snapped(Time(2, 1), candidates: [], thresholdSeconds: 1) == Time(2, 1))
    }

    @Test func splitIsClampedAndPersisted() {
        #expect(EffectControlsSplit.clamp(100, total: 800) == EffectControlsSplit.minLabelWidth)
        #expect(EffectControlsSplit.clamp(790, total: 800) == 800 - EffectControlsSplit.minLanesWidth)
        #expect(EffectControlsSplit.clamp(400, total: 800) == 400)
        #expect(EffectControlsSplit.clamp(400, total: 200) == 200)                // never wider than the panel
        let d = UserDefaults(suiteName: "split-test-\(UUID().uuidString)")!
        #expect(EffectControlsSplit.load(from: d) == EffectControlsSplit.defaultWidth)
        EffectControlsSplit.save(410, to: d)
        #expect(EffectControlsSplit.load(from: d) == 410)
        d.set(3.0, forKey: EffectControlsSplit.defaultsKey)                       // stale or hand-edited value
        #expect(EffectControlsSplit.load(from: d) == EffectControlsSplit.defaultWidth)
    }

    @Test func scrollClassification() {
        #expect(KeyframeZoomInput.classify(deltaX: 10, deltaY: 2, zoomModifier: false) == .pan(points: 10))
        #expect(KeyframeZoomInput.classify(deltaX: 1, deltaY: 10, zoomModifier: false) == .none)   // rows scroll vertically
        if case .zoom(let f) = KeyframeZoomInput.classify(deltaX: 0, deltaY: 5, zoomModifier: true) { #expect(f > 1) } else { Issue.record("zoom") }
        #expect(KeyframeZoomInput.magnifyFactor(0.25) == 1.25)
        #expect(KeyframeZoomInput.magnifyFactor(-5) > 0)
    }
}
