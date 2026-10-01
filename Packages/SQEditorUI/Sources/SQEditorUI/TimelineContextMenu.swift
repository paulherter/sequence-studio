import AppKit
import SQCore

/// What a context-menu item asks the host to do.
public enum TimelineMenuAction: Sendable, Hashable, CaseIterable {
    case cut, copy, paste, pasteInsert, pasteAttributes, delete, rippleDelete, unlink, link, nest, rename
    /// Enable / Disable Clip (Shift+Cmd+E).
    case enable
    case setToFrameSize
    case editCaption, splitCaption, mergeCaptions
    /// Clip > Speed/Duration.
    case speed
    /// Clip > Audio Options > Audio Gain, and the short-form pause remover.
    case audioGain, removeSilences
    /// Show Clip Keyframes > Time Remapping (the speed band on the clip).
    case timeRemapping
    /// Opens the label colour submenu (its choices go to `makeMenu`'s `labelHandler`).
    case label
}

public struct TimelineMenuItem: Sendable, Equatable {
    public var action: TimelineMenuAction
    public var title: String
    public var isEnabled: Bool
    /// A separator line goes above this item.
    public var separatorBefore: Bool
    public var key: String
    public var modifiers: NSEvent.ModifierFlags

    public func separatorBefore(_ on: Bool) -> TimelineMenuItem { var c = self; c.separatorBefore = on; return c }

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
        let hasAudio = clips.contains { $0.kind == .audio }
        let canRetime = clips.contains { Timeline.canRetime($0) }
        let hasVideoMedia = clips.contains { Timeline.canRetime($0) && $0.kind == .video }
        // Premiere order. Entries for features we do not have (Reveal in Project) are left out.
        return [
            TimelineMenuItem(.cut, "Cut", enabled: hasClips, key: "x"),
            TimelineMenuItem(.copy, "Copy", enabled: hasClips, key: "c"),
            TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, key: "v"),
            TimelineMenuItem(.pasteInsert, "Paste Insert", enabled: clipboardHasClips, key: "v", modifiers: [.command, .shift]),
            TimelineMenuItem(.pasteAttributes, "Paste Attributes", enabled: clipboardHasClips && hasClips, key: "v", modifiers: [.command, .option]),
            TimelineMenuItem(.delete, "Clear", enabled: hasAny, separatorBefore: true, key: "\u{8}", modifiers: []),
            TimelineMenuItem(.rippleDelete, "Ripple Delete", enabled: hasClips, key: "\u{8}", modifiers: [.shift]),
            linkItem.separatorBefore(true),
            TimelineMenuItem(.enable, clips.contains { !$0.isEnabled } ? "Enable" : "Disable", enabled: hasClips,
                             key: "e", modifiers: [.command, .shift]),
            TimelineMenuItem(.nest, "Nest…", enabled: hasClips, separatorBefore: true),
            TimelineMenuItem(.speed, "Speed/Duration…", enabled: canRetime, key: "r"),
            TimelineMenuItem(.audioGain, "Audio Gain…", enabled: hasAudio, key: "g", modifiers: []),
            TimelineMenuItem(.removeSilences, "Remove Silences…", enabled: hasAudio),   // hidden by `FeatureFlags.removeSilences`
            TimelineMenuItem(.timeRemapping, "Show Time Remapping", enabled: hasVideoMedia),
            TimelineMenuItem(.setToFrameSize, "Set to Frame Size", enabled: hasPictures, separatorBefore: true),
            TimelineMenuItem(.label, "Label", enabled: hasClips, separatorBefore: true),
            TimelineMenuItem(.rename, "Rename…", enabled: clips.count == 1),
        ].filter { FeatureFlags.removeSilences || $0.action != .removeSilences }
    }

    /// Menu of caption segments (right-click on a caption): edit the text, split at the playhead, merge, delete.
    public static func captionItems(timeline: Timeline, captionSelection: Set<CaptionItem.ID>, playhead: Time) -> [TimelineMenuItem] {
        let underPlayhead = timeline.captions(at: playhead).contains { captionSelection.isEmpty || captionSelection.contains($0.item.id) }
        // Merging needs two or more captions of the same track.
        let tracksOfSelection = Set(timeline.captionTracks.filter { t in t.items.contains { captionSelection.contains($0.id) } }.map(\.id))
        return [
            TimelineMenuItem(.editCaption, "Edit Caption Text", enabled: captionSelection.count == 1),
            TimelineMenuItem(.splitCaption, "Split Caption at Playhead", enabled: underPlayhead, separatorBefore: true),
            TimelineMenuItem(.mergeCaptions, "Merge Captions", enabled: captionSelection.count >= 2 && tracksOfSelection.count == 1),
            TimelineMenuItem(.delete, "Delete", enabled: !captionSelection.isEmpty, separatorBefore: true, key: "\u{8}", modifiers: []),
        ]
    }

    /// Right-click on a gap between clips: Premiere offers Ripple Delete (closes the gap).
    public static func gapItems(clipboardHasClips: Bool) -> [TimelineMenuItem] {
        [TimelineMenuItem(.rippleDelete, "Ripple Delete", enabled: true, key: "\u{8}", modifiers: [.shift]),
         TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, separatorBefore: true, key: "v"),
         TimelineMenuItem(.pasteInsert, "Paste Insert", enabled: clipboardHasClips, key: "v", modifiers: [.command, .shift])]
    }

    /// Right-click on empty track space.
    public static func emptyItems(clipboardHasClips: Bool) -> [TimelineMenuItem] {
        [TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, key: "v"),
         TimelineMenuItem(.pasteInsert, "Paste Insert", enabled: clipboardHasClips, key: "v", modifiers: [.command, .shift])]
    }

    /// Builds an NSMenu; `handler` runs on the main actor with the chosen action.
    @MainActor
    public static func makeMenu(items: [TimelineMenuItem], labelHandler: (@MainActor (LabelColor?) -> Void)? = nil,
                                handler: @escaping @MainActor (TimelineMenuAction) -> Void) -> NSMenu {
        let menu = TimelineNSMenu(handler: handler)
        menu.autoenablesItems = false
        for it in items {
            if it.separatorBefore { menu.addItem(.separator()) }
            if it.action == .label {
                let host = NSMenuItem(title: it.title, action: nil, keyEquivalent: "")
                host.isEnabled = it.isEnabled && labelHandler != nil
                let sub = NSMenu(title: it.title)
                sub.autoenablesItems = false
                menu.labelTarget = TimelineLabelTarget(handler: labelHandler)
                for (i, c) in ([nil] + LabelColor.allCases.map(Optional.some)).enumerated() {
                    let mi = NSMenuItem(title: c?.displayName ?? "Default", action: #selector(TimelineLabelTarget.fire(_:)), keyEquivalent: "")
                    mi.target = menu.labelTarget
                    mi.tag = i
                    if let c { mi.image = Self.swatch(c) }
                    sub.addItem(mi)
                    if i == 0 { sub.addItem(.separator()) }
                }
                host.submenu = sub
                menu.addItem(host)
                continue
            }
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

@MainActor
final class TimelineLabelTarget: NSObject {
    let handler: (@MainActor (LabelColor?) -> Void)?
    init(handler: (@MainActor (LabelColor?) -> Void)?) { self.handler = handler }
    @objc func fire(_ sender: NSMenuItem) {
        let all: [LabelColor?] = [nil] + LabelColor.allCases.map(Optional.some)
        if all.indices.contains(sender.tag) { handler?(all[sender.tag]) }
    }
}

extension TimelineContextMenu {
    @MainActor static func swatch(_ c: LabelColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let rgb = c.rgb
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        return img
    }
}

/// Keeps the (weakly referenced) item target alive as long as the menu.
@MainActor
final class TimelineNSMenu: NSMenu {
    let target: TimelineMenuTarget
    var labelTarget: TimelineLabelTarget?
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
