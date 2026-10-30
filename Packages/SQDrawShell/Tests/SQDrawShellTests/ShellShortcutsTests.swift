import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// Keyboard Shortcuts on the canvas (the Mac `KeyboardShortcutsWindow` flows): list, capture, conflicts, remove, reset.
@MainActor
@Suite(.serialized) struct ShellShortcutsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: "sq-test-shortcuts-\(UUID().uuidString)")! }

    func make(_ platform: KeyPlatform = .windows, defaults: UserDefaults = Self.defaults()) -> (ShellHost, ShellShortcutsEditor) {
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        h.size = CGSize(width: 1280, height: 800)
        let e = ShellShortcutsEditor(host: h, defaults: defaults, platform: platform)
        e.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        h.shortcutsEditor = e
        return (h, e)
    }

    func waitForDialog(_ h: ShellHost) async -> ShellDialog? {
        for _ in 0..<200 {
            if let d = h.dialog { return d }
            await Task.yield()
        }
        return nil
    }

    func row(_ e: ShellShortcutsEditor, _ c: EditorCommand) -> Int? {
        e.setQuery(c.title)
        return e.rows.firstIndex { $0.command == c && $0.entry != nil }
    }

    func binding(_ m: CommandMap, _ c: EditorCommand) -> [KeyBinding] { m.entries.filter { $0.command == c }.map(\.binding) }

    /// A Ctrl+Alt+Shift letter no command uses in the default map.
    func freeLetter(_ e: ShellShortcutsEditor) throws -> Character {
        try #require("jqyubnmpgh".first { ch in
            Keymap.conflicts(of: .undo, binding: KeyBinding(.char(ch), [.command, .option, .shift]), scope: .global, in: e.config.map).isEmpty
        })
    }

    @Test func windowsListNamesCtrlKeysAndFilters() throws {
        let (_, e) = make(.windows)
        let all = e.allRows.count
        #expect(e.countText == "\(all) shortcuts")
        let i = try #require(row(e, .undo))
        #expect(e.rows[i].listing.shortcut == "Ctrl+Z")
        #expect(e.countText == "\(e.rows.count) of \(all)")
        e.setQuery("zzzz-no-command")
        #expect(e.rows.isEmpty)
        let (_, mac) = make(.mac)
        let j = try #require(row(mac, .undo))
        #expect(mac.rows[j].listing.shortcut == "⌘Z")
    }

    @Test func pickedKeyShowsItsCommandsAndTheAssignTitle() {
        let (_, e) = make(.windows)
        e.toggleModifier(.command)
        e.selectKey(.char("z"))
        #expect(e.assignTitle == "Assign to Ctrl+Z")
        #expect(e.info.contains("Undo"))
        e.selectKey(nil)
        #expect(e.info == ShellShortcutsEditor.idleInfo)
    }

    @Test func capturedKeyIsSavedAndReachesTheMenus() async throws {
        let d = Self.defaults()
        let (h, e) = make(.windows, defaults: d)
        var told: CommandMap?
        h.onKeymapChanged = { told = $0 }
        e.select(index: try #require(row(e, .undo)))
        let ch = try freeLetter(e)
        let b = KeyBinding(.char(ch), [.command, .option, .shift])
        e.beginCapture()
        #expect(e.capturing)
        h.handle(.keyDown(.character(ch), modifiers: [.command, .option, .shift]), scale: 1)
        #expect(!e.capturing)
        for _ in 0..<200 where !binding(h.map, .undo).contains(b) { await Task.yield() }
        #expect(binding(h.map, .undo).contains(b))
        #expect(told?.entries == h.map.entries)
        #expect(e.canReset)
        // Saved under sq.keymap: a new editor reads it back.
        let again = ShellShortcutsEditor(host: h, defaults: d, platform: .windows)
        #expect(binding(again.config.map, .undo).contains(b))
    }

    @Test func escCancelsCaptureWithoutAChange() {
        let (h, e) = make(.windows)
        e.select(index: row(e, .undo))
        let before = h.map.entries
        e.beginCapture()
        h.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(!e.capturing)
        #expect(h.map.entries == before)
        #expect(h.isShortcutsShown)
        h.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(!h.isShortcutsShown)
    }

    @Test func takenKeyAsksBeforeReplacing() async throws {
        let (h, e) = make(.windows)
        let redo = KeyBinding(.char("z"), [.command, .shift])
        let undoRow = try #require(row(e, .undo).map { e.rows[$0] })
        let t = Task { await e.attempt(undoRow, binding: redo) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Replace the existing shortcut?")
        #expect(d.informativeText.contains("Ctrl+Shift+Z"))
        d.press(.first)
        await t.value
        #expect(binding(h.map, .undo).contains(redo))
        #expect(!binding(h.map, .redo).contains(redo))
    }

    @Test func canceledConflictChangesNothing() async throws {
        let (h, e) = make(.windows)
        let before = h.map.entries
        let undoRow = try #require(row(e, .undo).map { e.rows[$0] })
        let t = Task { await e.attempt(undoRow, binding: KeyBinding(.char("z"), [.command, .shift])) }
        let d = try #require(await waitForDialog(h))
        d.press(.second)
        await t.value
        #expect(h.map.entries == before)
        #expect(!e.canReset)
    }

    @Test func removeThenResetBringsTheDefaultBack() async throws {
        let (h, e) = make(.windows)
        e.select(index: try #require(row(e, .undo)))
        e.removeShortcut()
        #expect(binding(h.map, .undo).isEmpty)
        #expect(e.canReset)
        let t = Task { await e.resetAll() }
        let d = try #require(await waitForDialog(h))
        d.press(.first)
        await t.value
        #expect(binding(h.map, .undo) == [KeyBinding(.char("z"), .command)])
        #expect(!e.canReset)
    }

    @Test func layoutStyleIsRemembered() {
        let d = Self.defaults()
        let (h, e) = make(.windows, defaults: d)
        let other = KeyboardLayout.Style.allCases.first { $0 != e.style }!
        e.setStyle(other)
        #expect(ShellShortcutsEditor(host: h, defaults: d, platform: .windows).style == other)
    }

    @Test func menuCommandOpensTheEditorModally() {
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        h.size = CGSize(width: 1280, height: 800)
        #expect(h.execute(.keyboardShortcuts))
        #expect(h.isShortcutsShown)
        #expect(h.menuState().modalShown)
        var c = Canvas(width: 1280, height: 800, atlas: nil, scale: 1)
        h.drawOverlays(&c, theme: DrawTheme())
        #expect(c.list.quads.count > 100)
        h.hideShortcuts()
        #expect(!h.isShortcutsShown)
    }
}
