import Foundation
import Testing
import AppKit
import SQCore
import SQExport
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQMonitorUI

/// W5.1: the active format variant in the session (Program monitor switcher, edits into the variant's override).
@MainActor @Suite struct VariantSessionTests {
    static let fd = Time(1, 25)

    func make() -> (EditorSession, StubProgramEngine, Clip) {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var track = Track(kind: .video)
        try! track.overwrite(c)
        let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Self.fd), tracks: [track])
        let engine = StubProgramEngine()
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: engine)
        return (s, engine, c)
    }

    @Test func addFormatSwitchesToItAndIsOneUndoStep() throws {
        let (s, engine, _) = make()
        let v = try #require(s.addVariant(name: "9:16", width: 1080, height: 1920))
        #expect(s.activeVariantID == v)
        #expect(s.undoName == "Add Format")
        #expect(engine.timelines.last?.format.width == 1080 && engine.timelines.last?.format.height == 1920)
        #expect(s.undo())
        #expect(s.activeVariantID == nil)                       // the variant is gone, the monitor shows the base
        #expect(engine.timelines.last?.format.width == 1920)
    }

    @Test func switchingVariantPushesItsCanvasAndIsNotAnUndoStep() throws {
        let (s, engine, _) = make()
        let v = try #require(s.addVariant(name: "9:16", width: 1080, height: 1920))
        s.setActiveVariant(nil)
        #expect(engine.timelines.last?.format.width == 1920)
        #expect(s.undoName == "Add Format")
        s.setActiveVariant(v)
        #expect(engine.timelines.last?.format.width == 1080)
        #expect(engine.timelines.last?.variants.isEmpty == true)    // materialised view, nothing left to resolve
    }

    @Test func effectControlsEditInAVariantGoesToItsOverride() throws {
        let (s, _, c) = make()
        let v = try #require(s.addVariant(name: "9:16", width: 1080, height: 1920))
        s.select(clips: [c.id])
        var shown = try #require(s.displayedSelectedClip)
        #expect(abs(shown.animation.scale.value.x - 1920.0 / 1080.0) < 1e-9)   // fill into 9:16
        shown.animation.rotation = AnimatedProperty(15)
        s.replaceDisplayedClip(shown, name: "Rotation", continuesGesture: false)
        let base = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == c.id })
        #expect(base.animation.rotation.value == 0)
        #expect(base.variantOverrides[v]?.rotation?.value == 15)
        #expect(s.displayedSelectedClip?.animation.rotation.value == 15)
        s.setActiveVariant(nil)
        #expect(s.displayedSelectedClip?.animation.rotation.value == 0)
    }

    @Test func removeFormatDropsItAndFallsBackToTheBase() throws {
        let (s, _, _) = make()
        let v = try #require(s.addVariant(name: "1:1", width: 1080, height: 1080))
        s.removeVariant(v)
        #expect(s.activeTimeline?.variants.isEmpty == true)
        #expect(s.activeVariantID == nil)
        #expect(s.undoName == "Remove Format")
    }

    @Test func programMonitorSwitcherFollowsTheSession() throws {
        let (s, _, _) = make()
        let m = MonitorPanelModel(frameDuration: Self.fd, mode: .program)
        m.syncFormats(from: s)
        #expect(m.formatBaseName == "16:9" && m.formatItems.isEmpty && m.formatCurrent == nil)
        let preset = try #require(SequenceConform.aspectPresets.first { $0.name == "9:16" })
        let v = try #require(s.addVariant(preset))
        m.syncFormats(from: s)
        #expect(m.formatItems.map(\.name) == ["9:16"] && m.formatCurrent == v)
    }

    @Test func exportAllFormatsMakesOneJobPerVariant() throws {
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Self.fd)
        let vs = [FormatVariant(name: "9:16", width: 1080, height: 1920), FormatVariant(name: "1:1", width: 1080, height: 1080)]
        let item = ExportDialogModel.SequenceItem(name: "Promo", duration: Time(10, 1), format: f, variants: vs)
        let m = ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }
        #expect(m.hasVariants)
        let dir = URL(fileURLWithPath: "/tmp")
        #expect(m.buildJobs(outputDirectory: dir).count == 1)
        m.exportAllFormats = true
        let jobs = m.buildJobs(outputDirectory: dir)
        #expect(jobs.map(\.name) == ["Promo", "Promo 9:16", "Promo 1:1"])
        #expect(jobs.map(\.settings.variant) == [nil, vs[0].id, vs[1].id])
    }

    @Test func audioMeterPanelShowsSlimMeterAloneWhenNarrow() {
        let p = AudioMeterPanelView(frame: NSRect(x: 0, y: 0, width: 56, height: 400))
        p.reading = { (ObjectIdentifier(p), 1, [0.5, 0.25]) }
        p.layout()
        p.poll()
        #expect(p.loudness.isHidden)                                          // narrow: slim peak meter only, loudness columns hidden
        // The slim meter (v9, 48 pt) takes the whole height: slider and Dim are in its right-click menu at this width.
        #expect(p.meter.frame.width == AudioMeterView.width && p.meter.frame.height == 400 && p.monitorSlider.isHidden)
        #expect(p.meter.channels.count == 2 && p.meter.channels[0].levelDB > p.meter.channels[1].levelDB)
        p.frame.size.width = 240
        p.layout()
        #expect(!p.loudness.isHidden)                                         // wide enough: R128 columns appear beside the bars
        #expect(abs(p.meter.frame.union(p.loudness.frame).midX - 120) <= 0.5)  // group centered
    }

    @Test func switchingVariantMarksTheProjectDirty() throws {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Self.fd),
                         tracks: [Track(kind: .video, clips: [c])])
        let v = try t.addVariant(name: "9:16", width: 1080, height: 1920)
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        #expect(!s.isDirty)
        s.setActiveVariant(v)
        #expect(s.isDirty)
        #expect(s.undoName == nil)                                    // still no undo step
    }

    @Test func displayTimelineIsTheMaterialisedViewTheEngineGot() throws {
        let (s, engine, _) = make()
        _ = try #require(s.addVariant(name: "9:16", width: 1080, height: 1920))
        #expect(s.displayTimeline == engine.timelines.last)
        #expect(s.displayTimeline?.format.width == 1080)
        s.setActiveVariant(nil)
        #expect(s.displayTimeline == s.activeTimeline)
    }

    /// A nested clip whose inner sequence renders in the same variant: Effect Controls shows what render shows (not
    /// conformed), and an edit does not write a conformed Scale into the override.
    @Test func nestedClipInASharedVariantIsShownAndEditedUnconformed() throws {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var inner = Timeline(name: "I", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Self.fd),
                             tracks: [Track(kind: .video, clips: [c])])
        let v = try inner.addVariant(name: "9:16", width: 1080, height: 1920)
        let n = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                     start: .zero, sequence: inner.id)
        var t = Timeline(name: "S", format: inner.format, tracks: [Track(kind: .video, clips: [n])])
        t.variants = inner.variants
        let s = EditorSession(project: Project(name: "P", timelines: [t, inner]), engine: StubProgramEngine())
        s.setActiveTimeline(t.id)
        s.setActiveVariant(v)
        s.select(clips: [n.id])
        var shown = try #require(s.displayedSelectedClip)
        #expect(shown.animation.scale.value == Vec2(1, 1))
        shown.animation.rotation = AnimatedProperty(5)
        s.replaceDisplayedClip(shown, name: "Rotation", continuesGesture: false)
        let o = try #require(s.activeTimeline?.tracks[0].clips.first?.variantOverrides[v])
        #expect(o.rotation?.value == 5 && o.scale == nil)
        let dc = try #require(s.displayedSelectedClip), dt = try #require(s.displayTimeline)
        let target = try #require(OverlayTarget.make(clip: dc, project: s.project, timeline: dt, at: Time(1, 1), variant: v))
        #expect(target.size == CGSize(width: 1080, height: 1920))
    }

    /// Typing in a text clip whose override has its own generator edits that override, not the base text.
    @Test func textEditInAVariantWithAnOverriddenGeneratorEditsTheOverride() throws {
        let style = TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white)
        let baseRef = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Base", style: style), animations: nil)
        let varRef = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Vertical", style: style), animations: nil)
        let id = UUID()
        let clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                        start: .zero, generator: baseRef)
        var t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Self.fd),
                         tracks: [Track(kind: .video, clips: [clip])])
        let v = try t.addVariant(name: "9:16", width: 1080, height: 1920)
        try t.editOverride(clip: id, variant: v) { $0.generator = varRef }
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        s.setActiveVariant(v)
        s.select(clips: [id])
        let shownRef = try #require(s.displayedSelectedClip?.generator)
        #expect(try TextGenerator.decode(shownRef).0.text == "Vertical")
        var tpl = try TextGenerator.decode(shownRef).0
        tpl.text = "Vertical 2"
        s.updateTextClip(id, template: tpl, animations: nil, continuesGesture: false)
        let stored = try #require(s.activeTimeline?.tracks[0].clips.first)
        let sg = try #require(stored.generator), og = try #require(stored.variantOverrides[v]?.generator)
        #expect(try TextGenerator.decode(sg).0.text == "Base")
        #expect(try TextGenerator.decode(og).0.text == "Vertical 2")
        // Without an overridden generator the text is shared: the base changes.
        s.setActiveVariant(nil)
        tpl.text = "Shared"
        s.updateTextClip(id, template: tpl, animations: nil, continuesGesture: false)
        let shared = try #require(s.activeTimeline?.tracks[0].clips.first?.generator)
        #expect(try TextGenerator.decode(shared).0.text == "Shared")
    }

    @Test func activeVariantIsSavedWithTheProject() async throws {
        let (s, _, _) = make()
        let v = try #require(s.addVariant(name: "9:16", width: 1080, height: 1920))
        s.setActiveVariant(v)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-variant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.sqproj")
        try await s.saveAs(to: url)
        let other = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir.appendingPathComponent("Autosave")))
        try await other.open(url: url)
        #expect(other.activeVariantID == v)
    }
}
