import AppKit
import SSCore

/// What a context-menu item asks the host to do.
public enum TimelineMenuAction: Sendable, Hashable, CaseIterable {
    case cut, copy, paste, delete, rippleDelete, enable, unlink, link, nest, rename, revealInProject, speed
    case setToFrameSize, scaleToFrameSize
}

public struct TimelineMenuItem: Sendable, Equatable {
    public var action: TimelineMenuAction
    public var title: String
    public var isEnabled: Bool
    /// A separator line goes above this item.
    public var separatorBefore: Bool
    public var key: String
    public var modifiers: NSEvent.ModifierFlags

    public init(_ action: TimelineMenuAction, _ title: String, enabled: Bool, separatorBefore: Bool = false,
                key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
        self.action = action; self.title = title; self.isEnabled = enabled
        self.separatorBefore = separatorBefore; self.key = key; self.modifiers = modifiers
    }
}

/// Pure spec of the timeline context menu (Premiere order) plus the NSMenu builder.
public enum TimelineContextMenu {
    /// Items for the current selection. `clipboardHasClips` enables Paste.
    public static func items(timeline: Timeline, selection: Set<Clip.ID>, captionSelection: Set<CaptionItem.ID> = [],
                             clipboardHasClips: Bool) -> [TimelineMenuItem] {
        let clips = timeline.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        let hasClips = !clips.isEmpty
        let hasAny = hasClips || !captionSelection.isEmpty
        let links = Set(clips.compactMap(\.link))
        // Linking needs two or more clips that are not already one group.
        let canLink = clips.count >= 2 && !(links.count == 1 && clips.allSatisfy { $0.link == links.first })
        let linkItem = links.isEmpty
            ? TimelineMenuItem(.link, "Link", enabled: canLink, key: "l")
            : TimelineMenuItem(.unlink, "Unlink", enabled: true, key: "l")
        // Generators (text) have no picture size to fit.
        let hasPictures = clips.contains { !$0.isGenerator && $0.kind == .video }
        let canRetime = clips.contains { Timeline.canRetime($0) }
        return [
            TimelineMenuItem(.cut, "Cut", enabled: hasClips, key: "x"),
            TimelineMenuItem(.copy, "Copy", enabled: hasClips, key: "c"),
            TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, key: "v"),
            TimelineMenuItem(.delete, "Delete", enabled: hasAny, separatorBefore: true, key: "\u{8}", modifiers: []),
            TimelineMenuItem(.rippleDelete, "Ripple Delete", enabled: hasClips, key: "\u{8}", modifiers: [.shift]),
            // No enabled flag in the model yet.
            TimelineMenuItem(.enable, "Enable", enabled: false, separatorBefore: true),
            linkItem,
            TimelineMenuItem(.nest, "Nest…", enabled: hasClips, separatorBefore: true),
            TimelineMenuItem(.setToFrameSize, "Set to Frame Size", enabled: hasPictures, separatorBefore: true),
            TimelineMenuItem(.scaleToFrameSize, "Scale to Frame Size", enabled: hasPictures),
            TimelineMenuItem(.rename, "Rename…", enabled: clips.count == 1, separatorBefore: true),
            TimelineMenuItem(.revealInProject, "Reveal in Project", enabled: hasClips),
            TimelineMenuItem(.speed, "Speed/Duration…", enabled: canRetime, separatorBefore: true, key: "r"),
        ]
    }

    /// Builds an NSMenu; `handler` runs on the main actor with the chosen action.
    @MainActor
    public static func makeMenu(items: [TimelineMenuItem], handler: @escaping @MainActor (TimelineMenuAction) -> Void) -> NSMenu {
        let menu = TimelineNSMenu(handler: handler)
        menu.autoenablesItems = false
        for it in items {
            if it.separatorBefore { menu.addItem(.separator()) }
            let mi = NSMenuItem(title: it.title, action: #selector(TimelineMenuTarget.fire(_:)), keyEquivalent: it.key)
            mi.keyEquivalentModifierMask = it.modifiers
            mi.isEnabled = it.isEnabled
            mi.target = menu.target
            mi.representedObject = it.action
            menu.addItem(mi)
        }
        return menu
    }
}

@MainActor
final class TimelineMenuTarget: NSObject {
    let handler: @MainActor (TimelineMenuAction) -> Void
    init(handler: @escaping @MainActor (TimelineMenuAction) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSMenuItem) {
        if let a = sender.representedObject as? TimelineMenuAction { handler(a) }
    }
}

/// Keeps the (weakly referenced) item target alive as long as the menu.
@MainActor
final class TimelineNSMenu: NSMenu {
    let target: TimelineMenuTarget
    init(handler: @escaping @MainActor (TimelineMenuAction) -> Void) {
        target = TimelineMenuTarget(handler: handler)
        super.init(title: "")
    }
    required init(coder: NSCoder) { fatalError("not used") }
}

/// "Nest…" sheet: one name field, default "Nested Sequence NN", OK / Cancel.
public enum NestSheet {
    /// First free "Nested Sequence NN" among `existing` names.
    public static func defaultName(existing: [String]) -> String {
        let names = Set(existing)
        var n = 1
        while names.contains(String(format: "Nested Sequence %02d", n)) { n += 1 }
        return String(format: "Nested Sequence %02d", n)
    }

    /// Trimmed name, or the default for a blank field.
    public static func resolvedName(_ input: String, existing: [String]) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultName(existing: existing) : t
    }

    /// Presents the sheet on `window`; `completion` gets the name on OK, nil on Cancel.
    @MainActor
    public static func present(on window: NSWindow, existingNames: [String], completion: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Nest"
        alert.informativeText = "Name of the new sequence:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultName(existing: existingNames)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(response == .alertFirstButtonReturn ? resolvedName(field.stringValue, existing: existingNames) : nil)
            }
        }
    }
}
