import Foundation
import SQDrawShell
import SQEditorSession
import Testing
@testable import SQAppShell

@MainActor @Suite struct WindowChromeTests {
    func width(_ s: String) -> CGFloat { CGFloat(s.count) * 6 }

    func content() -> StatusBarContent {
        var s = StatusBarContent()
        s.format = StatusBarContent.format(width: 1920, height: 1080, fps: 25, variableFrameRate: false)
        s.save = SaveStatus.make(isDirty: false, hasFile: true, lastEdit: nil, lastBackup: nil)
        s.message = "Cut at 00:00:02:00"
        s.playback = StatusBarContent.playback(.half)
        s.version = "Sequence Studio 1.0"
        return s
    }

    @Test func statusBarTextsMatchTheMac() {
        #expect(StatusBarContent.format(width: 1080, height: 1920, fps: 29.97, variableFrameRate: true) == "1080 × 1920 · 29.97 fps VFR")
        #expect(StatusBarContent.playback(.full) == "Playback: Full · GPU")
    }

    @Test func leftPartsRunFormatDotSaveThenMessageAndTheRightEndHoldsVersionThenPlayback() throws {
        var s = content()
        s.grade = "Pro grade active, 4 steps"
        s.linkedSelectionOff = true
        let bar = CGRect(x: 0, y: 700, width: 1400, height: 28)
        let f = StatusBarDraw.layout(s, in: bar, width: width)
        let format = try #require(f.format), dot = try #require(f.dot), save = try #require(f.save)
        #expect(format.minX == 16 && dot.minX == format.maxX + 16 && save.minX == dot.maxX + 6)
        #expect(dot.midY == bar.midY)
        let version = try #require(f.version), playback = try #require(f.playback)
        let grade = try #require(f.grade), link = try #require(f.link), message = try #require(f.message)
        #expect(version.maxX == bar.maxX - 16 && playback.maxX == version.minX - 16)
        #expect(grade.maxX == playback.minX - 16 && link.maxX == grade.minX - 16)
        #expect(message.minX == save.maxX + 16 && message.maxX == link.minX - 16)
    }

    @Test func theRingSitsAtTheRightEndAndTheRelinkChipLeftOfTheLinkWarning() throws {
        var s = content()
        s.linkedSelectionOff = true
        s.relinkOffer = "Found 4 offline files · Reconnect"
        s.exportProgress = 0.4
        let bar = CGRect(x: 0, y: 700, width: 1400, height: 28)
        let f = StatusBarDraw.layout(s, in: bar, width: width, chipWidth: { CGFloat($0.count) * 5 })
        let ring = try #require(f.ring), version = try #require(f.version)
        let link = try #require(f.link), relink = try #require(f.relink), message = try #require(f.message)
        #expect(ring.maxX == bar.maxX - 16 + 3 && ring.width == 20 && ring.midY == bar.midY)
        #expect(version.maxX == ring.minX - 16 + 3)
        #expect(relink.maxX == link.minX - 16 && relink.width == CGFloat(s.relinkOffer.count) * 5)
        #expect(message.maxX == relink.minX - 16)
        let measure = TextMeasure(atlas: nil, scale: 1)
        let hit = StatusBarDraw.layout(s, in: bar, width: { measure.width($0, size: StatusBarDraw.fontSize) },
                                     chipWidth: { measure.width($0, size: StatusBarDraw.chipSize) })
        let r = try #require(hit.relink)
        do {
            #expect(StatusBarDraw.part(at: CGPoint(x: r.midX, y: r.midY), s, in: bar, measure: measure) == .relink)
        }
        #expect(StatusBarDraw.part(at: CGPoint(x: ring.midX, y: ring.midY), s, in: bar, measure: measure) == .ring)
        #expect(StatusBarDraw.part(at: CGPoint(x: 2, y: bar.midY), s, in: bar, measure: measure) == nil)
    }

    @Test func aNarrowBarDropsTheVersionFirstThenThePlaybackText() {
        let s = content()
        let w = StatusBarDraw.layout(s, in: CGRect(x: 0, y: 0, width: 1400, height: 28), width: width)
        #expect(w.version != nil && w.playback != nil)
        let mid = StatusBarDraw.layout(s, in: CGRect(x: 0, y: 0, width: 640, height: 28), width: width)
        #expect(mid.version == nil && mid.playback != nil)
        let narrow = StatusBarDraw.layout(s, in: CGRect(x: 0, y: 0, width: 380, height: 28), width: width)
        #expect(narrow.version == nil && narrow.playback == nil && narrow.format != nil)
    }

    @Test func emptyTextsLeaveNoFrames() {
        var s = StatusBarContent()
        s.version = ""
        let f = StatusBarDraw.layout(s, in: CGRect(x: 0, y: 0, width: 800, height: 28), width: width)
        #expect(f == StatusBarDraw.Frames())
    }

    @Test func editedTextCountsUpLikeTheMacTopBar() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(TitleRowHost.editedText(nil, now: now) == "")
        #expect(TitleRowHost.editedText(now.addingTimeInterval(-20), now: now) == "Edited just now")
        #expect(TitleRowHost.editedText(now.addingTimeInterval(-150), now: now) == "Edited 2 min ago")
        #expect(TitleRowHost.editedText(now.addingTimeInterval(-3 * 3600), now: now) == "Edited 3 h ago")
        #expect(TitleRowHost.editedText(now.addingTimeInterval(-4 * 86_400), now: now) == "Edited 4 d ago")
    }

    @Test func titleRowPlacesNameEditedSlotSwitchAndExportAtTheRightEnd() throws {
        let row = TitleRowHost()
        row.projectName = "Holiday"
        row.edited = Date()
        row.workspaceName = "Editing"
        let measure = TextMeasure(atlas: nil, scale: 1)
        row.layout(after: 300, width: 1400, barHeight: 38, switchWidth: 144, measure: measure)
        let name = try #require(row.frames[.name]), edited = try #require(row.frames[.edited])
        let export = try #require(row.frames[.export]), ws = try #require(row.frames[.workspace])
        #expect(name.minX == 312 && edited.minX == name.maxX + 8)
        #expect(row.switchAfter == edited.maxX)
        #expect(export.maxX == 1400 - 12 && ws.maxX == export.minX - 8 && export.midY == 19)
        // The edit time's slot is as wide as its widest text, so the switch does not move when the text changes.
        row.edited = nil
        row.layout(after: 300, width: 1400, barHeight: 38, switchWidth: 144, measure: measure)
        #expect(row.frames[.edited] == nil && row.switchAfter == edited.maxX)
    }

    /// The start screen's bar is the app's name only (the Mac chooser): no name, workspace, Export or page switch.
    @Test func theStartScreenBarLaysOutNoControls() throws {
        let row = TitleRowHost()
        row.projectName = "Untitled"
        row.workspaceName = "Editing"
        row.isChooser = true
        row.layout(after: 300, width: 1400, barHeight: 38, switchWidth: 144, measure: TextMeasure(atlas: nil, scale: 1))
        #expect(row.frames.isEmpty && row.switchAfter == 300)
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: StubProgramEngine())
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = ColorPageHost(session: s, menus: MenuController(), shell: shell)
        host.layoutSwitch(after: 300, barHeight: 38, shown: false)
        #expect(host.frames[.pageSwitch] == nil)
        host.layoutSwitch(after: 300, barHeight: 38)
        #expect(host.frames[.pageSwitch] != nil)
    }

    @Test func exportFiresOnReleaseOverTheButtonAndWorkspaceOpensItsMenu() throws {
        let row = TitleRowHost()
        row.projectName = "Holiday"
        row.workspaceName = "Editing"
        var exports = 0, asked = 0
        row.onExport = { exports += 1 }
        row.workspaceItems = { asked += 1; return [] }
        row.layout(after: 300, width: 1400, barHeight: 38, switchWidth: 144, measure: TextMeasure(atlas: nil, scale: 1))
        let e = try #require(row.frames[.export]), w = try #require(row.frames[.workspace])
        #expect(row.handle(.mouseDown(x: Float(e.midX * 2), y: Float(e.midY * 2), modifiers: []), scale: 2))
        #expect(row.handle(.mouseUp(x: 0, y: 0), scale: 2) && exports == 0, "released off the button")
        _ = row.handle(.mouseDown(x: Float(e.midX), y: Float(e.midY), modifiers: []), scale: 1)
        _ = row.handle(.mouseUp(x: Float(e.midX), y: Float(e.midY)), scale: 1)
        #expect(exports == 1)
        #expect(row.handle(.mouseDown(x: Float(w.midX), y: Float(w.midY), modifiers: []), scale: 1) && asked == 1)
        #expect(!row.handle(.mouseDown(x: 1, y: 1, modifiers: []), scale: 1))
    }
}
