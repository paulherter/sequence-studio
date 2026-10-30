import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

/// The Mac shows the shared menus in the system menu bar: the in-window bar then lays out, draws and takes no titles,
/// while its controller still opens the bar's popups (the Workspace popup).
@MainActor
@Suite("MenuBar titles")
struct MenuBarTitlesTests {
    @Test func hiddenTitlesTakeNoRoomAndNoClicks() {
        let ran = Ran(), bar = MenuBar()
        bar.menus = [ShellMenu(title: "File", items: [row("Save", ran)]), ShellMenu(title: "Edit", items: [row("Undo", ran)])]
        #expect(bar.titleFrames.count == 2)
        bar.showsTitles = false
        #expect(bar.titleFrames.isEmpty)
        #expect(!bar.handle(.mouseDown(x: 20, y: 10, modifiers: []), scale: 1))
        bar.drawsBackground = false
        var c = Canvas(list: DrawList(width: 800, height: 600), atlas: GlyphAtlas(), scale: 1)
        bar.draw(&c, theme: DrawTheme(), width: 800)
        #expect(c.list.quads.isEmpty)
        bar.showsTitles = true
        #expect(bar.titleFrames.count == 2)
    }

    /// A narrow window (Windows): the titles that do not fit fold into one "»" title whose menu holds them as submenus.
    @Test func titlesPastTheWidthFoldIntoAnOverflowMenu() {
        let ran = Ran(), bar = MenuBar()
        bar.menus = ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window", "Help"].map {
            ShellMenu(title: $0, items: [row($0 + " row", ran)])
        }
        let full = bar.titleFrames.last!.maxX
        #expect(bar.overflowFrame == nil)
        bar.maxWidth = full - 60
        let shown = bar.titleFrames.count
        #expect(shown < 8 && shown > 0)
        let more = try! #require(bar.overflowFrame)
        #expect(more.minX >= bar.titleFrames.last!.maxX && more.maxX <= full - 60)
        #expect(bar.handle(.mouseDown(x: Float(more.midX), y: Float(more.midY), modifiers: []), scale: 1))
        let items = bar.controller.views.first?.items ?? []
        #expect(items.map(\.title) == bar.menus.dropFirst(shown).map(\.title))
        #expect(items.first?.submenu?.first?.title == bar.menus[shown].title + " row")
        bar.controller.dismiss()
        bar.maxWidth = nil
        #expect(bar.titleFrames.count == 8 && bar.overflowFrame == nil)
        bar.maxWidth = 1                        // nothing fits: only the overflow title
        #expect(bar.titleFrames.isEmpty && bar.overflowFrame != nil)
    }
}
