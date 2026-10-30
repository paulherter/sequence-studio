import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellFocusedEditTests {
    func setup() throws -> (ShellHost, ProjectListView, MediaRef.ID) {
        let (h, _, media) = try ShellLocateTests().host()
        ProjectListViewTests.hosts.append(h)
        let v = ProjectListView(host: h, defaults: UserDefaults(suiteName: "sq.test.focusedEdit.\(UUID())")!)
        return (h, v, media[0].id)
    }

    @Test func deleteProjectItemsRemovesTheSelection() throws {
        let (h, v, id) = try setup()
        v.selection = [.media(id)]
        #expect(h.execute(.deleteProjectItems))
        #expect(h.session.project.media(id) == nil)
    }

    @Test func editDeleteWithTheProjectFocusedRemovesItems() throws {
        let (h, v, id) = try setup()
        v.selection = [.media(id)]
        h.focus = .project
        #expect(h.execute(.delete))
        #expect(h.session.project.media(id) == nil)
    }
}

/// An open text field wins over the shell's shortcuts (Cmd-Z / C / V / X), panel by panel: the panel consumes the key and
/// the sequence's undo history is untouched.
@MainActor
@Suite struct ShellOpenFieldKeysTests {
    @Test func projectSearchKeepsUndoCopyPaste() throws {
        let (v, m, h, _) = ProjectPanelChromeTests().view()
        v.toggleSearch()
        let undoable = h.session.canUndo
        for ch in "ab" { _ = v.handle(.keyDown(.character(ch), modifiers: []), scale: 1) }
        #expect(m.searchText == "ab")
        #expect(v.handle(.keyDown(.character("z"), modifiers: .command), scale: 1))
        #expect(m.searchText == "")
        TextClipboard.shared.write("xy")
        #expect(v.handle(.keyDown(.character("v"), modifiers: .command), scale: 1))
        #expect(m.searchText == "xy")
        #expect(v.handle(.keyDown(.character("x"), modifiers: .command), scale: 1))
        #expect(h.session.canUndo == undoable)
    }
}
