import Foundation
import SQDrawKit
import SQCore
import SQEditorSession
import SQUIKit

/// SQ rows of the monitor menus (options "...", viewer right-click pieces, source and format popups). Built directly, no NSMenu.
public enum MonitorMenus {
    /// Zoom presets with the current one checked (Program and Source viewer menus, options menu).
    @MainActor
    public static func zoomItems(current: MonitorZoom, set: @escaping @MainActor (MonitorZoom) -> Void) -> [SQMenuItem] {
        MonitorZoom.presets.map { z in SQMenuItem(title: z.title, isChecked: z == current, action: { set(z) }) }
    }

    @MainActor
    public static func qualityItems(current: MonitorQuality, autoLevel: MonitorQuality? = nil,
                                    set: @escaping @MainActor (MonitorQuality) -> Void) -> [SQMenuItem] {
        MonitorQuality.menuCases.map { q in
            SQMenuItem(title: autoTitle(q, level: autoLevel), isChecked: q == current, action: { set(q) })
        }
    }

    /// Menu title of a quality row: Auto names the level it currently resolved to ("Auto (1/2)").
    public static func autoTitle(_ q: MonitorQuality, level: MonitorQuality?) -> String {
        guard q == .auto, let level else { return q.title }
        return "Auto (\(level.title))"
    }

    /// Key column of an action row: the mapped key of its command (never hard-coded), "" when unbound.
    @MainActor
    public static func shortcut(of a: MonitorAction) -> String {
        #if canImport(AppKit)
        a.command.map { CommandMenuKeys.shortcut($0) } ?? ""
        #else
        a.command.flatMap { CommandMap.current.binding(for: $0) }.map { KeyBindingText.text($0) } ?? ""
        #endif
    }

    /// The "..." menu: toggles, Zoom, Playback Quality, then the overflow actions that are available.
    @MainActor
    public static func optionItems(mode: MonitorMode, available: [MonitorAction], isLooping: Bool, safeMargins: Bool,
                                   zoom: MonitorZoom, quality: MonitorQuality, autoLevel: MonitorQuality? = nil,
                                   title: (MonitorAction) -> String,
                                   shortcut: (MonitorAction) -> String = { shortcut(of: $0) },
                                   perform: @escaping @MainActor (MonitorAction) -> Void,
                                   setZoom: @escaping @MainActor (MonitorZoom) -> Void,
                                   setQuality: @escaping @MainActor (MonitorQuality) -> Void) -> [SQMenuItem] {
        func row(_ t: String, _ a: MonitorAction, on: Bool?) -> SQMenuItem {
            SQMenuItem(title: t, shortcut: shortcut(a), isChecked: on ?? false, action: { perform(a) })
        }
        var rows = [row("Loop Playback", .loop, on: isLooping), row("Play In to Out", .playInToOut, on: nil)]
        if mode == .program { rows.append(row("Safe Margins", .toggleSafeMargins, on: safeMargins)) }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Zoom", submenu: zoomItems(current: zoom, set: setZoom)))
        rows.append(SQMenuItem(title: "Playback Quality", submenu: qualityItems(current: quality, autoLevel: autoLevel, set: setQuality)))
        rows.append(.separator)
        let have = Set(available)
        for a in MonitorAction.overflowMenu(for: mode) where have.contains(a) { rows.append(row(title(a), a, on: nil)) }
        let extras = MonitorAction.sourceMenuExtras(for: mode).filter(have.contains)
        if !extras.isEmpty {
            rows.append(.separator)
            for a in extras { rows.append(row(a.menuTitle ?? title(a), a, on: nil)) }
        }
        return rows
    }

    /// The "..." menu in its final shape (E10): the base rows, then one submenu per non-empty group (Overlays, Playback,
    /// Compare), then `tail` rows. A group of one row is shown as that row, not as a submenu of one.
    @MainActor
    public static func grouped(base: [SQMenuItem], overlays: [SQMenuItem], playback: [SQMenuItem], compare: [SQMenuItem],
                               tail: [SQMenuItem] = []) -> [SQMenuItem] {
        var rows = base
        var groups: [SQMenuItem] = []
        for (title, items) in [("Overlays", overlays), ("Playback", playback), ("Compare", compare)] where !items.isEmpty {
            if items.count == 1 { groups.append(items[0]) } else { groups.append(SQMenuItem(title: title, submenu: items)) }
        }
        if !groups.isEmpty {
            if rows.last.map({ $0.kind != .separator }) ?? false { rows.append(.separator) }
            rows += groups
        }
        if !tail.isEmpty {
            if rows.last.map({ $0.kind != .separator }) ?? false { rows.append(.separator) }
            rows += tail
        }
        return rows
    }

    /// Source clip popup: the clips opened before (checked = current), then Close / Close All.
    @MainActor
    public static func sourceItems(_ items: [MonitorPanelModel.SourceItem], current: UUID?,
                                   pick: @escaping @MainActor (UUID) -> Void,
                                   close: @escaping @MainActor () -> Void,
                                   closeAll: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        guard !items.isEmpty else { return [] }
        var rows = items.map { it in SQMenuItem(title: it.name, isChecked: it.id == current, action: { pick(it.id) }) }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Close", action: close))
        rows.append(SQMenuItem(title: "Close All", action: closeAll))
        return rows
    }

    /// Title of the source popup ("No clip" when empty).
    public static func sourceTitle(_ items: [MonitorPanelModel.SourceItem], current: UUID?) -> String {
        guard !items.isEmpty else { return "No clip" }
        return items.first { $0.id == current }?.name ?? items[0].name
    }

    /// Program title popup: the open sequences (checked = the shown one). Frame formats are not listed here (see `formatItems`).
    @MainActor
    public static func sequenceItems(_ items: [MonitorPanelModel.SequenceItem], current: UUID?,
                                     pick: @escaping @MainActor (UUID) -> Void) -> [SQMenuItem] {
        items.map { it in SQMenuItem(title: it.name, isChecked: it.id == current, action: { pick(it.id) }) }
    }

    /// Title of the Program popup: the shown sequence's name ("Sequence" without one).
    public static func sequenceTitle(_ items: [MonitorPanelModel.SequenceItem], current: UUID?, fallback: String) -> String {
        if let n = items.first(where: { $0.id == current })?.name, !n.isEmpty { return n }
        return fallback.isEmpty ? "Sequence" : fallback
    }

    /// Format popup: the sequence's own format (nil id), its variants, then Add Format (aspect presets) and Remove Format.
    @MainActor
    public static func formatItems(base: String, _ items: [MonitorPanelModel.FormatItem], current: UUID?,
                                   pick: @escaping @MainActor (UUID?) -> Void,
                                   add: @escaping @MainActor (SequenceConform.AspectPreset) -> Void,
                                   remove: @escaping @MainActor (UUID) -> Void) -> [SQMenuItem] {
        var rows = [SQMenuItem(title: base.isEmpty ? "Sequence" : base, isChecked: current == nil, action: { pick(nil) })]
        for it in items { rows.append(SQMenuItem(title: it.name, isChecked: it.id == current, action: { pick(it.id) })) }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Add Format", submenu: SequenceConform.aspectPresets.map { p in
            SQMenuItem(title: "\(p.name) · \(p.width) × \(p.height)", action: { add(p) })
        }))
        rows.append(SQMenuItem(title: "Remove Format", isEnabled: current != nil, action: { if let c = current { remove(c) } }))
        return rows
    }

    public static func formatTitle(base: String, _ items: [MonitorPanelModel.FormatItem], current: UUID?,
                                   sequenceName: String = "") -> String {
        // Board: the popup in the Program tab strip names the sequence ("Main") for its own format, else the variant.
        current.flatMap { c in items.first { $0.id == c }?.name } ?? (sequenceName.isEmpty ? "Sequence" : sequenceName)
    }
}

extension MonitorMenus {
    /// Platform UI zone popup of the Program monitor (checked = current).
    @MainActor
    public static func safeZoneItems(current: SafeZoneChoice, set: @escaping @MainActor (SafeZoneChoice) -> Void) -> [SQMenuItem] {
        SafeZoneChoice.allCases.map { c in SQMenuItem(title: c.title, isChecked: c == current, action: { set(c) }) }
    }
}

extension MonitorMenus {
    /// "Show platform UI" row under the zone choices: the mock of the app's buttons and caption (TikTok, Reels, Shorts only).
    @MainActor
    public static func platformMockItems(isOn: Bool, available: Bool, set: @escaping @MainActor (Bool) -> Void) -> [SQMenuItem] {
        [.separator, SQMenuItem(title: "Show platform UI", isEnabled: available, isChecked: isOn && available, action: { set(!isOn) })]
    }
}

extension SafeZoneChoice {
    public static let mockDefaultsKey = "sq.monitor.safeZoneMock"
    public static var storedMock: Bool { UserDefaults.standard.bool(forKey: mockDefaultsKey) }
    public static func rememberMock(_ on: Bool) { UserDefaults.standard.set(on, forKey: mockDefaultsKey) }
    public static let defaultsKey = "sq.monitor.safeZone"
    /// The choice remembered across launches and projects.
    public static var stored: SafeZoneChoice { SafeZoneChoice(stored: UserDefaults.standard.string(forKey: defaultsKey)) }
    public func remember() { UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey) }
}
