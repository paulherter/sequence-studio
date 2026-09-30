import AppKit
import Foundation
import Testing
import SSCore
@testable import SSEditorUI

@MainActor @Suite struct ColorPanelEditTests {
    func rig() throws -> (EditorSession, ColorInspectorPanelView, Clip) {
        let fd = Time(1, 30)
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: fd, tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look"))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        return (session, ColorInspectorPanelView(session: session), clip)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    func basic(_ c: Clip) -> BasicCorrection? {
        if case .basic(let b)? = c.color.sections.first(where: { $0.kind == .basicCorrection })?.params { return b }
        return nil
    }

    @Test func inspectorEditsWriteClipColorAsOneUndoStepPerGesture() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        #expect(model.detectedSource == .sLog3SGamut3Cine && model.embeddedLUTName == "Look")

        // A slider drag: begin, several changes, end = one undo step.
        model.onGestureBegan?()
        model.set(1, .exposure, 0.5); model.set(1, .exposure, 1); model.set(1, .exposure, 1.5)
        model.onGestureEnded?()
        #expect(basic(current(session, clip.id))?.exposure == 1.5)
        #expect(session.undoName == "Color")
        session.undo()
        #expect(basic(current(session, clip.id))?.exposure == 0)
        #expect(!session.canUndo)

        // Popup-style edits are each their own gesture.
        model.gesture { model.setSourceOverride(.rec709) }
        model.setLUT(2, .file("/tmp/x.cube"))
        model.addSection(.creative)
        model.setLUT(3, .file("/tmp/c.cube"))
        model.gesture { model.set(3, .lookIntensity, 40) }
        let c = current(session, clip.id).color
        #expect(c.source == .rec709 && c.sections[1].params == .inputLUT(.file("/tmp/x.cube")))
        guard case .creative(let k) = c.sections[2].params else { Issue.record("creative"); return }
        #expect(k.look == .file("/tmp/c.cube") && k.intensity == 40)
        for _ in 0..<5 { session.undo() }
        #expect(current(session, clip.id).color == .default)
    }

    @Test func undoReloadsTheInspector() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.gesture { model.set(1, .tint, 20) }
        #expect(model.value(1, .tint) == 20)
        session.undo()
        panel.sync([.project])
        #expect(model.value(1, .tint) == 0)
    }

    @Test func reorderingAndWheelsReachTheClip() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.addSection(.wheels)
        model.moveSection(3, to: 0)
        model.setWheel(3, .shadows, hue: 200, amount: 0.5)
        model.setWheelLuma(3, .midtones, 30)
        let c = current(session, clip.id).color
        #expect(c.sections.map(\.kind) == [.wheels, .basicCorrection, .inputLUT])
        guard case .wheels(let w) = c.sections[0].params else { Issue.record("wheels"); return }
        #expect(w.shadows == WheelValue(hue: 200, amount: 0.5) && w.midtonesLuma == 30)
    }

    @Test func engineReceivesEditedColor() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.gesture { model.set(1, .saturation, 50) }
        let stub = try #require(session.engine as? StubProgramEngine)
        #expect(stub.timeline?.tracks[0].clips[0].color.sections[0].params == .basic({ var b = BasicCorrection(); b.saturation = 50; return b }()))
    }

    @Test func resettingDefaultsIsNotAnUndoStep() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        for s in model.sections { model.resetSection(s.id) }
        model.resetAll()
        #expect(!session.canUndo)
        #expect(current(session, clip.id).color == .default)
        // A real edit, then reset: back to the default, two steps.
        model.setLUT(2, nil)
        #expect(current(session, clip.id).color.sections[1].params == .inputLUT(nil))
        model.resetSection(2)
        #expect(current(session, clip.id).color == .default)
    }

    @Test func viewBuildsEveryBlockKindAndFollowsStructureEdits() throws {
        let m = ColorInspectorModel()
        m.recents = RecentLUTs(defaults: UserDefaults(suiteName: "ColorPanelEditTests-\(UUID())")!)
        let view = ColorInspectorView(model: m)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
        for k in ColorSectionKind.addable { m.addSection(k) }
        view.refresh()
        view.layoutSubtreeIfNeeded()
        let stack = try #require(findSubview(view, ofType: ColorSectionsStack.self))
        #expect(stack.arrangedSubviews.count == 7)
        // Collapsing hides the body; reordering rebuilds in the new order.
        m.setCollapsed(1, true)
        view.refresh()
        m.moveSection(m.sections.last!.id, to: 0)
        view.refresh()
        view.layoutSubtreeIfNeeded()
        #expect((stack.arrangedSubviews.first as? ColorSectionView)?.kind == .vignette)
        let basic = try #require(stack.arrangedSubviews.compactMap { $0 as? ColorSectionView }.first { $0.section == 1 })
        #expect(basic.body.isHidden)
        // A slider edit reaches the model; a double-click-style reset goes back to the default.
        let opened = try #require(stack.arrangedSubviews.compactMap { $0 as? ColorSectionView }.first { $0.kind == .vignette })
        let row = try #require(opened.rows[.vignetteAmount])
        row.onBegin?(); row.onSet?(-2); row.onEnd?()
        #expect(m.value(opened.section, .vignetteAmount) == -2)
        row.onReset?()
        #expect(m.value(opened.section, .vignetteAmount) == 0)
        m.removeSection(opened.section)
        view.refresh()
        #expect(stack.arrangedSubviews.count == 6)
    }

    private func findSubview<T: NSView>(_ v: NSView, ofType: T.Type) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let f = findSubview(s, ofType: T.self) { return f } }
        return nil
    }
}
