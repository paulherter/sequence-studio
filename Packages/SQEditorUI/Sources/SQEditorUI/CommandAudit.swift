import Foundation

/// One row per command: where it sits in the menus, which keys it has per scope, whether the app wires it.
/// Used by the parity tests and by the dev aid that prints the table.
public struct CommandAuditRow: Sendable {
    public var command: EditorCommand
    public var menuPath: String?
    public var keys: [CommandMap.Entry]
    public var supported: Bool
}

public enum CommandAudit {
    /// "Menu > Submenu" per command listed in `EditorMenus` (Window panel items map to the Window menu).
    public static func menuPaths() -> [EditorCommand: String] {
        var out: [EditorCommand: String] = [:]
        func walk(_ items: [MenuSpec.Item], _ path: String) {
            for item in items {
                switch item {
                case .command(let c): if out[c] == nil { out[c] = path }
                case .separator: break
                case .submenu(let t, let sub): walk(sub, path + " > " + t)
                }
            }
        }
        for m in EditorMenus.all { walk(m.items, m.title) }
        for p in EditorMenus.windowPanels where out[.focusPanel(p)] == nil { out[.focusPanel(p)] = "Window" }
        return out
    }

    public static func rows(_ map: CommandMap) -> [CommandAuditRow] {
        let paths = menuPaths()
        return CommandCatalog.audited(map).map { c in
            CommandAuditRow(command: c, menuPath: paths[c], keys: map.entries.filter { $0.command == c },
                            supported: CommandSupport.isSupported(c))
        }
    }

    /// Plain-text table, one line per command.
    public static func table(_ map: CommandMap) -> String {
        rows(map).map { r in
            let keys = r.keys.map { "\(KeyboardListing.scopeName($0.scope)): \(KeyboardListing.text(for: $0.binding))" }.joined(separator: "; ")
            return "\(r.command.title) | \(r.menuPath ?? "-") | \(keys.isEmpty ? "-" : keys) | \(r.supported ? "wired" : "NOT WIRED")"
        }.joined(separator: "\n")
    }
}
