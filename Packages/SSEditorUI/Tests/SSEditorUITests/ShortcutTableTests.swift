import Testing
@testable import SSEditorUI

/// The shortcut table (docs/audit/shell.md) as a test: Premiere's macOS defaults, no collisions, no dead keys.
@Suite struct ShortcutTableTests {
    let map = CommandMap.premiereDefault

    @Test func noDuplicateBindingsInAScope() {
        #expect(map.duplicates.isEmpty)
    }

    /// A key bound twice for different commands in scopes that can be active together (global + one panel scope) is a
    /// collision unless the panel scope deliberately overrides the global one. None of the defaults does.
    @Test func panelScopesNeverShadowGlobalKeys() {
        let global = Dictionary(uniqueKeysWithValues: map.entries.filter { $0.scope == .global }.map { ($0.binding, $0.command) })
        for e in map.entries where e.scope != .global {
            if let g = global[e.binding] { #expect(g == e.command, "\(e.scope) \(e.binding) shadows global \(g)") }
        }
    }

    /// Every key is reachable: the AppKit adapter produces a plain key (`=`, not `+`) plus modifiers.
    @Test func keysAreKeyCapsNotShiftedCharacters() {
        let shifted: Set<Character> = ["+", "_", "~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "{", "}", "|", ":", "\"", "<", ">", "?"]
        for e in map.entries {
            if case .char(let c) = e.binding.key { #expect(!shifted.contains(c), "\(e.command) uses shifted character \(c)") }
        }
    }

    @Test func everyMenuCommandHasAKeyOrIsMenuOnly() {
        for c in EditorMenus.all.flatMap(\.commands) {
            #expect(map.binding(for: c) != nil || EditorMenus.menuOnly.contains(c), "\(c)")
        }
    }

    @Test func fileAndAppShortcutsMatchPremiere() {
        func b(_ k: Character, _ m: KeyModifiers) -> KeyBinding { KeyBinding(.char(k), m) }
        let expected: [(KeyBinding, EditorCommand)] = [
            (b("n", .command), .newSequence), (b("n", [.command, .option]), .newProject),
            (b("o", .command), .openProject), (b("s", .command), .save), (b("s", [.command, .shift]), .saveAs),
            (b("i", .command), .importMedia), (b("m", .command), .export),
            (b("k", [.command, .option]), .keyboardShortcuts), (b(",", .command), .preferences),
            (b("z", .command), .undo), (b("z", [.command, .shift]), .redo),
            (b("x", .command), .cut), (b("c", .command), .copy), (b("v", .command), .paste),
            (b("v", [.command, .option]), .pasteAttributes),
        ]
        for (binding, command) in expected {
            #expect(map.command(for: binding, focus: nil) == command, "\(command)")
        }
    }

    @Test func focusPanelsFollowPremiereMapping() {
        func shift(_ n: Int) -> KeyBinding { KeyBinding(.char(Character(String(n))), .shift) }
        #expect(map.command(for: shift(1), focus: nil) == .focusPanel(.project))
        #expect(map.command(for: shift(2), focus: nil) == .focusPanel(.sourceMonitor))
        #expect(map.command(for: shift(3), focus: nil) == .focusPanel(.timeline))
        #expect(map.command(for: shift(4), focus: nil) == .focusPanel(.programMonitor))
        #expect(map.command(for: shift(5), focus: nil) == .focusPanel(.effectControls))
        #expect(map.command(for: shift(7), focus: nil) == .focusPanel(.effects))
        #expect(map.command(for: KeyBinding(.char("`")), focus: nil) == .maximizePanel)
    }

    @Test func shortcutsWindowSearch() {
        let rows = KeyboardListing.windowRows(map)
        #expect(rows.count == map.entries.count)
        #expect(KeyboardListing.filter(rows, query: "").count == rows.count)
        let razor = KeyboardListing.filter(rows, query: "razor")
        #expect(razor.map(\.shortcut) == ["C"])
        // Modifier names and symbols both match; every word must hit.
        let redo = KeyboardListing.filter(rows, query: "shift cmd z")
        #expect(redo.map(\.command) == ["Redo"])
        #expect(KeyboardListing.filter(rows, query: "⇧⌘Z").map(\.command) == ["Redo"])
        #expect(KeyboardListing.filter(rows, query: "nonsense words").isEmpty)
        #expect(rows.first { $0.command == "Add Edit" }?.scope == "Timeline")
    }

    /// Menu structure, Premiere order.
    @Test func menuOrderAndPlacement() {
        #expect(EditorMenus.all.map(\.title) == ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window"])
        #expect(EditorMenus.markers.commands.contains(.markIn) && EditorMenus.markers.commands.contains(.addMarker))
        #expect(EditorMenus.sequence.commands.contains(.toggleSnapping))
        #expect(EditorMenus.sequence.commands.first == .sequenceSettings)
        #expect(EditorMenus.file.commands.contains(.revert))
        // Each command sits in exactly one menu.
        let all = EditorMenus.all.flatMap(\.commands)
        #expect(Set(all).count == all.count)
    }
}
