import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// FB-B: a Color effect shows up collapsed, grouped like the Color page, with its curves.
@MainActor @Suite struct EffectControlsColorGroupsTests {
    func rig() -> (EffectControlsModel, EffectSection, ClipEffect.ID) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = clip.addEffect(kind: ClipEffect.colorKind)!
        let m = EffectControlsModel()
        m.setClip(clip)
        return (m, .effect(id, kind: ClipEffect.colorKind), id)
    }

    @Test func newColorEffectStartsCollapsedWithBasicGroupOpen() {
        let (m, s, id) = rig()
        #expect(m.collapsedSections.contains(s))
        #expect(m.openColorGroups == ["\(id.uuidString)/\(ClipEffect.colorBasicOnKey)"])
        // The user opens it, switches clips and comes back: it stays as the user left it.
        m.collapsedSections.remove(s)
        let c = m.clip
        m.setClip(nil); m.setClip(c)
        #expect(!m.collapsedSections.contains(s))
    }

    @Test func anEffectAddedToTheShownClipStaysOpenButAClipFirstShownStartsClosed() {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let m = EffectControlsModel(); m.setClip(clip)
        let id = clip.addEffect(kind: ClipEffect.dropShadowKind)!
        m.setClip(clip)                                           // the user just added it: open
        #expect(!m.collapsedSections.contains(.effect(id, kind: ClipEffect.dropShadowKind)))
        let other = EffectControlsModel(); other.setClip(clip)    // a clip first shown with the effect already on it: default (closed)
        #expect(other.collapsedSections.contains(.effect(id, kind: ClipEffect.dropShadowKind)))
        #expect(!other.collapsedSections.contains(.motion))
    }

    @Test func layoutGroupsTheColorRows() {
        let (_, s, id) = rig()
        let basic = "\(id.uuidString)/\(ClipEffect.colorBasicOnKey)"
        let groups = { (rows: [EffectRow]) in rows.compactMap { r -> String? in if case .colorGroup(_, let k) = r.kind { k } else { nil } } }
        var rows = EffectControlsLayout.rows(sections: [s], collapsed: [], expanded: [], openColorGroups: [basic])
        #expect(groups(rows) == ColorEffectGroups.toggleKeys)
        let props = rows.compactMap { r -> String? in if case .property(let p) = r.kind { p.rawValue } else { nil } }
        #expect(props.contains { $0.hasSuffix(ClipEffect.colorTemperatureKey) })          // Basic is open
        #expect(!props.contains { $0.hasSuffix(ClipEffect.colorFadedFilmKey) })           // Creative is closed
        #expect(!props.contains { $0.hasSuffix(ClipEffect.colorBasicOnKey) })             // the switch lives in the group header
        #expect(!rows.contains { if case .curves = $0.kind { true } else { false } })
        rows = EffectControlsLayout.rows(sections: [s], collapsed: [], expanded: [],
                                         openColorGroups: [basic, "\(id.uuidString)/\(ClipEffect.colorCurvesOnKey)"])
        let curves = rows.firstIndex { if case .curves = $0.kind { true } else { false } }
        let header = rows.firstIndex { if case .colorGroup(_, ClipEffect.colorCurvesOnKey) = $0.kind { true } else { false } }
        #expect(curves != nil && header != nil && curves == header! + 1)
    }

    @Test func curvesEditThroughTheModel() {
        let (m, _, id) = rig()
        var log: [String] = []
        m.onEdit = { _, n, _ in log.append(n) }
        #expect(m.colorCurves(id).isNeutral)
        var c = RGBCurves()
        c.master = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        m.setColorCurves(id, c)
        #expect(m.colorCurves(id) == c)
        #expect(m.clip?.effects.first { $0.id == id }?.colorData.curves == c)
        #expect(log == ["Edit Curves"])
    }

    @Test func closedGroupShowsSummaryKeysOfItsNumbers() {
        let (m, _, id) = rig()
        m.playhead = Time(2, 1)
        let exposure = EffectProperty.fx(id, kind: ClipEffect.colorKind, key: ClipEffect.colorExposureKey)
        _ = m.toggleKeyAtPlayhead(exposure)
        let basic = ClipEffect.colorBasicOnKey
        #expect(m.colorGroupSummaryKeys(id, basic).isEmpty)               // open by default: the rows show their own keys
        m.toggleColorGroup(id, basic)                                       // close it
        #expect(m.colorGroupSummaryKeys(id, basic).count == 1)
        #expect(m.colorGroupSummaryKeys(id, ClipEffect.colorCreativeOnKey).isEmpty)   // other groups unaffected
    }
}
