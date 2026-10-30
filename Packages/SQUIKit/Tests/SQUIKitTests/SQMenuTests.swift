import AppKit
import Testing
@testable import SQUIKit

@MainActor
@Suite struct SQMenuTests {
    private func items() -> [SQMenuItem] {
        [SQMenuItem(title: "Cut"),
         SQMenuItem(title: "Copy", isEnabled: false),
         .separator,
         SQMenuItem.header("Edit"),
         SQMenuItem(title: "Paste"),
         SQMenuItem(title: "Label", submenu: [SQMenuItem(title: "Red"), SQMenuItem(title: "Blue")])]
    }

    @Test func arrowsSkipSeparatorsHeadersAndDisabled() {
        var nav = SQMenuNavigator(items: items())
        nav.move(.down)
        #expect(nav.highlighted == 0)
        nav.move(.down)
        #expect(nav.highlighted == 4)      // Copy disabled, separator, header skipped
        nav.move(.down)
        #expect(nav.highlighted == 5)
        nav.move(.down)
        #expect(nav.highlighted == 0)      // wraps
        nav.move(.up)
        #expect(nav.highlighted == 5)
    }

    @Test func firstAndLast() {
        var nav = SQMenuNavigator(items: items())
        nav.move(.last); #expect(nav.highlighted == 5)
        nav.move(.first); #expect(nav.highlighted == 0)
    }

    @Test func submenuOpensWithRightAndClosesWithLeft() {
        var nav = SQMenuNavigator(items: items())
        nav.hover(5)
        let r = nav.rightKey()
        #expect(r == .openedSubmenu)
        #expect(nav.depth == 2)
        #expect(nav.highlighted == 0)
        nav.move(.down)
        let run = nav.activate()
        #expect(run == .run(path: [5, 1]))
        let closed = nav.leftKey()
        #expect(closed)
        #expect(nav.depth == 1)
        let rootClose = nav.leftKey()
        #expect(!rootClose)                // root cannot close
    }

    @Test func disabledRowsAreNotHighlightedAndSubmenuOpensOnActivate() {
        var nav = SQMenuNavigator(items: items())
        nav.hover(1)
        #expect(nav.highlighted == nil)
        nav.hover(5)
        let a = nav.activate()
        #expect(a == .openedSubmenu)
        #expect(nav.depth == 2)
    }

    @Test func activateRunsLeaf() {
        var nav = SQMenuNavigator(items: items())
        nav.hover(4)
        let a = nav.activate()
        #expect(a == .run(path: [4]))
        #expect(nav.item(at: [4])?.title == "Paste")
    }

    @Test func typeFilterNarrowsRowsAndMapsPath() {
        var nav = SQMenuNavigator(items: [.header("Edit"), SQMenuItem(title: "Cut"), .separator, SQMenuItem(title: "Paste"), SQMenuItem(title: "Paste Insert")])
        #expect(nav.filter.isEmpty)
        nav.typeFilter("p")
        #expect(nav.filter == "p")
        #expect(nav.items(level: 0).map(\.title) == ["Paste", "Paste Insert"])
        #expect(nav.highlighted == 0)
        nav.typeFilter("a"); nav.typeFilter("s"); nav.typeFilter("t"); nav.typeFilter("e"); nav.typeFilter(" ")
        #expect(nav.items(level: 0).map(\.title) == ["Paste Insert"])
        #expect(nav.activate() == .run(path: [4]))
        #expect(nav.deleteFilterCharacter() && nav.filter == "paste")
        #expect(nav.clearFilter() && nav.filter.isEmpty && !nav.clearFilter())
        #expect(nav.items(level: 0).count == 5)
    }

    @Test func hoverIsGreyStateOnly() {
        var nav = SQMenuNavigator(items: [SQMenuItem(title: "A"), SQMenuItem(title: "B", isEnabled: false)])
        nav.hover(0); #expect(nav.highlighted == 0)
        nav.hover(1); #expect(nav.highlighted == nil)
        #expect(SQMenuLayout.rowHeight == 24 && Theme.Overlay.rowHeight == 24)
    }

    @Test func typeAheadFindsEnabledPrefix() {
        var nav = SQMenuNavigator(items: items())
        nav.typeAhead("p")
        #expect(nav.highlighted == 4)
        nav.typeAhead("c")                 // Copy is disabled -> Cut
        #expect(nav.highlighted == 0)
        nav.typeAhead("z")
        #expect(nav.highlighted == 0)      // no match keeps it
    }

    @Test func shortcutGlyphs() {
        #expect(SQMenuShortcut.glyphs(key: "v", modifiers: [.command, .shift]) == "\u{21E7}\u{2318}V")
        #expect(SQMenuShortcut.glyphs(key: "\u{8}", modifiers: []) == "\u{232B}")
        #expect(SQMenuShortcut.glyphs(key: "v", modifiers: [.command, .option]) == "\u{2325}\u{2318}V")
        #expect(SQMenuShortcut.glyphs(key: "", modifiers: .command) == "")
    }

    /// Measured sizes of the two popups the maintainer called too long (Normal / Fast Cut, Fit) and the help wrap.
    @Test func helpWrapsAndMenuSizesAreCompact() {
        let long = SQMenuItem(title: "Fast Cut", help: "The main track closes gaps by itself, attached clips follow their clip")
        #expect(SQMenuLayout.helpLines(long) == 2)
        #expect(SQMenuLayout.heights([long]) == [SQMenuLayout.rowHeight + 2 * SQMenuLayout.helpHeight])
        let view = SQMenuListView(items: [long, SQMenuItem(title: "Normal", help: "Classic tracks, every edit stays where you put it")])
        #expect(view.contentSize.width <= 300)
        let fit = (0..<8).map { SQMenuItem(title: "\($0) %") }
        #expect(SQMenuLayout.contentHeight(fit) == CGFloat(8 * 24 + 8))
        #expect(SQMenuLayout.listCapHeight == CGFloat(248))
    }

    @Test func contentHeightIsRowsTimesRowHeightPlusPadding() {
        let rows = (0..<5).map { SQMenuItem(title: "Row \($0)") }
        #expect(SQMenuLayout.contentHeight(rows) == 5 * SQMenuLayout.rowHeight + 2 * SQMenuLayout.inset)
        #expect(SQMenuLayout.contentHeight(rows) == 128)
        let withHelp = [SQMenuItem(title: "Normal", help: "One line"), SQMenuItem(title: "Fast Cut", help: "Two")]
        #expect(SQMenuLayout.contentHeight(withHelp) == 2 * (SQMenuLayout.rowHeight + SQMenuLayout.helpHeight) + 8)
        #expect(SQMenuLayout.contentHeight([SQMenuItem(title: "A"), SQMenuItem.separator, SQMenuItem(title: "B")]) == 2 * SQMenuLayout.rowHeight + SQMenuLayout.separatorHeight + 2 * SQMenuLayout.inset)
    }

    @Test func layoutHeightsAndPlacement() {
        let h = SQMenuLayout.heights(items())
        #expect(h == [SQMenuLayout.rowHeight, SQMenuLayout.rowHeight, SQMenuLayout.separatorHeight,
                      SQMenuLayout.headerHeight, SQMenuLayout.rowHeight, SQMenuLayout.rowHeight])
        // Opens at the anchor (top-left), flips to stay inside the screen.
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let o1 = SQMenuLayout.origin(size: CGSize(width: 200, height: 300), anchor: CGPoint(x: 100, y: 700), screen: screen)
        #expect(o1 == CGPoint(x: 100, y: 400))
        let o2 = SQMenuLayout.origin(size: CGSize(width: 200, height: 300), anchor: CGPoint(x: 950, y: 100), screen: screen)
        #expect(o2.x == 800 && o2.y == 0)
    }

    @Test func convertsNSMenuWithSubmenuStateAndShortcut() {
        let menu = NSMenu(); menu.autoenablesItems = false
        let paste = NSMenuItem(title: "Paste Insert", action: nil, keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command, .shift]
        let off = NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""); off.isEnabled = false
        off.state = .on
        menu.addItem(paste); menu.addItem(.separator()); menu.addItem(off)
        let sub = NSMenuItem(title: "Label", action: nil, keyEquivalent: "")
        sub.submenu = NSMenu(); sub.submenu?.addItem(NSMenuItem(title: "Red", action: nil, keyEquivalent: ""))
        menu.addItem(sub)
        let model = SQMenuItem.items(from: menu)
        #expect(model.count == 4)
        #expect(model[0].shortcut == "\u{21E7}\u{2318}V")
        #expect(model[1].kind == .separator)
        #expect(!model[2].isEnabled && model[2].isChecked)
        #expect(model[3].submenu?.count == 1)
    }

    @Test func iconTableCoversTimelineAndEffectMenus() {
        for t in ["Cut", "Copy", "Paste", "Paste Insert", "Clear", "Ripple Delete", "Link", "Unlink", "Group", "Ungroup",
                  "Combine\u{2026}", "Speed\u{2026}", "Rename\u{2026}", "Duplicate Effect", "Enable Effect", "Disable Effect"] {
            #expect(SQMenuIconTable.symbol(forTitle: t) != nil, "\(t)")
        }
        #expect(SQMenuIconTable.symbol(forTitle: "Nonsense item") == nil)
    }

    @Test func switchDefaultsToCustom() {
        let d = UserDefaults(suiteName: "sq.test.menuswitch")!
        d.removePersistentDomain(forName: "sq.test.menuswitch")
        #expect(SQMenuSettings.useCustomMenus(defaults: d))
        d.set(false, forKey: SQMenuSettings.key)
        #expect(!SQMenuSettings.useCustomMenus(defaults: d))
    }

    /// A dot made from a Theme color (marker dialog) carries the tag the custom menu reads.
    @Test func aDotFromAColourIsTagged() {
        let img = SQMenuDot.image(color: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        #expect(SQMenuDot.rgb(of: img) == 0xFF8000)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Orange", action: nil, keyEquivalent: "")
        item.image = SQMenuDot.image(color: Theme.Palette.marker(.orange))
        menu.addItem(item)
        guard case .swatch = SQMenuItem.items(from: menu)[0].icon else { Issue.record("no color dot"); return }
    }
}
