import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// W9.8: Clip > Video Options > Add Subject Mask through the session (one undo step) and the Effect Controls entry.
@MainActor @Suite struct SubjectMaskSessionTests {
    private func makeSession(locked: Bool = false) -> (EditorSession, Clip) {
        let c = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(c)
        v.isLocked = locked
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])
        return (EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine()), c)
    }

    private func live(_ s: EditorSession, _ c: Clip) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == c.id }! }

    @Test func addSubjectMaskIsOneUndoStep() {
        let (ses, c) = makeSession()
        ses.select(clips: [c.id])
        #expect(ses.addSubjectMaskEnabled)
        #expect(ses.addSubjectMask())
        #expect(ses.undoName == "Add Subject Mask")
        #expect(live(ses, c).masks.map(\.source) == [.subject])
        // A second time changes nothing (one subject mask per clip) and is disabled.
        #expect(!ses.addSubjectMaskEnabled)
        #expect(!ses.addSubjectMask())
        ses.undo()
        #expect(live(ses, c).masks.isEmpty)
    }

    @Test func commandIsDisabledOnALockedTrack() {
        let (ses, c) = makeSession(locked: true)
        ses.select(clips: [c.id])
        #expect(!ses.addSubjectMaskEnabled)
        #expect(!ses.addSubjectMask())
    }

    @Test func pasteAttributesOpacityGroupDropsSubjectMaskOnAGenerator() {
        var src = Clip(name: "s", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        src.masks = [ClipMask.makeSubject(name: "Subject"), ClipMask.make(.rectangle, name: "Mask (1)")]
        var gen = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        gen.generator = .solid(rgb: [0, 0, 255])
        #expect(gen.pastingAttributes(from: src, groups: [.opacity]).masks.map(\.source) == [.path])
    }

    @Test func commandIsInTheCatalogAndTheClipMenu() {
        #expect(CommandCatalog.all.contains(.addSubjectMask))
        #expect(EditorCommand.addSubjectMask.title == "Add Subject Mask")
        #expect(CommandSupport.isEffectsLookOp(.addSubjectMask))
        #expect(EditorMenus.menuOnly.contains(.addSubjectMask))
    }
}

/// Effect Controls: the Subject mask entry under Opacity (name, Inverted, Mode, delete).
@MainActor @Suite struct EffectControlsSubjectMaskTests {
    final class Log { var edits: [(Clip, String)] = [] }

    private func rig() -> (EffectControlsModel, Log, ClipMask.ID) {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.masks = [ClipMask.make(.rectangle, name: "Mask (1)"), ClipMask.makeSubject(name: "Subject")]
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, _ in log.edits.append((c, n)) }
        m.setClip(clip)
        return (m, log, clip.masks[1].id)
    }

    @Test func subjectMasksAreListedForTheirRows() {
        let (m, _, id) = rig()
        #expect(m.subjectMaskIDs == [id])
        // Its own section (not under Opacity): name line, Feather / Opacity / Expansion, then its use.
        let rows = EffectControlsLayout.rows(sections: [.motion, .opacity, .mask(id)], collapsed: [], expanded: [], blendModeRow: true,
                                             subjectMasks: m.subjectMaskIDs)
        let kinds = rows.map(\.kind)
        let section = kinds.firstIndex(of: .section(.mask(id)))!
        #expect(kinds[section + 1] == .subjectMask(id))
        #expect(kinds.contains(.property(.mask(id, .feather))))
        #expect(kinds.last == .maskUse(id))
        #expect(!kinds.contains(.maskControls(id)))
        let collapsed = EffectControlsLayout.rows(sections: [.opacity, .mask(id)], collapsed: [.opacity], expanded: [], subjectMasks: [id])
        #expect(collapsed.map(\.kind).contains(.subjectMask(id)))
        #expect(m.visibleSections.contains(.mask(id)))
    }

    @Test func invertModeAndDeleteAreOneEditEach() throws {
        let (m, log, id) = rig()
        m.setMaskInverted(id, true)
        #expect(m.clip!.mask(id)?.inverted == true)
        #expect(log.edits.last?.1 == "Invert Mask")
        m.setMaskMode(id, .subtract)
        #expect(m.clip!.mask(id)?.mode == .subtract)
        #expect(log.edits.last?.1 == "Change Mask Mode")
        let before = log.edits.count
        m.setMaskMode(id, .subtract)               // unchanged: no edit
        #expect(log.edits.count == before)
        m.removeMask(id)
        #expect(m.subjectMaskIDs.isEmpty)
        #expect(m.clip!.masks.count == 1)
    }
}
