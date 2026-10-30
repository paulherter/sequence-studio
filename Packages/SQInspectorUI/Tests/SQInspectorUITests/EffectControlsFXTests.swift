import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsFXTests {
    final class Log { var edits: [(Clip, String, Bool)] = [] }

    func rig(_ configure: (inout Clip) -> Void = { _ in }) -> (EffectControlsModel, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        configure(&clip)
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = Time(6, 1)
        return (m, log)
    }

    // MARK: Instances

    @Test func twoBlursHaveIndependentRowsAndValues() {
        var ids: [UUID] = []
        let (m, _) = rig { c in ids = [c.addEffect(kind: ClipEffect.gaussianBlurKind)!, c.addEffect(kind: ClipEffect.gaussianBlurKind)!] }
        let sections = m.visibleSections
        #expect(sections == [.motion,
                             .effect(ids[0], kind: ClipEffect.gaussianBlurKind), .effect(ids[1], kind: ClipEffect.gaussianBlurKind)])
        let p0 = sections[1].properties[0], p1 = sections[2].properties[0]
        #expect(p0 != p1 && p0.title == "Amount")
        m.setValue(p0, to: 5)
        m.setValue(p1, to: 9)
        #expect(m.scalarValue(p0) == 5 && m.scalarValue(p1) == 9)
        #expect(m.toggleStopwatch(p1) == .added)
        #expect(m.isAnimated(p1) && !m.isAnimated(p0))
    }

    @Test func cropShowsItsRowsInTransformWithPercentUnits() {
        let (m, _) = rig { c in _ = c.addEffect(kind: ClipEffect.cropKind) }
        #expect(!m.visibleSections.contains { $0.effectKind == ClipEffect.cropKind })     // the first Crop lives in Transform
        let rows = m.transformCropProperties
        #expect(rows.map(\.title) == ["Left", "Right", "Top", "Bottom", "Softness"])
        #expect(rows.prefix(4).allSatisfy { $0.displayUnit == "%" && $0.displayRange == 0...100 })
        #expect(rows[4].displayUnit == "px")
        m.setValue(rows[0], to: 12.5)
        #expect(m.clip!.effects(at: Time(6, 1)).pre.crop.left == 0.125)
    }

    @Test func keysOfOneInstanceStayOnThatInstance() {
        var ids: [UUID] = []
        let (m, _) = rig { c in ids = [c.addEffect(kind: ClipEffect.gaussianBlurKind)!, c.addEffect(kind: ClipEffect.gaussianBlurKind)!] }
        let a = EffectSection.effect(ids[0], kind: ClipEffect.gaussianBlurKind).properties[0]
        let b = EffectSection.effect(ids[1], kind: ClipEffect.gaussianBlurKind).properties[0]
        #expect(m.toggleStopwatch(a) == .added)
        m.playhead = Time(8, 1)
        m.setValue(a, to: 30)
        #expect(m.clip!.effects[0].parameters[ClipEffect.blurrinessKey]!.track.keys.count == 2)
        #expect(m.clip!.effects[1].parameters[ClipEffect.blurrinessKey]!.track.isEmpty)
        #expect(m.track(b)?.keyIDs.isEmpty == true)
        m.selectKey(a, id: m.track(a)!.keyIDs[0], extend: false)
        m.deleteSelection()
        #expect(m.clip!.effects[0].parameters[ClipEffect.blurrinessKey]!.track.keys.count == 1)
    }

    @Test func rawValuesRoundTrip() {
        let id = UUID()
        let p = EffectProperty.fx(id, kind: ClipEffect.cropKind, key: ClipEffect.cropLeftKey)
        #expect(EffectProperty(rawValue: p.rawValue) == p)
        let s = EffectSection.effect(id, kind: ClipEffect.cropKind)
        #expect(EffectSection(rawValue: s.rawValue) == s)
        #expect(EffectSection(rawValue: "motion") == .motion && EffectProperty(rawValue: "volume") == .volume)
        #expect(EffectProperty(rawValue: "nonsense") == nil)
        #expect(p.section == s)
    }

    // MARK: Reorder, duplicate, cut

    @Test func reorderIsOneUndoStepAndChangesEvaluationOrder() {
        var ids: [UUID] = []
        let (m, log) = rig { c in
            ids = [c.addEffect(kind: ClipEffect.gaussianBlurKind)!, c.addEffect(kind: ClipEffect.roundedCornersKind)!]
            c.setParameter(ids[0], ClipEffect.blurrinessKey, to: 6)
        }
        let rc = EffectSection.effect(ids[1], kind: ClipEffect.roundedCornersKind)
        #expect(m.clip!.effects(at: Time(6, 1)).post.cornerRadius == 24)
        #expect(m.moveEffect(rc, toIndex: 0))
        #expect(log.edits.count == 1 && log.edits[0].1 == "Reorder Effects")
        #expect(m.visibleSections.suffix(2).first == rc)
        #expect(m.clip!.effects(at: Time(6, 1)).pre.cornerRadius == 24)
        #expect(!m.moveEffect(rc, toIndex: 0))
        #expect(!m.moveEffect(.motion, toIndex: 0))
    }

    @Test func dropIndexFollowsTheHeaderMidpoints() {
        let mids: [CGFloat] = [20, 60, 100]
        typealias M = EffectControlsModel
        #expect(M.dropIndex(forY: 5, midpoints: mids, dragging: 2) == 0)
        #expect(M.dropIndex(forY: 50, midpoints: mids, dragging: 2) == 1)
        #expect(M.dropIndex(forY: 500, midpoints: mids, dragging: 0) == 2)
        #expect(M.dropIndex(forY: 25, midpoints: mids, dragging: 0) == 0)
        #expect(M.dropIndex(forY: 25, midpoints: [], dragging: 0) == 0)
    }

    @Test func duplicateCopiesValuesWithANewInstance() {
        var id = UUID()
        let (m, log) = rig { c in id = c.addEffect(kind: ClipEffect.gaussianBlurKind)!; c.setParameter(id, ClipEffect.blurrinessKey, to: 7) }
        #expect(m.duplicateEffect(.effect(id, kind: ClipEffect.gaussianBlurKind)))
        #expect(m.clip!.effects.count == 2 && m.clip!.effects[1].id != id)
        #expect(m.clip!.effects[1].parameters[ClipEffect.blurrinessKey]?.value == 7)
        #expect(log.edits.last?.1 == "Duplicate Effect")
    }

    @Test func cutCopiesThenClearsAndPasteAddsAnInstance() {
        var id = UUID()
        let (m, _) = rig { c in id = c.addEffect(kind: ClipEffect.cropKind)! }
        let s = EffectSection.effect(id, kind: ClipEffect.cropKind)
        #expect(m.cutEffect(s))
        #expect(m.clip!.effects.isEmpty)
        #expect(m.canPasteFocused)
        #expect(m.pasteFocused())
        #expect(m.clip!.effects.count == 1 && m.clip!.effects[0].id != id)
        #expect(m.pasteEffect())                              // a second paste adds a second instance
        #expect(m.clip!.effects.count == 2)
    }

    // MARK: fx toggle of the fixed sections

    @Test func motionAndOpacityHaveAnFXToggleThatChangesTheRenderedTransform() {
        let (m, log) = rig { c in c.animation.position = AnimatedProperty(Vec2(30, 40)); c.animation.opacity = AnimatedProperty(0.4) }
        #expect(m.hasFXToggle(.motion) && m.hasFXToggle(.opacity) && !m.hasFXToggle(.volume))
        #expect(m.isEffectEnabled(.motion))
        m.setEffectEnabled(.motion, false)
        #expect(!m.isEffectEnabled(.motion))
        #expect(m.clip!.transform(at: Time(6, 1)).position == .zero)
        #expect(m.clip!.animation.position.value == Vec2(30, 40))
        // Opacity sits inside Motion: the one switch turns both off.
        #expect(m.clip!.transform(at: Time(6, 1)).opacity == 1)
        #expect(log.edits.map(\.1) == ["Disable Transform"])  // V1 Quiet: Effect Controls calls the Motion section Transform
        m.resetSection(.motion)
        #expect(m.isEffectEnabled(.motion))
    }

    // MARK: Blend mode

    @Test func blendModeIsOneUndoStep() {
        let (m, log) = rig()
        m.setBlendMode(.multiply)
        #expect(m.blendMode == .multiply && m.clip!.blendMode == .multiply)
        #expect(log.edits.last?.1 == "Change Blend Mode")
        m.setBlendMode(.multiply)
        #expect(log.edits.count == 1)
        m.resetSection(.opacity)
        #expect(m.blendMode == .normal)
    }

    // MARK: Layout

    @Test func blendModeRowSitsUnderOpacity() {
        let rows = EffectControlsLayout.rows(sections: [.opacity], collapsed: [], expanded: [], blendModeRow: true)
        #expect(rows.map(\.kind) == [.section(.opacity), .property(.opacity), .blendMode])
        let none = EffectControlsLayout.rows(sections: [.opacity], collapsed: [], expanded: [])
        #expect(none.count == 2)
    }

    /// One offscreen render of the panel with Crop and two blurs, written to the scratchpad for a look.
    @Test func panelRendersWithEffectsAndBlendRow() throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        _ = clip.addEffect(kind: ClipEffect.cropKind)
        let blur = clip.addEffect(kind: ClipEffect.gaussianBlurKind)!
        clip.setParameter(blur, ClipEffect.blurrinessKey, to: 12)
        _ = clip.addEffect(kind: ClipEffect.gaussianBlurKind)
        clip.blendMode = .multiply
        let m = EffectControlsModel()
        m.setClip(clip)
        let v = EffectControlsView(model: m)
        v.persistLabelWidth = { _ in }
        v.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        v.layoutSubtreeIfNeeded()
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        if let dir = ProcessInfo.processInfo.environment["SQ_SNAPSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("effect-controls-fx.png"))
        }
        #expect(png.count > 1000)
    }
}
