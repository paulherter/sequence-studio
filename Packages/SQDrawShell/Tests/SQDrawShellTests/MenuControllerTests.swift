import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

@MainActor
final class Ran { var titles: [String] = [] }

@MainActor
func row(_ t: String, _ ran: Ran, sub: [SQMenuItem]? = nil) -> SQMenuItem {
    var i = SQMenuItem(title: t, submenu: sub)
    if sub == nil { i.action = { ran.titles.append(t) } }
    return i
}

@MainActor
@Suite("MenuController")
struct MenuControllerTests {
    func make(_ ran: Ran, time: @escaping () -> TimeInterval = { 10 }) -> MenuController {
        let c = MenuController()
        c.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        c.clock = time
        return c
    }

    @Test func opensAtThePointAndKeysRunTheRow() {
        let ran = Ran(), c = make(ran)
        c.present(items: [row("Cut", ran), row("Copy", ran)], at: CGPoint(x: 100, y: 50))
        #expect(c.views[0].origin == CGPoint(x: 100, y: 50))
        #expect(c.handle(.keyDown(.down, modifiers: []), scale: 1))
        #expect(c.handle(.keyDown(.down, modifiers: []), scale: 1))
        _ = c.handle(.keyDown(.enter, modifiers: []), scale: 1)
        #expect(ran.titles == ["Copy"])
        #expect(!c.isOpen)
    }

    @Test func flipsAboveWhenNoRoomBelow() {
        let ran = Ran(), c = make(ran)
        c.popUp(items: [row("A", ran), row("B", ran), row("C", ran)], below: CGRect(x: 10, y: 560, width: 80, height: 22))
        let f = c.views[0].frame
        #expect(f.maxY <= 560)
    }

    @Test func hoverOpensSubmenuRightOfParentAtTheRow() {
        let ran = Ran(), c = make(ran)
        c.present(items: [row("A", ran), row("More", ran, sub: [row("X", ran)])], at: CGPoint(x: 100, y: 50))
        let r = c.views[0].rowFrames[1]
        let p = CGPoint(x: c.views[0].origin.x + r.midX, y: c.views[0].origin.y + r.midY)
        _ = c.handle(.mouseMoved(x: Float(p.x), y: Float(p.y)), scale: 1)
        #expect(c.depth == 2)
        #expect(c.views[1].origin.x == c.views[0].frame.maxX - 3)
        #expect(c.views[1].origin.y == c.views[0].origin.y + r.minY - SQMenuLayout.inset)
    }

    @Test func openingClickReleaseNeverSelectsButAPressInTheListDoes() {
        var now: TimeInterval = 10
        let ran = Ran(), c = make(ran, time: { now })
        c.present(items: [row("Cut", ran)], at: CGPoint(x: 100, y: 50), pointer: CGPoint(x: 100, y: 50))
        let r = c.views[0].rowFrames[0]
        let x = Float(100 + r.midX), y = Float(50 + r.midY)
        _ = c.handle(.mouseUp(x: x, y: y), scale: 1)   // release of the opening click, no delay
        #expect(ran.titles.isEmpty && c.isOpen)
        now += 1
        _ = c.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        _ = c.handle(.mouseUp(x: x, y: y), scale: 1)
        #expect(ran.titles == ["Cut"])
    }

    @Test func pressOutsideClosesAndPassesThrough() {
        let ran = Ran(), c = make(ran)
        c.present(items: [row("Cut", ran)], at: CGPoint(x: 100, y: 50))
        #expect(c.handle(.mouseDown(x: 700, y: 500, modifiers: []), scale: 1) == false)
        #expect(!c.isOpen)
    }

    @Test func typingFiltersAndEscapeClearsFirst() {
        let ran = Ran(), c = make(ran)
        c.present(items: [row("Cut", ran), row("Copy", ran), row("Paste", ran)], at: .zero)
        _ = c.handle(.keyDown(.character("p"), modifiers: []), scale: 1)
        #expect(c.views[0].items.map(\.title) == ["Copy", "Paste"])
        _ = c.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(c.isOpen && c.views[0].items.count == 3)
        _ = c.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(!c.isOpen)
    }
}

@MainActor
@Suite("MenuBar")
struct MenuBarTests {
    @Test func clickOpensBelowTheTitleAndHoverSwitches() {
        let ran = Ran(), bar = MenuBar()
        bar.controller.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        bar.menus = [ShellMenu(title: "File", items: [row("New", ran)]), ShellMenu(title: "Edit", items: [row("Undo", ran)])]
        let f = bar.titleFrames
        #expect(bar.handle(.mouseDown(x: Float(f[0].midX), y: 10, modifiers: []), scale: 1))
        #expect(bar.open == 0)
        #expect(bar.controller.views[0].origin.y == MenuBar.defaultHeight)
        _ = bar.handle(.mouseMoved(x: Float(f[1].midX), y: 10), scale: 1)
        #expect(bar.open == 1)
        _ = bar.handle(.keyDown(.left, modifiers: []), scale: 1)
        #expect(bar.open == 0)
        _ = bar.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(bar.open == nil)
    }
}

@MainActor
@Suite("ShellDialog")
struct ShellDialogTests {
    let m = TextMeasure(atlas: nil, scale: 1)

    @Test func footerOrderAndCenteredCard() {
        let d = ShellDialog("Save changes?")
        d.addButton("Save", role: .save); d.addButton("Cancel", role: .cancel); d.addButton("Don't Save", role: .dontSave)
        d.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 800), measure: m)
        #expect(d.card.midX == 500)
        #expect(d.buttonFrames[2]!.minX == d.card.minX + 20)          // Don't Save alone on the left
        #expect(d.buttonFrames[0]!.maxX == d.card.maxX - 20)          // Save, the main action, rightmost
        #expect(d.buttonFrames[1]!.maxX == d.buttonFrames[0]!.minX - 8)
    }

    @Test func keysAnswerWithTheModelRoles() {
        var got: [ShellDialog.Response] = []
        let d = ShellDialog("Delete?")
        d.addButton("Delete", role: .destructive); d.addButton("Cancel", role: .cancel)
        d.completion = { got.append($0) }
        d.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 800), measure: m)
        #expect(d.response(for: .enter, []) == .second)     // destructive: Return presses Cancel
        #expect(d.response(for: .character("."), .command) == .second)
        d.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(got == [.second])
    }

    @Test func clickOnAButtonPressesIt() {
        var got: [ShellDialog.Response] = []
        let d = ShellDialog("Info")
        d.completion = { got.append($0) }
        d.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 800), measure: m)
        let r = d.buttonFrames[0]!
        d.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(got == [.first])
    }
}
