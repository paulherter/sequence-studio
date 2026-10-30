import Foundation
import Testing
import SQCore
import SQDrawKit
@testable import SQInspectorUI

/// Controls > Graphic item rows on the shared toolkit (the Mac `GraphicItemRows`): Corners, Fill and Outline for two or
/// more shape items, the text box for a text item; edits go through the one `GraphicsEditor`, one undo step per gesture.
@MainActor @Suite(.serialized) struct GraphicItemRowsDrawTests {
    func rig(_ kinds: [ShapeKind] = [.rectangle, .rectangle]) -> (EditorSession, GraphicsEditor, ClipSectionsDraw) {
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let e = GraphicsEditor(session: session)
        e.newGraphicsClip()
        for k in kinds { e.addShape(k) }
        let sec = ClipSectionsDraw(session: session)
        sec.width = 360
        sec.graphicsEditor = e
        sec.sync([.project, .selection])
        return (session, e, sec)
    }

    func titles(_ sec: ClipSectionsDraw) -> [String] {
        sec.itemRows.form.rows.compactMap {
            switch $0.kind {
            case .numbers(let t, _, _), .appearance(let t, _, _, _, _, _, _): t
            default: nil
            }
        }
    }

    /// Center of `part` of the item row titled `title`, in section coordinates.
    func point(_ sec: ClipSectionsDraw, _ title: String, _ part: GraphicsFormDraw.Part) -> CGPoint? {
        let f = sec.itemRows.form
        for (r, y) in f.visible {
            switch r.kind {
            case .numbers(let t, _, _) where t == title, .appearance(let t, _, _, _, _, _, _) where t == title:
                guard let box = f.frame(part, of: r, y: y) else { return nil }
                return CGPoint(x: box.midX, y: box.midY + sec.itemsTop + sec.itemRows.boxRowHeight)
            default: continue
            }
        }
        return nil
    }

    func click(_ sec: ClipSectionsDraw, _ p: CGPoint) { sec.mouseDown(at: p, clickCount: 1); sec.mouseUp(at: p) }

    @Test func severalRectanglesShowCornersFillOutline() {
        let (_, e, sec) = rig()
        #expect(sec.mode == .graphic)
        e.select([])
        sec.graphicItemsChanged()
        #expect(titles(sec).isEmpty && sec.itemRows.height == 0)        // nothing picked: no rows
        let h0 = sec.height
        var grew = 0
        sec.onHeightChange = { grew += 1 }
        e.selectAllLayers()
        sec.graphicItemsChanged()
        #expect(titles(sec) == ["Corners", "Fill", "Outline"])
        #expect(grew == 1 && sec.height == h0 + 3 * ControlsGrid.rowHeight)
        var c = Canvas(width: 360, height: 400, atlas: nil, scale: 1)
        sec.draw(&c)
    }

    @Test func anEllipseDropsCornersAndLinesDropFill() {
        let (_, e, sec) = rig([.rectangle, .ellipse])
        e.selectAllLayers(); sec.graphicItemsChanged()
        #expect(titles(sec) == ["Fill", "Outline"])
        let (_, e2, sec2) = rig([.line, .arrow])
        e2.selectAllLayers(); sec2.graphicItemsChanged()
        #expect(titles(sec2) == ["Outline"])
    }

    @Test func typedCornersAreOneUndoStepOnEveryItem() throws {
        let (s, e, sec) = rig()
        e.selectAllLayers(); sec.graphicItemsChanged()
        let at = try #require(point(sec, "Corners", .field(0)))
        click(sec, at)
        for ch in "24" { _ = sec.key(.character(ch), modifiers: []) }
        _ = sec.key(.enter, modifiers: [])
        let p = GraphicsEditor.Property.shape(ClipEffect.shapeCornerRadiusKey)
        #expect(e.value(p) == 24)
        #expect(s.undo())
        #expect(e.value(p) != 24)
    }

    @Test func fillCheckTurnsTheFillOff() throws {
        let (s, e, sec) = rig()
        e.selectAllLayers(); sec.graphicItemsChanged()
        let on = e.shapeValue(ClipEffect.shapeFillKey).map { $0 >= 0.5 }
        let at = try #require(point(sec, "Fill", .appCheck))
        click(sec, at)
        #expect(e.shapeValue(ClipEffect.shapeFillKey).map { $0 >= 0.5 } == on.map { !$0 })
        #expect(s.undo())
        #expect(e.shapeValue(ClipEffect.shapeFillKey).map { $0 >= 0.5 } == on)
    }

    @Test func textItemShowsTheBoxAndTypesOneUndoStep() throws {
        let (s, e, sec) = rig([])
        e.addText()
        let id = try #require(e.document?.layers.first?.id)
        e.select([id])
        sec.sync([.project, .selection])
        sec.graphicItemsChanged()
        try #require(sec.mode == .graphic)
        let before = try #require(e.textTemplate?.text)
        #expect(sec.itemRows.boxText == before && sec.itemRows.boxRowHeight > 0)
        let box = sec.itemRows.boxFrame
        click(sec, CGPoint(x: box.maxX - 2, y: box.maxY - 2 + sec.itemsTop))
        #expect(sec.itemRows.isTyping)
        for ch in "ab" { _ = sec.key(.character(ch), modifiers: []) }
        #expect(e.textTemplate?.text.hasSuffix("ab") == true)
        _ = sec.key(.escape, modifiers: [])
        #expect(!sec.itemRows.isTyping)
        #expect(s.undo())
        #expect(e.textTemplate?.text == before)
    }
}
