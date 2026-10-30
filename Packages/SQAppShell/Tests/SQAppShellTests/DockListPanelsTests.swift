import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQLibrary
import SQUIKit
import Testing

/// The Marker List and Keystones dock panels of the shared shells (Mac `MarkerIndexView`, `KeystonesPanelView`).
@MainActor @Suite struct DockListPanelsTests {
    private static let fd = Time(1, 25)

    private func session(markers: [Marker] = []) -> (EditorSession, ShellHost) {
        var t = Timeline(name: "Main", frameDuration: Self.fd, tracks: [Track(kind: .video)])
        t.markers = markers
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        return (s, ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: [])))
    }

    private func markers() -> [Marker] {
        [Marker(time: Self.fd * 50, name: "Two", color: .red), Marker(time: Self.fd * 10, name: "One", color: .green, comment: "intro")]
    }

    @Test func markerListShowsTheSequenceMarkersInTimeOrder() {
        let (s, shell) = session(markers: markers())
        let h = MarkerListHost(session: s, shell: shell)
        h.layout(CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(h.model.rows.map(\.name) == ["One", "Two"])
        #expect(h.selectedRow == nil)                  // the playhead is before the first marker
    }

    @Test func clickingARowGoesToItsMarkerAndThePlayheadRowStaysSelected() {
        let (s, shell) = session(markers: markers())
        let h = MarkerListHost(session: s, shell: shell)
        h.layout(CGRect(x: 0, y: 0, width: 500, height: 300))
        // Row 1 ("Two"): under the field row (8 + 22 + 8) and the column header (24).
        let y = Float(8 + 22 + 8 + 24 + 24 + 12)
        #expect(h.handle(.mouseDown(x: 100, y: y, modifiers: []), scale: 1))
        #expect(s.playhead == Self.fd * 50)
        s.seek(to: Self.fd * 20)
        h.layout(CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(h.selectedRow == 0)
    }

    @Test func typingInTheFilterNarrowsTheRows() {
        let (s, shell) = session(markers: markers())
        let h = MarkerListHost(session: s, shell: shell)
        h.layout(CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(h.handle(.mouseDown(x: 20, y: 18, modifiers: []), scale: 1))
        for ch in "intro" { _ = h.handle(.keyDown(.character(ch), modifiers: []), scale: 1) }
        #expect(h.model.rows.map(\.name) == ["One"])
        _ = h.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(h.model.rows.count == 2)
    }

    @Test func exportWithoutMarkersSaysSoAndFileMenuRoutesToIt() {
        let (s, shell) = session()
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        let h = MarkerListHost(session: s, shell: shell)
        #expect(shell.onCommand?(.exportMarkersCSV) == true)
        #expect(lines.last == "There are no markers to export.")
        withExtendedLifetime(h) {}
    }

    /// A right click on Export CSV opens no save panel (the shot sweep hung in the modal NSSavePanel); a left click does.
    @Test func onlyALeftClickOnExportCSVAsksWhereToSave() {
        let (s, shell) = session(markers: markers())
        let picker = CSVPickerStub()
        shell.files = picker
        let h = MarkerListHost(session: s, shell: shell)
        h.layout(CGRect(x: 0, y: 0, width: 500, height: 300))
        let x = Float(h.exportRect.midX), y = Float(h.exportRect.midY)
        _ = h.handle(.mouseDown(x: x, y: y, modifiers: .secondary), scale: 1)
        _ = h.handle(.mouseUp(x: x, y: y), scale: 1)
        #expect(picker.asked == 0)
        #expect(h.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1))
        _ = h.handle(.mouseUp(x: x, y: y), scale: 1)
        #expect(picker.asked == 1)
    }

    @Test func keystonesDockedListsTheBuiltInsAndApplyNeedsAVideoClip() {
        let (s, shell) = session()
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        let h = KeystonesHost(session: s, menus: shell.menuBar.controller, shell: shell, loadLibrary: false)
        h.layout(docked: CGRect(x: 0, y: 0, width: 260, height: 300), scale: 1, theme: DrawTheme())
        #expect(h.palette.isDocked && h.palette.keystones == h.model.keystones && !h.model.keystones.isEmpty)
        h.applyToSelection(h.model.keystones[0])
        #expect(lines.last?.hasPrefix("Select a video clip") == true)
    }

    @Test func keystonesDragOntoTheTimelineAsksThePanel() {
        let (s, shell) = session()
        let h = KeystonesHost(session: s, menus: shell.menuBar.controller, shell: shell, loadLibrary: false)
        var asked = 0
        h.withTimeline = { _ in asked += 1 }
        h.layout(docked: CGRect(x: 0, y: 0, width: 260, height: 300), scale: 1, theme: DrawTheme())
        _ = h.handle(.mouseDown(x: 40, y: 14, modifiers: []), scale: 1)
        _ = h.handle(.mouseDragged(x: 40, y: 400), scale: 1)
        #expect(asked == 1)
    }
}

@MainActor
private final class CSVPickerStub: ShellFilePicker, PanelFileChooser {
    var asked = 0
    func chooseProject() async -> URL? { nil }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { nil }
    func chooseMedia() async -> [URL] { [] }
    func chooseSubtitles() -> URL? { nil }
    func chooseSRTLocation(suggestedName: String) -> URL? { nil }
    func choosePNGLocation(suggestedName: String) -> URL? { nil }
    func chooseCSVLocation(suggestedName: String) -> URL? { asked += 1; return nil }
    func chooseLUTs(multiple: Bool) -> [URL] { [] }
}

extension DockListPanelsTests {
    @Test func markerFilterKeepsUndoAndPaste() {
        let (s, shell) = session(markers: markers())
        let h = MarkerListHost(session: s, shell: shell)
        h.layout(CGRect(x: 0, y: 0, width: 500, height: 300))
        let undoable = s.canUndo
        #expect(h.handle(.mouseDown(x: 20, y: 18, modifiers: []), scale: 1))
        for ch in "intro" { _ = h.handle(.keyDown(.character(ch), modifiers: []), scale: 1) }
        #expect(h.handle(.keyDown(.character("z"), modifiers: .command), scale: 1))
        #expect(h.model.rows.count == 2)
        TextClipboard.shared.write("intro")
        #expect(h.handle(.keyDown(.character("v"), modifiers: .command), scale: 1))
        #expect(h.model.rows.map(\.name) == ["One"])
        #expect(s.canUndo == undoable)
    }
}
