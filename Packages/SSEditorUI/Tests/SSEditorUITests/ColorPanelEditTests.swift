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

    func basic(_ c: Clip) -> BasicCorrection { c.color.effects[0].basic }

    @Test func inspectorEditsWriteClipColorAsOneUndoStepPerGesture() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        #expect(model.detectedSource == .sLog3SGamut3Cine && model.embeddedLUTName == "Look")

        // A slider drag: begin, several changes, end = one undo step.
        model.onGestureBegan?()
        model.set(1, .exposure, 0.5); model.set(1, .exposure, 1); model.set(1, .exposure, 1.5)
        model.onGestureEnded?()
        #expect(basic(current(session, clip.id)).exposure == 1.5)
        #expect(session.undoName == "Color")
        session.undo()
        #expect(basic(current(session, clip.id)).exposure == 0)
        #expect(!session.canUndo)

        // Popup-style edits are each their own gesture.
        model.gesture { model.setSourceOverride(.rec709) }
        model.setLUT(1, .input, .file("/tmp/x.cube"))
        model.setLUT(1, .look, .file("/tmp/c.cube"))
        model.gesture { model.set(1, .lookIntensity, 40) }
        let c = current(session, clip.id).color
        #expect(c.source == .rec709 && c.effects[0].inputLUT == .file("/tmp/x.cube"))
        #expect(c.effects[0].creative.look == .file("/tmp/c.cube") && c.effects[0].creative.intensity == 40)
        for _ in 0..<4 { session.undo() }
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

    @Test func secondEffectAndWheelsReachTheClip() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.addEffect()
        model.setWheel(2, .shadows, hue: 200, amount: 0.5)
        model.setWheelLuma(2, .midtones, 30)
        let c = current(session, clip.id).color
        #expect(c.effects.map(\.id) == [1, 2])
        #expect(c.effects[1].wheels.shadows == WheelValue(hue: 200, amount: 0.5) && c.effects[1].wheels.midtonesLuma == 30)
        session.undo(); session.undo(); session.undo()
        #expect(current(session, clip.id).color == .default)
    }

    @Test func engineReceivesEditedColor() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.gesture { model.set(1, .saturation, 50) }
        let stub = try #require(session.engine as? StubProgramEngine)
        #expect(stub.timeline?.tracks[0].clips[0].color.effects[0].basic.saturation == 50)
    }

    @Test func resettingDefaultsIsNotAnUndoStep() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        for k in ColorSectionKind.allCases { model.resetSection(1, k) }
        model.resetAll()
        #expect(!session.canUndo)
        #expect(current(session, clip.id).color == .default)
        // A real edit, then reset: back to the default, two steps.
        model.setLUT(1, .input, nil)
        #expect(current(session, clip.id).color.effects[0].inputLUT == nil)
        model.resetSection(1, .basicCorrection)
        #expect(current(session, clip.id).color == .default)
    }

    @Test func viewBuildsEverySectionAndFollowsEdits() throws {
        let m = ColorInspectorModel()
        m.recents = RecentLUTs(defaults: UserDefaults(suiteName: "ColorPanelEditTests-\(UUID())")!)
        let view = ColorInspectorView(model: m)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 1400)
        view.refresh()
        view.layoutSubtreeIfNeeded()
        let sections = allSections(view)
        #expect(sections.map(\.kind) == ColorSectionKind.allCases, "fixed sections in fixed order")
        let basic = try #require(sections.first { $0.kind == .basicCorrection })
        let vignette = try #require(sections.first { $0.kind == .vignette })
        #expect(!basic.body.isHidden && vignette.body.isHidden, "Basic Correction open, Vignette closed by default")
        #expect(basic.groups.keys.sorted() == ["Color", "Light"])
        #expect(basic.lutPopups[.input]?.titleOfSelectedItem == "Automatic")
        // Opening a section and editing a slider reaches the model; double-click-style reset goes back.
        m.setCollapsed(ColorPanelKey(1, .vignette), false)
        view.refresh()
        #expect(!vignette.body.isHidden)
        let row = try #require(vignette.rows[.vignetteAmount])
        row.onBegin?(); row.onSet?(-2); row.onEnd?()
        view.refresh()
        #expect(m.value(1, .vignetteAmount) == -2 && row.slider.value == -2)
        row.onReset?()
        #expect(m.value(1, .vignetteAmount) == 0)
        // Scrubbing / typing in the value field is one gesture and reaches the model.
        row.field.onBegin?(); row.field.onChange?(1.5); row.field.onEnd?(1.5)
        #expect(m.value(1, .vignetteAmount) == 1.5)
        // The switch disables the section; HSL Secondary is a disabled placeholder.
        let toggle = basic.header.toggle
        toggle.state = .off
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        #expect(!m.isEnabled(1, .basicCorrection))
        let hsl = try #require(sections.first { $0.kind == .hslSecondary })
        #expect(!hsl.header.toggle.isEnabled)
        // A second effect appends another full set of sections.
        m.addEffect()
        view.refresh()
        #expect(allSections(view).count == 2 * ColorSectionKind.allCases.count)
        m.removeEffect(2)
        view.refresh()
        #expect(allSections(view).count == ColorSectionKind.allCases.count)
    }

    @Test func temperatureAndTintSlidersHaveColouredTracks() throws {
        let m = ColorInspectorModel()
        let view = ColorInspectorView(model: m)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 1400)
        view.refresh()
        let basic = try #require(allSections(view).first { $0.kind == .basicCorrection })
        #expect(basic.rows[.temperature]?.slider.track == .temperature)
        #expect(basic.rows[.tint]?.slider.track == .tint)
        #expect(basic.rows[.contrast]?.slider.track == .plain)
        // Slider maths: click position -> value, quantised to the row's precision, clamped.
        let s = try #require(basic.rows[.exposure]?.slider)
        s.frame = NSRect(x: 0, y: 0, width: 206, height: 18)
        #expect(s.value(atX: s.knobX(1.25)) == 1.25)
        #expect(s.value(atX: -50) == -5 && s.value(atX: 999) == 5)
    }

    private func allSections(_ v: NSView) -> [ColorSectionView] {
        var out: [ColorSectionView] = []
        if let s = v as? ColorSectionView { out.append(s) }
        for sub in v.subviews { out += allSections(sub) }
        return out
    }

    @Test func pasteColorIsOneUndoStepAcrossClipsAndSkipsAudio() throws {
        let fd = Time(1, 30)
        let m = UUID()
        func clip(_ n: String, _ at: Int64, _ kind: TrackKind = .video) -> Clip {
            Clip(name: n, media: m, kind: kind, source: TimeRange(start: .zero, duration: Time(1, 1)), start: Time(at, 1))
        }
        let a = clip("A", 0), b = clip("B", 1), c = clip("C", 2), au = clip("Au", 0, .audio)
        var v = Track(kind: .video), au1 = Track(kind: .audio)
        try v.overwrite(a); try v.overwrite(b); try v.overwrite(c); try au1.overwrite(au)
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "M", frameDuration: fd, tracks: [v, au1])]),
                                    engine: StubProgramEngine())
        var graded = ClipColor.default
        graded.effects[0].basic.exposure = 1.5
        graded.effects[0].vignette.amount = -2
        session.select(clips: [b.id, c.id, au.id])
        #expect(session.pasteColor(graded) == 2)
        func color(_ id: Clip.ID) -> ClipColor { current(session, id).color }
        #expect(color(a.id) == .default && color(b.id).effects[0].basic.exposure == 1.5 && color(c.id).effects[0].vignette.amount == -2)
        #expect(color(au.id) == .default, "audio clips have no colour")
        #expect(session.undoName == "Paste Colour")
        session.undo()
        #expect(color(b.id) == .default && color(c.id) == .default, "one step for both clips")
        session.redo()
        #expect(color(b.id).effects[0].basic.exposure == 1.5)
        #expect(session.pasteColor(graded) == 0, "pasting the same colour again changes nothing")
    }
}
