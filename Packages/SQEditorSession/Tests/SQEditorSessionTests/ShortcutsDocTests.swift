import Foundation
import Testing
@testable import SQEditorSession

/// docs/SHORTCUTS.md is generated from the key map. Regenerate with `SQ_WRITE_SHORTCUTS=1 SQ_TEST_FILTER=ShortcutsDoc
/// scripts/test.sh SQEditorUI`; `docIsUpToDate` fails when the file is stale.
@Suite struct ShortcutsDocTests {
    static let docURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/SHORTCUTS.md")

    static func render() -> String {
        let sq = CommandMap.sqDefault, pr = CommandMap.premiereDefault
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        func keyText(_ b: KeyBinding) -> String { cell(KeyboardListing.text(for: b)) }
        var out = """
        # Keyboard shortcuts

        Generated from the default key map; do not edit by hand. Every key can be changed in Window > Keyboard Shortcuts,
        where the Premiere-style set is available as well (the last section lists where it differs).

        Symbols: ⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command.

        ## How keys are routed

        - A key is looked up in the scope of the focused panel first, then in "Everywhere". A panel scope never reuses a key
          that "Everywhere" gives to another command, so no key means two things in one place.
        - The Timeline, Program monitor and Source monitor share the transport and marking keys (Space, J K L, arrows, I, O, X,
          comma and period).
        - While a text field is being edited (names, timecode, text layers, search) it keeps all typing keys: Space, J/K/L,
          Delete, the arrow keys and plain letters never reach the editor commands. Cmd+Z, Cmd+C, Cmd+X, Cmd+V and Cmd+A
          edit the text; Command shortcuts that only exist for the Timeline are switched off while typing.
        - In lists and number fields the arrow keys belong to the list or field, not to the playhead.
        - Menu items show the same keys. Every command that has a key is also in a menu; commands without a key are listed last.


        """
        let scopes: [(CommandScope, String)] = [(.global, "Everywhere"), (.timeline, "Timeline"), (.program, "Program monitor"),
                                                (.source, "Source monitor"), (.project, "Project panel")]
        for (scope, title) in scopes {
            let rows = sq.entries.filter { $0.scope == scope }
            guard !rows.isEmpty else { continue }
            out += "## \(title)\n\n| Key | Command |\n|---|---|\n"
            for e in rows.sorted(by: { ($0.command.title, keyText($0.binding)) < ($1.command.title, keyText($1.binding)) }) {
                out += "| \(keyText(e.binding)) | \(cell(e.command.title)) |\n"
            }
            out += "\n"
        }
        let keyed = Set(sq.entries.map(\.command))
        let paths = CommandAudit.menuPaths()
        out += "## Menu only (no key by default)\n\n| Command | Menu |\n|---|---|\n"
        for c in CommandCatalog.audited(sq).filter({ !keyed.contains($0) && CommandSupport.isSupported($0) }).sorted(by: { $0.title < $1.title }) {
            out += "| \(cell(c.title)) | \(cell(paths[c] ?? "-")) |\n"
        }
        out += "\n## Differences from the Premiere-style set\n\n| Command | Default | Premiere-style |\n|---|---|---|\n"
        var diffs: [(String, String, String)] = []
        for c in Set(sq.entries.map(\.command)).union(pr.entries.map(\.command)) {
            func list(_ m: CommandMap) -> [String] {
                m.entries.filter { $0.command == c }.map { "\(KeyboardListing.scopeName($0.scope)): \(KeyboardListing.text(for: $0.binding))" }.sorted()
            }
            if list(sq) != list(pr) { diffs.append((c.title, list(sq).joined(separator: ", "), list(pr).joined(separator: ", "))) }
        }
        for d in diffs.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            out += "| \(cell(d.0)) | \(cell(d.1.isEmpty ? "-" : d.1)) | \(cell(d.2.isEmpty ? "-" : d.2)) |\n"
        }
        return out
    }

    @Test func writeWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["SQ_WRITE_SHORTCUTS"] == "1" else { return }
        try Self.render().write(to: Self.docURL, atomically: true, encoding: .utf8)
    }

    @Test func docIsUpToDate() throws {
        guard ProcessInfo.processInfo.environment["SQ_WRITE_SHORTCUTS"] != "1",
              let current = try? String(contentsOf: Self.docURL, encoding: .utf8) else { return }
        #expect(current == Self.render(), "docs/SHORTCUTS.md is stale: regenerate with SQ_WRITE_SHORTCUTS=1")
    }
}
