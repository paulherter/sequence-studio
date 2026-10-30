import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// W6.7 follow-up: Effect Controls rows for path masks (Feather, Opacity, Expansion keyframable, Invert, Mode, Path, delete).
@MainActor @Suite struct EffectControlsMaskRowsTests {
    final class Log { var edits: [String] = [] }

    func rig() -> (EffectControlsModel, ClipMask.ID, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let mask = ClipMask.make(.ellipse, name: "Mask (1)")
        clip.masks = [mask]
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { _, n, _ in log.edits.append(n) }
        m.setClip(clip); m.playhead = Time(6, 1)
        return (m, mask.id, log)
    }

    @Test func sectionListsMasksAndRowsCarryControls() {
        let (m, id, _) = rig()
        #expect(m.visibleSections == [.motion, .mask(id)])
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [])
        let kinds = rows.map(\.kind)
        #expect(kinds.contains(.property(.mask(id, .feather))) && kinds.contains(.property(.mask(id, .expansion))))
        #expect(kinds.suffix(3) == [.maskControls(id), .maskTrack(id), .maskUse(id)])
        let collapsed = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [.mask(id)], expanded: [])
        #expect(collapsed.last?.kind == .section(.mask(id)))
    }

    @Test func rawValuesRoundTrip() {
        let id = UUID()
        for p in MaskParam.allCases { #expect(EffectProperty(rawValue: EffectProperty.mask(id, p).rawValue) == .mask(id, p)) }
        #expect(EffectSection(rawValue: EffectSection.mask(id).rawValue) == .mask(id))
    }

    @Test func slidersWriteAndKeyframe() throws {
        let (m, id, log) = rig()
        let f = EffectProperty.mask(id, .feather)
        #expect(m.scalarValue(f) == ClipMask.defaultFeather && m.isDefault(f))
        m.setValue(f, component: .all, to: 40)
        #expect(m.scalarValue(f) == 40 && !m.isDefault(f))
        #expect(log.edits.last != nil)
        #expect(m.toggleStopwatch(f) == .added)
        m.playhead = Time(8, 1)
        m.setValue(f, component: .all, to: 80)
        #expect(m.track(f)?.keyIDs.count == 2)
        m.playhead = Time(7, 1)
        #expect(abs(m.scalarValue(f) - 60) < 1e-6)
        let o = EffectProperty.mask(id, .opacity)
        m.setValue(o, component: .all, to: 50)
        #expect(m.clip?.mask(id)?.opacity.value == 50)
        #expect(m.reset(o) && m.clip?.mask(id)?.opacity.value == 100)
    }

    /// Deleting a mask drops its selected keys, its selected section and its expansion state.
    @Test func removingAMaskPrunesKeySelectionAndSection() throws {
        let (m, id, _) = rig()
        let f = EffectProperty.mask(id, .feather)
        #expect(m.toggleStopwatch(f) == .added)
        let key = try #require(m.track(f)?.keyIDs.first)
        m.selectKey(f, id: key, extend: false)
        m.selectedSection = .mask(id)
        #expect(!m.selectedKeyIDs(f).isEmpty)
        m.removeMask(id)
        #expect(m.selectedKeyIDs(f).isEmpty && m.selection.isEmpty)
        #expect(m.selectedSection == nil)
        let (m2, id2, _) = rig()
        m2.removeAllMasks()
        #expect(m2.selection.isEmpty && id2 != id)
    }

    @Test func invertModeEnableAndPathStopwatch() throws {
        let (m, id, _) = rig()
        m.setMaskInverted(id, true); m.setMaskMode(id, .intersect)
        #expect(m.clip?.mask(id)?.inverted == true && m.clip?.mask(id)?.mode == .intersect)
        #expect(m.isEffectEnabled(.mask(id)))
        m.setEffectEnabled(.mask(id), false)
        #expect(m.clip?.mask(id)?.enabled == false)
        m.setMaskPathAnimated(id, true)
        #expect(m.clip?.mask(id)?.path.isAnimated == true)
        m.removeMask(id)
        #expect(m.clip?.masks.isEmpty == true && m.visibleSections == [.motion])
    }
}
