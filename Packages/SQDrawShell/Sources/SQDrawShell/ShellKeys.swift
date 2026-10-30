import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// The event glue of the shortcut system: a shared-toolkit key press becomes the `Key` of the Mac key map, then
/// `WindowsKeyRoute` picks the command (Ctrl reaches Command bindings first, then Control ones). The map, scopes and
/// conflict rules are the Mac ones (`CommandMap`), unchanged.
public enum ShellKeys {
    /// `InputKey` → `Key`. Enter is Return, Backspace is the Mac Delete, Del is Forward Delete.
    public static func key(_ k: InputKey) -> Key? {
        switch k {
        case .space: .space
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .function(let n): .function(n)
        case .backspace: .delete
        case .delete: .forwardDelete
        case .enter: .returnKey
        case .plus: .char("=")      // the Mac map binds the unshifted key of the +/= cap
        case .minus: .char("-")
        case .character(let c): .char(Character(c.lowercased()))
        case .escape: nil           // Esc closes menus and dialogs first; the host routes it there
        }
    }

    /// The command a key press runs with `focus`, or nil (`InputModifiers.command` is the Ctrl key on Windows).
    public static func command(_ k: InputKey, _ m: InputModifiers, focus: PanelID?, map: CommandMap) -> EditorCommand? {
        guard let key = key(k) else { return nil }
        return WindowsKeyRoute.command(key, ctrl: m.contains(.command), alt: m.contains(.option), shift: m.contains(.shift),
                                       focus: focus, map: map)
    }
}

/// Alt pressed and released alone focuses the menu bar (`MenuBar.altTapped`), the Windows menu-key rule. The window feeds
/// raw presses: Alt down (repeats keep it armed), any other key or a mouse press in between disarms it (Alt+key shortcuts,
/// Alt+click), Alt up reports the tap.
public struct AltTap: Sendable, Equatable {
    private var down = false, clean = false
    public init() {}
    public mutating func altDown() { if !down { down = true; clean = true } }
    /// Another key or a mouse button while Alt is down: a shortcut, not a tap.
    public mutating func other() { clean = false }
    /// Alt released: true when nothing else happened since it went down.
    public mutating func altUp() -> Bool { defer { down = false; clean = false }; return down && clean }
}

/// Window title and dirty state: the Mac sets `window.title = session.displayName` and `isDocumentEdited` (the dot in the close
/// button). Windows shows the edited state the platform way, a leading "*", and names the app after the project.
public enum ShellWindowTitle {
    public static func text(projectName: String?, dirty: Bool) -> String {
        guard let name = projectName, !name.isEmpty else { return "Sequence Studio" }
        return (dirty ? "*" : "") + name + " - Sequence Studio"
    }
}
