import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit
@testable import SQInspectorUI

/// The shared-toolkit Captions tab (`CaptionsTabDraw`): the same session calls as the Mac `CaptionsTabView`.
@MainActor @Suite struct CaptionsTabDrawTests {
    func rig() throws -> (EditorSession, CaptionsTabDraw) {
        func item(_ text: String, _ a: Int64) -> CaptionItem {
            CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(a + 1, 1)))
        }
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([item("hello", 0), item("the cat", 2), item("nothing", 4), item("a cat again", 6)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let v = CaptionsTabDraw(session: s)
        v.size = CGSize(width: 320, height: 400)
        v.clock = { 10 }
        v.sync()
        return (s, v)
    }

    func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    func rowPoint(_ v: CaptionsTabDraw, _ i: Int) -> CGPoint {
        let lf = v.frame(.list), r = v.list.rect(row: i, width: lf.width)
        return CGPoint(x: lf.minX + r.midX, y: lf.minY + r.midY)
    }
    func type(_ v: CaptionsTabDraw, _ s: String) { for ch in s { _ = v.key(.character(ch), modifiers: []) } }

    @Test func layoutKeepsControlsApartAndListsTheCaptions() throws {
        let (_, v) = try rig()
        let all: [CaptionsTabDraw.Control] = [.find, .replace, .replaceAll, .matchCase, .list, .create]
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] { #expect(!v.frame(a).intersects(v.frame(b))) } }
        #expect(v.rows.map(\.text) == ["hello", "the cat", "nothing", "a cat again"])
        #expect(v.hint == "4 captions")
        var c = Canvas(width: 320, height: 400, atlas: nil, scale: 1)
        v.draw(&c)
        #expect(v.help(at: center(v.frame(.create))) != nil)                // no transcript: Create is dimmed
    }

    @Test func clicksSelectSeekAndExtend() throws {
        let (s, v) = try rig()
        var seeks: [Time] = []
        v.onSeek = { seeks.append($0) }
        v.mouseDown(at: rowPoint(v, 1), clickCount: 1)
        #expect(s.captionSelection == [v.rows[1].id])
        #expect(seeks == [Time(2, 1)])
        v.mouseDown(at: rowPoint(v, 3), modifiers: .shift, clickCount: 1)
        #expect(s.captionSelection == Set(v.rows[1...3].map(\.id)))
        v.mouseDown(at: rowPoint(v, 2), modifiers: .command, clickCount: 1)
        #expect(s.captionSelection == [v.rows[1].id, v.rows[3].id])
        #expect(v.key(.down, modifiers: []))
        #expect(s.captionSelection.count == 1)
    }

    @Test func doubleClickTypesIntoTheCaption() throws {
        let (s, v) = try rig()
        v.mouseDown(at: rowPoint(v, 0), clickCount: 2)
        #expect(v.editing != nil)
        for _ in 0..<5 { _ = v.key(.backspace, modifiers: []) }
        type(v, "hi there")
        #expect(v.key(.enter, modifiers: []))
        #expect(v.editing == nil)
        #expect(s.captionItems.contains { $0.lines == ["hi there"] })
        // Escape drops the typing.
        #expect(v.key(.enter, modifiers: []))                                 // Return on the one selected row
        type(v, "zzz")
        #expect(v.key(.escape, modifiers: []))
        #expect(s.captionItems.contains { $0.lines == ["hi there"] })
    }

    @Test func findStepsAndReplaceAllRewrites() throws {
        let (s, v) = try rig()
        var status: [String] = []
        v.onStatus = { status.append($0) }
        v.mouseDown(at: center(v.frame(.find)), clickCount: 1)
        type(v, "cat")
        #expect(v.hint == "2 of 4 match")
        _ = v.key(.enter, modifiers: [])
        #expect(s.captionSelection == [v.rows[1].id])
        _ = v.key(.enter, modifiers: [])
        #expect(s.captionSelection == [v.rows[3].id])
        v.mouseDown(at: center(v.frame(.replace)), clickCount: 1)
        type(v, "dog")
        _ = v.key(.enter, modifiers: [])
        #expect(s.captionItems.filter { $0.lines.joined().contains("dog") }.count == 2)
        #expect(status.last == "Replaced 2 times.")
        // Match Case toggles on a click.
        v.mouseDown(at: center(v.frame(.matchCase)), clickCount: 1)
        v.mouseUp(at: center(v.frame(.matchCase)))
        #expect(v.matchCase)
    }

    @Test func contextMenuAndDeleteEditTheCaptions() throws {
        let (s, v) = try rig()
        var menu: [SQMenuItem] = []
        v.onMenu = { items, _ in menu = items }
        v.mouseDown(at: rowPoint(v, 2), modifiers: .secondary, clickCount: 1)
        #expect(s.captionSelection == [v.rows[2].id])
        #expect(menu.contains { $0.title == "Merge Captions" && !$0.isEnabled })
        // Command-A, then Merge.
        _ = v.key(.character("a"), modifiers: .command)
        #expect(s.captionSelection.count == 4)
        v.mouseDown(at: rowPoint(v, 0), modifiers: .secondary, clickCount: 1)
        menu.first { $0.title == "Merge Captions" }?.action?()
        #expect(s.captionItems.count == 1)
        v.mouseDown(at: rowPoint(v, 0), clickCount: 1)
        #expect(v.key(.delete, modifiers: []))
        #expect(s.captionItems.isEmpty)
        var c = Canvas(width: 320, height: 400, atlas: nil, scale: 1)
        v.draw(&c)                                                           // the empty state
        #expect(v.hint == "0 captions")
    }

    @Test func importsASubtitleFileAndListsTheExport() throws {
        let (s, v) = try rig()
        var status: [String] = []
        v.onStatus = { status.append($0) }
        let srt = "1\n00:00:10,000 --> 00:00:11,000\nimported line\n\n"
        v.importSubtitles(data: Data(srt.utf8), fileExtension: "SRT")
        #expect(s.captionItems.contains { $0.lines == ["imported line"] })
        #expect(status.last?.hasPrefix("Imported") == true)
        #expect(v.exportItems.map(\.range.start) == v.exportItems.map(\.range.start).sorted())
        #expect(CaptionsTabDraw.subtitleExtensions.contains("vtt"))
    }

    @Test func addCaptionAtPlayheadIsEnabledWithATimelineLikeTheMacMenu() throws {
        let (s, v) = try rig()
        func add() -> SQMenuItem? { v.contextItems().first { $0.title == "Add Caption at Playhead" } }
        #expect(add()?.isEnabled == true)
        #expect(s.activeTimeline != nil)
        s.seek(to: Time(9, 1))
        add()?.action?()
        #expect(s.captionItems.count == 5)
    }
}
