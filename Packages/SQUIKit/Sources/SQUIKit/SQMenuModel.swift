import Foundation
#if canImport(AppKit)
import AppKit
/// The platform image a menu row can carry (`SQMenuIcon.image`).
public typealias SQMenuPlatformImage = NSImage
/// Tint of a leading menu symbol.
public typealias SQMenuTint = NSColor
#else
/// Off the Mac a menu image is whatever the host's image cache hands out (opaque to the model).
public typealias SQMenuPlatformImage = AnyObject
/// Off the Mac a tint is a palette color (the shared toolkit converts it).
public typealias SQMenuTint = PaletteColor
#endif

// SQMenu: the app's own context menu (FB-S). This file is the pure part (model, navigation, layout, icon table, switch), portable
// (the Windows app draws it through SQDrawKit). `SQMenuController.swift` shows it in floating borderless panels on the Mac.
// Existing NSMenu builders keep working: `SQMenuItem.items(from:)` (SQMenuModel+AppKit.swift) converts them, so every ported
// menu can fall back to the native NSMenu with one switch (`SQMenuSettings`).

/// Reference box so a platform image can sit in an Equatable enum.
public final class SQMenuImageBox: @unchecked Sendable {
    public let image: SQMenuPlatformImage
    public init(_ image: SQMenuPlatformImage) { self.image = image }
}

public enum SQMenuIcon: Equatable, Sendable {
    case none
    /// Icon from the one icon set.
    case symbol(SQIcon)
    /// Eased progress samples 0...1 drawn as a small curve (interpolation menus).
    case curve([Double])
    /// Label color chip, 0xRRGGBB.
    case swatch(UInt32)
    /// Any prepared image (template images are tinted with the row color).
    case image(SQMenuImageBox)

    public static func == (a: SQMenuIcon, b: SQMenuIcon) -> Bool {
        switch (a, b) {
        case (.none, .none): true
        case (.symbol(let x), .symbol(let y)): x == y
        case (.curve(let x), .curve(let y)): x == y
        case (.swatch(let x), .swatch(let y)): x == y
        case (.image(let x), .image(let y)): x === y
        default: false
        }
    }
}

public struct SQMenuItem: Equatable {
    public enum Kind: Sendable, Equatable { case action, separator, header, caption }
    public var kind: Kind
    public var title: String
    public var icon: SQMenuIcon
    /// Pre-formatted shortcut text, e.g. "⇧⌘V" (right column).
    public var shortcut: String
    public var isEnabled: Bool
    public var isChecked: Bool
    public var submenu: [SQMenuItem]?
    public var action: (@MainActor () -> Void)?
    /// Optional leading icon drawn left of the title (opt-in; `icon` stays the swatch/curve slot). Tint nil = row color.
    public var leadingSymbol: SQIcon?
    public var leadingTint: SQMenuTint?
    /// Help text drawn as a caption line under the title (the SQ replacement for `NSMenuItem.toolTip`).
    public var help: String?

    public init(title: String, icon: SQMenuIcon = .none, shortcut: String = "", isEnabled: Bool = true, isChecked: Bool = false,
                help: String? = nil, submenu: [SQMenuItem]? = nil, action: (@MainActor () -> Void)? = nil) {
        self.help = help.map { SQL10n.string($0) }
        self.kind = .action; self.title = SQL10n.string(title); self.icon = icon; self.shortcut = shortcut
        self.isEnabled = isEnabled; self.isChecked = isChecked; self.submenu = submenu; self.action = action
    }

    public static var separator: SQMenuItem {
        var i = SQMenuItem(title: ""); i.kind = .separator; i.isEnabled = false; return i
    }

    public static func header(_ title: String) -> SQMenuItem {
        var i = SQMenuItem(title: title); i.kind = .header; i.isEnabled = false; return i
    }

    /// A wrapping, non-selectable explanation row in the secondary text color (never truncated; the menu widens to `captionWidth`).
    public static func caption(_ text: String) -> SQMenuItem {
        var i = SQMenuItem(title: text); i.kind = .caption; i.isEnabled = false; return i
    }

    /// Row with a leading icon (optionally tinted, e.g. the support color).
    public func withLeading(symbol: SQIcon, tint: SQMenuTint? = nil) -> SQMenuItem {
        var i = self; i.leadingSymbol = symbol; i.leadingTint = tint; return i
    }

    /// Can the highlight rest on this row?
    public var isSelectable: Bool { kind == .action && isEnabled }

    public static func == (a: SQMenuItem, b: SQMenuItem) -> Bool {
        a.kind == b.kind && a.leadingSymbol == b.leadingSymbol && a.title == b.title && a.icon == b.icon && a.shortcut == b.shortcut
            && a.isEnabled == b.isEnabled && a.isChecked == b.isChecked && a.help == b.help && a.submenu == b.submenu
    }
}

// MARK: Navigation (pure)

public struct SQMenuNavigator {
    public enum Move { case up, down, first, last }
    public enum Result: Equatable {
        case none
        case openedSubmenu
        /// Index path from the root to the chosen leaf item.
        case run(path: [Int])
    }

    /// `source` is the full list; `items` the rows shown (filtered once the user types). `highlighted` indexes `items`,
    /// `parentIndex` and result paths index `source`.
    struct Level {
        var source: [SQMenuItem]
        var filter = ""
        var highlighted: Int?
        var parentIndex: Int
        var map: [Int] { SQMenuFilter.indices(source, matching: filter) }
        var items: [SQMenuItem] { filter.isEmpty ? source : map.map { source[$0] } }
    }
    private(set) var levels: [Level]

    public init(items: [SQMenuItem]) { levels = [Level(source: items, highlighted: nil, parentIndex: -1)] }

    /// Filter text of the innermost level; empty means no filter row is shown.
    public var filter: String { levels[levels.count - 1].filter }
    public func filter(level: Int) -> String { levels.indices.contains(level) ? levels[level].filter : "" }

    public var depth: Int { levels.count }
    /// Highlighted row of the innermost open level.
    public var highlighted: Int? { levels[levels.count - 1].highlighted }
    public func highlighted(level: Int) -> Int? { levels.indices.contains(level) ? levels[level].highlighted : nil }
    public func items(level: Int) -> [SQMenuItem] { levels.indices.contains(level) ? levels[level].items : [] }

    public func item(at path: [Int]) -> SQMenuItem? {
        var items = levels[0].source
        var found: SQMenuItem?
        for i in path {
            guard items.indices.contains(i) else { return nil }
            found = items[i]
            items = found?.submenu ?? []
        }
        return found
    }

    private var top: Int { levels.count - 1 }

    public mutating func move(_ m: Move) {
        let items = levels[top].items
        let sel = items.indices.filter { items[$0].isSelectable }
        guard !sel.isEmpty else { return }
        let cur = levels[top].highlighted
        switch m {
        case .first: levels[top].highlighted = sel.first
        case .last: levels[top].highlighted = sel.last
        case .down:
            levels[top].highlighted = cur.flatMap { c in sel.first { $0 > c } } ?? sel.first
        case .up:
            levels[top].highlighted = cur.flatMap { c in sel.last { $0 < c } } ?? sel.last
        }
    }

    /// Mouse over row `index` of `level` (default: innermost). Hovering a shallower level closes the deeper ones.
    public mutating func hover(_ index: Int?, level: Int? = nil) {
        let l = level ?? top
        guard levels.indices.contains(l) else { return }
        if l < top { levels.removeSubrange((l + 1)...) }
        if let index, levels[l].items.indices.contains(index), levels[l].items[index].isSelectable {
            levels[l].highlighted = index
        } else {
            levels[l].highlighted = nil
        }
    }

    /// Return / click on the highlighted row.
    public mutating func activate() -> Result {
        guard let h = highlighted, levels[top].items[h].isSelectable else { return .none }
        let it = levels[top].items[h]
        if it.submenu != nil { return openSubmenu(h) ? .openedSubmenu : .none }
        let path = levels.dropFirst().map(\.parentIndex) + [levels[top].map[h]]
        return .run(path: Array(path))
    }

    public mutating func rightKey() -> Result {
        guard let h = highlighted, levels[top].items[h].isSelectable, levels[top].items[h].submenu != nil else { return .none }
        return openSubmenu(h) ? .openedSubmenu : .none
    }

    /// Closes the innermost submenu; false at the root.
    public mutating func leftKey() -> Bool {
        guard levels.count > 1 else { return false }
        levels.removeLast()
        return true
    }

    private mutating func openSubmenu(_ index: Int) -> Bool {
        guard let sub = levels[top].items[index].submenu, !sub.isEmpty else { return false }
        levels.append(Level(source: sub, highlighted: nil, parentIndex: levels[top].map[index]))
        move(.first)
        return true
    }

    /// Type-to-filter: the first character creates the filter (row appears), later ones extend it.
    public mutating func typeFilter(_ c: Character) {
        levels[top].filter.append(c)
        refilter()
    }

    /// Removes the last filter character; false when there was no filter.
    @discardableResult
    public mutating func deleteFilterCharacter() -> Bool {
        guard !levels[top].filter.isEmpty else { return false }
        levels[top].filter.removeLast()
        refilter()
        return true
    }

    /// Clears the filter; false when there was none (Esc then closes the menu).
    @discardableResult
    public mutating func clearFilter() -> Bool {
        guard !levels[top].filter.isEmpty else { return false }
        levels[top].filter = ""
        refilter()
        return true
    }

    private mutating func refilter() {
        levels[top].highlighted = nil
        move(.first)
    }

    /// Jumps to the next enabled row whose title starts with `c` (cycling from the current row).
    public mutating func typeAhead(_ c: Character) {
        let items = levels[top].items
        let needle = String(c).lowercased()
        let start = (levels[top].highlighted ?? -1) + 1
        for off in 0..<items.count {
            let i = (start + off) % items.count
            if items[i].isSelectable, items[i].title.lowercased().hasPrefix(needle) {
                levels[top].highlighted = i
                return
            }
        }
    }
}

/// Case-insensitive substring filter over action titles; headers and separators drop out while filtering.
public enum SQMenuFilter {
    public static func indices(_ items: [SQMenuItem], matching filter: String) -> [Int] {
        let f = filter.lowercased()
        guard !f.isEmpty else { return Array(items.indices) }
        return items.indices.filter { items[$0].kind == .action && items[$0].title.lowercased().contains(f) }
    }
}

// MARK: Shortcut text, layout, icons, switch

public enum SQMenuShortcut {
    /// `NSMenuItem.identifier` prefix carrying the exact shortcut text (layout independent), preferred over the key equivalent.
    public static let hintPrefix = "sq.hint:"
    #if canImport(AppKit)
    /// "⌃⌥⇧⌘" + key, in Apple's order. Empty key gives an empty string.
    public static func glyphs(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var m: KeyModifiers = []
        if modifiers.contains(.control) { m.insert(.control) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.command) { m.insert(.command) }
        return glyphs(key: key, keyModifiers: m)
    }
    #endif

    /// "⌃⌥⇧⌘" + key, in Apple's order: the glyph text of `glyphs(key:modifiers:)` from a portable modifier set.
    public static func glyphs(key: String, keyModifiers m: KeyModifiers) -> String {
        guard !key.isEmpty else { return "" }
        #if os(Windows)
        return windowsText(key: key, keyModifiers: m)
        #else
        return macText(key: key, keyModifiers: m)
        #endif
    }

    /// "Ctrl+Alt+Shift+Key" (Command and Control both read as Ctrl, Option as Alt): what Windows shows in a menu row.
    public static func windowsText(key: String, keyModifiers m: KeyModifiers) -> String {
        guard !key.isEmpty else { return "" }
        var parts: [String] = []
        if m.contains(.command) || m.contains(.control) { parts.append("Ctrl") }
        if m.contains(.option) { parts.append("Alt") }
        if m.contains(.shift) { parts.append("Shift") }
        switch key {
        case "\u{8}", "\u{7F}": parts.append("Backspace")
        case "\r", "\u{3}": parts.append("Enter")
        case "\u{1B}": parts.append("Esc")
        case " ": parts.append("Space")
        default: parts.append(key == "ß" ? key : key.uppercased())
        }
        return parts.joined(separator: "+")
    }

    static func macText(key: String, keyModifiers m: KeyModifiers) -> String {
        var s = ""
        if m.contains(.control) { s += "\u{2303}" }
        if m.contains(.option) { s += "\u{2325}" }
        if m.contains(.shift) { s += "\u{21E7}" }
        if m.contains(.command) { s += "\u{2318}" }
        return s + keyText(key)
    }

    static func keyText(_ key: String) -> String {
        switch key {
        case "\u{8}", "\u{7F}": "\u{232B}"
        case "\r", "\u{3}": "\u{21A9}"
        case "\u{1B}": "\u{238B}"
        case " ": "Space"
        // "ß" must stay "ß": uppercasing it would print two letters.
        default: key == "ß" ? key : key.uppercased()
        }
    }
}

public enum SQMenuLayout {
    // Design B (`.menu`, `.mi`, `.msep`, `.mcap`): layer fill `overlay`, radius 10, padding 4, rows 24 with radius 6, padding
    // 8 left / 12 right, 8 gaps, check column 14, separator 1 px with 4/8 margin (9 high), caption 11 semibold. Width 220...320.
    #if canImport(AppKit)
    public static let rowHeight: CGFloat = Theme.Menu.rowHeight
    #else
    // The `Theme.Menu` values (OverlayTokens.swift is AppKit); the Mac build reads them from Theme.
    public static let rowHeight: CGFloat = 24
    #endif
    public static let separatorHeight: CGFloat = 9
    /// Extra row height for a help caption line.
    public static let helpHeight: CGFloat = 12
    /// A help line wraps at this text width (one more `helpHeight` per extra line), so one long sentence never widens a menu.
    public static let helpWidth: CGFloat = 220
    /// A menu dropped from a control (a value list) shows at most this many rows, then scrolls.
    public static let maxListRows = 10
    /// Tallest a list menu dropped from a control (no submenus) may be.
    public static let listCapHeight: CGFloat = inset * 2 + CGFloat(maxListRows) * rowHeight
    #if canImport(AppKit)
    static var helpFont: NSFont { Theme.Typography.caption }

    /// Lines of the item's help text wrapped at `helpWidth` (0 without help).
    public static func helpLines(_ i: SQMenuItem) -> Int {
        guard let h = i.help, !h.isEmpty else { return 0 }
        let r = (h as NSString).boundingRect(with: CGSize(width: helpWidth, height: 10_000), options: [.usesLineFragmentOrigin],
                                             attributes: [.font: helpFont])
        return max(1, Int((r.height / ceil(helpFont.boundingRectForFont.height)).rounded()))
    }
    public static let headerHeight: CGFloat = Theme.Menu.captionHeight
    public static let inset: CGFloat = Theme.Menu.inset
    /// Left padding of a row (8); `trailPad` is the right one (12).
    public static let rowPad: CGFloat = Theme.Menu.rowPadLeft
    public static let trailPad: CGFloat = Theme.Menu.rowPadRight
    #else
    /// Off the Mac the toolkit measures text: lines of `text` wrapped at `width` in the `size` pt UI font (help: caption 10,
    /// caption rows: body 11), and the height of one such line. Set by the host once its font is loaded.
    nonisolated(unsafe) public static var measureLines: (_ text: String, _ width: CGFloat, _ size: CGFloat) -> Int = { t, w, s in
        max(1, Int((CGFloat(t.count) * s * 0.55 / w).rounded(.up)))
    }
    nonisolated(unsafe) public static var lineHeight: (_ size: CGFloat) -> CGFloat = { ($0 * 1.21).rounded(.up) }

    public static func helpLines(_ i: SQMenuItem) -> Int {
        guard let h = i.help, !h.isEmpty else { return 0 }
        return measureLines(h, helpWidth, 10)
    }
    public static let headerHeight: CGFloat = 22
    public static let inset: CGFloat = 4
    public static let rowPad: CGFloat = 8
    public static let trailPad: CGFloat = 12
    #endif
    public static let gap: CGFloat = 8
    public static let checkColumn: CGFloat = 14
    public static let dotColumn: CGFloat = 16
    #if canImport(AppKit)
    public static let cornerRadius: CGFloat = Theme.Menu.radius
    public static let rowRadius: CGFloat = Theme.Menu.itemRadius
    public static let minWidth: CGFloat = Theme.Menu.minWidth
    #else
    public static let cornerRadius: CGFloat = 10
    public static let rowRadius: CGFloat = 6
    public static let minWidth: CGFloat = 160
    #endif
    public static let iconColumn: CGFloat = 22
    /// Wrap width of a caption row's text, and the room a leading symbol takes.
    public static let captionWidth: CGFloat = 240
    public static let captionPad: CGFloat = 6
    public static let symbolColumn: CGFloat = 22
    #if canImport(AppKit)
    static var captionFont: NSFont { Theme.Typography.body }

    /// Height of a caption wrapped at `captionWidth`.
    public static func captionHeight(_ text: String) -> CGFloat {
        let r = (text as NSString).boundingRect(with: CGSize(width: captionWidth, height: 10_000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: captionFont])
        return ceil(r.height) + 2 * captionPad
    }
    #else
    public static func captionHeight(_ text: String) -> CGFloat {
        CGFloat(measureLines(text, captionWidth, 11)) * lineHeight(11) + 2 * captionPad
    }
    #endif

    public static func heights(_ items: [SQMenuItem]) -> [CGFloat] {
        items.map { i in
            switch i.kind {
            case .separator: separatorHeight
            case .header: headerHeight
            case .caption: captionHeight(i.title)
            case .action: rowHeight + CGFloat(helpLines(i)) * helpHeight
            }
        }
    }

    /// Content height of a menu: inset + the rows + inset (what the list view lays out; the panel clamps it to the screen).
    public static func contentHeight(_ items: [SQMenuItem]) -> CGFloat {
        inset * 2 + heights(items).reduce(0, +)
    }

    /// Gap kept between a menu and the screen edge.
    public static let screenMargin: CGFloat = 8
    /// Below this a side is not worth squeezing a long menu into; the menu uses the whole screen height instead.
    public static let minSideHeight: CGFloat = 160

    /// Tallest a menu may be on `screen` (its visible frame).
    public static func maxHeight(screen: CGRect) -> CGFloat { max(screen.height - 2 * screenMargin, rowHeight) }

    /// Screen frame (y up) of a menu with `content` size. `anchor` is the top-left corner when it opens downward;
    /// `anchorTop` (the control's top edge, y) allows flipping above the control. The height is clamped to the screen's
    /// visible frame minus a margin, and the frame always lies fully inside it. The menu opens below if the whole content fits
    /// there, else above if it fits, else on the roomier side shortened to that room (it scrolls), else it fills the screen height.
    public static func placement(content: CGSize, anchor: CGPoint, anchorTop: CGFloat?, screen: CGRect) -> CGRect {
        let area = screen.insetBy(dx: screenMargin, dy: screenMargin)
        let full = min(content.height, area.height)
        let w = min(content.width, area.width)
        let x = max(area.minX, min(anchor.x, area.maxX - w))
        let below = max(anchor.y - area.minY, 0)
        var h = full, y = anchor.y - full
        if full > below {
            if let top = anchorTop {
                let above = max(area.maxY - top, 0)
                if full <= above { y = top }
                else if max(below, above) >= minSideHeight {
                    h = min(full, max(below, above))
                    y = below >= above ? anchor.y - h : top
                }
            }
        }
        y = max(area.minY, min(y, area.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Screen y (up) of the top of a submenu opened from a row of a possibly scrolled parent.
    public static func submenuTop(parentMaxY: CGFloat, rowMinY: CGFloat, parentScroll: CGFloat) -> CGFloat {
        parentMaxY - (rowMinY - parentScroll) + inset
    }

    /// Bottom-left origin (screen coordinates, y up) for a menu whose top-left corner is at `anchor`; kept inside `screen`.
    public static func origin(size: CGSize, anchor: CGPoint, screen: CGRect) -> CGPoint {
        var x = anchor.x, y = anchor.y - size.height
        x = max(screen.minX, min(x, screen.maxX - size.width))
        y = max(screen.minY, min(y, screen.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}

/// The mouse-release rule of a menu (the usual menu rule). The click that opens a menu never selects. A row is chosen by a
/// new press inside the list followed by its release, or by releasing the opening press on a row after the pointer clearly
/// moved and a short delay passed.
public enum SQMenuReleaseRule {
    public enum Outcome: Sendable, Equatable { case activate, dismiss, ignore }
    public static let minDistance: CGFloat = 4
    public static let minDelay: TimeInterval = 0.2

    /// `pressedInList`: a press landed inside the open list before this release. `moved`: distance in points from where the menu
    /// opened to the release. `held`: seconds since the menu opened.
    /// `overAnchor`: the release is over the control the menu opened from; that never closes the menu.
    public static func outcome(pressedInList: Bool, overRow: Bool, overAnchor: Bool = false, moved: CGFloat, held: TimeInterval) -> Outcome {
        if pressedInList { return overRow ? .activate : .ignore }
        guard moved >= minDistance, held >= minDelay else { return .ignore }
        if overRow { return .activate }
        return overAnchor ? .ignore : .dismiss
    }
}

/// Symbol per menu title, so ported menus get icons without per-item code. Unknown titles get none.
public enum SQMenuIconTable {
    static let exact: [String: SQIcon] = [
        "Cut": .toolBlade, "Copy": .copy, "Paste": .paste, "Paste Insert": .pasteInsert,
        "Paste Settings": .paintbrush, "Paste Attributes": .paintbrush, "Clear": .trash, "Delete": .trash, "Ripple Delete": .arrowRightToLine,
        "Link": .link, "Unlink": .unlink, "Enable": .eye, "Disable": .eyeOff, "Group": .group,
        "Ungroup": .ungroup, "Bundle": .bundle, "Unbundle": .unbundle,
        "Edit Original": .openExternal, "Make Subclip": .bladeBadge,"Combine\u{2026}": .stack, "Speed\u{2026}": .gauge, "Speed/Duration\u{2026}": .gauge,
        "Audio Gain\u{2026}": .volume, "Remove Silences\u{2026}": .waveformLines,
        "Show Speed Ramp": .timer, "Fit to Frame": .maximize, "Set to Frame Size": .maximize, "Fill Frame": .maximize, "Label": .tag,
        "Rename\u{2026}": .pencil, "Save as Preset\u{2026}": .download, "Edit in Text": .captions,
        "Split Caption at Playhead": .toolBlade, "Merge Captions": .merge,
        "Enable Effect": .eye, "Disable Effect": .eyeOff, "Duplicate Effect": .duplicate,
        "Convert to Keyframes": .diamond, "Reset Value at Playhead": .reset,
        "Reset All (Remove Keyframes)": .reset, "Reset": .reset,
        "Use as Default": .star, "Use as Default Without Keyframes": .star, "Reset Default to Factory": .starOff,
        "Save Curve\u{2026}": .download, "Custom\u{2026}": .curve,
        "Saved Curves": .bookmark, "Speed Graph": .gauge, "Value Graph": .chartLine,
        "Default": .tag,
        // Project panel, library, captions, templates, markers, source monitor, tabs, text styles
        "New Folder": .folderAdd, "New Bin": .folderAdd, "New Sequence\u{2026}": .sequence, "Import\u{2026}": .download,
        "Find\u{2026}": .search, "Hover Scrub": .pointerHand, "Open in Source": .openInSource,
        "Insert": .insertEdit, "Overwrite": .overwriteEdit,
        "New Sequence From Clip": .sequence, "Open in Timeline": .timelineSelection, "Rename": .pencil,
        "Clear Poster Frame": .imageRemove, "Reveal in Finder": .folder, "Reveal in Project": .folder,
        "Toggle Favorite": .star, "Whoosh at Selected Cuts": .wind, "Punch In Cuts\u{2026}": .zoomIn, "Apply to Selected Clips": .checkCircle,
        "Apply Absolute (Replace Values)": .equal, "Apply Relative (Add to Clip)": .plusCircle,
        "Export\u{2026}": .upload, "Import Presets\u{2026}": .download,
        "Edit Text": .pencil, "Style": .text, "Use Track Style": .text,
        "New Folder...": .folderAdd, "Rename Folder...": .pencil, "Delete Folder": .trash,
        "Remove from Folder": .folderRemove, "Add to Folder": .folderAdd, "Add Format": .addRectangle,
        "Add Marker": .marker, "Clear Marker": .markerOff, "Clear All Markers": .markerOff,
        "Mark In": .markIn, "Mark Out": .markOut, "Mark Clip": .markClip,
        "Go to In": .arrowRightToLine, "Go to Out": .arrowLeftToLine, "Clear In": .closeCircle,
        "Clear Out": .closeCircle, "Clear In and Out": .closeCircle, "Export Frame\u{2026}": .camera,
        "Loop Playback": .loop, "Zoom": .search, "Safe Margins": .viewfinder,
        "Close Panel": .close, "Maximize Panel": .maximize,
        "Restore Panel Size": .minimize, "Duplicate": .duplicate,
        "Update Style": .refresh, "Delete Keyframe": .trash, "Speed Transition Curve\u{2026}": .gauge,
        "Delete Masks": .trash,
    ]

    public static func symbol(forTitle t: String) -> SQIcon? {
        if let s = exact[t] { return s }
        if t.hasPrefix("Reset ") { return .reset }
        if t.hasPrefix("Use as Default") { return .star }
        if t.hasPrefix("Clear ") { return .closeCircle }
        if t.hasPrefix("Delete ") { return .trash }
        if t.hasPrefix("Go to ") { return .arrowRightToLine }
        return nil
    }
}

/// The one switch: custom menus on (default) or the native NSMenu. `defaults write <app> sq.customMenus -bool NO`, or env SQ_NATIVE_MENUS=1.
public enum SQMenuSettings {
    public static let key = "sq.customMenus"
    public static func useCustomMenus(defaults: UserDefaults = .standard) -> Bool {
        if ProcessInfo.processInfo.environment["SQ_NATIVE_MENUS"] == "1" { return false }
        return defaults.object(forKey: key) as? Bool ?? true
    }
}
