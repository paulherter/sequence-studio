import AppKit
import SQEditorUI

/// `SQ_DUMPMENU=1`: logs the whole main menu (titles, key equivalents, enabled state) and quits. For the shortcut audit.
@MainActor
enum ShellDevAids {
    static func runIfRequested(_ c: AppController) {
        guard ProcessInfo.processInfo.environment["SQ_DUMPMENU"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let main = NSApp.mainMenu else { exit(2) }
            var lines: [String] = []
            func dump(_ menu: NSMenu, _ depth: Int) {
                menu.update()
                for item in menu.items {
                    let pad = String(repeating: "  ", count: depth)
                    if item.isSeparatorItem { lines.append(pad + "---"); continue }
                    var keys = ""
                    if !item.keyEquivalent.isEmpty {
                        let m = item.keyEquivalentModifierMask
                        keys = (m.contains(.control) ? "^" : "") + (m.contains(.option) ? "~" : "") + (m.contains(.shift) ? "$" : "")
                            + (m.contains(.command) ? "@" : "") + item.keyEquivalent
                    }
                    lines.append("\(pad)\(item.title)\t[\(keys)]\t\(item.isEnabled ? "on" : "OFF")\(item.state == .on ? " checked" : "")")
                    if let s = item.submenu { dump(s, depth + 1) }
                }
            }
            dump(main, 0)
            lines.append("--- every command: title | menu | keys | wired (same table as the CommandParityTests walk)")
            lines.append(CommandAudit.table(c.commandMap))
            NSLog("MENUDUMP\n" + lines.joined(separator: "\n"))
            exit(0)
        }
    }
}
