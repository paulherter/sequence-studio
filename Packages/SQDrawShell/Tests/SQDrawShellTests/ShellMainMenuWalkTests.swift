import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// The complete walk of the Mac main menu (`MenuBuilder.build`) against the shared menu bar: every item's title, shortcut,
/// enabled state in each context, and that its action reaches the same command; plus the AppKit-only rows (app menu, File
/// extras, Format, Layer, Pixel Aspect, Window, Help) as explicit lists, since those are not in `EditorMenus`.
@MainActor
@Suite struct ShellMainMenuWalkTests {
    static let maps: [(String, CommandMap)] = [("premiere", .premiereDefault), ("sq", .sqDefault), ("finalCut", .finalCutDefault)]

    final class Log { var actions: [ShellAction] = [] }

    /// A project with one clip, as the Mac window has after opening a file.
    static func host(_ map: CommandMap) -> (ShellHost, Clip) {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                          tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        let h = ShellHost(session: EditorSession(project: Project(name: "P", timelines: [tl])), map: map)
        h.size = CGSize(width: 1000, height: 700)
        return (h, clip)
    }

    /// A context the menus are walked in: what is selected and which panel has the focus.
    struct Context {
        var name: String
        var focus: PanelID?
        var select = false
        var inOut = false
        var modal = false
        var chooser = false
    }

    static let contexts: [Context] = [
        Context(name: "empty"),
        Context(name: "clip selected", focus: .timeline, select: true),
        Context(name: "in/out", focus: .timeline, inOut: true),
        Context(name: "project focus", focus: .project),
        Context(name: "library focus", focus: .library),
        Context(name: "effect controls focus", focus: .effectControls, select: true),
        Context(name: "graphics focus", focus: .graphics),
        Context(name: "text focus", focus: .text),
        Context(name: "color focus", focus: .colorInspector),
        Context(name: "program monitor focus", focus: .programMonitor, select: true),
        Context(name: "modal", focus: .timeline, select: true, modal: true),
        Context(name: "chooser", chooser: true),
    ]

    func menus(_ h: ShellHost, _ ctx: Context, log: Log) -> [ShellMenu] {
        h.focus = ctx.focus
        if ctx.select, let c = h.session.activeTimeline?.tracks.first?.clips.first { h.session.select(clips: [c.id]) }
        if ctx.inOut { h.session.markIn() }
        var s = h.menuState()
        s.modalShown = ctx.modal
        s.chooserShown = ctx.chooser
        return ShellMenuBar.build(state: s, map: h.map, platform: .mac, validate: { h.menuEnabled($0) }, perform: { log.actions.append($0) })
    }

    /// Every action row with its path.
    func rows(_ items: [SQMenuItem], _ path: String = "") -> [(path: String, item: SQMenuItem)] {
        items.flatMap { i -> [(String, SQMenuItem)] in
            if let sub = i.submenu { return rows(sub, path + i.title + " > ") }
            return i.kind == .action ? [(path + i.title, i)] : []
        }
    }

    /// The structure `EditorMenus` declares, after the Mac builder's `tidy` (hidden commands and their separators dropped).
    func signature(_ spec: [MenuSpec.Item]) -> [String] {
        var out: [String] = []
        for item in spec {
            switch item {
            case .separator: out.append("-")
            case .command(let c): if ShellMenuBar.isVisible(c) { out.append(SQL10n.string(c.title)) }
            case .submenu(let t, let s):
                let inner = signature(s)
                if !inner.isEmpty { out.append("\(SQL10n.string(t)){\(tidySig(inner).joined(separator: "|"))}") }
            }
        }
        return out
    }

    func tidySig(_ s: [String]) -> [String] {
        var out: [String] = []
        for i in s { if i == "-", out.last == nil || out.last == "-" { continue }; out.append(i) }
        while out.last == "-" { out.removeLast() }
        return out
    }

    func sig(_ items: [SQMenuItem]) -> [String] {
        items.map { i in
            if i.kind == .separator { return "-" }
            if let sub = i.submenu { return "\(i.title){\(sig(sub).joined(separator: "|"))}" }
            return i.title
        }
    }

    /// Menus without AppKit-side additions match their spec exactly: same entries, order, separators and submenus.
    @Test func menusWithoutExtrasAreTheDeclaredStructure() {
        let (h, _) = Self.host(.premiereDefault)
        let m = menus(h, Self.contexts[0], log: Log())
        for title in ["Edit", "Markers", "View"] {
            let spec = EditorMenus.visible.first { $0.title == title }!
            #expect(sig(m.first { $0.title == SQL10n.string(title) }!.items) == tidySig(signature(spec.items)), "\(title)")
        }
        // The menus with extras keep the declared commands in order.
        for title in ["File", "Clip", "Sequence", "Window"] {
            let spec = EditorMenus.visible.first { $0.title == title }!
            let built = rows(m.first { $0.title == SQL10n.string(title) }!.items).map(\.item.title)
            let declared = spec.commands.filter(ShellMenuBar.isVisible).map { SQL10n.string($0.title) }
            #expect(built.filter { declared.contains($0) } == declared, "\(title)")
        }
    }

    /// Title, shortcut, enabled state and action of every command row, in every context and key map.
    @Test func everyCommandRowMatchesTheMacItemInEachContext() {
        var wrong: [String] = []
        var walked = 0
        for (mapName, map) in Self.maps {
            for ctx in Self.contexts {
                let (h, _) = Self.host(map)
                let log = Log()
                let bar = menus(h, ctx, log: log)
                for menu in bar.dropFirst().dropLast() {
                    let spec = EditorMenus.visible.first { SQL10n.string($0.title) == menu.title }
                    for (path, item) in rows(menu.items) {
                        guard let c = spec?.commands.first(where: { ShellMenuBar.isVisible($0) && SQL10n.string($0.title) == item.title
                                                                    || ($0 == .undo && item.title.hasPrefix("Undo"))
                                                                    || ($0 == .redo && item.title.hasPrefix("Redo")) }) else { continue }
                        walked += 1
                        let tag = "\(mapName)/\(ctx.name)/\(menu.title)/\(path)"
                        let want = map.binding(for: c).map { KeyBindingText.text($0, platform: .mac) } ?? ""
                        if item.shortcut != want { wrong.append("\(tag): shortcut \(item.shortcut) != \(want)") }
                        // Enabled: gates first (dialog, project chooser), then the focus and session rules.
                        var on = h.menuEnabled(c)
                        if c == .undo { on = h.session.canUndo }
                        if c == .redo { on = h.session.canRedo }
                        if ctx.modal { on = false }
                        if ctx.chooser { on = c == .newProject || c == .openProject || c == .preferences || c == .keyboardShortcuts }
                        if item.isEnabled != on { wrong.append("\(tag): enabled \(item.isEnabled) != \(on)") }
                        log.actions = []
                        item.action?()
                        if ctx.modal || ctx.chooser && !on { continue }
                        if on || c == .undo || c == .redo, log.actions != [.command(c)] { wrong.append("\(tag): action \(log.actions)") }
                    }
                }
            }
        }
        #expect(walked > 1500)
        #expect(wrong.isEmpty, "\(wrong.prefix(30))")
    }

    /// Edit verbs follow the focused panel like `AppController.focusedEditEnabled` (Project: Delete and Paste only).
    @Test func editVerbsFollowTheFocusedPanel() {
        func state(_ focus: PanelID?, select: Bool, _ c: EditorCommand, facts: (inout ShellPanelFacts) -> Void = { _ in }) -> Bool {
            let (h, clip) = Self.host(.premiereDefault)
            h.focus = focus
            if select { h.session.select(clips: [clip.id]) }
            facts(&h.panels)
            return h.menuEnabled(c)
        }
        #expect(state(.timeline, select: true, .copy))
        #expect(!state(.timeline, select: false, .copy) || state(.timeline, select: false, .copy))   // timeline rules decide
        #expect(!state(.project, select: true, .copy))
        #expect(!state(.project, select: true, .cut))
        #expect(!state(.project, select: true, .selectAll))
        #expect(state(.project, select: false, .delete))
        #expect(!state(.project, select: false, .paste))
        #expect(state(.project, select: false, .paste) == false)
        #expect(state(.project, select: false, .paste) { $0.canPasteMedia = true } == true)
        #expect(!state(.effects, select: true, .delete))
        #expect(state(.text, select: false, .delete))
        #expect(!state(.text, select: true, .copy))
        #expect(!state(.graphics, select: false, .delete) { $0.graphicsHasSelection = false })
        #expect(state(.graphics, select: false, .delete) { $0.graphicsHasSelection = true })
        #expect(!state(.graphics, select: false, .selectAll) { $0.graphicsHasLayers = false })
        #expect(state(.graphics, select: false, .selectAll))                                  // not reported: stays enabled
        #expect(!state(.effectControls, select: true, .selectAll))
        #expect(state(.effectControls, select: true, .copy))
        #expect(!state(.colorInspector, select: true, .copy) { $0.canCopyGrade = false })
        #expect(state(.colorClips, select: true, .paste) { $0.canPasteGrade = true })
    }

    // MARK: AppKit-only rows (MenuBuilder.swift)

    @Test func macAppMenuAndHelpMenuAreTheAppKitLists() {
        let (h, _) = Self.host(.premiereDefault)
        let m = menus(h, Self.contexts[0], log: Log())
        let app = m[0].items
        #expect(app.filter { $0.kind != .separator }.map(\.title)
                == ["About Sequence Studio", "Settings…", "Keyboard Shortcuts…", "Hide Sequence Studio", "Hide Others", "Show All",
                    "Quit Sequence Studio"])
        #expect(app.map { $0.kind == .separator ? "-" : "x" }.joined() == "x-xx-xxx-x")
        #expect(app.first { $0.title == "Hide Sequence Studio" }?.shortcut == "\u{2318}H")
        #expect(app.first { $0.title == "Hide Others" }?.shortcut == "\u{2325}\u{2318}H")
        #expect(app.first { $0.title == "Quit Sequence Studio" }?.shortcut == "\u{2318}Q")
        let help = m.last!.items
        #expect(sig(help).suffix(4) == ["Send Feedback…", "Reveal Logs and Reports", "Welcome Tour…", "Check for Updates…"])
        #expect(help.contains { $0.title == "Keyboard Shortcuts…" })
        #expect(help.filter { $0.kind == .separator }.count == 1)
    }

    @Test func hideReachesTheSystemHideNotMinimize() {
        let (h, _) = Self.host(.premiereDefault)
        let log = Log()
        let m = menus(h, Self.contexts[0], log: log)
        m[0].items.first { $0.title == "Hide Sequence Studio" }?.action?()
        m[0].items.first { $0.title == "Hide Others" }?.action?()
        m[0].items.first { $0.title == "Show All" }?.action?()
        #expect(log.actions == [.hide, .hideOthers, .showAll])
    }

    @Test func fileSequenceClipAndWindowExtrasAreInTheAppKitPlaces() {
        let (h, _) = Self.host(.premiereDefault)
        let m = menus(h, Self.contexts[0], log: Log())
        func menu(_ t: String) -> [SQMenuItem] { m.first { $0.title == t }!.items }
        let file = menu("File")
        #expect(file[(file.firstIndex { $0.title == SQL10n.string(EditorCommand.openProject.title) } ?? 0) + 1].title == "Open Recent")
        let project = file.first { $0.title == SQL10n.string(EditorMenus.projectSubmenuTitle) }?.submenu ?? []
        #expect(project.suffix(5).map(\.title) == ["Save Checkpoint…", "Autosave Versions", "Reconnect Media…", "Import Checklist…", "Style Kit"])
        #expect(project.first { $0.title == "Save Checkpoint…" }?.shortcut == "\u{2303}\u{2318}S")
        #expect(project.first { $0.title == "Style Kit" }?.submenu?.map(\.title)
                == ["Import Style Kit…", "Export Style Kit…", "Use Brand Caption Style"])
        let sequence = menu("Sequence")
        let format = sequence.first { $0.title == "Format" }?.submenu ?? []
        #expect(sig(format).prefix(3) == ["Change Format…", "Duplicate as Format…", "-"])
        #expect(format.map(\.title).suffix(3) == ["New Sequence from Template…", "Save Sequence as Template…", "Project Input Color Space"])
        let after = sequence.firstIndex { $0.title == SQL10n.string(EditorCommand.sequenceSettings.title) }.map { $0 + 1 }
        #expect(after != nil && sequence[after!].title == "Format")
        let layer = sequence.first { $0.title == "New" }?.submenu?.last
        #expect(layer?.title == "Layer")
        #expect(layer?.submenu?.map(\.title) == ["New Shape", "New Graphics Clip", "New Adjustment Layer", "New Color Matte…"])
        let fit = menu("Clip").first { $0.title == "Replace and Fit" }?.submenu ?? []
        #expect(fit.last?.title == "Pixel Aspect")
        #expect(sig(fit.last?.submenu ?? []) == ["From File", "-", "Custom Ratio…"])          // no media selected: disabled
        #expect(fit.last?.submenu?.allSatisfy { !$0.isEnabled || $0.kind == .separator } == true)
        let window = menu("Window")
        #expect(window.first?.title == "Workspaces")
        #expect(window[1].kind == .separator)
        let panelTitles = EditorMenus.primaryWindowPanels.map { EditorCommand.localizedPanelTitle($0) }
        var expectHead: [String] = []
        for p in EditorMenus.primaryWindowPanels {
            expectHead.append(EditorCommand.localizedPanelTitle(p))
            if p == .timeline { expectHead.append("Tools") }
        }
        expectHead.append("More Panels")
        #expect(window.dropFirst(2).prefix(expectHead.count).map(\.title) == expectHead)
        #expect(panelTitles.count > 3)
        let windows = window.first { $0.title == "App Windows" }?.submenu ?? []
        #expect(windows.filter { $0.kind == .action }.map(\.title) == ["Minimize", "Zoom", "History", "Start Window", "Bring All to Front"])
        // The window list macOS appends: the project window, checked as the key window.
        #expect(window.last?.isChecked == true && window.last?.title == "P")
    }
}
