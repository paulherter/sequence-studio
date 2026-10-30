import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

/// Preferences sidebar: keyboard focus (Tab stop, Up/Down pick the page) and a page list that stays while a long page scrolls.
@MainActor
@Suite struct ShellFormSidebarTests {
    func form(_ rows: Int = 3) -> (ShellDialog, ShellForm, Recorder) {
        let d = ShellDialog("Settings")
        d.width = ShellDialog.M.widthL
        d.addButton("Done")
        let f = ShellForm((0..<rows).map { .check(id: "c\($0)", title: "Row \($0)", on: false) },
                          sidebar: ShellForm.Sidebar(id: "page", items: [("General", .folder), ("Audio", .folder), ("Media", .folder)]))
        let r = Recorder()
        f.onChange = { id, v in if id == "page", case .index(let i) = v { r.pages.append(i) } }
        d.form = f
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        return (d, f, r)
    }

    final class Recorder { var pages: [Int] = [] }

    func key(_ d: ShellDialog, _ k: InputKey, _ m: InputModifiers = []) { d.handle(.keyDown(k, modifiers: m), scale: 1) }

    @Test func tabReachesTheSidebarFirstThenTheRows() {
        let (d, f, _) = form()
        #expect(!f.sidebarFocused)
        key(d, .tab)
        #expect(f.sidebarFocused && f.focused == nil)
        key(d, .tab)
        #expect(!f.sidebarFocused && f.focused == 0)
        key(d, .tab, .shift)
        #expect(f.sidebarFocused && f.focused == nil)
        #expect(!f.moveFocus(forward: false), "Shift-Tab off the sidebar leaves the form")
        #expect(!f.sidebarFocused)
    }

    @Test func upAndDownPickThePageAndStopAtTheEnds() {
        let (d, f, r) = form()
        key(d, .tab)
        key(d, .down)
        key(d, .down)
        key(d, .down)
        #expect(r.pages == [1, 2])
        #expect(f.index("page") == 2)
        key(d, .up)
        #expect(r.pages == [1, 2, 1])
    }

    @Test func aClickOnAPageDropsTheSidebarFocus() {
        let (d, f, _) = form()
        key(d, .tab)
        let p = CGPoint(x: f.sidebarFrames[1].midX, y: f.sidebarFrames[1].midY)
        d.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: []), scale: 1)
        #expect(!f.sidebarFocused)
    }

    @Test func theSidebarStaysAndTheRuleSpansTheViewportWhileALongPageScrolls() {
        let (d, f, _) = form(60)
        #expect(d.formScrolls)
        let top = f.sidebarFrames.map(\.minY)
        d.scrollForm(by: 300)
        #expect(d.formScroll > 0)
        #expect(f.sidebarFrames.map(\.minY) == top, "same place on screen")
        #expect(f.rowFrames[0].minY < d.formViewport.minY, "the rows moved up")
        #expect(f.sidebarRuleFrame.minY == d.formViewport.minY && f.sidebarRuleFrame.height == d.formViewport.height)
    }

    @Test func aNewPageStartsAtTheTop() {
        let (d, _, _) = form(60)
        d.scrollForm(by: 300)
        d.resetFormScroll()
        #expect(d.formScroll == 0)
    }

    @Test func theFocusedSidebarRowIsOutlined() {
        let (d, f, _) = form()
        func draw() -> Int {
            var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
            f.draw(&c, theme: DrawTheme())
            return c.list.quads.count
        }
        let plain = draw()
        key(d, .tab)
        #expect(draw() > plain)
    }
}
