import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Mask tool shape drawing (drag = rubber band, one undo step on release), selecting a mask (row or monitor) and deleting
/// the selected mask with Delete / Backspace.
@MainActor @Suite struct MaskDrawSelectTests {
    final class Log { var edits: [(Clip, String, Bool)] = [] }

    func rig() -> (EffectControlsModel, Log) {
        let clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: Time(10, 1), duration: Time(4, 1)), start: Time(5, 1))
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, coalescing in log.edits.append((c, n, coalescing)) }
        m.setClip(clip); m.playhead = Time(6, 1)
        m.frameDuration = Time(1, 25)
        return (m, log)
    }

    private func drawn(_ kind: MaskShapeKind, _ a: Vec2, _ b: Vec2) -> MaskPath {
        MaskShapeDrag(kind: kind, start: a).path(to: b, square: false, fromCenter: false, frame: Vec2(1920, 1080))
    }

    @Test func drawnShapeIsOneUndoStepAndSelected() throws {
        let (m, log) = rig()
        let path = drawn(.rectangle, Vec2(0.1, 0.2), Vec2(0.4, 0.6))
        let id = try #require(m.addDrawnMask(.rectangle, path: path))
        #expect(log.edits.count == 1 && log.edits[0].1 == "Add Mask" && !log.edits[0].2)
        #expect(m.clip?.mask(id)?.path.value == path && m.clip?.mask(id)?.kind == .rectangle)
        #expect(m.selectedSection == .mask(id) && m.activeMaskID == id)
        #expect(m.maskOverlays.first { $0.id == id }?.active == true)
    }

    /// Regression (the maintainer's hang): a second mask while one exists, both drawn; the second becomes the active one and the
    /// first keeps its handles reachable (selecting it from the monitor).
    @Test func secondDrawnMaskWhileOneExists() throws {
        let (m, log) = rig()
        let a = try #require(m.addDrawnMask(.rectangle, path: drawn(.rectangle, Vec2(0.1, 0.1), Vec2(0.3, 0.3))))
        let b = try #require(m.addDrawnMask(.ellipse, path: drawn(.ellipse, Vec2(0.5, 0.5), Vec2(0.8, 0.9))))
        #expect(a != b && m.clip?.masks.count == 2 && log.edits.count == 2)
        #expect(m.activeMaskID == b)
        #expect(m.maskOverlays.map(\.active) == [false, true])
        m.selectMask(a)
        #expect(m.selectedSection == .mask(a) && m.activeMaskID == a && log.edits.count == 2)
        // Both masks render: shapes at the playhead have polygons.
        let shapes = try #require(m.clip).maskShapes(atLocal: Time(1, 1))
        #expect(shapes.count == 2 && shapes.allSatisfy { $0.polygon.count >= 4 })
    }

    @Test func selectedMaskRowIsDeletableWithDelete() throws {
        let (m, log) = rig()
        let a = try #require(m.addDrawnMask(.rectangle, path: drawn(.rectangle, Vec2(0.1, 0.1), Vec2(0.3, 0.3))))
        let b = try #require(m.addDrawnMask(.rectangle, path: drawn(.rectangle, Vec2(0.5, 0.5), Vec2(0.7, 0.7))))
        m.selectEffectHeader(.mask(a))           // click on the mask row
        #expect(m.isSectionSelected(.mask(a)) && !m.isSectionSelected(.mask(b)))
        #expect(m.canDeleteSection(.mask(a)) && m.canCutFocused == false)
        m.deleteSelectionOrEffect()             // Delete / Backspace
        #expect(m.clip?.masks.map(\.id) == [b])
        #expect(log.edits.last?.1 == "Delete Mask" && log.edits.count == 3)
        #expect(m.selectedSection == nil)
        // Nothing selected: Delete does nothing more.
        m.deleteSelectionOrEffect()
        #expect(m.clip?.masks.count == 1 && log.edits.count == 3)
    }

    /// A click inside a mask that is not the active one finds it (the monitor selects it), topmost first.
    @Test func clickInsideAnyMaskFindsTheTopmost() {
        let g = MaskOverlayGeometry(quad: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)])
        let a = MaskOverlay(id: UUID(), path: .rectangle(Vec2(0.1, 0.1), Vec2(0.6, 0.6)), active: true)
        let b = MaskOverlay(id: UUID(), path: .rectangle(Vec2(0.4, 0.4), Vec2(0.9, 0.9)), active: false)
        #expect(g.hitAnyInside(CGPoint(x: 80, y: 80), masks: [a, b]) == 1)
        #expect(g.hitAnyInside(CGPoint(x: 50, y: 50), masks: [a, b]) == 1)   // overlap: the later (top) one
        #expect(g.hitAnyInside(CGPoint(x: 20, y: 20), masks: [a, b]) == 0)
        #expect(g.hitAnyInside(CGPoint(x: 95, y: 5), masks: [a, b]) == nil)
        #expect(g.hitInside(CGPoint(x: 80, y: 80), masks: [a, b]) == nil)    // inside-move stays on the active mask
    }

    /// The session hands every edit back (`setClip` with the same clip): the mask selection survives that, and a click
    /// outside Effect Controls (on the Program monitor) keeps it too, so Delete still finds it.
    @Test func maskSelectionSurvivesTheSessionRoundTripAndClickAway() throws {
        let (m, log) = rig()
        m.onEdit = { [weak m] c, n, co in log.edits.append((c, n, co)); m?.setClip(c) }
        let a = try #require(m.addDrawnMask(.rectangle, path: drawn(.rectangle, Vec2(0.1, 0.1), Vec2(0.3, 0.3))))
        let b = try #require(m.addDrawnMask(.rectangle, path: drawn(.rectangle, Vec2(0.5, 0.5), Vec2(0.7, 0.7))))
        #expect(m.selectedSection == .mask(b) && m.activeMaskID == b)
        m.selectMask(a)
        m.clearRowSelection(keepMask: true)
        #expect(m.selectedSection == .mask(a))
        m.deleteSelectionOrEffect()
        #expect(m.clip?.masks.map(\.id) == [b] && m.selectedSection == nil)
        m.selectEffectHeader(.motion)
        m.clearRowSelection(keepMask: true)
        #expect(m.selectedSection == nil)
    }

    @Test func motionHeaderIsNotDeletable() {
        let (m, _) = rig()
        m.selectEffectHeader(.motion)
        #expect(!m.canDeleteSection(.motion))
        m.deleteSelectionOrEffect()
        #expect(m.clip?.masks.isEmpty == true)
    }
}
