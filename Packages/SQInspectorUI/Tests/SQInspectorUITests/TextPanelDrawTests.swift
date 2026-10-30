import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQLibrary
import SQText
import SQUIKit
@testable import SQInspectorUI

/// The shared-toolkit Text panel (Windows): the Look tab (`CaptionStyleTabDraw`), the Templates tab, the Look gallery
/// and the kit token rows of the text block, on the same session calls as the Mac views.
@MainActor @Suite(.serialized) struct TextPanelDrawTests {
    func session() throws -> EditorSession {
        func item(_ text: String, _ a: Int64) -> CaptionItem {
            CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(a + 1, 1)))
        }
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([item("hello", 0), item("the cat", 2)])
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    func lookTab(_ s: EditorSession, galleryOpen: Bool = false) -> CaptionStyleTabDraw {
        let d = UserDefaults.standard
        d.set(galleryOpen, forKey: TextBlockDraw.sectionKey(CaptionStyleTabDraw.Section.looks.rawValue))
        for sec in [CaptionStyleTabDraw.Section.captions, .position] { d.set(true, forKey: TextBlockDraw.sectionKey(sec.rawValue)) }
        d.set(false, forKey: TextBlockDraw.sectionKey(CaptionStyleTabDraw.Section.kit.rawValue))
        let v = CaptionStyleTabDraw(session: s)
        v.size = CGSize(width: 340, height: 4000)
        v.clock = { 10 }
        v.refresh()
        return v
    }

    func click(_ v: CaptionStyleTabDraw, _ k: CaptionStyleTabDraw.Control) throws {
        let f = try #require(v.frame(k))
        let p = CGPoint(x: f.midX, y: f.midY)
        v.mouseDown(at: p, clickCount: 1)
        v.mouseUp(at: p)
    }

    @Test func positionSegmentMovesTheCaptionsInOneUndoStep() throws {
        let s = try session()
        let v = lookTab(s)
        #expect(v.stateShown)
        try click(v, .vertical(0))
        #expect(s.captionPosition.vertical == .top)
        try click(v, .horizontal(2))
        #expect(s.captionPosition.horizontal == .right)
        #expect(s.undo())
        #expect(s.captionPosition.horizontal == .center)
        #expect(s.captionPosition.vertical == .top)
    }

    @Test func offsetScrubIsOneUndoStepAndShowsYUp() throws {
        let s = try session()
        let v = lookTab(s)
        let f = try #require(v.frame(.offset(isY: true)))
        v.mouseDown(at: CGPoint(x: f.midX, y: f.midY), clickCount: 1)
        for dx in stride(from: 4, through: 40, by: 4) { v.mouseDragged(to: CGPoint(x: f.midX + CGFloat(dx), y: f.midY)) }
        v.mouseUp(at: CGPoint(x: f.midX + 40, y: f.midY))
        #expect(s.captionPosition.offsetY < 0)                  // dragged up on screen = stored fraction goes up (negative)
        #expect(s.undo())
        #expect(s.captionPosition.offsetY == 0)
    }

    @Test func wordHighlightTurnsOnAndKeepSpokenFollows() throws {
        let s = try session()
        let v = lookTab(s)
        #expect(s.captionKaraoke == nil)
        try click(v, .karaoke)
        #expect(s.captionKaraoke != nil)
        try click(v, .karaokeKeep)
        #expect(s.captionKaraoke?.keepSpoken == true)
        try click(v, .karaoke)
        #expect(s.captionKaraoke == nil)
    }

    @Test func textBlockEditsBecomeCaptionStyleFields() throws {
        let s = try session()
        let v = lookTab(s)
        #expect(v.block.frame(.textBox, .text) == nil)          // a caption's words are edited in the list
        let before = try #require(s.captionStyleState(scope: .all)).style
        let f = try #require(v.block.frame(.button(.style, 0), .text))      // Bold
        let p = CGPoint(x: f.midX, y: f.midY + v.blockY)
        v.mouseDown(at: p, clickCount: 1)
        v.mouseUp(at: p)
        let after = try #require(s.captionStyleState(scope: .all)).style
        #expect(after.weight != before.weight)
        #expect(s.undo())
        #expect(try #require(s.captionStyleState(scope: .all)).style.weight == before.weight)
    }

    @Test func galleryPickAppliesTheLookToTheCaptions() throws {
        let s = try session()
        let v = lookTab(s, galleryOpen: true)
        var c = Canvas(width: 340, height: 4000, atlas: nil, scale: 1)
        v.draw(&c)
        let look = try #require(CaptionStyleLooks.looks(in: .entrance).first)
        let tile = try #require(v.gallery.frame(of: look.id))
        // The gallery sits right under the Looks header (scope row + header above it).
        let top = try #require(v.frame(.header(.looks))).maxY
        let p = CGPoint(x: tile.midX, y: top + tile.midY)
        v.mouseMoved(to: p)
        #expect(v.tick())                                       // the hovered tile previews
        v.mouseDown(at: p, clickCount: 1)
        v.mouseUp(at: p)
        #expect(s.currentCaptionStyleLook?.id == look.id)
    }

    @Test func styleKitRowsEditBrandTokens() throws {
        let s = try session()
        s.editStyleKit(name: "Kit") { $0.fonts["brand"] = "Inter"; $0.colors["accent"] = EffectColor(red: 1, green: 0, blue: 0, alpha: 1) }
        UserDefaults.standard.set(true, forKey: TextBlockDraw.sectionKey(CaptionStyleTabDraw.Section.kit.rawValue))
        let v = CaptionStyleTabDraw(session: s)
        v.size = CGSize(width: 340, height: 4000)
        v.clock = { 10 }
        v.refresh()
        defer { UserDefaults.standard.set(false, forKey: TextBlockDraw.sectionKey(CaptionStyleTabDraw.Section.kit.rawValue)) }
        var menus: [[SQMenuItem]] = []
        v.onMenu = { items, _ in menus.append(items) }
        try click(v, .motionCurve)
        let curve = try #require(menus.last)
        #expect(curve.count == MotionCurve.titles.count)
        curve[0].action?()
        #expect(s.project.styleKit?.motion?.curve == 0)
        var change: ((EffectColor?) -> Void)?
        v.onPickColor = { _, _, ch in change = ch }
        try click(v, .brandColor("accent"))
        change?(EffectColor(red: 0, green: 1, blue: 0, alpha: 1))
        change?(EffectColor(red: 0, green: 0, blue: 1, alpha: 1))
        change?(nil)
        #expect(s.project.styleKit?.colors["accent"]?.blue == 1)
        #expect(s.undo())                                       // one picker session = one undo step
        #expect(s.project.styleKit?.colors["accent"]?.red == 1)
    }

    @Test func templatesTabFiltersAndPlacesATextClip() throws {
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "t", frameDuration: Time(1, 30),
                                                                                tracks: [Track(kind: .video)])]))
        let panel = TextPanelDraw(session: s)
        panel.size = CGSize(width: 340, height: 600)
        var shown = 0
        panel.onShowTemplates = { shown += 1 }
        panel.select(.templates)
        #expect(shown == 1)
        panel.templates.allTiles = TextTemplateTile.tiles(presets: [], builtIns: TextTemplateCatalog.all)
        let plain = try #require(panel.templates.shownTiles.first { tile in
            guard case .builtIn(let id) = tile.source, let e = TextTemplateCatalog.entry(id: id) else { return false }
            return !e.isCTA && e.graphicPresetID == nil
        })
        let before = s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0
        TextTemplatePlacement.place(plain, presets: [], session: s)
        #expect((s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0) == before + 1)
        #expect(TextTemplateTile.filter(panel.templates.allTiles, query: "zzzz-none").isEmpty)
    }

    @Test func textBlockShowsKitTokenRowsAndTheLookGallery() throws {
        let m = TextInspectorModel(style: TextStyle(), fontFamilies: { ["Inter", "Georgia"] })
        let b = TextBlockDraw(model: m)
        b.width = 360
        #expect(b.frame(.token(.font), .text) == nil)           // no kit: no token rows
        m.kit = StyleKit(fonts: ["brand": "Georgia"])
        let f = try #require(b.frame(.token(.font), .text))
        var items: [SQMenuItem] = []
        b.onMenu = { i, _, _ in items = i }
        b.mouseDown(at: CGPoint(x: f.midX, y: f.midY), part: .text, clickCount: 1)
        #expect(items.map(\.title) == ["Literal", "brand"])
        items[1].action?()
        #expect(m.boundToken(.font) == "brand")
        #expect(m.style.fontName == "Georgia")

        UserDefaults.standard.set(true, forKey: TextBlockDraw.sectionKey("textblock.animation"))
        defer { UserDefaults.standard.removeObject(forKey: TextBlockDraw.sectionKey("textblock.animation")) }
        let g = TextBlockDraw(model: m)
        g.width = 360
        #expect(g.frame(.gallery, .animation) == nil)
        g.showsLookGallery = true
        let gf = try #require(g.frame(.gallery, .animation))
        let look = try #require(CaptionStyleLooks.looks(in: .entrance).first)
        let tile = try #require(g.lookGallery.frame(of: look.id))
        let p = CGPoint(x: gf.minX + tile.midX, y: gf.minY + tile.midY)
        g.mouseMoved(to: p, part: .animation)
        g.mouseDown(at: p, part: .animation, clickCount: 1)
        g.mouseUp(at: p, part: .animation)
        #expect(m.currentLookID == look.id)
    }

    @Test func savedTemplatesFromTheLibraryLeadTheTilesAndPlace() throws {
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "t", frameDuration: Time(1, 30),
                                                                                tracks: [Track(kind: .video)])]))
        let panel = TextPanelDraw(session: s)
        panel.size = CGSize(width: 340, height: 600)
        let builtIns = panel.templates.allTiles.count
        #expect(builtIns == TextTemplateCatalog.all.count)
        let t = TextTemplate(name: "Mine", text: "Saved", style: TextStyle())
        let item = PresetItem(kind: .textTemplate, name: "Mine", payload: try t.encoded(), payloadVersion: 1)
        panel.setLibrary([item])
        let first = try #require(panel.templates.allTiles.first)
        #expect(first.name == "Mine" && panel.templates.allTiles.count == builtIns + 1)
        var status: [String] = []
        panel.onStatus = { status.append($0) }
        let before = s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0
        panel.templates.onPick?(first)
        #expect((s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0) == before + 1)
        #expect(status.isEmpty)
    }

    @Test func menusAndPickersArriveInPanelPoints() throws {
        let s = try session()
        let panel = TextPanelDraw(session: s)
        panel.size = CGSize(width: 340, height: 600)
        var anchors: [CGRect] = []
        panel.onMenu = { _, a in anchors.append(a) }
        panel.style.onMenu?([], CGRect(x: 10, y: 20, width: 5, height: 5))
        panel.captions.onMenu?([], CGRect(x: 10, y: 20, width: 5, height: 5))
        #expect(anchors.map(\.minY) == [20 + TextPanelDraw.barHeight, 20 + TextPanelDraw.barHeight])
        // Without a host picker the swatch closes at once (no open color gesture).
        var closed = false
        panel.style.onPickColor?(EffectColor(red: 1, green: 1, blue: 1, alpha: 1), .zero) { closed = $0 == nil }
        #expect(closed)
        var picked: CGRect?
        panel.onPickColor = { _, a, _ in picked = a }
        panel.style.onPickColor?(EffectColor(red: 1, green: 1, blue: 1, alpha: 1), CGRect(x: 0, y: 4, width: 1, height: 1)) { _ in }
        #expect(picked?.minY == 4 + TextPanelDraw.barHeight)
    }

    /// SQSegmented geometry: 8 pt bar padding plus 1 pt track padding before the first segment; segments touch each other.
    @Test func tabSwitchStartsAtMacTrackPadding() throws {
        let panel = TextPanelDraw(session: try session())
        panel.size = CGSize(width: 340, height: 600)
        let first = panel.frame(panel.tabs[0]), second = panel.frame(panel.tabs[1])
        #expect(first.minX == TextPanelDraw.pad + TextPanelDraw.trackPadding)
        #expect(second.minX == first.maxX)
    }
}
