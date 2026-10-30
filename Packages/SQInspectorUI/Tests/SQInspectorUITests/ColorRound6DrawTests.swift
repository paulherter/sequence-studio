import Foundation
import CoreGraphics
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// Color page on the shared toolkit, round 6: Color settings pointer shapes and tips (the Mac `ColorWheelControl` /
/// `ColorCurveEditor` / `ScrubField` cursor rects), the viewer header's compact segment (SQSegmented), and the wheel
/// backdrop drawn from the span cache without a change.
@MainActor @Suite struct ColorRound6DrawTests {
    /// The cursor `panel` asks for during `event` at `p` (view points).
    func cursor(_ panel: ColorGradeDraw, _ p: CGPoint, _ event: (CGPoint) -> Void) -> DrawCursor? {
        let hover = HostHover()
        return HostHover.$current.withValue(hover) {
            hover.beginEvent(.mouseMoved(x: Float(p.x), y: Float(p.y)))
            event(p)
            hover.endEvent(.mouseMoved(x: Float(p.x), y: Float(p.y)), now: 0)
            return hover.cursor
        }
    }

    @Test func wheelsCurvesAndFieldsShowTheMacPointerShapes() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let id = try #require(panel.model?.effects.first?.id)
        let w = ColorGradeDraw.Wheel.slot(id, .midtones)
        let disc = try #require(panel.frame(.wheel(w)))
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - panel.scrollY) }
        // The puck (centered at rest) is the open hand, the rest of the disc the arrow.
        #expect(cursor(panel, view(CGPoint(x: disc.midX, y: disc.midY))) { panel.mouseMoved(to: $0) } == .openHand)
        #expect(cursor(panel, view(CGPoint(x: disc.midX + disc.width * 0.35, y: disc.midY))) { panel.mouseMoved(to: $0) } == nil)
        // The vertical master slider beside the disc drags up and down.
        let m = try #require(panel.frame(.master(w)))
        #expect(cursor(panel, view(CGPoint(x: m.midX, y: m.midY))) { panel.mouseMoved(to: $0) } == .resizeUpDown)
        // A curve: the crosshair over the plot, the open hand over a point; a drag holds the closed hand.
        let curve = try #require(panel.frame(.curve(.rgb(id))))
        #expect(cursor(panel, view(CGPoint(x: curve.minX + curve.width * 0.3, y: curve.minY + 10))) { panel.mouseMoved(to: $0) } == .crosshair)
        #expect(cursor(panel, view(CGPoint(x: curve.minX + 1, y: curve.maxY - 1))) { panel.mouseMoved(to: $0) } == .openHand)
        let start = view(CGPoint(x: disc.midX, y: disc.midY))
        panel.mouseDown(at: start, clickCount: 1)
        #expect(cursor(panel, CGPoint(x: start.x + 10, y: start.y)) { panel.mouseDragged(to: $0) } == .closedHand)
        panel.mouseUp(at: CGPoint(x: start.x + 10, y: start.y))
        #expect(cursor(panel, view(CGPoint(x: m.midX, y: m.midY))) { panel.mouseMoved(to: $0) } == .resizeUpDown)
        // A slider's number field scrubs sideways; the track keeps the arrow.
        let s = try #require(panel.frame(.slider(.param(id, .exposure))))
        let parts = panel.sliderParts(s)
        #expect(cursor(panel, view(CGPoint(x: parts.field.midX, y: parts.field.midY))) { panel.mouseMoved(to: $0) } == .resizeLeftRight)
        #expect(cursor(panel, view(CGPoint(x: parts.track.midX, y: s.midY))) { panel.mouseMoved(to: $0) } == nil)
    }

    @Test func simpleProAndTheHueCurveHaveTheirMacTips() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let id = try #require(panel.model?.effects.first?.id)
        let tools = ColorStripToolsDraw(controller: panel.controller)
        let strip = CGRect(x: 0, y: 0, width: 800, height: 28)
        let g = try #require(tools.frames(.colorInspector, strip: strip).first { $0.0 == .pro }).1
        #expect(tools.help(panel: .colorInspector, strip: strip, at: CGPoint(x: g.midX, y: g.midY))
                == "Simple: the guided controls. Pro: the Color Graph of Steps. The other grade keeps its values.")
        let hue = try #require(panel.frame(.curve(.hue(id))))
        #expect(panel.help(at: CGPoint(x: hue.midX, y: hue.midY - panel.scrollY)) == panel.hueKind(id).explanation)
        // The RGB curve has no tip.
        let rgb = try #require(panel.frame(.curve(.rgb(id))))
        #expect(panel.help(at: CGPoint(x: rgb.midX, y: rgb.midY - panel.scrollY)) == nil)
    }

    @Test func viewerHeaderSegmentFitsItsLabelsLikeSQSegmented() throws {
        let (_, grade, _) = try ColorGradeDrawTests().rig()
        let atlas = try #require(GlyphAtlas())
        let h = ColorViewerHeaderDraw(controller: grade.controller)
        h.size = CGSize(width: 800, height: 30)
        var c = Canvas(width: 800, height: 30, atlas: atlas, scale: 1)
        h.draw(&c)
        let fr = h.frames()
        let before = try #require(fr.first { $0.0 == .compare(.before) }?.1)
        let after = try #require(fr.first { $0.0 == .compare(.after) }?.1)
        let split = try #require(fr.first { $0.0 == .compare(.split) }?.1)
        let more = try #require(fr.first { $0.0 == .more }?.1)
        // Each segment is its label plus 20; the segments touch; 1 pt track padding; 6 pt to the 24 wide more button.
        for (m, r) in [(ColorCompareMode.before, before), (.after, after), (.split, split)] {
            #expect(r.width == ceil(c.size(of: m.title, fontSize: CGFloat(DrawTheme.TypeSize.body)).width) + 20)
        }
        #expect(before.maxX == after.minX && after.maxX == split.minX)
        let track = h.trackRect(fr)
        #expect(track.maxX == split.maxX + 1 && track.minX == before.minX - 1 && track.height == 22)
        #expect(more.width == 24 && more.maxX == 800 - 8 && more.minX - track.maxX == 6)
        // A click anywhere in a segment's column (full header height) picks it, as on the Mac.
        h.mouseDown(at: CGPoint(x: split.midX, y: 1))
        #expect(grade.controller.compare == .split)
        h.mouseDown(at: CGPoint(x: before.minX - 1, y: 29))
        #expect(grade.controller.compare == .before)
        grade.controller.setCompare(.after)
    }

    @Test func wheelBackdropRedrawsTheSameQuads() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let atlas = try #require(GlyphAtlas())
        panel.size = CGSize(width: 376, height: 900)
        var a = Canvas(width: 376, height: 900, atlas: atlas, scale: 2)
        panel.draw(&a)
        var b = Canvas(width: 376, height: 900, atlas: atlas, scale: 2)
        panel.draw(&b)
        #expect(a.list.quads == b.list.quads)
        // The cached wedges are exactly the direct fill's spans.
        var direct = Canvas(width: 400, height: 400, atlas: nil, scale: 2)
        for (pts, col) in ColorGradeDraw.wedges(radius: 40) { direct.fill(polygon: pts.map { CGPoint(x: $0.x + 10.5, y: $0.y + 20) }, col) }
        var cached = Canvas(width: 400, height: 400, atlas: nil, scale: 2)
        cached.fill(polygons: ColorGradeDraw.wedges(radius: 40), at: CGPoint(x: 10.5, y: 20), key: 40.0, cache: PolygonSpanCache())
        #expect(cached.list.quads.count == direct.list.quads.count && cached.list.quads.count > 1000)
    }
}
