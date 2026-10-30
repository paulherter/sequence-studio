import Foundation
import Testing
@testable import SQDrawKit

@Suite struct HostHoverTests {
    private func move(_ h: HostHover, _ tip: String?, at x: Float = 100, now: Double) {
        let e = InputEvent.mouseMoved(x: x, y: 50)
        h.beginEvent(e)
        h.offerTip(tip)
        h.endEvent(e, now: now)
    }

    @Test func tipShowsAfterTheDelayAndHidesOnExit() {
        let h = HostHover()
        move(h, "Snapping (S)", now: 10)
        #expect(!h.tooltip.isVisible(now: 10.5))
        #expect(h.needsFrame(now: 10.5))
        #expect(h.tooltip.isVisible(now: 10.8))
        move(h, "Snapping (S)", at: 104, now: 11)            // moving inside the control keeps it
        #expect(h.tooltip.isVisible(now: 11) && h.tooltip.anchor.x == 100)
        move(h, nil, now: 12)
        #expect(!h.tooltip.isVisible(now: 20))
    }

    @Test func neighborShowsAtOnceAfterATipClosedByLeaving() {
        let h = HostHover()
        move(h, "A", now: 0)
        var c = Canvas(width: 400, height: 300, atlas: nil, scale: 1)
        h.drawTooltip(&c, theme: DrawTheme(), now: 1)          // shown
        move(h, "B", now: 1.2)
        #expect(h.tooltip.isVisible(now: 1.2))
        move(h, nil, now: 2)
        move(h, "C", now: 3)                                   // 1 s after: the full delay again
        #expect(!h.tooltip.isVisible(now: 3.5))
    }

    @Test func pressHidesTheTipUntilAnotherControl() {
        let h = HostHover()
        move(h, "A", now: 0)
        h.beginEvent(.mouseDown(x: 100, y: 50, modifiers: []))
        #expect(!h.tooltip.isVisible(now: 5))
        move(h, "A", now: 6)
        #expect(!h.tooltip.isVisible(now: 9))
        move(h, "B", now: 10)
        #expect(h.tooltip.isVisible(now: 10.8))
    }

    @Test func firstOfferWinsAndOnlyDuringAMove() {
        let h = HostHover()
        h.offerTip("outside a move")
        let e = InputEvent.mouseMoved(x: 1, y: 1)
        h.beginEvent(e)
        h.offerTip("top"); h.offerTip("below")
        h.endEvent(e, now: 0)
        #expect(h.tooltip.text == "top")
    }

    @Test func cursorRequestLastsUntilTheNextMouseEvent() {
        let h = HostHover()
        h.beginEvent(.mouseMoved(x: 0, y: 0))
        h.request(.razor)
        h.request(nil)
        #expect(h.cursor == .razor)
        h.beginEvent(.keyDown(.space, modifiers: []))
        #expect(h.cursor == .razor)
        h.beginEvent(.mouseMoved(x: 1, y: 0))
        #expect(h.cursor == nil)
    }

    @Test func keyIsSplitIntoAChip() {
        #expect(TooltipLayout.split("Snapping (S)") == ("Snapping", "S"))
        #expect(TooltipLayout.split("Lock Track") == ("Lock Track", nil))
    }

    @Test func frameStaysInsideTheWindow() {
        let b = CGSize(width: 300, height: 200), s = CGSize(width: 80, height: 30)
        let f = TooltipLayout.frame(size: s, pointer: CGPoint(x: 290, y: 190), bounds: b)
        #expect(f.maxX <= 296 && f.maxY <= 196 && f.minX >= 4 && f.minY >= 4)
        let g = TooltipLayout.frame(size: s, pointer: CGPoint(x: 20, y: 20), bounds: b)
        #expect(g.origin == CGPoint(x: 30, y: 38))
    }

    @Test func drawnTipUsesTheOverlayToken() {
        let h = HostHover()
        move(h, "Lock Track", now: 0)
        var c = Canvas(width: 400, height: 300, atlas: nil, scale: 2)
        h.drawTooltip(&c, theme: DrawTheme(), now: 1)
        #expect(c.list.quads.first?.color == DrawTheme().overlay)
    }

    @Test func toolCursorsRenderWithAHaloAndTransparentCorners() throws {
        for cur in DrawCursor.allCases {
            let img = DrawCursorImage.render(cur, scale: 1)
            #expect((img != nil) == cur.hasDrawnGlyph)
        }
        // Drag copy and zoom have no Windows system cursor: drawn too (the Mac keeps NSCursor for them).
        #expect(DrawCursor.dragCopy.hasDrawnGlyph && DrawCursor.zoomIn.hasDrawnGlyph)
        #expect(!DrawCursor.dragCopy.isToolGlyph && !DrawCursor.arrow.hasDrawnGlyph)
        let copy = try #require(DrawCursorImage.render(.dragCopy, scale: 1))
        #expect(copy.image.pixels[(12 * 24 + 12) * 4 + 3] > 0)                 // the arrow's tip on the hot spot
        let img = try #require(DrawCursorImage.render(.trimIn, scale: 2))
        #expect(img.image.width == 48 && img.hotX == 24 && img.hotY == 24)
        #expect(img.image.pixels[3] == 0)                                     // corner: clear
        let center = (24 * 48 + 24) * 4                                       // the bar: opaque black
        #expect(img.image.pixels[center + 3] > 200 && img.image.pixels[center] < 60)
        let halo = (24 * 48 + 24 + 4) * 4                                     // beside the shaft... still the shaft
        #expect(img.image.pixels[halo + 3] > 0)
    }
}


@Suite struct DrawCursorTransformTests {
    @Test func resizeAngleMapsToAxisOrDiagonal() {
        #expect(DrawCursor.resize(angle: 0) == .resizeLeftRight)
        #expect(DrawCursor.resize(angle: 180) == .resizeLeftRight)
        #expect(DrawCursor.resize(angle: 45) == .resizeDiagonalDown)
        #expect(DrawCursor.resize(angle: 225) == .resizeDiagonalDown)
        #expect(DrawCursor.resize(angle: 90) == .resizeUpDown)
        #expect(DrawCursor.resize(angle: 135) == .resizeDiagonalUp)
        #expect(DrawCursor.resize(angle: -45) == .resizeDiagonalUp)
    }

    @Test func rotateAngleMapsToItsCorner() {
        #expect(DrawCursor.rotate(angle: 45) == .rotateBottomRight)
        #expect(DrawCursor.rotate(angle: 135) == .rotateBottomLeft)
        #expect(DrawCursor.rotate(angle: 225) == .rotateTopLeft)
        #expect(DrawCursor.rotate(angle: -45) == .rotateTopRight)
        for c in DrawCursor.allCases { if let a = c.rotateAngle { #expect(DrawCursor.rotate(angle: a) == c) } }
    }

    @Test func rotateCursorsAreDrawnOnBothHosts() {
        for c in DrawCursor.allCases where c.rotateAngle != nil {
            #expect(c.hasDrawnGlyph)
            let img = DrawCursorImage.render(c, scale: 2)
            #expect(img != nil && img!.image.pixels.contains { $0 != 0 })
        }
        // The system has diagonal and four-way shapes; the hosts map them, no drawn glyph.
        for c: DrawCursor in [.resizeDiagonalDown, .resizeDiagonalUp, .move] { #expect(!c.hasDrawnGlyph) }
        // The two corners facing each other draw mirrored strokes, not the same ones.
        #expect(DrawCursorGlyph.strokes(.rotateTopLeft) != DrawCursorGlyph.strokes(.rotateBottomRight))
    }
}
