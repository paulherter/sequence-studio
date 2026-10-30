import Testing
@testable import SQUIKit

/// Shortcut invariants checked for both shipped key sets (Premiere and the Sequence Studio default), not only Premiere.
@Suite struct ShortcutAuditTests {
    static let maps: [KeySet] = [KeySet(name: "premiere", map: .premiereDefault), KeySet(name: "sq", map: .sqDefault)]

    struct KeySet: Sendable, CustomTestStringConvertible {
        let name: String
        let map: CommandMap
        var testDescription: String { name }
    }

    private static var menuCommands: [EditorCommand] {
        EditorMenus.all.flatMap(\.commands).filter(CommandSupport.isSupported) + MenuKeys.appMenuCommands
            + EditorMenus.windowPanels.map(EditorCommand.focusPanel)
    }

    @Test(arguments: maps) func noDuplicatesAndNoShadowing(_ s: KeySet) {
        #expect(s.map.duplicates.isEmpty, "\(s.name)")
        let global = Dictionary(s.map.entries.filter { $0.scope == .global }.map { ($0.binding, $0.command) }, uniquingKeysWith: { a, _ in a })
        for e in s.map.entries where e.scope != .global {
            if let g = global[e.binding] {
                #expect(g == e.command, "\(s.name) \(e.scope) \(KeyboardListing.text(for: e.binding)): \(e.command) vs global \(g)")
            }
        }
    }

    @Test(arguments: maps) func everyBindingIsWired(_ s: KeySet) {
        for e in s.map.entries { #expect(CommandSupport.isSupported(e.command), "\(s.name) \(e.command)") }
    }

    /// Menu items carry one key each; two items may not show the same key.
    @Test(arguments: maps) func menuKeysAreUnique(_ s: KeySet) {
        var seen: [KeyBinding: EditorCommand] = [:]
        for c in Self.menuCommands {
            guard let k = s.map.binding(for: c) else { continue }
            if let other = seen[k], other != c { Issue.record("\(s.name) \(KeyboardListing.text(for: k)) is shown by \(other) and \(c)") }
            seen[k] = c
        }
    }

    /// A Command key owned by a menu item fires that item before the router sees it. A scoped binding of the same key
    /// for another command would be dead.
    @Test(arguments: maps) func menuOwnedKeysDoNotHideScopedBindings(_ s: KeySet) {
        var owner: [KeyBinding: EditorCommand] = [:]
        for c in Self.menuCommands { if let k = s.map.binding(for: c) { owner[k] = c } }
        for e in s.map.entries where e.binding.modifiers.contains(.command) {
            if let o = owner[e.binding], o != e.command {
                Issue.record("\(s.name) \(e.scope) \(KeyboardListing.text(for: e.binding)) is bound to \(e.command) but the menu item \(o) fires first")
            }
        }
    }

    /// Transport, marking and edit keys work the same in the monitors and the timeline.
    @Test(arguments: maps) func monitorsOwnTransportKeys(_ s: KeySet) {
        for focus in [PanelID.programMonitor, .sourceMonitor, .timeline] {
            func cmd(_ k: Key, _ m: KeyModifiers = []) -> EditorCommand? { s.map.command(for: KeyBinding(k, m), focus: focus) }
            #expect(cmd(.space) == .playPause, "\(s.name) \(focus)")
            #expect(cmd(.char("j")) == .shuttleReverse)
            #expect(cmd(.char("k")) == .shuttleStop)
            #expect(cmd(.char("l")) == .shuttleForward)
            #expect(cmd(.left) == .stepBackward)
            #expect(cmd(.right) == .stepForward)
            #expect(cmd(.char("i")) == .markIn)
            #expect(cmd(.char("o")) == .markOut)
            #expect(cmd(.char("x")) == .markClip)
            #expect(cmd(.char(",")) == .insert)
            #expect(cmd(.char(".")) == .overwrite)
        }
    }
}
