import AppKit
import SQCore
import SQUIKit

/// The Mac side of the timeline context menu (`TimelineMenuSpec.swift` holds the portable spec): NSEvent modifier
/// flags for the menu keys and the AppKit sheets.
extension TimelineMenuItem {
    public var modifiers: NSEvent.ModifierFlags {
        get { Self.flags(keyModifiers) }
        set { keyModifiers = Self.keyModifiers(newValue) }
    }

    public init(_ action: TimelineMenuAction, _ title: String, enabled: Bool, separatorBefore: Bool = false,
                key: String = "", modifiers: NSEvent.ModifierFlags) {
        self.init(action, title, enabled: enabled, separatorBefore: separatorBefore, key: key, keyModifiers: Self.keyModifiers(modifiers))
    }

    /// NSMenuItem key equivalent of a binding; nil for keys a menu cannot show as an equivalent.
    public static func keyEquivalent(_ b: KeyBinding) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        portableKeyEquivalent(b).map { ($0.key, flags($0.modifiers)) }
    }

    static func flags(_ m: KeyModifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        return f
    }

    static func keyModifiers(_ f: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }
}

extension RulerRangeEntry {
    public var modifiers: NSEvent.ModifierFlags {
        get { TimelineMenuItem.flags(keyModifiers) }
        set { keyModifiers = TimelineMenuItem.keyModifiers(newValue) }
    }
}

extension NestSheet {
    /// Presents the sheet on `window`; `completion` gets the name on OK, nil on Cancel.
    @MainActor
    public static func present(on window: NSWindow, existingNames: [String], completion: @escaping @MainActor (String?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Combine"
        alert.informativeText = "Name of the new sequence:"
        let field = SQDialog.makeField(width: 260)
        field.stringValue = defaultName(existing: existingNames)
        alert.accessoryView = field
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(response == .first ? resolvedName(field.stringValue, existing: existingNames) : nil)
            }
        }
    }
}

extension PresetSaveSheet {
    /// Presents the sheet on `window`; `completion` gets name and anchor on Save, nil on Cancel.
    @MainActor
    public static func present(on window: NSWindow, defaultName: String,
                               completion: @escaping @MainActor ((name: String, anchor: EffectPreset.Anchor)?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Save as Preset"
        alert.informativeText = "Saves Transform, Opacity and effects with their keyframes and easing."
        let field = SQDialog.makeField(width: 260)
        field.stringValue = defaultName
        let popup = SQPopup(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: anchorTitles.map(\.1))
        alert.accessoryView = SQDialogForm(rows: [SQDialog.fieldRow(field), SQDialog.popupRow(popup)])
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { completion(nil); return }
                let anchor = anchorTitles[max(popup.indexOfSelectedItem, 0)].0
                completion((resolvedName(field.stringValue, fallback: defaultName), anchor))
            }
        }
    }
}

extension TitleBlockSaveSheet {
    /// Presents the sheet on `window`; `completion` gets the name on Save, nil on Cancel.
    @MainActor
    public static func present(on window: NSWindow, defaultName: String, completion: @escaping @MainActor (String?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Save to Library"
        alert.informativeText = "Saves the selected clips with their animations as a title block."
        let field = SQDialog.makeField(width: 260)
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(response == .first ? PresetSaveSheet.resolvedName(field.stringValue, fallback: defaultName) : nil)
            }
        }
    }
}
