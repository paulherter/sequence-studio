import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// Floating monitors and Maximize Panel on a floating panel (the Mac `toggleFloatingZoom`).
@MainActor
@Suite struct ShellFloatingMonitorZoomTests {
    let left = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let right = CGRect(x: 2000, y: 0, width: 1600, height: 900)
    let main = CGRect(x: 100, y: 100, width: 1600, height: 944)

    func dock() -> ShellDock {
        let d = ShellDock()
        d.frame = CGRect(x: 0, y: 44, width: 1600, height: 872)
        d.floating.screens = { [left, right] in [left, right] }
        d.floating.mainScreenFrame = { [main] in main }
        d.layout()
        return d
    }

    @Test func monitorsFloatAndTheMonitorCardMovesIntoTheWindowBelowItsTitleRow() {
        let d = dock()
        let docked = d.monitorCard!
        #expect(d.floating.float(.programMonitor))
        let w = d.floating.window(of: .programMonitor)!
        #expect(w.rect.minX >= d.frame.maxX)
        #expect(d.monitorCard == CGRect(x: w.rect.minX, y: w.rect.minY + ShellFloating.titleBar, width: w.rect.width, height: w.rect.height - ShellFloating.titleBar))
        d.floating.dockBack(.programMonitor)
        #expect(d.monitorCard == docked)
    }

    @Test func aFloatingSourceMonitorOwnsTheCardWhileTheProgramStaysDocked() {
        let d = dock()
        #expect(d.floating.float(.sourceMonitor))
        let w = d.floating.window(of: .sourceMonitor)!
        #expect(d.monitorCard?.minX == w.rect.minX)
    }

    @Test func maximizePanelZoomsAFloatingPanelToItsDisplayAndRestores() {
        let d = dock()
        d.floating.float(.library)
        let before = d.floating.window(of: .library)!.frame
        let rev = d.floating.revision
        d.toggleMaximize(.library)
        #expect(d.floating.isZoomed(.library))
        #expect(d.floating.window(of: .library)!.frame == left)
        #expect(d.floating.revision > rev)                   // the host moves the OS window
        #expect(d.maximized == nil)                          // the docked layout is not maximized
        #expect(d.tabMenu(.library).first?.title == "Restore Panel Size")
        d.toggleMaximize(.library)
        #expect(!d.floating.isZoomed(.library))
        #expect(d.floating.window(of: .library)!.frame == before)
        #expect(d.tabMenu(.library).first?.title == "Maximize Panel")
    }

    @Test func zoomFillsTheDisplayTheWindowIsOn() {
        let d = dock()
        d.floating.float(.library)
        let w = d.floating.window(of: .library)!
        var f = w.frame
        f.origin = CGPoint(x: 2100, y: 100)
        d.floating.setFrame(f, of: .library)
        d.floating.toggleZoom(.library)
        #expect(d.floating.window(of: .library)!.frame == right)
    }

    @Test func dockingOrClosingForgetsTheZoom() {
        let d = dock()
        d.floating.float(.library)
        d.floating.toggleZoom(.library)
        d.floating.dockBack(.library)
        #expect(!d.floating.isZoomed(.library))
        d.floating.float(.library)
        #expect(!d.floating.isZoomed(.library))
    }

    @Test func theShortcutOnAFloatingPanelUnderThePointerZoomsIt() {
        let d = dock()
        d.floating.float(.library)
        let w = d.floating.window(of: .library)!
        d.pointer = CGPoint(x: w.rect.midX, y: w.rect.midY)
        #expect(d.panel(at: d.pointer!) == .library)
        d.toggleMaximize(d.panel(at: d.pointer!)!)
        #expect(d.floating.isZoomed(.library))
    }
}
