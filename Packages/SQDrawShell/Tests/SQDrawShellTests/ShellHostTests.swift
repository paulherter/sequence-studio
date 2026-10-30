import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
private final class PickerStub: ShellFilePicker {
    var open: URL?
    var save: URL?
    var asked: [String] = []
    func chooseProject() async -> URL? { open }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { asked.append(suggestedName); return save }
    func chooseMedia() async -> [URL] { [] }
}

@MainActor
@Suite struct ShellCommandsTests {
    static func session() -> EditorSession {
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video), Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [tl]))
    }

    @Test func revertNeedsAFileAndChangesAndRangeCommandsNeedARange() {
        let s = Self.session()
        let p = ShellPanelFacts()
        #expect(!ShellCommands.enabled(.revert, session: s, panels: p))
        #expect(!ShellCommands.enabled(.lift, session: s, panels: p))
        s.markIn()
        #expect(ShellCommands.enabled(.lift, session: s, panels: p))
        #expect(!ShellCommands.enabled(.revert, session: s, panels: p))   // dirty but never saved
        #expect(!ShellCommands.enabled(.insert, session: s, panels: p))   // no source loaded
    }

    @Test func sessionCommandsRunAndPanelCommandsAreLeftToTheHost() {
        let s = Self.session()
        #expect(ShellCommands.run(.markIn, session: s) == "")
        #expect(s.activeTimeline?.inOut != nil)
        #expect(ShellCommands.run(.undo, session: s) == "")
        #expect(s.activeTimeline?.inOut == nil)
        #expect(ShellCommands.run(.zoomIn, session: s) == nil)
        #expect(ShellCommands.run(.setToFrameSize, session: s) == "Select clips to scale to the frame size.")
    }
}

@MainActor
@Suite struct ShellHostTests {
    final class Flows { var list: [@MainActor () async -> Void] = [] }

    func host() -> (ShellHost, Flows) {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        let f = Flows()
        h.spawn = { f.list.append($0) }
        h.size = CGSize(width: 1000, height: 700)
        return (h, f)
    }

    /// Runs the flow until it shows a dialog, answers it, then lets the flow finish.
    func answer(_ h: ShellHost, _ flow: @escaping @MainActor () async -> Void, with r: ShellDialog.Response) async {
        let t = Task { @MainActor in await flow() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        h.dialog?.press(r)
        await t.value
    }

    @Test func titleMarksUnsavedChanges() {
        let (h, _) = host()
        #expect(h.windowTitle == "Sequence Studio")   // nothing open: the Mac shows the start window
        h.session.markIn()
        #expect(h.windowTitle == "*P - Sequence Studio")
    }

    @Test func ctrlKeyRunsTheCommandAndUnknownKeysPassThrough() {
        let (h, _) = host()
        #expect(h.handle(.keyDown(.character("i"), modifiers: []), scale: 1))
        #expect(h.session.activeTimeline?.inOut != nil)
        #expect(h.handle(.keyDown(.character("z"), modifiers: [.command]), scale: 1))
        #expect(h.session.activeTimeline?.inOut == nil)
        #expect(!h.handle(.keyDown(.character("q"), modifiers: [.option, .shift]), scale: 1))
    }

    @Test func closeAsksAndDontSaveCloses() async {
        let (h, f) = host()
        h.session.markIn()
        h.execute(.closeProject)
        #expect(f.list.count == 1)
        await answer(h, f.list[0], with: .third)   // Don’t Save
        #expect(h.session.isEmptyUntitled)
        #expect(h.dialog == nil)
    }

    @Test func cancelKeepsTheProject() async {
        let (h, f) = host()
        h.session.markIn()
        h.execute(.closeProject)
        await answer(h, f.list[0], with: .second)   // Cancel
        #expect(!h.session.isEmptyUntitled)
        #expect(h.session.isDirty)
    }

    @Test func dialogTakesEveryEventWhileItShows() async {
        let (h, f) = host()
        h.session.markIn()
        h.execute(.closeProject)
        let t = Task { @MainActor in await f.list[0]() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        #expect(h.handle(.keyDown(.character("i"), modifiers: []), scale: 1))
        #expect(!h.enabled(.closeProject))
        #expect(h.handle(.keyDown(.escape, modifiers: []), scale: 1))   // Esc = Cancel
        await t.value
        #expect(h.dialog == nil)
        #expect(!h.session.isEmptyUntitled)
    }

    @Test func saveOfAnUntitledProjectAsksForAPlaceAndNotesTheRecent() async throws {
        let (h, f) = host()
        let picker = PickerStub()
        h.files = picker
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqshell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        picker.save = dir.appendingPathComponent("Cut")
        h.session.markIn()
        h.execute(.save)
        await f.list[0]()
        #expect(picker.asked == ["P." + ProjectFile.fileExtension])
        #expect(h.session.fileURL?.pathExtension == ProjectFile.fileExtension)
        #expect(!h.session.isDirty)
        #expect(h.recents.entries.first?.name == "Cut")
        #expect(h.windowTitle == "Cut - Sequence Studio")
    }

    @Test func canceledSavePlaceStaysDirty() async {
        let (h, f) = host()
        h.files = PickerStub()
        h.session.markIn()
        h.execute(.save)
        await f.list[0]()
        #expect(h.session.isDirty)
        #expect(h.session.fileURL == nil)
    }

    @Test func menusFollowTheSessionAndClearRecents() {
        let (h, _) = host()
        h.recents.note(URL(fileURLWithPath: "/tmp/A.sqproj"))
        var saved: RecentProjects?
        h.saveRecents = { saved = $0 }
        #expect(h.menuState().recents.count == 1)
        h.perform(.clearRecents)
        #expect(h.recents.entries.isEmpty)
        #expect(saved?.entries.isEmpty == true)
        var status: [String] = []
        h.onStatus = { status.append($0) }
        h.perform(.bringAllToFront)   // a Mac-only row nobody runs here
        #expect(status == [ShellPlatformText.notAvailable])
        // Window > Tools shows the host's tool strip state.
        h.fillMenuState = { $0.toolStripVisible = false }
        #expect(!h.menuState().toolStripVisible)
    }
}

@MainActor
@Suite struct ShellEditKeysTests {
    func host() -> ShellHost {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        h.size = CGSize(width: 1000, height: 700)
        return h
    }

    @Test func commandZUndoesAndShiftCommandZRedoesInEveryFocus() {
        for focus in [nil, PanelID.timeline, .effectControls, .programMonitor, .project] {
            let h = host()
            h.focus = focus
            h.session.markIn()
            #expect(h.session.activeTimeline?.inOut != nil)
            #expect(h.handle(.keyDown(.character("z"), modifiers: .command), scale: 1), "undo key taken, focus \(String(describing: focus))")
            #expect(h.session.activeTimeline?.inOut == nil, "undone, focus \(String(describing: focus))")
            #expect(h.handle(.keyDown(.character("z"), modifiers: [.command, .shift]), scale: 1))
            #expect(h.session.activeTimeline?.inOut != nil, "redone, focus \(String(describing: focus))")
        }
    }
}

@MainActor
@Suite struct ShellMenuShortcutWalkTests {
    /// The window event a Mac key press with `b` sends (`MacKeys.events`): Command, Shift and Option reach the key map.
    static func event(_ b: KeyBinding) -> (InputKey, InputModifiers)? {
        let k: InputKey
        switch b.key {
        case .char(let c): k = c == "=" ? .plus : c == "-" ? .minus : .character(c)
        case .space: k = .space
        case .left: k = .left
        case .right: k = .right
        case .up: k = .up
        case .down: k = .down
        case .home: k = .home
        case .end: k = .end
        case .pageUp: k = .pageUp
        case .pageDown: k = .pageDown
        case .delete: k = .backspace
        case .forwardDelete: k = .delete
        case .returnKey: k = .enter
        case .function(let n): k = .function(n)
        }
        if b.modifiers.contains(.control) { return nil }      // the Mac key route has no Control modifier
        var m: InputModifiers = []
        if b.modifiers.contains(.command) { m.insert(.command) }
        if b.modifiers.contains(.shift) { m.insert(.shift) }
        if b.modifiers.contains(.option) { m.insert(.option) }
        return (k, m)
    }

    /// Every shortcut a menu row shows reaches that row's command in each focus, and its text reads back (the system
    /// menu's key equivalent) to the same binding.
    @Test func everyShownShortcutRoutesToItsCommand() {
        var wrong: [String] = []
        var walked = 0
        for (name, map) in [("premiere", CommandMap.premiereDefault), ("sq", .sqDefault), ("finalCut", .finalCutDefault)] {
        for spec in EditorMenus.visible {
            for c in spec.commands where ShellMenuBar.isVisible(c) {
                guard let b = map.binding(for: c) else { continue }
                walked += 1
                if KeyBindingText.parseMac(KeyBindingText.text(b, platform: .mac)) != b { wrong.append("\(name) \(c): text") }
                guard let (k, m) = Self.event(b) else { continue }
                let scope = map.entries.first { $0.command == c && $0.binding == b }?.scope
                for focus in PanelID.allCases {
                    let got = ShellKeys.command(k, m, focus: focus, map: map)
                    // A panel-scoped binding of the same key may win in its own panel (that is the point of scopes).
                    if got != c, scope == .global, CommandScope.scope(for: focus).flatMap({ s in map.entries.first { $0.scope == s && $0.binding == b } }) == nil {
                        wrong.append("\(name) \(c) in \(focus): \(String(describing: got))")
                    }
                }
            }
        }
        }
        #expect(walked > 100)
        #expect(wrong.isEmpty, "\(wrong)")
    }
}
