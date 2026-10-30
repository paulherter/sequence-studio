import AppKit
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                     tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}

@MainActor @Suite struct ShapeSessionTests {
    @Test func addShapeAtPlayheadSelectsItAndIsOneUndoStep() throws {
        let session = makeSession()
        let depth = session.undoDepth
        let id = try #require(session.addShapeClip(.ellipse))
        #expect(session.undoDepth == depth + 1)
        #expect(session.selection == [id])
        let c = try #require(session.singleSelectedClip)
        #expect(c.generator?.shapeKind == .ellipse)
        #expect(c.timeline.start == .zero && c.timeline.duration == s(5))
        #expect(ClipSectionMode.resolve(c) == .shape)
        #expect(ClipSectionMode.shape.title == "Shape")
    }

    @Test func secondShapeGoesToAFreeTrack() throws {
        let session = makeSession()
        let a = try #require(session.addShapeClip(.rectangle))
        let b = try #require(session.addShapeClip(.line))
        let tl = try #require(session.activeTimeline)
        let ta = tl.tracks.first { $0.clips.contains { $0.id == a } }!.id
        let tb = tl.tracks.first { $0.clips.contains { $0.id == b } }!.id
        #expect(ta != tb)
    }

    @Test func shapeSectionShowsAndSwitchesTheOutline() throws {
        let session = makeSession()
        let view = ClipSectionsView(session: session)
        let id = try #require(session.addShapeClip(.ellipse))
        view.sync([.project, .selection])
        #expect(view.mode == .shape)
        #expect(view.preferredHeight(for: 300) > ClipSectionsView.headerHeight)
        #expect(view.shapeView.kindControl.selectedSegment == ShapeKind.allCases.firstIndex(of: .ellipse))
        view.shapeView.kindControl.selectedSegment = ShapeKind.allCases.firstIndex(of: .line)!
        view.shapeView.kindControl.sendAction(view.shapeView.kindControl.action, to: view.shapeView.kindControl.target)
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.generator?.shapeKind == .line)
    }

    /// Launch cost: the text inspector (170+ views, ~150 ms first layout in Debug) is built on the first text clip only.
    @Test func textInspectorIsBuiltOnFirstTextClipOnly() throws {
        func inspectors(_ v: NSView) -> Int { (v is TextInspectorView ? 1 : 0) + v.subviews.reduce(0) { $0 + inspectors($1) } }
        let session = makeSession()
        let view = ClipSectionsView(session: session)
        #expect(inspectors(view) == 0)
        _ = try #require(session.addShapeClip(.ellipse))
        view.sync([.project, .selection])
        #expect(inspectors(view) == 0)
        _ = try #require(session.addTextClip(template: TextTemplate(name: "T", text: "Hi", style: TextStyle(fontName: "Helvetica", size: 80, color: .white))))
        view.sync([.project, .selection])
        #expect(view.mode == .text)
        #expect(inspectors(view) == 1)
        #expect(view.preferredHeight(for: 300) > ClipSectionsView.headerHeight + 100)
        _ = try #require(session.addShapeClip(.line))
        view.sync([.project, .selection])
        #expect(inspectors(view) == 1)     // built once, then only hidden
    }

    @Test func changeKindKeepsLookAndIsUndoable() throws {
        let session = makeSession()
        let id = try #require(session.addShapeClip(.rectangle))
        let effects = session.singleSelectedClip?.effects
        session.setShapeKind(.ellipse, for: id)
        #expect(session.singleSelectedClip?.generator?.shapeKind == .ellipse)
        #expect(session.singleSelectedClip?.effects == effects)
        _ = session.undo()
        #expect(session.singleSelectedClip?.generator?.shapeKind == .rectangle)
    }

    @Test func sessionRefusesToAddAShapeEffect() throws {
        let session = makeSession()
        let id = try #require(session.addShapeClip(.rectangle))
        #expect(!session.addEffect(kind: ClipEffect.shapeEffectKind, to: [id]))
        #expect(session.singleSelectedClip?.effects.filter { $0.kind == ClipEffect.shapeEffectKind }.count == 1)
    }

    @Test func shapeSectionCannotBeRemovedDuplicatedOrPastedElsewhere() throws {
        let session = makeSession()
        let id = try #require(session.addShapeClip(.rectangle))
        var shape = try #require(session.singleSelectedClip)
        let sid = shape.effects.first { $0.kind == ClipEffect.shapeEffectKind }!.id
        shape.setParameter(sid, ClipEffect.shapeWidthKey, to: 77)
        let m = EffectControlsModel()
        m.setClip(shape)
        let sec = try #require(m.visibleSections.first { $0.effectID == sid })
        #expect(!m.canRemoveEffect(sec))
        #expect(!m.removeEffect(sec))
        #expect(!m.cutEffect(sec))
        #expect(!m.duplicateEffect(sec))
        m.selectedSection = sec
        #expect(!m.canCutFocused)
        #expect(m.canCopyFocused && m.canCopyEffect(sec))

        // Copy, then paste onto a plain video clip: refused.
        #expect(m.copyEffect(sec))
        let plain = Clip(name: "c", media: UUID(), kind: .video,
                         source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        m.setClip(plain)
        #expect(!m.canPasteEffect && !m.pasteEffect())

        // Onto another shape: replaces its one Shape effect.
        var edited: Clip?
        m.onEdit = { c, _, _ in edited = c }
        let other = try #require(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id })
        m.setClip(other)
        #expect(m.canPasteEffect && m.pasteEffect())
        let shapes = edited?.effects.filter { $0.kind == ClipEffect.shapeEffectKind } ?? []
        #expect(shapes.count == 1 && shapes.first?.parameters[ClipEffect.shapeWidthKey]?.value == 77)
    }
}
