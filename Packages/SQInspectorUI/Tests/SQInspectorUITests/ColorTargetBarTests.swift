import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Color target bar (variant E step 1): target resolution, the Linked switch and the Timeline grade in the session.
@MainActor @Suite struct ColorTargetBarTests {
    static let fd = Time(1, 30)

    /// V1: A, B (media m), C (other media); A1: an audio clip linked to A.
    func rig() throws -> (EditorSession, a: Clip, b: Clip, c: Clip, au: Clip) {
        let m = UUID(), link = UUID()
        func clip(_ n: String, _ media: UUID, _ at: Int64, _ kind: TrackKind = .video, link: UUID? = nil) -> Clip {
            Clip(name: n, media: media, kind: kind, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(at, 1), link: link)
        }
        let a = clip("A", m, 0, link: link), b = clip("B", m, 2), c = clip("C", UUID(), 4), au = clip("A audio", m, 0, .audio, link: link)
        var v = Track(kind: .video), au1 = Track(kind: .audio)
        try v.overwrite(a); try v.overwrite(b); try v.overwrite(c); try au1.overwrite(au)
        let t = Timeline(name: "Main", frameDuration: Self.fd, tracks: [v, au1])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        return (s, a, b, c, au)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }
    func exposure(_ s: EditorSession, _ id: Clip.ID) -> Float { current(s, id).color.effects[0].basic.exposure }

    // MARK: Target resolution

    @Test func selectionPicksAndEmptySelectionKeepsThePick() throws {
        let (s, a, b, _, au) = try rig()
        var st = ColorTargetState()
        st.selectionChanged([b.id], in: s.activeTimeline)
        #expect(st.resolve(in: s.activeTimeline) == .clip(b.id))
        st.selectionChanged([], in: s.activeTimeline)
        #expect(st.resolve(in: s.activeTimeline) == .clip(b.id))
        // A video clip with its linked audio is one clip.
        st.selectionChanged([a.id, au.id], in: s.activeTimeline)
        #expect(st.resolve(in: s.activeTimeline) == .clip(a.id))
    }

    @Test func audioMultiSelectAndTextExplainThemselves() throws {
        let (s, a, b, _, au) = try rig()
        var st = ColorTargetState()
        st.selectionChanged([au.id], in: s.activeTimeline)
        #expect(st.resolve(in: s.activeTimeline) == .message(ColorTargetState.audioNotice))
        st.selectionChanged([a.id, b.id], in: s.activeTimeline)
        #expect(st.resolve(in: s.activeTimeline) == .message(ColorTargetState.multiNotice(2)))
        // A list pick ends the notice.
        st.listPicked(b.id)
        #expect(st.resolve(in: s.activeTimeline) == .clip(b.id))
        // Nothing picked or selected: the Whole Sequence is the visible default target (no layer until the first edit).
        let tl = try #require(s.activeTimelineID)
        #expect(ColorTargetState().resolve(in: s.activeTimeline) == .sequence(tl, layer: nil))
    }

    @Test func defaultWholeSequenceTargetEditCreatesTheLayerOnFirstChange() throws {
        let (s, _, _, _, _) = try rig()
        #expect(s.activeTimeline?.sequenceGradeClip == nil)
        let tl = try #require(s.activeTimelineID)
        #expect(ColorTargetState().resolve(in: s.activeTimeline) == .sequence(tl, layer: nil))
        let changed = s.editSequenceGrade(continuesGesture: false) { c in c.setSharpenAmount(20) }
        #expect(changed)
        let layer = try #require(s.activeTimeline?.sequenceGradeClip)
        #expect(layer.sharpenAmount == 20)
        #expect(ColorTargetState().resolve(in: s.activeTimeline) == .sequence(tl, layer: layer.id))
    }

    @Test func sharpenRowReportsClampedValuesOnce() {
        let m = ColorInspectorModel()
        var seen: [Float] = []
        m.onSharpenSet = { seen.append($0) }
        m.setSharpen(20); m.setSharpen(20); m.setSharpen(250)
        #expect(seen == [20, 100])
        m.loadSharpen(5)
        #expect(m.sharpen == 5 && seen.count == 2)
    }

    @Test func sharpenAmountWritesOneSharpenEffect() {
        var c = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        #expect(c.sharpenAmount == 0)
        let step0 = c.setSharpenAmount(0); #expect(!step0)                       // nothing to add for 0
        let step1 = c.setSharpenAmount(20); #expect(step1)
        let step2 = c.setSharpenAmount(35); #expect(step2)
        #expect(c.effects.filter { $0.kind == ClipEffect.sharpenKind }.count == 1)
        #expect(c.sharpenAmount == 35)
        let step3 = c.setSharpenAmount(35); #expect(!step3)
        let step4 = c.setSharpenAmount(0); #expect(step4)                        // back to 0: the effect stays at 0 (does nothing)
        #expect(c.sharpenAmount == 0)
    }

    @Test func timelineModeTargetsTheSequenceAndItsLayerOnceItExists() throws {
        let (s, _, _, _, _) = try rig()
        let tl = try #require(s.activeTimelineID)
        var st = ColorTargetState()
        st.wholeSequencePicked()
        #expect(st.resolve(in: s.activeTimeline) == .sequence(tl, layer: nil))
        #expect(s.editSequenceGrade(continuesGesture: false) { c in
            var col = c.color; col.effects[0].basic.exposure = 0.5; c.color = col; return true
        })
        let layer = try #require(s.activeTimeline?.sequenceGradeClip)
        #expect(st.resolve(in: s.activeTimeline) == .sequence(tl, layer: layer.id))
        // Selecting the layer in the timeline targets the whole sequence; the list does not show it as a source.
        st.listPicked(try #require(s.activeTimeline?.tracks.first?.clips.first?.id))
        #expect(!st.wholeSequence)
        st.selectionChanged([layer.id], in: s.activeTimeline)
        #expect(st.wholeSequence)
        #expect(!ColorSourceListItem.items(s.activeTimeline).contains { $0.clips.contains(layer.id) })
    }

    @Test func onScreenHintNamesTheClipUnderThePlayhead() throws {
        let (s, a, b, _, _) = try rig()
        #expect(ColorTargetState.onScreenHint(target: .clip(a.id), timeline: s.activeTimeline, playhead: Time(1, 1)) == nil)
        #expect(ColorTargetState.onScreenHint(target: .clip(a.id), timeline: s.activeTimeline, playhead: Time(3, 1)) == "On screen: \(b.name)")
        #expect(ColorTargetState.onScreenHint(target: .clip(a.id), timeline: s.activeTimeline, playhead: Time(30, 1)) == "On screen: no clip")
    }

    // MARK: Linked edits

    @Test func aLinkedEditGradesTheWholeSourceInOneUndoStep() throws {
        let (s, a, b, c, _) = try rig()
        #expect(s.editClipColor(a.id, continuesGesture: false) { clip in
            var col = clip.color; col.effects[0].basic.exposure = 1; clip.color = col; return true
        })
        #expect(exposure(s, a.id) == 1 && exposure(s, b.id) == 1)
        #expect(current(s, c.id).colorGradeEffects.isEmpty)
        s.undo()
        #expect(current(s, a.id).colorGradeEffects.isEmpty && current(s, b.id).colorGradeEffects.isEmpty)
        #expect(current(s, a.id).gradeLink == nil, "the link formed in the same step")
    }

    @Test func linkedOffEditsOnlyTheClipAndOnAgainRelinks() throws {
        let (s, a, b, _, _) = try rig()
        func set(_ id: Clip.ID, _ v: Float) {
            s.editClipColor(id, continuesGesture: false) { clip in
                var col = clip.color; col.effects[0].basic.exposure = v; clip.color = col; return true
            }
        }
        set(a.id, 1)
        #expect(s.setGradeLinkedToSource(b.id, false))
        #expect(s.undoName == "Unlink Grade")
        #expect(!s.setGradeLinkedToSource(b.id, false))
        set(b.id, 3)
        #expect(exposure(s, a.id) == 1 && exposure(s, b.id) == 3)
        #expect(s.setGradeLinkedToSource(b.id, true))
        #expect(exposure(s, b.id) == 1, "relinked to the shared grade")
        s.undo()
        #expect(exposure(s, b.id) == 3)
    }

    @Test func aRefusedEditChangesNothing() throws {
        let (s, a, b, _, _) = try rig()
        let before = s.project
        #expect(!s.editClipColor(a.id, continuesGesture: false) { _ in false })
        #expect(s.project == before)
        #expect(current(s, b.id).gradeLink == nil)
    }

    // MARK: Timeline grade

    @Test func theTimelineGradeLayerIsCreatedOnceAndUndoable() throws {
        let (s, a, _, _, _) = try rig()
        let tracks = s.activeTimeline!.tracks.count
        for v in [Float(0.2), 0.4] {
            s.editSequenceGrade(continuesGesture: false) { c in
                var col = c.color; col.effects[0].basic.exposure = v; c.color = col; return true
            }
        }
        let t = try #require(s.activeTimeline)
        #expect(t.tracks.count == tracks + 1)
        let layer = try #require(t.sequenceGradeClip)
        #expect(layer.color.effects[0].basic.exposure == 0.4)
        #expect(current(s, a.id).colorGradeEffects.isEmpty, "clips keep their own grade")
        s.undo(); s.undo()
        #expect(s.activeTimeline?.sequenceGradeClip == nil)
        #expect(s.activeTimeline?.tracks.count == tracks)
    }

    // MARK: Panel

    @Test func thePanelEditsThePickedClipAndTheTimeline() throws {
        let (s, a, b, _, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        panel.pick(b.id)
        #expect(s.selection == [b.id], "a list pick selects the clip in the timeline")
        #expect(s.playhead == Time(2, 1), "and moves the playhead onto it")
        let model = try #require(panel.colorModels[b.id])
        model.gesture { model.set(1, .exposure, 1.5) }
        #expect(exposure(s, b.id) == 1.5 && exposure(s, a.id) == 1.5)
        panel.pickWholeSequence()
        let tl = try #require(s.activeTimelineID)
        let tm = try #require(panel.colorModels[tl])
        tm.gesture { tm.set(1, .exposure, -0.5) }
        #expect(s.activeTimeline?.sequenceGradeClip?.color.effects[0].basic.exposure == -0.5)
        #expect(exposure(s, b.id) == 1.5)
    }

    // MARK: Review fixes

    @Test func pasteOntoALinkedClipGradesItsSourceAndStaysLinked() throws {
        let (s, a, b, c, _) = try rig()
        var donor = current(s, c.id)
        var col = donor.color; col.effects[0].basic.exposure = 2; donor.color = col
        #expect(s.pasteColor(effects: donor.colorGradeEffects, to: [a.id]) == 1)
        #expect(exposure(s, a.id) == 2 && exposure(s, b.id) == 2)
        #expect(s.project.isGradeLinkedToSource(a.id) && s.project.isGradeLinkedToSource(b.id))
        s.undo()
        #expect(current(s, a.id).colorGradeEffects.isEmpty && current(s, b.id).colorGradeEffects.isEmpty)
    }

    @Test func resetOfALinkedClipResetsItsSourceAndStaysLinked() throws {
        let (s, a, b, _, _) = try rig()
        s.editClipColor(a.id, continuesGesture: false) { clip in
            var col = clip.color; col.effects[0].basic.exposure = 1; clip.color = col; return true
        }
        #expect(s.resetColor(of: b.id))
        #expect(current(s, a.id).colorGradeEffects.isEmpty && current(s, b.id).colorGradeEffects.isEmpty)
        #expect(s.project.isGradeLinkedToSource(a.id))
        #expect(!s.resetColor(of: b.id), "nothing left to reset")
    }

    @Test func unlinkGradesKeepsTheNextEditAlone() throws {
        let (s, a, b, _, _) = try rig()
        s.editClipColor(a.id, continuesGesture: false) { clip in
            var col = clip.color; col.effects[0].basic.exposure = 1; clip.color = col; return true
        }
        #expect(s.unlinkGrades([b.id]))
        s.editClipColor(b.id, continuesGesture: false) { clip in
            var col = clip.color; col.effects[0].basic.exposure = 4; clip.color = col; return true
        }
        #expect(exposure(s, a.id) == 1 && exposure(s, b.id) == 4)
    }
}
