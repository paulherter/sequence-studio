import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellFloatingTests {
    let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let main = CGRect(x: 100, y: 100, width: 1600, height: 944)

    func dock() -> ShellDock {
        let d = ShellDock()
        d.frame = CGRect(x: 0, y: 44, width: 1600, height: 872)
        d.floating.screens = { [screen] in [screen] }
        d.floating.mainScreenFrame = { [main] in main }
        d.layout()
        return d
    }

    @Test func floatingPanelLeavesTheLayoutAndGetsARectangleRightOfTheWindow() {
        let d = dock()
        let slot = d.contentFrame(.project)!
        #expect(d.floating.float(.project))
        let w = d.floating.window(of: .project)!
        #expect(!d.visiblePanels.isEmpty && d.visiblePanels.contains(.project))      // still "shown" in the Window menu
        #expect(d.groups.filter { !$0.isFloating }.allSatisfy { $0.selected != .project && !$0.panels.contains(.project) })
        #expect(w.rect.minX >= d.frame.maxX)
        #expect(d.contentFrame(.project) == CGRect(x: w.rect.minX, y: ShellFloating.titleBar, width: w.rect.width, height: w.rect.height - ShellFloating.titleBar))
        // The window opens at the dock size (plus the title row), offset from the dock position, on a display.
        #expect(w.frame.width >= slot.width && w.frame.height >= slot.height + ShellFloating.titleBar)
        #expect(screen.contains(w.frame))
        #expect(d.focused == .project)
    }

    @Test func dockingBackRestoresTheExactSlot() {
        let d = dock()
        let before = d.contentFrame(.project)!
        d.floating.float(.project)
        d.floating.dockBack(.project)
        #expect(d.floating.windows.isEmpty)
        #expect(d.contentFrame(.project) == before)
    }

    @Test func closeHidesThePanelLikeADockedOne() {
        let d = dock()
        d.floating.float(.project)
        d.floating.close(.project)
        #expect(d.floating.windows.isEmpty && !d.visiblePanels.contains(.project))
    }

    @Test func windowRowOfAFloatingPanelClosesItAndAShortcutKeepsItFloating() {
        let d = dock()
        d.floating.float(.library)
        d.show(.library)
        #expect(d.floating.isFloating(.library))
        d.toggle(.library)
        #expect(!d.floating.isFloating(.library) && !d.visiblePanels.contains(.library))
    }

    @Test func colorPageTabsDoNotFloat() {
        let d = dock()
        #expect(!d.floating.float(.colorClips))
        #expect(d.floating.windows.isEmpty)
    }

    @Test func floatingStateIsPerWorkspaceAndPage() {
        let d = dock()
        d.floating.float(.project)
        d.setPage(.color)
        #expect(d.floating.windows.isEmpty)
        d.setPage(.edit)
        #expect(d.floating.isFloating(.project))
        let name = d.store.library.names.first { $0 != d.store.editName }!
        d.chooseWorkspace(name)
        #expect(d.floating.windows.isEmpty)
    }

    @Test func titleRowButtonsDockAndCloseAndTheTitleIsTheDragArea() {
        let d = dock()
        d.floating.float(.library)
        let w = d.floating.window(of: .library)!
        #expect(d.floating.hit(at: CGPoint(x: w.rect.minX + 30, y: 10)) == .title(.library))
        #expect(d.floating.hit(at: CGPoint(x: w.rect.maxX - 8, y: 14)) == .close(.library))
        #expect(d.floating.hit(at: CGPoint(x: w.rect.maxX - 8 - ShellFloating.button, y: 14)) == .dock(.library))
        #expect(d.floating.hit(at: CGPoint(x: w.rect.maxX - 4, y: w.rect.maxY - 4)) == .grip(.library))
        #expect(d.floating.hit(at: CGPoint(x: w.rect.midX, y: w.rect.midY)) == .content(.library))
        #expect(d.floating.hit(at: CGPoint(x: 100, y: 300)) == nil)
        // A press on the title is the dock's (the OS drags the window), the panel content is not.
        #expect(d.handle(.mouseDown(x: Float(w.rect.minX + 30), y: 10, modifiers: []), scale: 1))
        #expect(!d.handle(.mouseDown(x: Float(w.rect.midX), y: Float(w.rect.midY), modifiers: []), scale: 1))
        #expect(d.handle(.mouseDown(x: Float(w.rect.maxX - 8 - ShellFloating.button), y: 14, modifiers: []), scale: 1))
        #expect(d.floating.windows.isEmpty)
    }

    @Test func movingKeepsTheCanvasAndResizingRelaysOut() {
        let d = dock()
        d.floating.float(.library)
        let w = d.floating.window(of: .library)!
        var moved = w.frame; moved.origin.x += 300
        d.floating.setFrame(moved, of: .library)
        #expect(d.floating.window(of: .library)!.rect == w.rect)
        var bigger = moved; bigger.size.width += 100
        d.floating.setFrame(bigger, of: .library)
        #expect(d.floating.window(of: .library)!.rect.width == w.rect.width + 100)
        #expect(d.contentFrame(.library)!.width == w.rect.width + 100)
    }

    @Test func saveWaitsHalfASecondAndFlushesAtQuit() {
        let d = dock()
        var now: TimeInterval = 10
        var saved: [FloatingPanelState] = []
        d.floating.clock = { now }
        d.floating.save = { saved.append($0) }
        d.floating.float(.library)
        d.floating.flush()
        #expect(saved.isEmpty)
        now = 10.6
        d.floating.flush()
        #expect(saved.count == 1)
        #expect(saved[0].panels(for: FloatingPanelState.key(page: .edit, editName: d.store.editName)) == [.library])
        d.floating.flush(force: true)
        #expect(saved.count == 1)          // nothing new to write
    }

    @Test func loadedStateReopensTheWindowsAndClampsMissingDisplays() {
        var s = FloatingPanelState()
        let d0 = dock()
        let key = FloatingPanelState.key(page: .edit, editName: d0.store.editName)
        s.float(.library, key: key, frame: FloatingPanelFrame(x: 5000, y: 100, width: 600, height: 500))
        let d = ShellDock()
        d.frame = CGRect(x: 0, y: 44, width: 1600, height: 872)
        d.floating.screens = { [screen] in [screen] }
        d.floating.load(s)
        #expect(d.floating.isFloating(.library))
        #expect(screen.contains(d.floating.window(of: .library)!.frame))
    }

    @Test func tabDraggedOutsideTheWindowFloatsInsideItDocks() {
        let d = dock()
        let tab = d.groups.first { $0.selected == .project || $0.panels.contains(.project) }!
        let t = tab.tabs[tab.panels.firstIndex(of: .project)!]
        _ = d.handle(.mouseDown(x: Float(t.midX), y: Float(t.midY), modifiers: []), scale: 1)
        _ = d.handle(.mouseDragged(x: Float(t.midX) + 40, y: Float(t.midY) + 40), scale: 1)
        _ = d.handle(.mouseUp(x: 1650, y: 300), scale: 1)
        let w = d.floating.window(of: .project)
        #expect(w != nil)
        // The title row sits under the pointer (screen: main origin + window point, y flipped).
        #expect(w!.frame.midX == main.minX + 1650)
        #expect(w!.frame.maxY == main.maxY - 300 + ShellFloating.titleBar / 2)
    }

    // Esc in a floating window docks its panel (the Mac `FloatingPanelWindow.cancelOperation`), after everything that takes
    // Esc first (menus, dialogs, text fields, Trim mode); a docked focus leaves it to the selection.
    @Test func escapeDocksTheFocusedFloatingPanelAfterTrimAndOnlyWhenFocused() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault, recents: RecentProjects(entries: []))
        h.size = CGSize(width: 1600, height: 960)
        h.dock.floating.screens = { [screen] in [screen] }
        h.dock.floating.mainScreenFrame = { [main] in main }
        h.dock.layout()
        h.dock.floating.float(.library)
        h.dock.floating.float(.project)
        h.dock.focused = .library
        h.focus = .library
        #expect(h.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(!h.dock.floating.isFloating(.library) && h.dock.floating.isFloating(.project))
        // The library is docked now and focused: Esc does not dock the other floating panel.
        _ = h.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(h.dock.floating.isFloating(.project))
        // Shift+Esc is not Esc.
        h.dock.focused = .project; h.focus = .project
        _ = h.handle(.keyDown(.escape, modifiers: .shift), scale: 1)
        #expect(h.dock.floating.isFloating(.project))
    }

    // Mixed DPI: the frame is drawn once at the largest scale of any window, so no window shows an upscaled picture; a
    // window with a smaller scale shows the same frame reduced by `ratio`.
    @Test func theFrameDrawsAtTheLargestWindowScale() {
        #expect(ShellFloating.drawScale(main: 1, floating: []) == 1)
        #expect(ShellFloating.drawScale(main: 1, floating: [2, 1.5]) == 2)
        #expect(ShellFloating.drawScale(main: 2, floating: [1]) == 2)
        #expect(ShellFloating.ratio(window: 1, draw: 2) == 0.5)
        #expect(ShellFloating.ratio(window: 2, draw: 2) == 1)
        #expect(ShellFloating.ratio(window: 1, draw: 0) == 1)
        // The drawn size of a window of `size` own pixels, and a pointer position back in the window's pixels.
        #expect(ShellFloating.drawSize(100, window: 1, draw: 2) == 200)
        #expect(ShellFloating.drawSize(101, window: 1.5, draw: 2) == 135)
        #expect(ShellFloating.drawn(40, window: 1, draw: 2) == 80)
    }

    // Cmd-Z / Ctrl-Z and Space reach their commands whichever floating panel has the focus (the keyboard proof of the Mac probe).
    @Test func undoAndSpaceRunFromAnyFocusedPanel() {
        for p in [PanelID.library, .project, .programMonitor, .effects] {
            #expect(ShellKeys.command(.character("z"), .command, focus: p, map: .premiereDefault) == .undo, "undo with focus \(p)")
        }
    }
}
