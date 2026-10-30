import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}

/// Transition "Custom" curve: a hand-drawn bezier stored as `EasingCurve`, used by render and export alike.
@Suite struct TransitionCustomCurveTests {
    static let drawn = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.9), in: EaseHandle(dx: 0.7, dy: 0.1))

    @Test func customCurveCarriesTheDrawnShape() throws {
        let c = try #require(EasingCurve.transitionCustom(Self.drawn))
        #expect(c.shape == Self.drawn && c.name == "Custom")
        #expect(EasingCurve.transitionCustom(Self.drawn) == c)   // stable identity: equal shapes, equal curves
        #expect(EasingCurve.transitionCustom(.hold) == nil)       // hold would turn the transition into a cut
    }

    @Test func presetsAreNotCustomAndDrawnCurvesAre() throws {
        for p in EasingCurve.transitionPresets { #expect(p.matchingTransitionPreset == p) }
        let c = try #require(EasingCurve.transitionCustom(Self.drawn))
        #expect(c.matchingTransitionPreset == nil)
        // Dragging the handles back onto a preset shape is that preset again.
        let back = try #require(EasingCurve.transitionCustom(EasingCurve.easeInOut.shape))
        #expect(back.matchingTransitionPreset == .easeInOut)
    }

    @Test func curveForShapeIsThePresetWhenItMatchesElseCustom() throws {
        #expect(EasingCurve.transitionCurve(for: EasingCurve.fastEnd.shape) == .fastEnd)
        #expect(EasingCurve.transitionCurve(for: Self.drawn)?.shape == Self.drawn)
        #expect(EasingCurve.transitionCurve(for: .hold) == nil)
        // A preset chip the transition cannot use (Premiere default etc.) still becomes a valid custom curve.
        let chip = try #require(EasingCurve.transitionCurve(for: EasingCurve.softLanding.shape))
        #expect(chip.shape == EasingCurve.softLanding.shape)
    }

    @Test func mixWeightStaysInUnitRangeEvenWhenTheCurveOvershoots() throws {
        let over = try #require(EasingCurve.transitionCustom(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.3, dy: 1.6),
                                                                      in: EaseHandle(dx: 0.3, dy: -0.8))))
        var sawOutside = false
        for i in 0...40 {
            let t = Double(i) / 40
            let p = over.progress(t)
            if p < 0 || p > 1 { sawOutside = true }
            let w = over.mixWeight(t)
            #expect(w >= 0 && w <= 1)
        }
        #expect(sawOutside)
        #expect(EasingCurve.easeInOut.mixWeight(0.37) == EasingCurve.easeInOut.progress(0.37))
    }

    @Test func clipEdgeTransitionKeepsCurveThroughProjectFile() throws {
        var v = Track(kind: .video, name: "V1")
        let a = clip(0), b = clip(60)
        try v.overwrite(a); try v.overwrite(b)
        var t = Timeline(name: "T", frameDuration: fd, tracks: [v])
        let id = try t.addTransition(kind: .crossDissolve, track: v.id, outgoing: a.id, incoming: b.id, duration: f(12))
        let c = try #require(EasingCurve.transitionCustom(Self.drawn))
        try t.setTransition(id, easing: c)
        // The resolved transition (what render and export read) carries the curve.
        let r = try #require(t.resolvedTransitions(on: v.id).first { $0.id == id })
        #expect(r.easing == c)
        // Round trip through the project file keeps it unchanged (no format change: EasingCurve is already Codable).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-tcc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Project(name: "P", timelines: [t])
        try ProjectFile.write(p, to: dir)
        let back = try ProjectFile.read(from: dir)
        #expect(back.timelines[0].tracks[0].transitions.first?.easing == c)
        #expect(back.timelines[0].tracks[0].transitions.first?.effectiveEasing.progress(0.4) == c.progress(0.4))
    }

    @Test func presetKeepsTheCustomCurve() throws {
        let c = try #require(EasingCurve.transitionCustom(Self.drawn))
        var tr = Transition(kind: .push, duration: f(12), outgoing: UUID(), incoming: UUID())
        tr.easing = c
        let p = TransitionPreset.capture(from: tr)
        #expect(p.easing == c)
        let back = try TransitionPreset(payload: try p.payload(), version: TransitionPreset.payloadVersion)
        #expect(back.easing == c && back.easing.shape == Self.drawn)
    }

    @Test func layerKeepsTheCustomCurveAndPlaysItLikeAClipEdge() throws {
        let c = try #require(EasingCurve.transitionCustom(Self.drawn))
        var l = TransitionLayer(kind: .crossDissolve, cut: f(30))
        l.easing = c
        #expect(l.effectiveEasing == c)
        #expect(TransitionLayer.decode(l.payload)?.easing == c)
        let t = TransitionMix.videoWeight(frameIndex: 3, frames: 12)
        #expect(c.mixWeight(t) == c.progress(t))
    }
}
