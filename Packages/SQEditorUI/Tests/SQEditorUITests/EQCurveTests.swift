import AppKit
import Foundation
import Testing
import SQAudioFX
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct EQCurveTests {
    private func setup() -> (EffectControlsModel, ClipEffect.ID, [Clip]) {
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = a.addEffect(kind: ClipEffect.audioParametricEQKind)!
        let m = EffectControlsModel()
        m.setClip(a)
        var edits: [Clip] = []
        m.onEdit = { [weak m] c, _, _ in edits.append(c); m?.setClip(c) }
        m.onAudioEdit = { [weak m] c, _, _ in edits.append(c); m?.setClip(c) }
        return (m, id, edits)
    }

    @Test func geometryRoundTripsAndPlacesDecades() {
        let g = EQCurveGeometry(plot: NSRect(x: 0, y: 0, width: 300, height: 100))
        #expect(abs(g.x(hz: 20)) < 1e-9 && abs(g.x(hz: 20_000) - 300) < 1e-9)
        #expect(abs(g.x(hz: 1_000) - 300 * (log10(50) / 3)) < 1e-6)
        for hz in [25.0, 440, 8_000] { #expect(abs(g.hz(x: g.x(hz: hz)) - hz) / hz < 1e-9) }
        #expect(abs(g.y(db: 0) - 50) < 1e-9 && abs(g.y(db: 18)) < 1e-9 && abs(g.y(db: -18) - 100) < 1e-9)
        #expect(abs(g.db(y: g.y(db: 7.5)) - 7.5) < 1e-9)
    }

    @Test func dragWritesTheSliderParametersInOneUndoStep() throws {
        let (m, id, _) = setup()
        var commits = 0
        m.onAudioEdit = { [weak m] c, _, _ in commits += 1; m?.setClip(c) }
        m.onEdit = { [weak m] c, _, _ in commits += 1; m?.setClip(c) }
        var undoSteps = 0
        m.beginGesture()
        m.onEdit = { [weak m] c, _, merge in if !merge { undoSteps += 1 }; m?.setClip(c) }
        m.onAudioEdit = { [weak m] c, _, merge in if !merge { undoSteps += 1 }; m?.setClip(c) }
        for hz in [500.0, 700, 900] { m.setEQBand(id, filter: 3, hz: hz, gainDB: 6, q: nil) }
        m.endGesture()
        #expect(undoSteps == 1)
        let v = try #require(m.eqValues(id))
        #expect(v.b2.hz == 900 && v.b2.gainDB == 6)
        // The slider property reads the same value.
        let p = EffectProperty.fx(id, kind: ClipEffect.audioParametricEQKind, key: ClipEffect.peqKey("b2", "Freq"))
        #expect(m.scalarValue(p) == 900)
    }

    @Test func resetRestoresTheCatalogDefaults() throws {
        let (m, id, _) = setup()
        m.setEQBand(id, filter: 4, hz: 3_000, gainDB: 9, q: 4)
        m.resetEQBand(id, filter: 4)
        let b = try #require(m.eqValues(id)).b3
        #expect(b.hz == 1_500 && b.gainDB == 0 && b.q == 1)
    }

    @Test func cutBandsIgnoreGainAndQ() throws {
        let (m, id, _) = setup()
        m.setEQBand(id, filter: 0, hz: 120, gainDB: 5, q: 3)
        let v = try #require(m.eqValues(id))
        #expect(v.hp.hz == 120 && v.hp.gainDB == 0 && v.hp.q == 0.7071)
    }

    @Test func curveRowsAppearOnlyWhileOpen() throws {
        let (m, id, _) = setup()
        let sec = EffectSection.effect(id, kind: ClipEffect.audioParametricEQKind)
        func rows() -> [EffectRow] { EffectControlsLayout.rows(sections: [sec], collapsed: [], expanded: [], openColorGroups: m.openColorGroups) }
        #expect(rows().contains { $0.kind == .eqCurveHeader(id) } && !rows().contains { $0.kind == .eqCurve(id) })
        m.toggleEQCurve(id)
        #expect(rows().contains { $0.kind == .eqCurve(id) })
    }

    @Test func pathIsCachedAndDrawTimeIsMeasured() throws {
        let (m, id, _) = setup()
        let view = EQCurveView(frame: NSRect(x: 0, y: 0, width: 360, height: 170))
        view.values = m.eqValues(id)
        view.layoutSubtreeIfNeeded()
        let builds = view.buildCount
        view.values = m.eqValues(id)               // same values: no rebuild
        #expect(view.buildCount == builds)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let clock = ContinuousClock()
        let n = 50
        let draw = clock.measure { for _ in 0..<n { view.cacheDisplay(in: view.bounds, to: rep) } }
        var v = try #require(m.eqValues(id))
        let rebuild = clock.measure { for i in 0..<n { v.b2.hz = 400 + Double(i); view.values = v } }
        print("EQCurve draw \(draw / n), path rebuild \(rebuild / n)")
        #expect(draw / n < .milliseconds(20), "draw \(draw / n), rebuild \(rebuild / n)")   // measured: draw about 1.4 ms at 360 x 170
    }

    @Test func pointsHaveAccessibilityLabels() throws {
        let (m, id, _) = setup()
        let view = EQCurveView(frame: NSRect(x: 0, y: 0, width: 360, height: 170))
        view.values = m.eqValues(id)
        let kids = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(kids.count == 9 && kids[3].accessibilityLabel()?.hasPrefix("Band 2, 400 hertz") == true)
    }

    @Test func qEditWritesOnlyQEvenWhenGainIsAnimated() throws {
        let (m, id, _) = setup()
        let gain = EffectProperty.fx(id, kind: ClipEffect.audioParametricEQKind, key: ClipEffect.peqKey("b2", "Gain"))
        m.playhead = Time(1, 1)
        _ = m.toggleStopwatch(gain)
        let keysBefore = try #require(m.track(gain)).times.count
        m.setEQBand(id, filter: 3, hz: nil, gainDB: nil, q: 3)
        #expect(try #require(m.eqValues(id)).b2.q == 3)
        #expect(try #require(m.track(gain)).times.count == keysBefore)
        let freq = EffectProperty.fx(id, kind: ClipEffect.audioParametricEQKind, key: ClipEffect.peqKey("b2", "Freq"))
        #expect(m.track(freq) == nil || !m.isAnimated(freq))
    }

    @Test func oneScrollGestureIsOneBeginEndPair() throws {
        let (m, id, _) = setup()
        let view = EQCurveView(frame: NSRect(x: 0, y: 0, width: 360, height: 170))
        view.values = m.eqValues(id)
        view.layoutSubtreeIfNeeded()
        var begins = 0, ends = 0, qs: [Double] = []
        view.onBegin = { begins += 1 }
        view.onEnd = { ends += 1 }
        view.onChange = { _, hz, gain, q in #expect(hz == nil && gain == nil); if let q { qs.append(q) } }
        let p = try #require(view.pointPosition(3))
        for _ in 0..<5 { view.applyScroll(at: NSPoint(x: p.x + 40, y: p.y + 40), dy: 4) }   // off the point, still in the gesture? no: first event must hit
        #expect(begins == 0)
        for _ in 0..<5 { view.applyScroll(at: p, dy: 4) }
        #expect(begins == 1 && ends == 0 && qs.count == 5 && qs == qs.sorted())
        view.endScrollGesture()
        #expect(ends == 1)
    }
}
