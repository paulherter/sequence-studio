import Foundation
import SQUIKit

/// Texts that name the platform the shared shell runs on (the Windows app, or the Mac's opt-in shared UI) and the key
/// hints of the start screen, so the Mac shows "⌘N" and "not in the shared UI yet" where Windows says "Ctrl+N".
public enum ShellPlatformText {
    /// `abbreviatingWithTildeInPath`: the home folder shown as "~" (Mac only; Windows paths stay whole).
    public static func abbreviatingHome(_ path: String) -> String {
        #if os(macOS)
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        #endif
        return path
    }

    /// A command or panel the shared UI does not have yet.
    public static var notAvailable: String {
        KeyPlatform.current == .windows ? "Not available on Windows yet." : "Not available in the shared UI yet."
    }

    /// The placeholder card's note.
    public static var panelMissing: String {
        KeyPlatform.current == .windows ? "Not on Windows yet" : "Not in the shared UI yet"
    }

    /// "%@ does not import …" for files the platform's probe cannot read.
    public static var doesNotImport: String {
        KeyPlatform.current == .windows ? "%@ does not import on Windows yet." : "%@ does not import in the shared UI yet."
    }

    /// Preferences > Advanced, the Edit API help (two whole strings, so each has its own translation).
    public static var editAPIHelp: String {
        KeyPlatform.current == .windows
            ? "Only programs on this computer can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md."
            : "Only programs on this Mac can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md."
    }

    /// The Command-key hint for `key` ("Ctrl+N" / "⌘N").
    public static func commandKey(_ key: Character) -> String {
        KeyBindingText.text(KeyBinding(.char(key), .command))
    }
}
