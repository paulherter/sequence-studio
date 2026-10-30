import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQMonitorUI

/// The Color page's target (design boards "Color" and "ColorClips"): the Clips strip shows each source file once as a
/// tile and grades every use of it, a timeline click grades that clip, adjustment layers and the sequence grade layer
/// are picked in the timeline. The Color panel is driven like the app drives it (the session reports every change).
@MainActor @Suite struct ColorClipsPanelTests {
    /// V1: A, B, D (media m, three cuts of one file), C (other media); A1: audio of A.
    func rig() throws -> (EditorSession, a: Clip, b: Clip, c: Clip, d: Clip, m: UUID) {
        let m = UUID()
        func clip(_ n: String, _ media: UUID, _ at: Int64, _ kind: TrackKind = .video) -> Clip {
            Clip(name: n, media: media, kind: kind, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(at, 1))
        }
        let a = clip("A", m, 0), b = clip("B", m, 2), c = clip("C", UUID(), 4), d = clip("D", m, 6)
        var v = Track(kind: .video), au = Track(kind: .audio)
        try v.overwrite(a); try v.overwrite(b); try v.overwrite(c); try v.overwrite(d)
        try au.overwrite(clip("A audio", m, 0, .audio))
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, au])
        let ref = MediaRef(id: m, name: "interview.mp4", path: "/x/interview.mp4", fingerprint: MediaFingerprint(size: 1))
        let s = EditorSession(project: Project(name: "P", media: [ref], timelines: [t]), engine: StubProgramEngine())
        return (s, a, b, c, d, m)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }
    func layerExposure(_ s: EditorSession) -> Float? { s.activeTimeline?.sequenceGradeClip?.color.effects.first?.basic.exposure }

    // MARK: Source list

    @Test func theListShowsEachSourceFileOnceInTimelineOrder() throws {
        let (s, a, b, c, d, m) = try rig()
        let items = ColorSourceListItem.items(s.activeTimeline, project: s.project)
        #expect(items.map(\.media) == [m, c.media])
        #expect(items[0].clips == [a.id, b.id, d.id])
        #expect(items[0].name == "interview.mp4", "the source file's name, not a cut's")
        #expect(items[1].name == "C", "no media entry: the clip name")
        #expect(!items[0].graded)
    }

    @Test func adjustmentLayersAreRowsOfTheirOwnAndTheTimelineGradeIsNot() throws {
        let (s, _, _, _, _, _) = try rig()
        let tl = try #require(s.activeTimelineID)
        var adj = UUID()
        try s.perform("Setup") { p in
            let v2 = p.timelines[0].addTrack(kind: .video)
            adj = try p.addAdjustmentClip(in: tl, at: .zero, track: v2, duration: Time(1, 1))
            _ = try p.ensureSequenceGrade(in: tl)
        }
        let items = ColorSourceListItem.items(s.activeTimeline, project: s.project)
        #expect(items.count == 3)
        #expect(items.contains { $0.clips == [adj] && $0.isAdjustment })
        #expect(!items.contains { $0.clips.contains(s.activeTimeline!.sequenceGradeClip!.id) })
    }

    @Test func aSourceRowGradesItsPickedCutOrItsFirstLinkedCut() throws {
        let (s, a, b, _, d, _) = try rig()
        let row = try #require(ColorSourceListItem.items(s.activeTimeline, project: s.project).first)
        #expect(row.clipToGrade(picked: nil, in: s.project) == a.id)
        #expect(row.clipToGrade(picked: d.id, in: s.project) == d.id, "a cut of this source already picked stays picked")
        #expect(s.setGradeLinkedToSource(a.id, false))
        #expect(row.clipToGrade(picked: nil, in: s.project) == b.id, "an unlinked cut is not the row's grade")
    }

    @Test func pickingASourceRowGradesEveryCutOfIt() throws {
        let (s, a, b, c, d, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        let row = try #require(panel.clipsPanel.items.first)
        panel.pickSource(row)
        #expect(s.selection == [a.id])
        let model = try #require(panel.colorModels[a.id])
        model.gesture { model.set(1, .exposure, 0.75) }
        for id in [a.id, b.id, d.id] { #expect(current(s, id).color.effects[0].basic.exposure == 0.75) }
        #expect(current(s, c.id).colorGradeEffects.isEmpty)
        #expect(panel.clipsPanel.items.first?.graded == true)
    }

    // MARK: Whole sequence

    @Test func aTileShowsTheMiddleOfItsFirstCutNotThePoster() throws {
        let (s, a, _, _, _, _) = try rig()
        let item = try #require(ColorClipsPanelView.tiles(s.activeTimeline, project: s.project).first)
        #expect(item.clips.first == a.id)
        // A uses source 0..2 s: the frame at 1 s.
        #expect(ColorClipsPanelView.frameTime(of: item, in: s.activeTimeline) == Time(1, 1))
        #expect(ColorClipsPanelView.frameTime(of: item, in: nil) == nil)
    }

    @Test func theStripHasOneTilePerSourceAndNoWholeSequenceOrAdjustmentTile() throws {
        let (s, a, _, c, _, m) = try rig()
        let tl = try #require(s.activeTimelineID)
        try s.perform("Setup") { p in
            let v2 = p.timelines[0].addTrack(kind: .video)
            _ = try p.addAdjustmentClip(in: tl, at: .zero, track: v2, duration: Time(1, 1))
            _ = try p.ensureSequenceGrade(in: tl)
        }
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        let strip = panel.clipsPanel
        #expect(strip.items.map(\.media) == [m, c.media], "sources only: no adjustment layer, no sequence grade")
        #expect(strip.highlighted == nil)
        strip.clickTile(1)
        #expect(panel.resolution == .clip(c.id) && strip.highlighted == 1)
        strip.clickTile(0)
        #expect(panel.resolution == .clip(a.id) && strip.highlighted == 0)
        panel.pickWholeSequence()
        #expect(strip.highlighted == nil, "no tile stands for the whole sequence")
    }

    @Test func aTileClickGradesEveryUseOfItsSource() throws {
        let (s, a, b, c, d, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        panel.clipsPanel.clickTile(0)
        #expect(panel.headerDetail == "3 uses")
        let model = try #require(panel.colorModels[a.id])
        model.gesture { model.set(1, .saturation, 1.4) }
        for id in [a.id, b.id, d.id] { #expect(current(s, id).color.effects[0].basic.saturation == 1.4) }
        #expect(current(s, c.id).colorGradeEffects.isEmpty)
    }

    @Test func aTimelineClickGradesThatClipAndFollowsItsLink() throws {
        let (s, a, b, c, d, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        s.select(clips: [c.id])
        #expect(panel.resolution == .clip(c.id) && panel.headerDetail == "1 use")
        #expect(panel.clipsPanel.highlighted == 1, "the strip rings the source of the clip being graded")
        let mc = try #require(panel.colorModels[c.id])
        mc.gesture { mc.set(1, .exposure, 0.3) }
        #expect(current(s, c.id).color.effects[0].basic.exposure == 0.3)
        for id in [a.id, b.id, d.id] { #expect(current(s, id).colorGradeEffects.isEmpty) }
        // A use taken out of its source's grade is graded alone.
        #expect(s.setGradeLinkedToSource(b.id, false))
        s.select(clips: [b.id])
        #expect(panel.resolution == .clip(b.id) && panel.headerDetail == "1 use")
        let mb = try #require(panel.colorModels[b.id])
        mb.gesture { mb.set(1, .exposure, 0.9) }
        #expect(current(s, b.id).color.effects[0].basic.exposure == 0.9)
        #expect(current(s, a.id).colorGradeEffects.isEmpty && current(s, d.id).colorGradeEffects.isEmpty)
    }

    @Test func anAdjustmentLayerIsGradedAloneAndTheGradeLayerIsSequenceWide() throws {
        let (s, a, _, _, _, _) = try rig()
        let tl = try #require(s.activeTimelineID)
        var adj = UUID()
        try s.perform("Setup") { p in
            let v2 = p.timelines[0].addTrack(kind: .video)
            adj = try p.addAdjustmentClip(in: tl, at: .zero, track: v2, duration: Time(8, 1))
            _ = try p.ensureSequenceGrade(in: tl)
        }
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        s.select(clips: [adj])
        #expect(panel.resolution == .clip(adj))
        let m = try #require(panel.colorModels[adj])
        m.gesture { m.set(1, .exposure, 0.4) }
        #expect(current(s, adj).color.effects[0].basic.exposure == 0.4)
        #expect(current(s, a.id).colorGradeEffects.isEmpty, "the clips under the layer keep their own grade")
        let layer = try #require(s.activeTimeline?.sequenceGradeClip)
        s.select(clips: [layer.id])
        #expect(panel.resolution == .sequence(tl, layer: layer.id) && panel.headerDetail == "Whole sequence")
        let ms = try #require(panel.colorModels[tl])
        ms.gesture { ms.set(1, .exposure, 0.6) }
        #expect(layerExposure(s) == 0.6)
        #expect(current(s, adj).color.effects[0].basic.exposure == 0.4)
    }

    @Test func usesAndViewerHeaderTexts() throws {
        let (s, a, _, c, d, _) = try rig()
        #expect(ColorUses.text(1) == "1 use" && ColorUses.text(2) == "2 uses")
        #expect(ColorUses.tileLine(uses: 2, grade: "Pro") == "2 uses \u{00B7} Pro")
        #expect(ColorUses.tileLine(uses: 1, grade: "No grade") == "1 use \u{00B7} No grade")
        let tl = try #require(s.activeTimeline)
        #expect(ColorViewerHeaderContent.make(.clip(c.id), timeline: tl) == ColorViewerHeaderContent(name: "C", position: "3 of 4"))
        #expect(ColorViewerHeaderContent.make(.clip(d.id), timeline: tl).position == "4 of 4")
        #expect(ColorViewerHeaderContent.make(.sequence(tl.id, layer: nil), timeline: tl) == ColorViewerHeaderContent(name: "Whole sequence"))
        #expect(ColorViewerHeaderContent.make(.message("x"), timeline: tl).name == "Main")
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        s.select(clips: [a.id])
        #expect(panel.viewerHeader.content == ColorViewerHeaderContent(name: "A", position: "1 of 4"))
        #expect(ColorInspectorPanelView.sourcesHint.hasPrefix("Every source once"))
        #expect(ColorClipsPanelView.thumbSize(.portrait) == NSSize(width: 104, height: 184))
    }

    @Test func rowTextsSlidersAndScopeLayoutFollowTheBoard() {
        #expect(LumetriSlider.isCentred(min: -100, max: 100, neutral: 0))
        #expect(!LumetriSlider.isCentred(min: 0, max: 100, neutral: 0))
        #expect(InputPickerView.choices.count == Set(InputPickerView.choices).count && !InputPickerView.choices.isEmpty)
        #expect(ScopeLayout.title(.waveform) == "Waveform \u{00B7} Luma" && ScopeLayout.title(.parade) == "Parade \u{00B7} RGB")
        #expect(ScopeLayout.plot(.waveform, in: CGSize(width: 300, height: 170)) == CGRect(x: 26, y: 8, width: 268, height: 154))
        #expect(ScopeLayout.plot(.histogram, in: CGSize(width: 300, height: 170)) == CGRect(x: 6, y: 6, width: 288, height: 148))
        let v = ScopeLayout.plot(.vectorscope, in: CGSize(width: 300, height: 222))
        #expect(abs(v.width - 174.8) < 0.01 && abs(v.height - 174.8) < 0.01 && abs(v.midX - 150) <= 0.5)
        #expect(!ScopeLayout.showsTwo(height: 240, popup: 22) && ScopeLayout.showsTwo(height: 420, popup: 22))
    }

    /// The bug from the maintainer's test: with the whole sequence targeted, clicking a clip in the timeline did nothing (the
    /// panel stayed on the sequence, the list was dimmed), so neither target seemed to react.
    @Test func aTimelineClipSelectionLeavesWholeSequence() throws {
        let (s, a, _, _, _, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        panel.pickWholeSequence()
        s.select(clips: [a.id])
        #expect(panel.resolution == .clip(a.id))
    }

    @Test func wholeSequenceEditsWorkAcrossGestures() throws {
        let (s, a, b, _, _, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        panel.pick(b.id)
        panel.pickWholeSequence()
        let tl = try #require(s.activeTimelineID)
        let m = try #require(panel.colorModels[tl])
        m.gesture { m.set(1, .exposure, 0.5) }
        #expect(layerExposure(s) == 0.5)
        let layer = try #require(s.activeTimeline?.sequenceGradeClip)
        #expect(s.selection == [layer.id], "the timeline shows what is graded")
        let m2 = try #require(panel.colorModels[tl])
        m2.gesture { m2.set(1, .exposure, 1.0) }
        #expect(layerExposure(s) == 1.0)
        m2.gesture { for v in [Float(1.2), 1.4, 1.6] { m2.set(1, .contrast, v) } }
        #expect(s.activeTimeline?.sequenceGradeClip?.color.effects.first?.basic.contrast == 1.6)
        #expect(current(s, a.id).colorGradeEffects.isEmpty, "clips keep their own grade")
        // Picking the whole sequence again with the layer in place selects the layer.
        panel.pick(a.id)
        panel.pickWholeSequence()
        #expect(s.selection == [layer.id])
        #expect(panel.resolution == .sequence(tl, layer: layer.id))
    }

    @Test func wholeSequenceEditsWorkWithThePlayheadPastTheEnd() throws {
        let (s, _, _, _, _, _) = try rig()
        let panel = ColorInspectorPanelView(session: s)
        s.onChange = { panel.sync($0) }
        panel.pickWholeSequence()
        s.seek(to: Time(30, 1))
        let tl = try #require(s.activeTimelineID)
        let m = try #require(panel.colorModels[tl])
        m.gesture { m.set(1, .exposure, 0.5) }
        #expect(layerExposure(s) == 0.5)
    }

    // MARK: Target description

    @Test func theTargetIsLinkedOnlyForASourceWithSeveralCuts() throws {
        let (s, a, _, c, _, _) = try rig()
        let tl = try #require(s.activeTimeline)
        let linked = ColorTargetBarContent.clip(current(s, a.id), project: s.project)
        #expect(linked.title == "interview.mp4" && linked.linked == true)
        let lone = ColorTargetBarContent.clip(current(s, c.id), project: s.project)
        #expect(lone.linked == nil, "one cut: nothing to link")
        #expect(ColorTargetBarContent.wholeSequence(tl).linked == nil)
        #expect(s.setGradeLinkedToSource(a.id, false))
        let off = ColorTargetBarContent.clip(current(s, a.id), project: s.project)
        #expect(off.title == "A" && off.linked == false, "an unlinked cut is named by itself")
    }

    // MARK: Layouts

    /// Sources and Steps are tabs of the Color page's lower group; no Edit layout docks them.
    @Test func onlyTheColorPageDocksSourcesAndSteps() {
        #expect(Workspace.color.isVisible(.colorInspector) && Workspace.color.isVisible(.scopes) && Workspace.color.isVisible(.colorClips) && Workspace.color.isVisible(.steps))
        for w in Workspace.builtIns { #expect(!w.allPanels.contains(.colorClips) && !w.allPanels.contains(.steps)) }
    }
}
