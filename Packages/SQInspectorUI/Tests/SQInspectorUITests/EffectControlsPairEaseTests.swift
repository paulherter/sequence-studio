import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsPairEaseTests {
    func animated() -> EffectControlsModel {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(c); m.playhead = Time(5, 1)
        m.setValue(.opacity, to: 0.1); m.toggleStopwatch(.opacity)
        m.playhead = Time(7, 1); m.setValue(.opacity, to: 0.5)
        m.playhead = Time(9, 1); m.setValue(.opacity, to: 0.9)
        return m
    }

    @Test func pairEaseSetsBothSidesInOneEdit() {
        let m = animated()
        var edits = 0
        let prev = m.onEdit
        m.onEdit = { c, n, g in edits += 1; prev?(c, n, g) }
        let ids = m.track(.opacity)!.keyIDs
        m.select(ids.prefix(2).map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0) }, extend: false)
        #expect(m.hasSelectedPair)
        m.applyInterpolation(.easyEase)
        #expect(edits == 1)
        guard case .scalar(let t)? = m.track(.opacity) else { return }
        #expect(t.keys[0].outHandle.dy == 0 && t.keys[1].inHandle.dy == 0)
        #expect(t.keys[1].outHandle == .linear)
    }

    @Test func singleKeyKeepsOneSidedEase() {
        let m = animated()
        m.selectKey(.opacity, id: m.track(.opacity)!.keyIDs[1], extend: false)
        #expect(!m.hasSelectedPair)
        m.applyInterpolation(.easeIn)
        guard case .scalar(let t)? = m.track(.opacity) else { return }
        #expect(t.keys[1].inHandle.dy == 0 && t.keys[1].outHandle == .linear)
    }

    @Test func customCurveMakesBezierOpensGraphInValueMode() {
        let m = animated()
        m.selectKey(.opacity, id: m.track(.opacity)!.keyIDs[1], extend: false)
        m.revealCustomCurve()
        guard case .scalar(let t)? = m.track(.opacity) else { return }
        #expect(t.keys[1].interpolation == .bezier)
        #expect(m.expanded.contains(.opacity))
        #expect(m.graphMode == .speed)
    }

    @Test func pairOnOpacityAndSingleKeyOnScaleBothEase() {
        let m = animated()
        m.playhead = Time(5, 1); m.toggleStopwatch(.scale)
        m.playhead = Time(7, 1); m.setValue(.scale, to: 200)
        let o = m.track(.opacity)!.keyIDs, sc = m.track(.scale)!.keyIDs
        m.select(o.prefix(2).map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0) }
                 + [SummaryMember(property: EffectProperty.scale.id, keyID: sc[1])], extend: false)
        m.applyInterpolation(.easyEase)
        guard case .scalar(let to)? = m.track(.opacity), case .vector(let ts)? = m.track(.scale) else { return }
        #expect(to.keys[0].outHandle.dy == 0 && to.keys[1].inHandle.dy == 0)
        #expect(ts.keys[1].inHandle.dy == 0)
    }
}
