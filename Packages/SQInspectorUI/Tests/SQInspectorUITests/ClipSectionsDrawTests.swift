import Foundation
import Testing
import SQCore
import SQEditorSession
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The clip's content section on the shared toolkit (Windows): `ClipSectionsView`'s modes and slots through the panel.
@MainActor @Suite struct ClipSectionsDrawTests {
    private func session(audio: Bool) -> (EditorSession, Clip.ID?) {
        var a = Track(kind: .audio)
        var id: Clip.ID?
        if audio {
            let c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
            try? a.overwrite(c)
            id = c.id
        }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), a])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        if let id { s.select(clips: [id]) }
        return (s, id)
    }

    private func panel(_ s: EditorSession) -> (EffectControlsDrawPanel, ClipSectionsDraw) {
        let m = EffectControlsModel()
        m.sync(with: s, change: [.project, .selection])
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 400, height: 2000)
        let sec = ClipSectionsDraw(session: s)
        p.clipSections = sec
        return (p, sec)
    }

    @Test func audioClipClosesTheColumnWithTheTrackControls() throws {
        let (s, _) = session(audio: true)
        let (p, sec) = panel(s)
        #expect(sec.mode == .audio)
        let block = try #require(sec.audioBlock)
        #expect(sec.height == ControlsGrid.headerHeight + block.height)
        #expect(p.sectionFrame.minY >= (p.rows.last.map { $0.y + $0.height } ?? 0))
        #expect(p.contentHeight == p.sectionFrame.maxY)
        var c = Canvas(width: 400, height: 2000, atlas: nil, scale: 1)
        p.draw(&c)
        // The Bypass box toggles the track's compressor through the panel.
        let box = try #require(block.frame(.bypass))
        let at = CGPoint(x: box.minX + 7, y: p.sectionFrame.minY + ControlsGrid.headerHeight + box.midY)
        let before = block.model.compressor.bypass
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseUp(at: at)
        #expect(block.model.compressor.bypass != before)
        #expect(sec.audioPresets.values.first?.compressor.bypass == !before)
    }

    @Test func headerFoldsTheSection() {
        let (s, _) = session(audio: true)
        let (p, sec) = panel(s)
        let at = CGPoint(x: 40, y: p.sectionFrame.minY + 5)
        #expect(p.help(at: at) == "Collapse Audio")
        p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        #expect(sec.isCollapsed && sec.height == ControlsGrid.headerHeight)
        #expect(p.sectionFrame.height == ControlsGrid.headerHeight)
    }

    @Test func shapeLeadsTheColumnAndSwitchesTheKind() throws {
        let (s, _) = session(audio: false)
        let id = try #require(s.addShapeClip(.ellipse))
        let (p, sec) = panel(s)
        #expect(sec.mode == .shape && sec.shapeKind == .ellipse)
        #expect(p.sectionFrame.minY == 0)
        #expect(p.rows.first.map { $0.y } == sec.height + ControlsMetrics.sectionGap)
        let i = try #require(ShapeKind.allCases.firstIndex(of: .line))
        let f = sec.kindFrame(i)
        p.mouseDown(at: CGPoint(x: f.midX, y: f.midY), clickCount: 1, modifiers: [])
        p.mouseUp(at: CGPoint(x: f.midX, y: f.midY))
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.generator?.shapeKind == .line)
    }

    /// Captions live only in the Captions tab: with a caption track and nothing (or a caption) selected, Controls
    /// shows no caption list and no caption header.
    @Test func controlsNeverListCaptions() throws {
        let items = (0..<5).map { n in
            CaptionItem(lines: ["line \(n)"], range: TimeRange(start: Time(Int64(n), 1), end: Time(Int64(n) + 1, 1)))
        }
        var t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        t.captionTracks = [CaptionTrack(name: "Subtitles", items: items)]
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        let (p, sec) = panel(s)
        #expect(sec.mode == .none && sec.captionSummary == nil)
        s.select(clips: [], captions: [items[1].id])
        sec.sync(.selection)
        #expect(sec.mode == .none && sec.captionSummary == nil)
        #expect(p.showsEmptyState)
    }

    /// An applied title template leads the column with its slots: a number drag is one gesture, a text run goes out
    /// live, the color swatch opens the host picker, the zones box and Middle report their choice.
    @Test func templateSlotsEditThroughTheirControls() throws {
        let (s, _) = session(audio: false)
        var c = Clip(name: "Title", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        c.sequence = UUID()
        let lay = UUID()
        c.templateSlots = [
            TemplateSlot(name: "Headline", kind: .text, layer: lay, path: "text", value: .text("Hi")),
            TemplateSlot(name: "Color", kind: .color, layer: lay, path: "color", value: .color(red: 1, green: 0, blue: 0, alpha: 1)),
            TemplateSlot(name: "Size", kind: .number, layer: lay, path: "size", value: .number(40)),
        ]
        var tl = try #require(s.activeTimeline)
        try tl.tracks[0].overwrite(c)
        let s2 = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        s2.select(clips: [c.id])
        let (p, sec) = panel(s2)
        #expect(sec.mode == .template)
        #expect(sec.height == ControlsGrid.headerHeight + 4 * ControlsGrid.rowHeight)
        var sent: [(String, Bool)] = []
        sec.template.onSlotChange = { id, v, cont in
            let name = c.templateSlots?.first { $0.id == id }?.name ?? "?"
            if case .text(let t) = v { sent.append(("\(name)=\(t)", cont)) } else { sent.append((name, cont)) }
        }
        var zonesOn: Bool?
        sec.template.onZonesToggle = { zonesOn = $0 }
        func click(_ f: CGRect) {
            let at = CGPoint(x: f.midX, y: f.midY + ControlsGrid.headerHeight)
            p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        }
        // Typing replaces the selected text and goes out on every key; Return ends the run.
        click(sec.template.frame(.slot(0)))
        #expect(sec.template.focused != nil)
        _ = p.key(.character("Y"), modifiers: [])
        _ = p.key(.character("o"), modifiers: [])
        _ = p.key(.enter, modifiers: [])
        #expect(sent.map(\.0) == ["Headline=Y", "Headline=Yo"] && sent.map(\.1) == [false, true])
        #expect(sec.template.focused == nil)
        // The swatch asks the host's picker; two changes are one gesture.
        var picked: ((EffectColor?) -> Void)?
        p.onPickColor = { _, _, change in picked = change }
        click(sec.template.frame(.slot(1)))
        let change = try #require(picked)
        change(EffectColor(red: 0, green: 1, blue: 0)); change(EffectColor(red: 0, green: 0, blue: 1))
        #expect(sent.suffix(2).map(\.1) == [false, true])
        // The zones box.
        click(CGRect(x: ControlsGrid.valueX, y: sec.template.rowY(3), width: 14, height: ControlsGrid.rowHeight))
        #expect(zonesOn == true)
        var cv = Canvas(width: 400, height: 2000, atlas: nil, scale: 1)
        p.draw(&cv)
    }

    /// A graphics clip leads the column with its item picker and Edit in Graphics; picking an item sets the shared
    /// item selection and asks the host to sync Controls.
    @Test func graphicPicksAnItemAndOpensTheGraphicsPanel() throws {
        let (s, _) = session(audio: false)
        let box = GraphicsLayer(name: "Box", content: .shape(kind: .rectangle)), dot = GraphicsLayer(name: "Dot", content: .shape(kind: .ellipse))
        let id = try #require(s.addGraphicsClip(layers: [box, dot]))
        let (p, sec) = panel(s)
        #expect(sec.mode == .graphic && p.sectionFrame.minY == 0)
        #expect(sec.height == ControlsGrid.headerHeight + 2 * ControlsGrid.rowHeight)
        var menu: [SQMenuItem] = []
        p.onMenu = { items, _ in menu = items }
        var synced = 0, edits = 0
        sec.onGraphicItemChange = { synced += 1 }
        sec.onEditGraphics = { edits += 1 }
        let pick = try #require(sec.graphicFrame(.layerPicker))
        p.mouseDown(at: CGPoint(x: pick.midX, y: pick.midY), clickCount: 1, modifiers: [])
        p.mouseUp(at: CGPoint(x: pick.midX, y: pick.midY))
        // Whole graphic, then the items front first.
        #expect(menu.map(\.title) == ["Whole graphic", "Dot", "Box"])
        menu[2].action?()
        #expect(s.graphicLayerSelection == GraphicLayerSelection(clip: id, layers: [box.id]) && synced == 1)
        #expect(sec.pickedItem == box.id)
        let edit = try #require(sec.graphicFrame(.editGraphics))
        p.mouseDown(at: CGPoint(x: edit.midX, y: edit.midY), clickCount: 1, modifiers: [])
        p.mouseUp(at: CGPoint(x: edit.midX, y: edit.midY))
        #expect(edits == 1)
        var cv = Canvas(width: 400, height: 2000, atlas: nil, scale: 1)
        p.draw(&cv)
    }
}
