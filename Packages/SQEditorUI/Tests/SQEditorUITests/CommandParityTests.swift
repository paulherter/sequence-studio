import Testing
@testable import SQEditorUI

/// Command, shortcut and menu parity (docs/audit/shortcuts.md). Walks `CommandMap`, `EditorMenus` and `CommandSupport`.
/// Written to tolerate new commands: `CommandCatalog.audited` adds every command that is bound or listed in a menu.
@Suite struct CommandParityTests {
    let map = CommandMap.premiereDefault
    var audited: [EditorCommand] { CommandCatalog.audited(map) }

    private func b(_ k: Character, _ m: KeyModifiers = []) -> KeyBinding { KeyBinding(.char(k), m) }

    // MARK: Duplicates

    @Test func noKeyIsBoundTwiceInAScope() {
        #expect(map.duplicates.isEmpty, "\(map.duplicates.map { "\($0.scope) \(KeyboardListing.text(for: $0.binding)) \($0.command)" })")
    }

    /// A panel scope may not rebind a key that is global to another command: both are live when that panel has focus.
    @Test func panelScopesDoNotShadowGlobalKeys() {
        let global = Dictionary(map.entries.filter { $0.scope == .global }.map { ($0.binding, $0.command) }, uniquingKeysWith: { a, _ in a })
        for e in map.entries where e.scope != .global {
            if let g = global[e.binding] { #expect(g == e.command, "\(e.scope) \(KeyboardListing.text(for: e.binding)): \(e.command) vs global \(g)") }
        }
    }

    /// Menu key equivalents are unique and do not take macOS or app-menu keys (Hide, Hide Others, Quit, Close).
    @Test func menuKeyEquivalentsAreUniqueAndAvoidAppMenuKeys() {
        let cmds = (EditorMenus.all.flatMap(\.commands).filter(CommandSupport.isSupported) + MenuKeys.appMenuCommands
            + EditorMenus.windowPanels.map(EditorCommand.focusPanel))
        var seen: [KeyBinding: EditorCommand] = [:]
        for c in cmds {
            guard let k = map.binding(for: c) else { continue }
            if let other = seen[k], other != c { Issue.record("\(KeyboardListing.text(for: k)) is the key of \(other) and \(c)") }
            seen[k] = c
        }
        let reserved: [KeyBinding] = [b("h", .command), b("h", [.command, .option]), b("q", .command), b("w", .command), b("h", [.command, .shift])]
        for k in reserved { #expect(seen[k] == nil, "\(KeyboardListing.text(for: k)) is reserved by macOS or the app menu") }
        #expect(map.entries.allSatisfy { !reserved.contains($0.binding) })
    }

    // MARK: Dead bindings and dead menu items

    @Test func everyBindingFiresSomething() {
        for e in map.entries {
            #expect(CommandSupport.isSupported(e.command), "\(e.scope) \(KeyboardListing.text(for: e.binding)) is bound to \(e.command), which is not wired")
        }
    }

    @Test func everyMenuItemIsWired() {
        for m in EditorMenus.all {
            for c in m.commands { #expect(CommandSupport.isSupported(c), "\(m.title) > \(c.title) is not wired") }
        }
    }

    @Test func everyWiredCommandHasAMenuItemOrAKey() {
        let paths = CommandAudit.menuPaths()
        for c in audited where CommandSupport.isSupported(c) {
            #expect(paths[c] != nil || map.binding(for: c) != nil, "\(c.title) is wired but has neither a menu item nor a key")
        }
    }

    @Test func menuOnlyCommandsReallyHaveNoKey() {
        for c in EditorMenus.menuOnly { #expect(map.binding(for: c) == nil || EditorMenus.all.flatMap(\.commands).contains(c), "\(c)") }
    }

    /// The key equivalent a menu item shows must really exist in the map for that command.
    @Test func menuItemsShowTheirCommandsKey() {
        for c in EditorMenus.all.flatMap(\.commands) {
            if let k = map.binding(for: c) { #expect(map.entries.contains { $0.command == c && $0.binding == k }) }
        }
    }

    // MARK: Command keys without a menu go through the router

    @Test func commandKeysWithoutAMenuItemAreNotOwnedByMenus() {
        let owned = MenuKeys.owned(map, isVisible: CommandSupport.isSupported)
        // Cmd+K (Add Edit) has an item: macOS handles it. Nudge (Cmd+Left) has none: the router must see it.
        #expect(owned.contains(b("k", .command)))
        #expect(owned.contains(KeyBinding(.char("s"), .command)))
        #expect(!owned.contains(KeyBinding(.left, .command)))
        #expect(!owned.contains(KeyBinding(.right, [.command, .shift])))
        #expect(!owned.contains(b("b", .command)))     // Cmd+B: Project panel New Bin, File shows Cmd+/
        #expect(owned.contains(b("/", .command)))
        // Every Command binding is either owned by a menu or resolvable by the router in its scope.
        for e in map.entries where e.binding.modifiers.contains(.command) && !owned.contains(e.binding) {
            #expect(CommandSupport.isSupported(e.command), "\(e.command)")
        }
    }

    @Test func panelOnlyCommandShortcutsAreBlockedWhileTyping() {
        #expect(MenuKeys.blockedWhileTyping(.addEdit, map))
        #expect(MenuKeys.blockedWhileTyping(.link, map))
        #expect(MenuKeys.blockedWhileTyping(.speedDuration, map))
        #expect(MenuKeys.blockedWhileTyping(.deselectAll, map))
        #expect(!MenuKeys.blockedWhileTyping(.selectAll, map))     // goes to the text field
        #expect(!MenuKeys.blockedWhileTyping(.save, map))
        #expect(!MenuKeys.blockedWhileTyping(.undo, map))
        #expect(!MenuKeys.blockedWhileTyping(.openProject, map))
    }

    // MARK: Premiere macOS defaults (docs/audit/shortcuts.md)

    /// Keys Adobe lists as macOS defaults (keyboard-shortcuts and project-shortcuts references) for commands we have.
    @Test func defaultsMatchAdobe() {
        let adobe: [(EditorCommand, KeyBinding)] = [
            (.newProject, b("n", [.option, .command])), (.newSequence, b("n", .command)), (.newBin, b("/", .command)),
            (.newBin, b("b", .command)),
            (.openProject, b("o", .command)), (.save, b("s", .command)), (.saveAs, b("s", [.shift, .command])),
            (.importMedia, b("i", .command)), (.export, b("m", .command)),
            (.undo, b("z", .command)), (.redo, b("z", [.shift, .command])), (.cut, b("x", .command)), (.copy, b("c", .command)),
            (.paste, b("v", .command)), (.pasteInsert, b("v", [.shift, .command])), (.pasteAttributes, b("v", [.option, .command])),
            (.duplicate, b("/", [.shift, .command])), (.selectAll, b("a", .command)), (.deselectAll, b("a", [.shift, .command])),
            (.find, b("f", .command)), (.keyboardShortcuts, b("k", [.option, .command])),
            (.audioGain, b("g")), (.speedDuration, b("r", .command)), (.insert, b(",")), (.overwrite, b(".")),
            (.enableClip, b("e", [.shift, .command])), (.link, b("l", .command)),
            (.matchFrame, b("f")), (.reverseMatchFrame, b("r", .shift)), (.addEdit, b("k", .command)),
            (.addEditAllTracks, b("k", [.shift, .command])), (.extendEdit, b("e")),
            (.applyVideoTransition, b("d", .command)), (.applyAudioTransition, b("d", [.shift, .command])),
            (.applyDefaultTransitions, b("d", .shift)), (.lift, b(";")), (.extract, b("'")),
            (.zoomIn, b("=")), (.zoomOut, b("-")), (.toggleSnapping, b("s")),
            (.markIn, b("i")), (.markOut, b("o")), (.markClip, b("x")), (.markSelection, b("/")),
            (.goToIn, b("i", .shift)), (.goToOut, b("o", .shift)), (.clearIn, b("i", .option)), (.clearOut, b("o", .option)),
            (.clearInOut, b("x", .option)), (.addMarker, b("m")), (.nextMarker, b("m", .shift)),
            (.previousMarker, b("m", [.shift, .command])),
            (.resetLayout, b("0", [.option, .shift])),
            (.focusPanel(.project), b("1", .shift)), (.focusPanel(.sourceMonitor), b("2", .shift)),
            (.focusPanel(.timeline), b("3", .shift)), (.focusPanel(.programMonitor), b("4", .shift)),
            (.focusPanel(.effectControls), b("5", .shift)), (.focusPanel(.effects), b("7", .shift)),
            (.delete, KeyBinding(.delete)), (.rippleDelete, KeyBinding(.delete, .shift)), (.rippleDelete, KeyBinding(.delete, .option)),
            (.videoTracksShorter, b("-", .command)), (.videoTracksTaller, b("=", .command)),
            (.audioTracksShorter, b("-", .option)), (.audioTracksTaller, b("=", .option)),
            (.minimizeAllTracks, b("-", .shift)), (.expandAllTracks, b("=", .shift)),
            (.nudgeLeft, KeyBinding(.left, .command)), (.nudgeRight, KeyBinding(.right, .command)),
            (.nudgeLeft5, KeyBinding(.left, [.shift, .command])), (.nudgeRight5, KeyBinding(.right, [.shift, .command])),
            (.nextEditPoint, KeyBinding(.down)), (.previousEditPoint, KeyBinding(.up)),
            (.nextEditPointAnyTrack, KeyBinding(.down, .shift)), (.previousEditPointAnyTrack, KeyBinding(.up, .shift)),
            (.selectClipAtPlayhead, b("d")), (.goToStart, KeyBinding(.home)), (.goToEnd, KeyBinding(.end)),
            (.maximizePanel, b("`")), (.maximizeActivePanel, b("`", .shift)),
            (.playAround, b("k", .shift)), (.playInToOut, b("k", .option)), (.playInToOutRoll, KeyBinding(.space, .shift)),
            (.playPause, KeyBinding(.space)), (.rippleTrimNext, b("w")), (.rippleTrimPrevious, b("q")),
            (.setPosterFrame, b("p", .command)), (.shuttleReverse, b("j")), (.shuttleStop, b("k")), (.shuttleForward, b("l")),
            (.shuttleSlowReverse, b("j", .shift)), (.shuttleSlowForward, b("l", .shift)),
            (.stepBackward, KeyBinding(.left)), (.stepForward, KeyBinding(.right)),
            (.stepBackward5, KeyBinding(.left, .shift)), (.stepForward5, KeyBinding(.right, .shift)),
            (.toggleAudioScrubbing, b("s", .shift)), (.toggleTrimType, b("t", .control)),
            (.trimBackward, KeyBinding(.left, .option)), (.trimForward, KeyBinding(.right, .option)),
            (.trimBackward5, KeyBinding(.left, [.option, .shift])), (.trimForward5, KeyBinding(.right, [.option, .shift])),
            (.trimPrevious, b("q", .option)), (.trimNext, b("w", .option)), (.toggleHoverScrub, b("h", .shift)),
        ]
        for (c, k) in adobe {
            #expect(map.entries.contains { $0.command == c && $0.binding == k }, "\(c.title) should have \(KeyboardListing.text(for: k))")
        }
    }

    /// Where we knowingly differ from Adobe's table (reasons in docs/audit/shortcuts.md).
    @Test func documentedDeviationsAreReal() {
        // Shift+6 is Library here, Audio Track Mixer in Premiere (we have no mixer panel).
        #expect(map.command(for: b("6", .shift), focus: nil) == .focusPanel(.library))
        // Loop is Ctrl+L: Adobe's Cmd+L is panel-scoped Loop and would clash with Link.
        #expect(map.binding(for: .toggleLoop) == b("l", .control))
        // Opt+K is Play In to Out in the monitors and the Project panel, not in the Timeline.
        #expect(map.command(for: b("k", .option), focus: .programMonitor) == .playInToOut)
    }

    // MARK: Keyboard Shortcuts window

    @Test func shortcutsWindowListsEveryBindingAndFindsIt() {
        let rows = KeyboardListing.windowRows(map)
        #expect(rows.filter { $0.scope != "Menu only" }.count == map.entries.count)
        // Commands without a key are listed too ("Linked Selection", "Show Time Remapping"), so search finds them.
        #expect(rows.contains { $0.command == "Linked Selection" && $0.scope == "Menu only" && $0.shortcut.isEmpty })
        for c in audited where CommandSupport.isSupported(c) { #expect(rows.contains { $0.command == c.title }, "\(c.title)") }
        // Search finds each command by its own name.
        for c in audited where !map.entries.filter({ $0.command == c }).isEmpty {
            let hits = KeyboardListing.filter(rows, query: c.title)
            #expect(hits.contains { $0.command == c.title }, "\(c.title)")
        }
        // New commands show up.
        #expect(KeyboardListing.filter(rows, query: "trim backward").contains { $0.shortcut == "⌥←" })
        #expect(KeyboardListing.filter(rows, query: "easy ease").map(\.shortcut) == ["F9"])
        #expect(KeyboardListing.filter(rows, query: "option left").contains { $0.command == "Trim Backward" })
    }

    @Test func noTwoCommandsShareATitle() {
        var titles: [String: EditorCommand] = [:]
        for c in audited {
            if let other = titles[c.title], other != c { Issue.record("\(c) and \(other) are both titled \(c.title)") }
            titles[c.title] = c
        }
    }

    @Test func noRowRepeatsInTheShortcutsWindow() {
        let rows = KeyboardListing.windowRows(map)
        #expect(Set(rows.map { "\($0.command)|\($0.shortcut)|\($0.scope)" }).count == rows.count)
    }

    // MARK: Menu placement

    @Test func menusFollowPremiere() {
        #expect(EditorMenus.sequence.commands.contains(.zoomIn))
        #expect(!EditorMenus.view.commands.contains(.zoomIn))
        #expect(EditorMenus.markers.commands.contains(.markSelection))
        #expect(EditorMenus.edit.commands.contains(.duplicate) && EditorMenus.edit.commands.contains(.find))
        #expect(EditorMenus.clip.commands.contains(.link) && EditorMenus.clip.commands.contains(.audioGain))
        #expect(EditorMenus.file.commands.contains(.newBin))
    }

    @Test func auditTableListsEveryCommandOnce() {
        let rows = CommandAudit.rows(map)
        #expect(Set(rows.map(\.command)).count == rows.count)
        #expect(rows.first { $0.command == .addEdit }?.menuPath == "Sequence")
        #expect(rows.first { $0.command == .trimBackward }?.keys.count == 1)
    }

    // MARK: Tooltips carry the shortcut

    @Test func monitorButtonTipsShowTheirKeys() {
        #expect(KeyboardListing.tip("Export Frame", .exportFrame) == "Export Frame (⇧E)")
        #expect(KeyboardListing.tip("Linked Selection", .toggleLinkedSelection) == "Linked Selection")     // no key: bare title
        for mode in [MonitorMode.source, .program] {
            for a in MonitorAction.buttonBar(for: mode) {
                guard let c = a.command else { Issue.record("\(a) has no command"); continue }
                if let k = map.binding(for: c) {
                    #expect(a.tip("T").hasSuffix("(\(KeyboardListing.text(for: k)))"), "\(a)")
                } else {
                    Issue.record("\(a) runs \(c.title), which has no key to show")
                }
            }
        }
    }

    /// The timeline tool column shows the tool's own key: it must be the key the map binds to that tool.
    @Test func toolColumnKeysMatchTheMap() {
        for t in TimelineTool.allCases where t.isAvailable {
            guard let c = map.command(for: KeyBinding(.char(t.key)), focus: nil) else { Issue.record("\(t) key \(t.key) is unbound"); continue }
            if case .tool = c {} else { Issue.record("\(t) key \(t.key) runs \(c)") }
        }
    }
}
