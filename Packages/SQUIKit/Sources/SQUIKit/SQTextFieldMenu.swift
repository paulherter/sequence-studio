import AppKit

/// Right-click menu of any text field: Cut, Copy, Paste, separator, Select All (docs/design-source/menus.txt "Text field").
/// Built on SQMenuController; the system menu never shows for fields.
@MainActor
public enum SQTextFieldMenu {
    /// What the menu needs to know about the field (pure, testable).
    public struct Context: Equatable, Sendable {
        public var isEditable: Bool
        public var hasSelection: Bool
        public var hasText: Bool
        public var canPaste: Bool
        public init(isEditable: Bool, hasSelection: Bool, hasText: Bool, canPaste: Bool) {
            self.isEditable = isEditable; self.hasSelection = hasSelection; self.hasText = hasText; self.canPaste = canPaste
        }
    }

    public struct Actions {
        public var cut: @MainActor () -> Void
        public var copy: @MainActor () -> Void
        public var paste: @MainActor () -> Void
        public var selectAll: @MainActor () -> Void
        public init(cut: @escaping @MainActor () -> Void, copy: @escaping @MainActor () -> Void,
                    paste: @escaping @MainActor () -> Void, selectAll: @escaping @MainActor () -> Void) {
            self.cut = cut; self.copy = copy; self.paste = paste; self.selectAll = selectAll
        }
        public static var none: Actions { Actions(cut: {}, copy: {}, paste: {}, selectAll: {}) }
    }

    /// Items in board order. Disabled (not hidden) when they do not apply.
    public static func items(for c: Context, actions: Actions = .none) -> [SQMenuItem] {
        [
            SQMenuItem(title: "Cut", shortcut: "⌘X", isEnabled: c.isEditable && c.hasSelection, action: actions.cut),
            SQMenuItem(title: "Copy", shortcut: "⌘C", isEnabled: c.hasSelection, action: actions.copy),
            SQMenuItem(title: "Paste", shortcut: "⌘V", isEnabled: c.isEditable && c.canPaste, action: actions.paste),
            .separator,
            SQMenuItem(title: "Select All", shortcut: "⌘A", isEnabled: c.hasText, action: actions.selectAll),
        ]
    }

    static func context(for tv: NSTextView) -> Context {
        Context(isEditable: tv.isEditable, hasSelection: tv.selectedRange().length > 0, hasText: !tv.string.isEmpty,
                canPaste: NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil))
    }

    /// Shows the menu for a text view (a field editor or any NSTextView) at the screen point.
    public static func present(for tv: NSTextView, at screenPoint: CGPoint) {
        let actions = Actions(cut: { [weak tv] in tv?.cut(nil) }, copy: { [weak tv] in tv?.copy(nil) },
                              paste: { [weak tv] in tv?.paste(nil) }, selectAll: { [weak tv] in tv?.selectAll(nil) })
        SQMenuController.shared.present(items: items(for: context(for: tv), actions: actions), at: screenPoint)
    }

    /// The text view a right-click should get this menu for: an active field editor, or the editor of a selectable or
    /// editable field under the pointer (focused first). Nil for everything else.
    static func target(for event: NSEvent) -> NSTextView? {
        guard let window = event.window, let hit = window.contentView?.hitTest(event.locationInWindow) else { return nil }
        if let tv = hit as? NSTextView, tv.isFieldEditor { return tv }
        if let field = hit as? NSTextField, field.isSelectable || field.isEditable {
            if field.currentEditor() == nil { window.makeFirstResponder(field) }
            return field.currentEditor() as? NSTextView
        }
        return nil
    }

    nonisolated(unsafe) private static var monitor: Any?

    /// App-wide: every right-click on a text field or its field editor opens the SQ menu. Idempotent.
    public static func installGlobalRouting() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            nonisolated(unsafe) let e = event
            nonisolated(unsafe) var out: NSEvent? = e
            MainActor.assumeIsolated {
                guard !SQMenuController.shared.isOpen, let tv = target(for: e), let w = e.window else { return }
                present(for: tv, at: w.convertPoint(toScreen: e.locationInWindow))
                out = nil
            }
            return out
        }
    }

    /// One-line adoption for a field: `SQTextFieldMenu.install(on: field)`. Starts the global routing (right-clicks on
    /// the field and its editor are swallowed before AppKit builds a menu).
    public static func install(on field: NSTextField) {
        installGlobalRouting()
    }
}
