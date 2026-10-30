import Foundation
import SQDrawKit
import SQDrawShell
import SQEditorSession
import Testing
@testable import SQAppShell

/// The Windows window has no system caption: our menu row holds the window buttons and tells Windows where to drag and
/// resize; the title row sits below it and stays free of overlaps at any window width.
@MainActor @Suite struct WindowCaptionTests {
    let size = CGSize(width: 1400, height: 900)

    @Test func buttonsSitAtTheRightEndOfTheMenuRow() throws {
        let row = CaptionRowHost()
        row.layout(width: 1400)
        let min = try #require(row.frames[.minimize]), max = try #require(row.frames[.maximize]), close = try #require(row.frames[.close])
        #expect(close.maxX == 1400 && close.width == 46 && close.height == CaptionRowHost.height && close.minY == 0)
        #expect(max.maxX == close.minX && min.maxX == max.minX && row.buttonsMinX == 1400 - 3 * 46)
        #expect(CaptionRowHost.menuRoom(from: 0, width: 1400) == 1400 - 138 - CaptionRowHost.dragRoom)
        #expect(CaptionRowHost.menuRoom(from: 0, width: 100) == 0)
    }

    @Test func hitTestGivesEdgesButtonsDragAreaAndControls() {
        let row = CaptionRowHost()
        row.layout(width: size.width)
        let menuTitle = CGRect(x: 4, y: 0, width: 40, height: 32)
        func hit(_ x: CGFloat, _ y: CGFloat) -> WindowHit { row.hit(CGPoint(x: x, y: y), size: size, captionHeight: 76, controls: [menuTitle]) }
        #expect(hit(2, 2) == .topLeft && hit(1398, 1) == .topRight && hit(1, 898) == .bottomLeft && hit(1399, 899) == .bottomRight)
        #expect(hit(2, 400) == .left && hit(1398, 400) == .right && hit(700, 2) == .top && hit(700, 898) == .bottom)
        #expect(hit(1400 - 23, 16) == .close && hit(1400 - 69, 16) == .maximize && hit(1400 - 115, 16) == .minimize)
        #expect(hit(20, 16) == .client)                  // a menu title
        #expect(hit(600, 16) == .caption && hit(600, 60) == .caption)
        #expect(hit(600, 80) == .client)                 // the dock below the rows
        row.isMaximized = true                           // maximized: no resize band, the top pixel still drags
        #expect(hit(700, 1) == .caption && hit(1, 400) == .client && hit(1399, 2) == .close)
    }

    @Test func aButtonFiresOnReleaseOverItself() throws {
        let row = CaptionRowHost()
        row.layout(width: 1400)
        var fired: [CaptionRowHost.Button] = []
        row.onButton = { fired.append($0) }
        let close = try #require(row.frames[.close]), max = try #require(row.frames[.maximize])
        #expect(!row.handle(.mouseMoved(x: Float(close.midX * 2), y: Float(close.midY * 2)), scale: 2) && row.hovered == .close)
        #expect(row.handle(.mouseDown(x: Float(close.midX * 2), y: Float(close.midY * 2), modifiers: []), scale: 2))
        #expect(row.handle(.mouseUp(x: 10, y: 400), scale: 2) && fired.isEmpty, "released off the button")
        _ = row.handle(.mouseDown(x: Float(max.midX), y: Float(max.midY), modifiers: []), scale: 1)
        _ = row.handle(.mouseUp(x: Float(max.midX), y: Float(max.midY)), scale: 1)
        #expect(fired == [.maximize])
        #expect(!row.handle(.mouseDown(x: 300, y: 10, modifiers: []), scale: 1))
    }

    /// Windows: the title row is the second row (below the 32 pt menu row) and the page switch follows it there.
    @Test func titleRowAndSwitchLayOutInTheSecondRow() throws {
        let row = TitleRowHost()
        row.projectName = "Oppo Find x10 pro Max (Recovered)"
        row.edited = Date()
        row.workspaceName = "Editing"
        let measure = TextMeasure(atlas: nil, scale: 1)
        row.layout(after: 0, width: 1400, barHeight: 44, top: 32, measure: measure)
        let name = try #require(row.frames[.name]), export = try #require(row.frames[.export]), ws = try #require(row.frames[.workspace])
        #expect(name.minY == 32 && name.height == 44 && export.midY == 32 + 22 && ws.midY == export.midY)
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: StubProgramEngine())
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = ColorPageHost(session: s, menus: MenuController(), shell: shell)
        host.layoutSwitch(after: row.switchAfter, barHeight: 44, top: 32)
        let sw = try #require(host.frames[.pageSwitch])
        #expect(sw.midY == 32 + 22 && sw.minX > name.maxX && sw.maxX < ws.minX)
    }

    /// From wide to the minimum width nothing overlaps: the name shortens, then the edit time and the Workspace popup go.
    @Test func narrowTitleRowNeverOverlaps() throws {
        let row = TitleRowHost()
        row.projectName = "Oppo Find x10 pro Max (Recovered) with a very long project name that never fits"
        row.edited = Date()
        row.workspaceName = "Editing (modified)"
        let measure = TextMeasure(atlas: nil, scale: 1)
        let switchW = 2 * ColorPageHost.switchSegment
        for width in stride(from: CGFloat(1600), through: 360, by: -20) {
            row.layout(after: 0, width: width, barHeight: 44, top: 32, measure: measure)
            let sw = CGRect(x: row.switchAfter + ColorPageHost.switchLead, y: 41, width: switchW, height: 26)
            var boxes = [sw]
            for p in [TitleRowHost.Part.name, .edited, .workspace, .export] { if let r = row.frames[p] { boxes.append(r) } }
            let export = try #require(row.frames[.export])
            #expect(export.maxX <= width && export.minX >= 0, "width \(width)")
            if let n = row.frames[.name] { #expect(n.maxX <= sw.minX, "name under the switch at \(width)") }
            if let e = row.frames[.edited] { #expect(e.maxX <= sw.minX, "edit time under the switch at \(width)") }
            if let w = row.frames[.workspace] { #expect(w.minX >= sw.maxX, "workspace under the switch at \(width)") }
            if width >= 640 { #expect(sw.maxX <= export.minX, "switch under Export at \(width)") }
        }
        row.layout(after: 0, width: 1600, barHeight: 44, top: 32, measure: measure)
        #expect(row.frames[.workspace] != nil && row.frames[.edited] != nil)
        row.layout(after: 0, width: 360, barHeight: 44, top: 32, measure: measure)
        #expect(row.frames[.workspace] == nil && row.frames[.edited] == nil && row.frames[.export] != nil)
    }
}
