import Foundation
#if canImport(AppKit)
import AppKit
#endif
import SQCore
import SQUIKit
import SQEditorSession

/// What a shell menu row does. The Mac shell sends these as AppKit selectors on `AppController`; here they are values the
/// host performs (`ShellMenuBar.build(perform:)`), so the same menu works on any platform.
public enum ShellAction: Hashable, Sendable {
    case command(EditorCommand)
    // App menu and Help
    case about, quit
    /// Mac app menu: the system's Hide, Hide Others and Show All.
    case hide, hideOthers, showAll
    case support(SupportEntry)
    case sendFeedback, revealLogs, welcomeTour, checkForUpdates
    // File
    case openRecent(path: String), clearRecents
    case restoreAutosave(path: String), saveCheckpoint, relinkMedia, importChecklist
    case importStyleKit, exportStyleKit, useKitCaptionStyle
    /// File > Collect Files into Project Folder and File > Media Management (`MediaMenuTarget`).
    case collectFiles, outsideMedia(OutsideMediaMode), toggleCopyLibraryItems, toggleWatchFolder
    // Sequence > Format, Layer
    case changeFormat, duplicateAsFormat, newSequenceFromTemplate, saveSequenceAsTemplate
    case projectInputColor(ColorSpaceID?)
    case newShape(ShapeKind), newGraphicsClip, newAdjustmentLayer, newColorMatte
    // Clip > Replace and Fit > Pixel Aspect
    case pixelAspect(PixelAspect?), customPixelAspect
    // Window
    case selectWorkspace(String), saveWorkspaceAs, renameWorkspace, deleteWorkspace, resetLayout, resetAllWorkspaces
    case togglePanel(PanelID), toggleToolStrip
    case minimize, zoom, history, startWindow, bringAllToFront
}

/// The state the menus show (what `validateMenuItem` and the `NSMenuDelegate` fills read on the Mac).
public struct ShellMenuState: Sendable, Equatable {
    public var recents: [RecentProjects.Entry] = []
    /// `session.autosaveVersions`, newest first.
    public var autosaveVersions: [AutosaveVersionRow] = []
    public var workspaces: [String] = []
    public var currentWorkspace: String?
    public var visiblePanels: Set<PanelID> = []
    /// Panels whose Window row is disabled (shown, not stored: Steps while the Color grade is Simple).
    public var unavailablePanels: Set<PanelID> = []
    public var toolStripVisible = true
    /// The open window's name (the project's display name, as the Mac `window.title`): the Mac Window menu ends with the
    /// system window list, one checked row for the key window. nil: no row (start screen).
    public var windowName: String?
    public var projectInputColor: ColorSpaceID?
    /// The Mac `validateMenuItem` rules of the shell rows: Format needs a sequence, Reconnect Media missing files,
    /// Rename / Delete Workspace a user workspace, Reset to Saved Layout a changed one; Import Checklist a Premiere import.
    public var hasSequence = true
    public var canRelink = true
    public var canRenameWorkspace = true
    public var canResetWorkspace = true
    public var hasImportChecklist = false
    /// File > Media Management checks: the effective outside-files mode, library copies and folder watching; the last two
    /// need a project in its own folder (`MediaMenuTarget.validateMenuItem`).
    public var outsideMedia: OutsideMediaMode = .ask
    public var copyLibraryItems = true
    public var watchFolder = false
    public var inProjectFolder = false
    /// Toggle commands shown with a check mark (View > Audio Scrubbing, Safe Margins...).
    public var checkedCommands: Set<EditorCommand> = []
    /// Pixel aspect rows of the selected Project items; nil = no media selection (the submenu rows are disabled).
    public var pixelAspect: PixelAspectRows?
    public var undoName: String?
    public var redoName: String?
    /// Titles that replace a command's own while it runs: "Cancel Anonymize" (the Mac `validateMenuItem`).
    public var titles: [EditorCommand: String] = [:]
    /// The project chooser is up: only commands that start or open a project (and app-level items) work.
    public var chooserShown = false
    /// A dialog waits for an answer: nothing reaches the project behind it.
    public var modalShown = false
    public var now = Date()
    public init() {}
}

/// One autosave version as the menu needs it (`EditorSession.autosaveVersions` element).
public struct AutosaveVersionRow: Sendable, Equatable {
    public var path: String
    public var date: Date
    public var name: String?
    public init(path: String, date: Date, name: String?) { self.path = path; self.date = date; self.name = name }
}

/// Clip > Replace and Fit > Pixel Aspect rows (the pure part of the Mac `PixelAspectMenuTarget`).
public struct PixelAspectRows: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var title: String
        public var aspect: PixelAspect?
        public var checked: Bool
        public init(title: String, aspect: PixelAspect?, checked: Bool) { self.title = title; self.aspect = aspect; self.checked = checked }
    }
    public var rows: [Row]
    public var customTitle: String
    public var customChecked: Bool
    public init(rows: [Row], customTitle: String, customChecked: Bool) {
        self.rows = rows; self.customTitle = customTitle; self.customChecked = customChecked
    }
}

/// One top-level menu of the bar.
public struct ShellMenu: Equatable {
    public var title: String
    public var items: [SQMenuItem]
    public init(title: String, items: [SQMenuItem]) { self.title = title; self.items = items }
}

/// The main menu: `MenuBuilder.build` of the Mac app translated from NSMenu to `SQMenuItem` trees. Same structure, same
/// order, same key texts (Windows names on Windows): app menu, `EditorMenus.visible` with the File, Sequence, Clip and Window
/// extensions, Help. Mac-only system rows (Hide, Hide Others, Show All, Bring All to Front) are left out off the Mac.
@MainActor
public enum ShellMenuBar {
    /// `validate`: the enabled rule of a command row (`ShellCommands.enabled`, the Mac `commandEnabled`); nil: all enabled.
    public static func build(state: ShellMenuState, map: CommandMap, platform: KeyPlatform = .current,
                             validate: (@MainActor (EditorCommand) -> Bool)? = nil,
                             perform: @escaping @MainActor (ShellAction) -> Void) -> [ShellMenu] {
        let b = Builder(state: state, map: map, platform: platform, validate: validate, perform: perform)
        var out = [ShellMenu(title: SQL10n.string("Sequence Studio"), items: b.appMenu())]
        for spec in EditorMenus.visible {
            var items = b.items(spec.items)
            if spec.title == "File" { b.extendFile(&items) }
            if spec.title == "Sequence" { b.extendSequence(&items) }
            if spec.title == "Clip" { b.extendClip(&items) }
            if spec.title == "Window" { b.windowMenu(&items) }
            out.append(ShellMenu(title: SQL10n.string(spec.title), items: tidy(items)))
        }
        out.append(ShellMenu(title: SQL10n.string("Help"), items: b.helpMenu()))
        return out
    }

    /// Wired and worth a menu item (`MenuBuilder.isVisible`).
    public static func isVisible(_ c: EditorCommand) -> Bool {
        EditorMenus.alwaysShown.contains(c) || CommandRouting.isSupported(c)
    }

    /// Drops leading, trailing and doubled separators left behind by hidden items.
    public static func tidy(_ items: [SQMenuItem]) -> [SQMenuItem] {
        var out: [SQMenuItem] = []
        for i in items {
            if i.kind == .separator, out.last == nil || out.last?.kind == .separator { continue }
            out.append(i)
        }
        while out.last?.kind == .separator { out.removeLast() }
        return out
    }

    @MainActor struct Builder {
        let state: ShellMenuState
        let map: CommandMap
        let platform: KeyPlatform
        let validate: (@MainActor (EditorCommand) -> Bool)?
        let perform: @MainActor (ShellAction) -> Void

        func keyText(_ b: KeyBinding) -> String { KeyBindingText.text(b, platform: platform) }

        func row(_ title: String, _ a: ShellAction, shortcut: String = "", enabled: Bool = true, checked: Bool = false,
                 help: String? = nil) -> SQMenuItem {
            let perform = self.perform
            return SQMenuItem(title: title, shortcut: shortcut, isEnabled: enabled && allowed(a), isChecked: checked, help: help,
                              action: { perform(a) })
        }
        func sub(_ title: String, _ items: [SQMenuItem]) -> SQMenuItem { SQMenuItem(title: title, submenu: items) }

        /// `validateMenuItem`'s gate: a dialog blocks everything, the project chooser lets only project starts and app items through.
        func allowed(_ a: ShellAction) -> Bool {
            if state.modalShown { return false }
            guard state.chooserShown else { return true }
            switch a {
            case .command(let c): return c == .newProject || c == .openProject
            case .openRecent, .clearRecents, .about, .quit, .support, .sendFeedback, .revealLogs, .hide, .hideOthers, .showAll, .minimize, .zoom,
                 .startWindow, .command(.preferences), .command(.keyboardShortcuts): return true
            default: return false
            }
        }

        /// `MenuBuilder.menuItem(for:)`: title, help line and the binding text.
        func command(_ c: EditorCommand) -> SQMenuItem {
            var title = c.title
            if c == .undo { title = state.undoName.map { SQL10n.format("Undo %@", SQL10n.undoName($0)) } ?? "Undo" }
            if c == .redo { title = state.redoName.map { SQL10n.format("Redo %@", SQL10n.undoName($0)) } ?? "Redo" }
            if let running = state.titles[c] { title = running }
            var enabled = validate?(c) ?? true
            if c == .undo { enabled = state.undoName != nil }
            if c == .redo { enabled = state.redoName != nil }
            return row(title, .command(c), shortcut: map.binding(for: c).map(keyText) ?? "", enabled: enabled,
                       checked: state.checkedCommands.contains(c), help: c.menuHelp)
        }

        func items(_ spec: [MenuSpec.Item]) -> [SQMenuItem] {
            var out: [SQMenuItem] = []
            for item in spec {
                switch item {
                case .separator: out.append(.separator)
                case .command(let c): if ShellMenuBar.isVisible(c) { out.append(command(c)) }
                case .submenu(let title, let s):
                    let m = ShellMenuBar.tidy(items(s))
                    if !m.isEmpty { out.append(sub(title, m)) }
                }
            }
            return out
        }

        func appMenu() -> [SQMenuItem] {
            var m = [row("About Sequence Studio", .about), .separator, command(.preferences), command(.keyboardShortcuts), .separator]
            if platform == .mac {
                m += [row("Hide Sequence Studio", .hide, shortcut: keyText(KeyBinding(.char("h"), .command))),
                      row("Hide Others", .hideOthers, shortcut: keyText(KeyBinding(.char("h"), [.option, .command]))),
                      row("Show All", .showAll), .separator]
            }
            let quit = platform == .mac ? KeyBinding(.char("q"), .command) : KeyBinding(.function(4), .option)
            m.append(row(platform == .mac ? "Quit Sequence Studio" : "Exit", .quit, shortcut: keyText(quit)))
            return m
        }

        func helpMenu() -> [SQMenuItem] {
            var m: [SQMenuItem] = []
            for e in SupportEntry.visible(discord: SupportLinks.discord) {
                var i = row(e.helpTitle, .support(e))
                if let icon = SQIcon(rawValue: e.symbol) {
                    i = i.withLeading(symbol: icon, tint: e == .support ? ShellMenuBar.supportTint : nil)
                }
                m.append(i)
            }
            m += [.separator, command(.keyboardShortcuts)]
            m += [row("Send Feedback…", .sendFeedback), row("Reveal Logs and Reports", .revealLogs),
                  row("Welcome Tour…", .welcomeTour), row("Check for Updates…", .checkForUpdates)]
            return m
        }

        /// Open Recent right after Open Project; the stateful project items join File > Project.
        func extendFile(_ items: inout [SQMenuItem]) {
            var recent: [SQMenuItem] = state.recents.map { e in
                row(URL(fileURLWithPath: e.path).deletingPathExtension().lastPathComponent, .openRecent(path: e.path), help: e.path)
            }
            if !recent.isEmpty { recent.append(.separator) }
            recent.append(row("Clear Menu", .clearRecents, enabled: !state.recents.isEmpty))
            let open = SQL10n.string(EditorCommand.openProject.title)
            let at = items.firstIndex { $0.title == open }.map { $0 + 1 } ?? items.count
            items.insert(sub("Open Recent", recent), at: at)

            let projectTitle = SQL10n.string(EditorMenus.projectSubmenuTitle)
            var project: [SQMenuItem]
            let pi = items.firstIndex { $0.submenu != nil && $0.title == projectTitle }
            project = pi.map { items[$0].submenu ?? [] } ?? []
            if !project.isEmpty { project.append(.separator) }
            // Control-Command-S on the Mac (Command-S is Save, Shift Save As, Option Save a Copy).
            project.append(row("Save Checkpoint…", .saveCheckpoint, shortcut: keyText(KeyBinding(.char("s"), [.control, .command]))))
            project.append(sub("Autosave Versions", autosaveRows()))
            project.append(row("Reconnect Media…", .relinkMedia, enabled: state.canRelink))
            project.append(row("Import Checklist…", .importChecklist, enabled: state.hasImportChecklist))
            project.append(sub("Style Kit", [row("Import Style Kit…", .importStyleKit), row("Export Style Kit…", .exportStyleKit),
                                             row("Use Brand Caption Style", .useKitCaptionStyle)]))
            if let pi { items[pi].submenu = project } else { items.append(sub(EditorMenus.projectSubmenuTitle, project)) }
            // `AppController.installFileExtras`: Collect and Media Management close the File menu.
            items += [.separator, row("Collect Files into Project Folder", .collectFiles), sub("Media Management", mediaRows())]
        }

        /// `MediaMenuTarget.items`: the four outside-file modes, then library copies and folder watching.
        func mediaRows() -> [SQMenuItem] {
            let modes: [(OutsideMediaMode, String)] = [(.ask, "Ask About Outside Files"), (.copy, "Copy Outside Files Into Project"),
                                                       (.move, "Move Outside Files Into Project"),
                                                       (.leave, "Leave Outside Files Where They Are")]
            return OutsideMediaMode.allCases.compactMap { m in modes.first { $0.0 == m } }.map {
                row($0.1, .outsideMedia($0.0), checked: state.outsideMedia == $0.0)
            } + [.separator,
                 row("Copy Library Items Into Project", .toggleCopyLibraryItems, enabled: state.inProjectFolder, checked: state.copyLibraryItems),
                 row("Watch Project Folder", .toggleWatchFolder, enabled: state.inProjectFolder, checked: state.watchFolder)]
        }

        /// `fillAutosaveMenu`: named checkpoints first (bookmark icon), then the timed autosaves; "Latest" marks the newest.
        func autosaveRows() -> [SQMenuItem] {
            let all = state.autosaveVersions
            let versions = all.filter { $0.name != nil } + all.filter { $0.name == nil }
            let newestPlain = all.first { $0.name == nil }
            var out: [SQMenuItem] = versions.map { v in
                let title = v.name.map { AutosaveVersionLabel.checkpointTitle(name: $0, date: v.date) }
                    ?? AutosaveVersionLabel.title(date: v.date, now: state.now, isNewest: v == newestPlain)
                let r = row(title, .restoreAutosave(path: v.path))
                return v.name != nil ? r.withLeading(symbol: .bookmarkFilled) : r
            }
            if out.isEmpty { out.append(SQMenuItem(title: "No Versions Yet", isEnabled: false)) }
            return out
        }

        /// Clip > Replace and Fit > Pixel Aspect.
        func extendClip(_ items: inout [SQMenuItem]) {
            var rows: [SQMenuItem]
            if let p = state.pixelAspect {
                rows = p.rows.map { row($0.title, .pixelAspect($0.aspect), checked: $0.checked) }
                if rows.count > 1 { rows.insert(.separator, at: 1) }
                rows += [.separator, row(p.customTitle, .customPixelAspect, checked: p.customChecked)]
            } else {
                rows = [SQMenuItem(title: "From File", isEnabled: false), .separator,
                        SQMenuItem(title: "Custom Ratio…", isEnabled: false)]
            }
            let host = sub("Pixel Aspect", rows)
            let fit = SQL10n.string("Replace and Fit")
            if let i = items.firstIndex(where: { $0.submenu != nil && $0.title == fit }) { items[i].submenu?.append(host) }
            else { items.append(host) }
        }

        /// Sequence > Format after Sequence Settings, and New > Layer.
        func extendSequence(_ items: inout [SQMenuItem]) {
            var color = [row("None (as tagged)", .projectInputColor(nil), checked: state.projectInputColor == nil), SQMenuItem.separator]
            color += ColorSpaceID.allCases.map { row($0.displayName, .projectInputColor($0), checked: state.projectInputColor == $0) }
            let format = [row("Change Format…", .changeFormat, enabled: state.hasSequence),
                          row("Duplicate as Format…", .duplicateAsFormat, enabled: state.hasSequence), .separator,
                          row("New Sequence from Template…", .newSequenceFromTemplate),
                          row("Save Sequence as Template…", .saveSequenceAsTemplate), sub("Project Input Color Space", color)]
            let settings = SQL10n.string(EditorCommand.sequenceSettings.title)
            let at = items.firstIndex { $0.title == settings }.map { $0 + 1 } ?? 0
            items.insert(sub("Format", format), at: min(at, items.count))
            let layer = [sub("New Shape", ShapeKind.allCases.map { row($0.title, .newShape($0)) }),
                         row("New Graphics Clip", .newGraphicsClip), row("New Adjustment Layer", .newAdjustmentLayer),
                         row("New Color Matte…", .newColorMatte)]
            let new = SQL10n.string("New")
            if let i = items.firstIndex(where: { $0.submenu != nil && $0.title == new }) { items[i].submenu?.append(sub("Layer", layer)) }
            else { items.append(sub("Layer", layer)) }
        }

        /// Window: Workspaces, one checkable item per panel (Tools after Timeline), More Panels, then the plain commands and
        /// App Windows.
        func windowMenu(_ items: inout [SQMenuItem]) {
            var ws: [SQMenuItem] = state.workspaces.map { row($0, .selectWorkspace($0), checked: $0 == state.currentWorkspace) }
            ws.append(.separator)
            ws += [row("Save as New Workspace…", .saveWorkspaceAs),
                   row("Rename Workspace…", .renameWorkspace, enabled: state.canRenameWorkspace),
                   row("Delete Workspace", .deleteWorkspace, enabled: state.canRenameWorkspace),
                   row("Reset to Saved Layout", .resetLayout, shortcut: keyText(KeyBinding(.char("0"), [.option, .shift])),
                       enabled: state.canResetWorkspace),
                   row("Reset All Workspaces", .resetAllWorkspaces)]
            func panel(_ p: PanelID) -> SQMenuItem {
                row(EditorCommand.localizedPanelTitle(p), .togglePanel(p),
                    shortcut: map.binding(for: .focusPanel(p)).map(keyText) ?? "", enabled: !state.unavailablePanels.contains(p),
                    checked: state.visiblePanels.contains(p))
            }
            var head: [SQMenuItem] = [sub("Workspaces", ws), .separator]
            for p in EditorMenus.primaryWindowPanels {
                head.append(panel(p))
                if p == .timeline { head.append(row("Tools", .toggleToolStrip, checked: state.toolStripVisible)) }
            }
            head.append(sub("More Panels", EditorMenus.secondaryWindowPanels.map(panel)))
            head.append(.separator)
            var windows = [row("Minimize", .minimize), row(platform == .mac ? "Zoom" : "Maximize", .zoom), .separator,
                           row("History", .history), row("Start Window", .startWindow)]
            if platform == .mac { windows += [.separator, row("Bring All to Front", .bringAllToFront)] }
            items = head + items + [.separator, sub("App Windows", windows)]
            // The window list macOS appends to `NSApp.windowsMenu`: the project window, checked as the key window.
            if platform == .mac, let name = state.windowName, !name.isEmpty {
                items += [.separator, row(name, .bringAllToFront, checked: true)]
            }
        }
    }

    /// The support color of the heart row (`Theme.Colors.support`).
    static var supportTint: SQMenuTint? {
        #if canImport(AppKit)
        Theme.Colors.support
        #else
        PaletteColor(hex: 0xEA4AAA)   // `Theme.Colors.support`
        #endif
    }
}
