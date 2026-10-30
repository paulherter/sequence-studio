import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI
@testable import SQMonitorUI

/// Redesign round 2 follow-ups: Before | After | Split reaches the Program monitor; "Reset Color Range" in the menu.
@MainActor @Suite struct ColorCompareTests {
    func rig() throws -> (EditorSession, StubProgramEngine, ColorInspectorPanelView, Clip) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1)))]
        let engine = StubProgramEngine()
        let session = EditorSession(project: p, engine: engine)
        session.select(clips: [clip.id])
        return (session, engine, ColorInspectorPanelView(session: session), clip)
    }

    @Test func bypassFollowsTheModeAndTheTarget() {
        let a = UUID(), b = UUID()
        #expect(ColorInspectorPanelView.colorBypass(.after, target: a, linked: [a, b]) == nil)
        #expect(ColorInspectorPanelView.colorBypass(.before, target: nil, linked: []) == nil)
        #expect(ColorInspectorPanelView.colorBypass(.before, target: a, linked: [a, b]) == ColorBypass(clips: [a, b], mode: .before))
        #expect(ColorInspectorPanelView.colorBypass(.split, target: a, linked: []) == ColorBypass(clips: [a], mode: .split))
    }

    @Test func viewerHeaderDrivesTheEngineOnlyOnTheColourPage() throws {
        let (_, engine, panel, clip) = try rig()
        panel.setCompare(.before)
        #expect(engine.colorBypass == nil, "off the Color page the monitor stays graded")
        panel.isOnColorPage = true
        #expect(engine.colorBypass == ColorBypass(clips: [clip.id], mode: .before))
        // The header's segmented control reaches the engine.
        let header = panel.viewerHeader
        #expect(header.compare == .before)
        panel.setCompare(.split)
        #expect(engine.colorBypass?.mode == .split && header.compare == .split)
        panel.setCompare(.after)
        #expect(engine.colorBypass == nil)
        panel.setCompare(.before)
        panel.isOnColorPage = false
        #expect(engine.colorBypass == nil, "leaving the page clears the bypass")
    }

    /// Review finding: the eyedropper and Auto read the monitor picture; Before / Split would count the grade twice.
    @Test func beforeAndSplitBlockTheEyedropperAndAuto() throws {
        let (_, _, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        panel.isOnColorPage = true
        #expect(model.samplingBlock == nil && model.autoToneBlock(1) == nil)
        panel.setCompare(.before)
        #expect(model.samplingBlock == ColorInspectorPanelView.compareBlockReason(.before))
        #expect(model.autoToneBlock(1) == ColorInspectorPanelView.compareBlockReason(.before))
        panel.setCompare(.split)
        #expect(model.samplingBlock == ColorInspectorPanelView.compareBlockReason(.split))
        panel.setCompare(.after)
        #expect(model.samplingBlock == nil)
        // Off the page the monitor is graded, so measuring is fine whatever the header shows.
        panel.setCompare(.before)
        panel.isOnColorPage = false
        #expect(model.samplingBlock == nil)
    }

    /// Round 2 follow-up: a nested-sequence clip selected on the Color page compares its inside (every clip in the
    /// nest, deeper nests too) instead of staying graded.
    @Test func nestedClipSelectionBypassesEverythingInsideTheNest() throws {
        let fd = Time(1, 30)
        let media = UUID()
        let deepClip = Clip(name: "D", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        var dv = Track(kind: .video); try dv.overwrite(deepClip)
        let deep = Timeline(name: "Deep", frameDuration: fd, tracks: [dv])
        let innerClip = Clip(name: "I", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        let deepNest = Clip(name: "DeepNest", media: deep.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                            start: Time(1, 1), sequence: deep.id)
        var iv = Track(kind: .video); try iv.overwrite(innerClip); try iv.overwrite(deepNest)
        let inner = Timeline(name: "Inner", frameDuration: fd, tracks: [iv])
        let nest = Clip(name: "Nest", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, sequence: inner.id)
        var ov = Track(kind: .video); try ov.overwrite(nest)
        let outer = Timeline(name: "Outer", frameDuration: fd, tracks: [ov])
        var p = Project(name: "P", timelines: [outer, inner, deep])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1)))]
        #expect(ColorInspectorPanelView.nestedClips(of: nest, in: p) == [innerClip.id, deepNest.id, deepClip.id])
        #expect(ColorInspectorPanelView.nestedClips(of: innerClip, in: p).isEmpty)

        let engine = StubProgramEngine()
        let session = EditorSession(project: p, engine: engine)
        session.select(clips: [nest.id])
        let panel = ColorInspectorPanelView(session: session)
        panel.isOnColorPage = true
        panel.setCompare(.before)
        #expect(engine.colorBypass == ColorBypass(clips: [innerClip.id, deepNest.id, deepClip.id], mode: .before))
        panel.setCompare(.split)
        #expect(engine.colorBypass?.mode == .split)
        panel.setCompare(.after)
        #expect(engine.colorBypass == nil)
        // "Whole sequence" targeted with no grade layer yet: the nest selected in the timeline is not the target.
        panel.setCompare(.before)
        panel.pickWholeSequence()
        session.select(clips: [nest.id])
        #expect(panel.resolution == .sequence(outer.id, layer: nil))
        #expect(engine.colorBypass == nil, "the inside of a selected nest is bypassed only while its notice shows")
    }

    /// Round 2 follow-up: Split draws a divider on the monitor at the split column.
    @Test func splitShowsTheDividerOnTheMonitor() throws {
        let (_, _, panel, _) = try rig()
        var shown: [Bool] = []
        panel.onSplitShownChange = { shown.append($0) }
        panel.setCompare(.split)
        #expect(shown.isEmpty, "off the page nothing is split")
        panel.setCompare(.before)
        panel.isOnColorPage = true
        #expect(shown.isEmpty)
        panel.setCompare(.split)
        panel.setCompare(.after)
        #expect(shown == [true, false])
        panel.setCompare(.split)
        panel.isOnColorPage = false
        #expect(shown == [true, false, true, false] && !panel.splitShown)

        let surface = ProgramSurfaceView(viewer: NSView())
        surface.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.splitDivider.isHidden)
        surface.showsSplitDivider = true
        #expect(!surface.splitDivider.isHidden)
        let canvas = surface.mapping.canvasRect
        #expect(abs(surface.splitDivider.frame.midX - canvas.midX) <= 1)
        #expect(surface.splitDivider.frame.width == 1)
        surface.showsSplitDivider = false
        #expect(surface.splitDivider.isHidden)
        // Odd widths: the split column is floor(w / 2) of the picture.
        let f = ProgramSurfaceView.splitDividerFrame(canvas: CGRect(x: 10, y: 0, width: 101, height: 50), sequenceWidth: 101,
                                                     bounds: CGRect(x: 0, y: 0, width: 200, height: 50), lineWidth: 1)
        #expect(f.minX == 59.5.rounded() && f.height == 50)
    }

    @Test func compareNeverTouchesTheProject() throws {
        let (session, _, panel, _) = try rig()
        let before = session.project
        panel.isOnColorPage = true
        panel.setCompare(.split)
        panel.setCompare(.before)
        #expect(session.project == before)
        #expect(!session.canUndo)
    }

    @Test func resetColorRangeIsListedAndEnabledOnlyWithARange() {
        let m = ColorInspectorModel()
        let resets = m.sectionResets(1)
        let titles = resets.map { $0.title }
        #expect(titles == ["Reset Basic", "Reset Creative", "Reset Curves", "Reset Wheels & Match", "Reset Zone Board", "Reset Color Range", "Reset Vignette"])
        let range = resets.first { $0.kind == .hslSecondary }
        #expect(range?.enabled == false, "no range yet: nothing to reset")
        let othersEnabled = resets.filter { $0.kind != .hslSecondary }.allSatisfy { $0.enabled }
        #expect(othersEnabled)
        // Choosing it anyway changes nothing.
        let c = m.color
        m.resetSection(1, .hslSecondary)
        #expect(m.color == c)
        // With a range it is enabled and removes the range.
        m.setRange(1, .saturation, 70)
        #expect(m.sectionResets(1).first { $0.kind == .hslSecondary }?.enabled == true)
        m.resetSection(1, .hslSecondary)
        #expect(m.colorRange(1) == nil)
    }
}
