import Foundation
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

/// The draw-list tool strip: the Mac `ToolStripView` / `ToolStripDockView` behavior through `InputEvent`s.
@Suite("ToolStrip")
struct ToolStripTests {
    final class Clock: @unchecked Sendable { var now = 100.0 }

    private func strip(_ edge: ToolStripEdge = .left, clock: Clock = Clock()) -> ToolStrip {
        var s = ToolStrip()
        s.followsPrefs = false
        s.edge = edge
        s.visible = true
        s.floatOrigin = CGPoint(x: 40, y: 40)
        s.clock = { clock.now }
        _ = s.layout(DrawRect(x: 0, y: 0, w: 1600, h: 600), scale: 2)   // 800 x 300 pt
        return s
    }

    private func click(_ s: inout ToolStrip, _ p: CGPoint, state: ToolState = ToolState(), secondary: Bool = false) -> [ToolStripAction] {
        let x = Float(p.x * 2), y = Float(p.y * 2)
        var out = s.handle(.mouseDown(x: x, y: y, modifiers: secondary ? .secondary : []), state: state) ?? []
        out += s.handle(.mouseUp(x: x, y: y), state: state) ?? []
        return out
    }

    @Test func dockedLeftTakesItsColumnFromTheTimeline() {
        var s = strip(.left)
        let content = s.layout(DrawRect(x: 0, y: 0, w: 1600, h: 600), scale: 2)
        #expect(content == DrawRect(x: 76, y: 0, w: 1524, h: 600))
        #expect(s.strip == CGRect(x: 0, y: 0, width: 38, height: 300))
        var hidden = strip(.left)
        hidden.visible = false
        #expect(hidden.layout(DrawRect(x: 0, y: 0, w: 1600, h: 600), scale: 2) == DrawRect(x: 0, y: 0, w: 1600, h: 600))
        // Floating leaves the whole area to the timeline.
        var f = strip(.floating)
        #expect(f.layout(DrawRect(x: 0, y: 0, w: 1600, h: 600), scale: 2) == DrawRect(x: 0, y: 0, w: 1600, h: 600))
        #expect(f.strip.origin == CGPoint(x: 40, y: 40))
    }

    @Test func clickPicksTheSlotsTool() {
        var s = strip()
        let blade = s.slots.tools[1]
        #expect(click(&s, CGPoint(x: blade.midX, y: blade.midY)) == [.setTool({ var t = ToolState(); t.tool = .razor; return t }())])
        // A release off the slot picks nothing.
        let x = Float(blade.midX * 2), y = Float(blade.midY * 2)
        _ = s.handle(.mouseDown(x: x, y: y, modifiers: []), state: ToolState())
        #expect(s.handle(.mouseUp(x: x + 400, y: y), state: ToolState()) == [])
    }

    @Test func holdOrRightPressOpensTheVariants() {
        let clock = Clock()
        var s = strip(clock: clock)
        let slip = s.slots.tools[2]
        let x = Float(slip.midX * 2), y = Float(slip.midY * 2)
        _ = s.handle(.mouseDown(x: x, y: y, modifiers: []), state: ToolState())
        clock.now += 0.2
        #expect(s.tick() == [])
        clock.now += 0.3
        #expect(s.tick() == [.menu(.variants(.slip), at: CGPoint(x: slip.minX, y: slip.maxY))])
        #expect(s.handle(.mouseUp(x: x, y: y), state: ToolState()) == [])     // the release after the menu picks nothing
        #expect(click(&s, CGPoint(x: slip.midX, y: slip.midY), secondary: true) == [.menu(.variants(.slip), at: CGPoint(x: slip.minX, y: slip.maxY))])
        let hand = s.slots.tools[3]
        let p = CGPoint(x: hand.midX, y: hand.midY)
        #expect(click(&s, p, secondary: true) == [.menu(.allTools, at: p)])
    }

    @Test func gripClickOpensEveryToolAndDoubleClickDocksLeft() {
        let clock = Clock()
        var s = strip(.right, clock: clock)
        let g = s.slots.grip
        #expect(click(&s, CGPoint(x: g.midX, y: g.midY)) == [.menu(.allTools, at: CGPoint(x: g.maxX, y: g.minY))])
        clock.now += 0.2
        _ = click(&s, CGPoint(x: g.midX, y: g.midY))
        #expect(s.edge == .left)
    }

    @Test func gripDragDocksAtTheEdgeOrFloats() {
        var s = strip(.left)
        let g = s.slots.grip
        _ = s.handle(.mouseDown(x: Float(g.midX * 2), y: Float(g.midY * 2), modifiers: []), state: ToolState())
        _ = s.handle(.mouseDragged(x: 790 * 2, y: 150 * 2), state: ToolState())
        #expect(s.edge == .right && s.dragTarget == .right)
        _ = s.handle(.mouseDragged(x: 400 * 2, y: 150 * 2), state: ToolState())
        #expect(s.edge == .floating && s.dragTarget == nil)
        _ = s.handle(.mouseUp(x: 400 * 2, y: 150 * 2), state: ToolState())
        #expect(s.edge == .floating && !s.isDragging)
        #expect(s.floatOrigin == CGPoint(x: 400 - ToolStripLayout.floatPadding - ToolStripLayout.rowGripLength / 2,
                                         y: 150 - ToolStripLayout.rowThickness / 2))
    }

    @Test @MainActor func menusPickToolsThroughCommit() {
        let s = strip()
        var picked: ToolState?
        let items = s.items(.variants(.mask), state: ToolState()) { picked = $0 }
        items.last { $0.kind == .action }?.action?()
        #expect(picked?.tool == .mask && picked?.maskMode == MaskToolMode.allCases.last)
        let all = s.items(.allTools, state: ToolState()) { picked = $0 }
        #expect(all.contains { $0.title == "Ripple" } && all.contains { $0.title == "Float" })
    }

    @Test func drawsTheBarWithItsTools() {
        let s = strip()
        var cv = Canvas(list: DrawList(width: 1600, height: 600), atlas: nil, scale: 2)
        s.draw(&cv, state: ToolState())
        #expect(cv.list.quads.count > 10)
    }
}
