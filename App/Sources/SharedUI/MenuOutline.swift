import SQUIKit

/// A menu as text for the Mac parity audit: one line per row (kind, title, key, disabled, checked, icon), submenus
/// indented. `scripts/render-panels.sh` writes it beside each `menu-*.png`, `SQ_SHARED_UI_SHOT` beside each
/// `shared-menu-*.png`; `diff` the two.
enum MenuOutline {
    static func text(_ items: [SQMenuItem], depth: Int = 0) -> String {
        var out = ""
        let pad = String(repeating: "  ", count: depth)
        for i in items {
            switch i.kind {
            case .separator: out += pad + "---\n"; continue
            case .header: out += pad + "# " + i.title + "\n"; continue
            case .caption: out += pad + "~ " + i.title + "\n"; continue
            case .action: break
            }
            var line = pad + i.title
            if !i.shortcut.isEmpty { line += "  [" + i.shortcut + "]" }
            if !i.isEnabled { line += "  (off)" }
            if i.isChecked { line += "  (x)" }
            switch i.icon {
            case .none: break
            case .symbol(let s): line += "  <\(s)>"
            case .swatch(let c): line += "  <#\(String(c, radix: 16))>"
            default: line += "  <icon>"
            }
            if let s = i.leadingSymbol { line += "  <lead \(s)>" }
            out += line + "\n"
            if let sub = i.submenu { out += text(sub, depth: depth + 1) }
        }
        return out
    }
}
