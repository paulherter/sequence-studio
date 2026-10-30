import CoreGraphics
import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

/// The Mask tool (Magic / Pen / Ellipse / Rectangle) on the Program monitor, Magic masks in Effect Controls, and a mask as
/// an effect's input (Cuts picture + Use in effects).
@MainActor @Suite struct MaskToolUITests {
    final class Log { var edits: [(Clip, String)] = [] }

    func rig(effects: [ClipEffect] = []) -> (EffectControlsModel, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: Time(10, 1), duration: Time(4, 1)), start: Time(5, 1))
        clip.effects = effects
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, _ in log.edits.append((c, n)) }
        m.setClip(clip); m.playhead = Time(6, 1)
        m.frameDuration = Time(1, 25)
        return (m, log)
    }

    @Test func toolStateKnowsTheMaskModes() {
        var s = ToolState()
        #expect(s.maskMode == .magic)
        s.maskMode = .ellipse
        #expect(MaskToolMode.allCases.map(\.title) == ["Magic", "Pen", "Ellipse", "Rectangle"])
    }

    /// P selects the Mask tool (O stays Mark Out; Shift-P punch-in, Cmd-P poster frame keep their keys).
    @Test func keyPSelectsTheMaskTool() {
        #expect(TimelineTool.mask.key == "p")
        #expect(TimelineTool(key: "p") == .mask)
        #expect(TimelineTool(key: "o") == nil)
        let map = CommandMap.premiereDefault
        #expect(map.duplicates.isEmpty)
        #expect(map.command(for: KeyBinding(.char("p")), focus: .timeline) == .tool(.mask))
        #expect(map.command(for: KeyBinding(.char("o")), focus: .timeline) == .markOut)
        #expect(map.command(for: KeyBinding(.char("p"), [.shift]), focus: .timeline) == .togglePunchIn)
        #expect(ToolStripView.editorTool(.mask) == .mask)
        #expect(EditorCommand.tool(.mask).title == "Mask Tool")
    }

    @Test func magicClicksMakeOneMaskAddAndSubtractAndShiftStartsANewOne() throws {
        let (m, log) = rig()
        let a = try #require(m.maskToolClick(.magic, at: Vec2(0.3, 0.4), subtract: false, newMask: false))
        #expect(m.selectedSection == .mask(a) && m.activeMagicMaskID == a)
        let mk = try #require(m.clip?.mask(a))
        #expect(mk.source == .magic && mk.magic?.points.count == 1)
        // Source frame of the click: playhead 6 s, clip at 5 s, source starts at 10 s.
        #expect(mk.magic?.anchorTime == Time(11, 1))
        _ = m.maskToolClick(.magic, at: Vec2(0.6, 0.4), subtract: false, newMask: false)
        _ = m.maskToolClick(.magic, at: Vec2(0.7, 0.4), subtract: true, newMask: false)
        #expect(m.clip?.mask(a)?.magic?.points.map(\.subtract) == [false, false, true])
        let b = try #require(m.maskToolClick(.magic, at: Vec2(0.1, 0.1), subtract: false, newMask: true))
        #expect(b != a && m.clip?.masks.count == 2 && m.activeMagicMaskID == b)
        #expect(log.edits.count == 4)
        // Magic masks show as Effect Controls sections and their numbers are properties.
        #expect(m.visibleSections.contains(.mask(a)))
        #expect(EffectControlsModel.allProperties(in: m.clip!).contains(.mask(a, .feather)))
    }

    /// A click on another frame corrects the pick there: its point is stored at the clip's (rational) source time of the
    /// playhead's frame, the pick's frame stays.
    @Test func magicClickOnAnotherFrameIsACorrection() throws {
        let (m, _) = rig()
        let a = try #require(m.maskToolClick(.magic, at: Vec2(0.3, 0.4), subtract: false, newMask: false))
        #expect(!m.magicClickCorrects(a))
        m.playhead = Time(7, 1)
        #expect(m.magicClickCorrects(a))
        _ = m.maskToolClick(.magic, at: Vec2(0.7, 0.4), subtract: true, newMask: false)
        let points = try #require(m.clip?.mask(a)?.magic?.points)
        #expect(points.map(\.sourceTime) == [Time(11, 1), Time(12, 1)])
        #expect(m.clip?.mask(a)?.magic?.anchorTime == Time(11, 1))
    }

    /// The host stores the matte before the click is applied: the preview changes nothing, applying it is one edit.
    @Test func aMagicClickEditChangesNothingUntilItIsApplied() throws {
        let (m, log) = rig()
        let a = try #require(m.maskToolClick(.magic, at: Vec2(0.3, 0.4), subtract: false, newMask: false))
        m.playhead = Time(7, 1)
        let before = m.clip
        let e = try #require(m.magicClickEdit(at: Vec2(0.7, 0.4), subtract: true, newMask: false))
        #expect(e.mask == a && e.points.count == 2 && e.key != m.magicCacheKey(a))
        #expect(m.clip == before && log.edits.count == 1)
        #expect(m.applyMagicClick(e) == a)
        #expect(m.clip?.mask(a)?.magic?.points.count == 2 && log.edits.count == 2)
        #expect(m.magicCacheKey(a) == e.key)
        #expect(m.magicClickEdit(at: Vec2(0.3, 0.4), subtract: true, newMask: true) == nil)     // nothing to remove from
    }

    @Test func subtractWithoutAPickDoesNothing() {
        let (m, log) = rig()
        #expect(m.maskToolClick(.magic, at: Vec2(0.3, 0.4), subtract: true, newMask: false) == nil)
        #expect(log.edits.isEmpty)
    }

    @Test func clickOutsideTheClipDoesNothing() {
        let (m, log) = rig()
        m.playhead = Time(20, 1)
        #expect(m.maskToolClick(.magic, at: Vec2(0.3, 0.4), subtract: false, newMask: false) == nil)
        #expect(log.edits.isEmpty)
    }

    @Test func penAndShapeClicks() throws {
        let (m, _) = rig()
        let p = try #require(m.maskToolClick(.pen, at: Vec2(0.1, 0.1), subtract: false, newMask: false))
        _ = m.maskToolClick(.pen, at: Vec2(0.5, 0.1), subtract: false, newMask: false)
        _ = m.maskToolClick(.pen, at: Vec2(0.3, 0.5), subtract: false, newMask: false)
        #expect(m.clip?.mask(p)?.path.value.vertices.count == 3 && m.clip?.masks.count == 1)
        let e = try #require(m.maskToolClick(.ellipse, at: Vec2(0.25, 0.25), subtract: false, newMask: false))
        #expect(m.clip?.mask(e)?.kind == .ellipse && m.selectedSection == .mask(e))
        let r = try #require(m.maskToolClick(.rectangle, at: Vec2(0.5, 0.5), subtract: false, newMask: false))
        #expect(m.clip?.mask(r)?.kind == .rectangle && m.clip?.masks.count == 3)
    }

    @Test func maskUseCutsPictureAndFeedsEffects() throws {
        let blur = ClipEffect(kind: ClipEffect.gaussianBlurKind)
        let (m, log) = rig(effects: [blur])
        let a = try #require(m.maskToolClick(.ellipse, at: Vec2(0.5, 0.5), subtract: false, newMask: false))
        #expect(m.maskInputChoices(a).map(\.on) == [false])
        m.setMask(a, input: true, ofEffect: blur.id)
        #expect(m.clip?.effects[0].maskInput == [a] && m.maskInputChoices(a).first?.on == true)
        m.setMask(a, usedByOpacity: false)
        #expect(m.clip?.mask(a)?.usedByOpacity == false)
        #expect(log.edits.last?.1 == "Mask Cuts Picture")
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: []).map(\.kind)
        #expect(rows.contains(.maskUse(a)))
        // Deleting the mask drops it from the effect's input.
        m.removeMask(a)
        #expect(m.clip?.effects[0].maskInput == [])
    }

    @Test func magicTrackRangeRunsFromThePlayheadToTheClipEdge() throws {
        let (m, _) = rig()
        let a = try #require(m.maskToolClick(.magic, at: Vec2(0.3, 0.4), subtract: false, newMask: false))
        let fw = try #require(m.magicTrackRange(a, forward: true))
        #expect(abs(fw.from - 11) < 1e-9 && abs(fw.to - (14 - 0.04)) < 1e-9)
        let bw = try #require(m.magicTrackRange(a, forward: false))
        #expect(abs(bw.from - 11) < 1e-9 && abs(bw.to - 10) < 1e-9)
        #expect(m.magicCacheKey(a) == m.clip?.mask(a)?.magic?.cacheKey(media: m.clip!.media))
    }

    @Test func magicSessionHighlightsThePointedObjectAndPicks() async throws {
        let media = UUID()
        var l = [UInt8](repeating: 0, count: 20 * 10)
        for y in 2..<8 { for x in 2..<8 { l[y * 20 + x] = 1 } }
        let frame = InstanceFrame(labels: InstanceLabels(width: 20, height: 10, labels: l))
        let s = MagicMaskSession { _, seconds in (frame, seconds) }
        await s.prepare(media: media, url: URL(fileURLWithPath: "/x.mov"), sourceTime: Time(1, 1))
        #expect(s.isReady(media: media, sourceTime: Time(1, 1)))
        let hit = try #require(s.hover(at: Vec2(0.25, 0.5)))
        #expect(hit.label == 1 && hit.matte[4, 4] == 1 && hit.matte[15, 4] == 0)
        #expect(s.hover(at: Vec2(0.9, 0.5)) == nil)
        let store = MagicMatteStore(directory: nil)
        let pts = [MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: Time(1, 1))]
        #expect(await s.pick(points: pts, key: "k", store: store) == .stored)
        #expect(store.matte(key: "k", pts: 1) != nil)
        #expect(MagicHighlight.image(hit.matte) != nil)
    }
}
