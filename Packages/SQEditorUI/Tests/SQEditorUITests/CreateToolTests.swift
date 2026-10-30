import AppKit
import Foundation
import Testing
import SQCore
import SQEditorSession
import SQUIKit
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQMonitorUI
@testable import SQTimelineUI

/// The Create tool slot (Text, Rectangle, Ellipse, Line, Draw) and its drag on the Program monitor.
@MainActor @Suite struct CreateToolTests {
    @Test func theCreateSlotHasFiveModesAndStartsWithText() {
        let s = ToolState()
        #expect(s.createMode == .text)
        #expect(CreateToolMode.allCases.map(\.title) == ["Text", "Rectangle", "Ellipse", "Line", "Draw"])
        #expect(CreateToolMode.allCases.map(\.editorTool) == [.type, .rectangle, .ellipse, .line, .draw])
        for mode in CreateToolMode.allCases {
            #expect(CreateToolMode(editorTool: mode.editorTool) == mode)
            #expect(SQIcon(rawValue: mode.symbol) != nil)
        }
        #expect(CreateToolMode(editorTool: .razor) == nil)
        #expect(CreateToolMode.rectangle.shapeKind == .rectangle)
        #expect(CreateToolMode.ellipse.shapeKind == .ellipse)
        #expect(CreateToolMode.line.shapeKind == .line)
        #expect(CreateToolMode.text.shapeKind == nil && CreateToolMode.draw.shapeKind == nil)
    }

    /// T stays Text; the shape modes sit on Option+Shift (R, O, L and P are Stretch, Mark Out, Shuttle and Mask).
    @Test func everyModeHasItsOwnKey() {
        let map = CommandMap.premiereDefault
        #expect(map.duplicates.isEmpty)
        #expect(map.command(for: KeyBinding(.char("t")), focus: .timeline) == .tool(.type))
        #expect(map.command(for: KeyBinding(.char("r"), [.option, .shift]), focus: .timeline) == .tool(.rectangle))
        #expect(map.command(for: KeyBinding(.char("e"), [.option, .shift]), focus: .timeline) == .tool(.ellipse))
        #expect(map.command(for: KeyBinding(.char("l"), [.option, .shift]), focus: .timeline) == .tool(.line))
        #expect(map.command(for: KeyBinding(.char("d"), [.option, .shift]), focus: .timeline) == .tool(.draw))
        #expect(map.command(for: KeyBinding(.char("r")), focus: .timeline) == .tool(.rateStretch))
        #expect(EditorCommand.tool(.rectangle).title == "Rectangle Tool")
        #expect(EditorCommand.tool(.draw).title == "Draw Tool")
    }

    @Test func theSlotMenuPicksAModeAndTellsTheMonitor() throws {
        let strip = ToolStripView()
        // The menu opens with its "Create" title row (v9: every slot menu is titled); the modes follow.
        #expect(strip.createModeItems().first?.kind == .header && strip.createModeItems().first?.title == "Create")
        let items = strip.createModeItems().filter { $0.kind == .action }
        #expect(items.map(\.title) == ["Text", "Rectangle", "Ellipse", "Line", "Draw"])
        #expect(items.map(\.isChecked) == [true, false, false, false, false])
        items[2].action?()
        #expect(strip.toolState.tool == .type)
        #expect(strip.toolState.createMode == .ellipse)
        #expect(strip.toolButtons.first { $0.tool == .type }?.button.sqToolTip?.hasPrefix("Create: Ellipse") == true)
        #expect(strip.createModeItems().filter { $0.kind == .action }.map(\.isChecked) == [false, false, true, false, false])
        #expect(ToolStripView.editorTool(.type) == .type)
    }

    @Test func theToolTipNamesTheModeItsKeyAndTheOthers() {
        let tip = ToolStripView.createToolTip(.rectangle, map: .premiereDefault)
        #expect(tip.hasPrefix("Create: Rectangle"))
        #expect(tip.hasSuffix("Adds an item to a Graphic clip. Hold for the shape."))   // v9 tooltip: title with key, then what it does
        #expect(ToolStripView.createToolTip(.text, map: .premiereDefault).contains("T"))
    }

    // MARK: The drag

    @Test func aClickIsNotADrag() {
        var d = CreateToolDrag(mode: .rectangle, start: CGPoint(x: 100, y: 100))
        #expect(!d.isDrag(minimum: 6))
        d.move(to: Vec2(103, 104), constrain: false, fromCenter: false)
        #expect(!d.isDrag(minimum: 6))
        d.move(to: Vec2(100, 107), constrain: false, fromCenter: false)
        #expect(d.isDrag(minimum: 6))
    }

    @Test func theOutlineFollowsTheModeAndTheModifiers() {
        var r = CreateToolDrag(mode: .rectangle, start: CGPoint(x: 10, y: 10))
        r.move(to: Vec2(110, 60), constrain: false, fromCenter: false)
        #expect(r.outline == .box(GraphicsRect(minX: 10, minY: 10, maxX: 110, maxY: 60), ellipse: false))
        r.move(to: Vec2(110, 60), constrain: true, fromCenter: false)
        #expect(r.outline == .box(GraphicsRect(minX: 10, minY: 10, maxX: 110, maxY: 110), ellipse: false))
        var e = CreateToolDrag(mode: .ellipse, start: CGPoint(x: 50, y: 50))
        e.move(to: Vec2(70, 60), constrain: false, fromCenter: true)
        #expect(e.outline == .box(GraphicsRect(minX: 30, minY: 40, maxX: 70, maxY: 60), ellipse: true))
        var l = CreateToolDrag(mode: .line, start: CGPoint(x: 0, y: 0))
        l.move(to: Vec2(100, 4), constrain: true, fromCenter: false)
        guard case .line(let a, let b) = l.outline else { Issue.record("not a line"); return }
        #expect(a == .zero)
        #expect(b.y == 0 && b.x > 100)
    }

    @Test func aStrokeRecordsPointsNoCloserThanItsStep() {
        var d = CreateToolDrag(mode: .draw, start: CGPoint(x: 0, y: 0))
        for i in 1...100 { d.move(to: Vec2(Double(i) * 0.5, 0), constrain: false, fromCenter: false) }
        guard case .stroke(let pts) = d.outline else { Issue.record("not a stroke"); return }
        #expect(pts.count == 26)   // 50 pt in 2 pt steps, plus the press point
        #expect(d.isDrag(minimum: 6))
        #expect(d.sizeLabel(viewPointsPerPixel: 1) == nil)
    }

    @Test func theSizeLabelIsInSequencePixels() {
        var r = CreateToolDrag(mode: .rectangle, start: CGPoint(x: 0, y: 0))
        r.move(to: Vec2(48, 24), constrain: false, fromCenter: false)
        #expect(r.sizeLabel(viewPointsPerPixel: 0.5) == "96 × 48")
        var l = CreateToolDrag(mode: .line, start: CGPoint(x: 0, y: 0))
        l.move(to: Vec2(30, 40), constrain: false, fromCenter: false)
        #expect(l.sizeLabel(viewPointsPerPixel: 0.5) == "100")
        #expect(l.sizeLabel(viewPointsPerPixel: 0) == nil)
    }

    // MARK: Monitor interaction table and the stroke layer

    @Test func aShapeModeNeverStartsOrEditsText() {
        for hit in [MonitorTextInteraction.Hit.empty, .textLayer] {
            let actions = MonitorTextInteraction.actions(tool: .create(.rectangle), hit: hit, editing: true, event: .click)
            #expect(actions == [.endEditing])
            #expect(MonitorTextInteraction.actions(tool: .create(.draw), hit: hit, editing: false, event: .click).isEmpty)
        }
    }

    @Test func aDrawnStrokeBecomesAReducedPathLayer() throws {
        let pts = (0...200).map { i in Vec2(Double(i) * 2, i % 2 == 0 ? 0.5 : -0.5) }
        let layer = try #require(GraphicsEditor.strokeLayer(pts, tolerance: 2))
        guard case .path(let out, let closed) = layer.content else { Issue.record("not a path"); return }
        #expect(!closed)
        #expect(out.count == 2)
        #expect(GraphicsEditor.strokeLayer([Vec2(1, 1)], tolerance: 2) == nil)
    }

    // MARK: Where the new item lands

    @Test func aNewGraphicNeverOverwritesFootage() throws {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                        mediaDuration: Time(60, 1))
        var v = Track(kind: .video, isTargeted: true)
        try v.overwrite(clip)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                          tracks: [v, Track(kind: .audio, isTargeted: true)])
        let s = EditorSession(project: Project(name: "P", timelines: [tl]))
        let before = try #require(s.activeTimeline)
        let layer = GraphicsEditor.createdShape(.rectangle, from: Vec2(-100, -50), to: Vec2(100, 50),
                                                mapping: GraphicsCanvasMapping(transform: ClipTransform()), canvas: Vec2(1920, 1080))
        let id = try #require(s.addGraphicsClip(at: Time(2, 1), duration: Time(5, 1), layers: [layer], neverOverwrite: true))
        let after = try #require(s.activeTimeline)
        let video = after.tracks.filter { $0.kind == .video }
        #expect(video.count == 2)
        // The footage is whole, the Graphic sits on the new track above it.
        #expect(video[0].clips == before.tracks[0].clips)
        #expect(video[1].clips.map(\.id) == [id])
        #expect(video[1].clips.first?.graphics?.layers.map(\.id) == [layer.id])
        s.undo()
        #expect(s.activeTimeline == before)
    }

    @Test func aShapeLandsUnderThePreviewInARotatedGraphic() throws {
        let a = Vec2(40, -120), b = Vec2(340, 80)
        let upright = [Vec2(a.x, a.y), Vec2(b.x, a.y), Vec2(b.x, b.y), Vec2(a.x, b.y)]
        for transform in [ClipTransform(), ClipTransform(position: Vec2(60, -30), scale: Vec2(2, 2), rotation: 45)] {
            let map = GraphicsCanvasMapping(transform: transform)
            for kind in [ShapeKind.rectangle, .ellipse] {
                let layer = GraphicsEditor.createdShape(kind, from: a, to: b, mapping: map, canvas: Vec2(1920, 1080))
                #expect(layer.animation.rotation.value(atLocal: .zero) == -transform.rotation)
                let corners = try #require(layer.corners(atLocal: .zero)).map(map.sequenceOffset(fromCanvas:))
                for (got, want) in zip(corners, upright) {
                    #expect(abs(got.x - want.x) < 1e-6 && abs(got.y - want.y) < 1e-6)
                }
            }
        }
    }
}
