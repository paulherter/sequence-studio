import AppKit

/// What an editor window does with a key down that no responder took. AppKit ends such a key in `NSWindow.keyDown`, which
/// plays the error beep. Delete and Forward Delete reach that end after a *successful* delete too (a list or panel that
/// deletes through a menu item or an own handler, a table that has no delete handler of its own), so those two keys are
/// swallowed silently; every other unhandled key keeps the system beep.
public enum SQUnhandledKey {
    /// True for Delete (51) and Forward Delete (117): never beep.
    public static func isSilent(keyCode: UInt16) -> Bool { keyCode == 51 || keyCode == 117 }
}

/// The editor's main window (`SQUnhandledKey`).
@MainActor
open class SQEditorWindow: NSWindow {
    open override func keyDown(with event: NSEvent) {
        if SQUnhandledKey.isSilent(keyCode: event.keyCode) { return }
        super.keyDown(with: event)
    }
}

/// Panel twin of `SQEditorWindow` (floating panels).
@MainActor
open class SQEditorPanel: NSPanel {
    open override func keyDown(with event: NSEvent) {
        if SQUnhandledKey.isSilent(keyCode: event.keyCode) { return }
        super.keyDown(with: event)
    }
}
