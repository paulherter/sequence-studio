import Foundation

public struct CommandMap: Sendable {
    public struct Entry: Sendable, Hashable {
        public var scope: CommandScope
        public var binding: KeyBinding
        public var command: EditorCommand
    }

    public let entries: [Entry]
    private let table: [CommandScope: [KeyBinding: EditorCommand]]

    public init(entries: [Entry]) {
        self.entries = entries
        var t: [CommandScope: [KeyBinding: EditorCommand]] = [:]
        for e in entries where t[e.scope]?[e.binding] == nil { t[e.scope, default: [:]][e.binding] = e.command }
        table = t
    }

    /// Entries whose (scope, binding) is bound more than once. Must be empty.
    public var duplicates: [Entry] {
        var seen: [CommandScope: Set<KeyBinding>] = [:]
        var out: [Entry] = []
        for e in entries where seen[e.scope, default: []].insert(e.binding).inserted == false { out.append(e) }
        return out
    }

    /// Focus-specific scope wins over `global`.
    public func command(for binding: KeyBinding, focus: PanelID?) -> EditorCommand? {
        if let s = CommandScope.scope(for: focus), let c = table[s]?[binding] { return c }
        return table[.global]?[binding]
    }

    /// First binding of a command (menus show it as key equivalent). Global scope preferred.
    public func binding(for command: EditorCommand) -> KeyBinding? {
        entries.first { $0.command == command && $0.scope == .global }?.binding
            ?? entries.first { $0.command == command }?.binding
    }

    // MARK: Premiere defaults (docs/UX.md section 3)

    public static let premiereDefault: CommandMap = {
        var e: [Entry] = []
        func add(_ s: CommandScope, _ k: Key, _ m: KeyModifiers, _ c: EditorCommand) {
            e.append(Entry(scope: s, binding: KeyBinding(k, m), command: c))
        }
        func add(_ s: CommandScope, _ k: Key, _ c: EditorCommand) { add(s, k, [], c) }
        func ch(_ c: Character) -> Key { .char(c) }
        let g = CommandScope.global, t = CommandScope.timeline

        // Transport
        add(g, ch("j"), .shuttleReverse); add(g, ch("k"), .shuttleStop); add(g, ch("l"), .shuttleForward)
        add(g, .space, .playPause)
        add(g, ch("j"), .shift, .shuttleSlowReverse); add(g, ch("l"), .shift, .shuttleSlowForward)
        add(g, .left, .stepBackward); add(g, .right, .stepForward)
        add(g, .left, .shift, .stepBackward5); add(g, .right, .shift, .stepForward5)
        add(g, .home, .goToStart); add(g, .end, .goToEnd)
        // Marking
        add(g, ch("i"), .markIn); add(g, ch("o"), .markOut)
        add(g, ch("i"), .shift, .goToIn); add(g, ch("o"), .shift, .goToOut)
        add(g, ch("x"), .markClip); add(g, ch("x"), .option, .clearInOut)
        add(g, ch("i"), .option, .clearIn); add(g, ch("o"), .option, .clearOut)
        add(g, .space, .shift, .playInToOutRoll); add(g, ch("k"), .shift, .playAround); add(g, ch("l"), .control, .toggleLoop)
        add(g, ch("e"), .shift, .exportFrame); add(g, ch("b"), .command, .newBin)
        add(g, ch("e"), [.command, .shift], .enableClip)         // Premiere: Clip > Enable. (Export Frame is Shift+E only.)
        add(g, ch("/"), [.command, .shift], .duplicate)
        add(g, ch(";"), .lift); add(g, ch("'"), .extract)
        add(g, ch(","), .insert); add(g, ch("."), .overwrite)
        add(g, ch("m"), .addMarker)
        add(g, ch("d"), .command, .applyVideoTransition); add(g, ch("d"), [.command, .shift], .applyAudioTransition)
        add(g, ch("d"), .shift, .applyDefaultTransitions)
        add(g, ch("m"), .shift, .nextMarker); add(g, ch("m"), [.command, .shift], .previousMarker)
        add(g, ch("/"), .markSelection)
        // Tools
        add(g, ch("v"), .tool(.selection)); add(g, ch("a"), .tool(.trackForward))
        add(g, ch("a"), .shift, .tool(.trackBackward))
        add(g, ch("b"), .tool(.ripple)); add(g, ch("n"), .tool(.rolling))
        add(g, ch("y"), .tool(.slip)); add(g, ch("u"), .tool(.slide))
        add(g, ch("c"), .tool(.razor)); add(g, ch("h"), .tool(.hand))
        add(g, ch("z"), .tool(.zoom)); add(g, ch("t"), .tool(.type)); add(g, ch("r"), .tool(.rateStretch))
        // Clipboard / history / file
        add(g, ch("c"), .command, .copy); add(g, ch("x"), .command, .cut); add(g, ch("v"), .command, .paste)
        add(g, ch("v"), [.command, .option], .pasteAttributes)
        add(g, ch("v"), [.command, .shift], .pasteInsert)
        add(g, ch("z"), .command, .undo); add(g, ch("z"), [.command, .shift], .redo)
        add(g, ch("i"), .command, .importMedia); add(g, ch("n"), .command, .newSequence)
        add(g, ch("s"), .command, .save); add(g, ch("m"), .command, .export)
        add(g, ch("s"), [.command, .shift], .saveAs); add(g, ch("o"), .command, .openProject)
        add(g, ch("n"), [.command, .option], .newProject)
        add(g, ch("k"), [.command, .option], .keyboardShortcuts); add(g, ch(","), .command, .preferences)
        // Panels (Premiere set; 6 maps to Library, our closest to the audio-side panel)
        let panels: [PanelID] = [.project, .sourceMonitor, .timeline, .programMonitor, .effectControls, .library, .effects]
        for (i, p) in panels.enumerated() {
            add(g, ch(Character(String(i + 1))), .shift, .focusPanel(p))
        }
        add(g, ch("`"), .maximizePanel); add(g, ch("`"), .shift, .maximizeActivePanel)
        add(g, ch("0"), [.option, .shift], .resetLayout)

        // Timeline
        add(t, .up, .previousEditPoint); add(t, .down, .nextEditPoint)
        add(t, ch("k"), .command, .addEdit); add(t, ch("k"), [.command, .shift], .addEditAllTracks)
        add(t, ch("q"), .rippleTrimPrevious); add(t, ch("w"), .rippleTrimNext); add(t, ch("e"), .extendEdit)
        add(t, ch("q"), .shift, .rollTrimPrevious); add(t, ch("w"), .shift, .rollTrimNext)
        add(t, ch("q"), .option, .trimPrevious); add(t, ch("w"), .option, .trimNext)
        add(t, ch("t"), .control, .toggleTrimType)
        add(t, .up, .option, .moveSelectionUp); add(t, .down, .option, .moveSelectionDown)
        add(t, .delete, .delete); add(t, .delete, .shift, .rippleDelete)
        add(t, ch("s"), .toggleSnapping)
        add(t, ch("a"), .command, .selectAll); add(t, ch("a"), [.command, .shift], .deselectAll)
        add(t, ch("d"), .selectClipAtPlayhead)
        add(t, .up, .shift, .previousEditPointAnyTrack); add(t, .down, .shift, .nextEditPointAnyTrack)
        // Nudge the selected clips (Cmd+arrows) or trim the selected edit (Opt+Shift+arrows; Opt+arrows is one frame, see AppController).
        add(t, .left, .command, .nudgeLeft); add(t, .right, .command, .nudgeRight)
        add(t, .left, [.command, .shift], .nudgeLeft5); add(t, .right, [.command, .shift], .nudgeRight5)
        add(t, .left, [.option, .shift], .trimBackward5); add(t, .right, [.option, .shift], .trimForward5)
        add(t, ch("l"), .command, .link); add(t, ch("g"), .command, .group)
        add(t, ch("g"), .audioGain)
        add(t, ch("r"), .command, .speedDuration)
        add(t, ch("f"), .matchFrame); add(t, ch("r"), .shift, .reverseMatchFrame)
        add(t, ch("="), .zoomIn); add(t, ch("-"), .zoomOut); add(t, ch("\\"), .zoomFit)
        // Track heights: modifier combinations only, so plain +/-/\ stay timeline zoom.
        add(t, ch("="), .command, .videoTracksTaller); add(t, ch("-"), .command, .videoTracksShorter)
        add(t, ch("="), .option, .audioTracksTaller); add(t, ch("-"), .option, .audioTracksShorter)
        add(t, ch("="), .shift, .expandAllTracks); add(t, ch("-"), .shift, .minimizeAllTracks)
        add(t, .function(9), .easyEase); add(t, .function(9), .shift, .easeIn)
        add(t, .function(9), [.command, .shift], .easeOut)
        add(t, ch("h"), [.command, .option], .toggleHoldInterpolation)
        add(t, .left, .option, .previousKeyframe); add(t, .right, .option, .nextKeyframe)
        add(t, .function(3), .shift, .toggleSpeedGraph); add(t, ch("k"), .option, .addKeyframe)
        // Play In to Out (Option+K on the Mac; the Timeline keeps Option+K for Add Keyframe, so the key is bound per panel).
        for scope in [CommandScope.program, .source, .project] { add(scope, ch("k"), .option, .playInToOut) }
        // Program monitor
        add(.program, .up, .previousEditPoint); add(.program, .down, .nextEditPoint)
        add(.program, ch("f"), .matchFrame); add(.program, ch("r"), .shift, .reverseMatchFrame)
        // Project panel
        add(.project, .delete, .deleteProjectItems)
        add(.project, ch("p"), .command, .setPosterFrame); add(.project, ch("p"), .option, .clearPosterFrame)
        add(.project, ch("h"), .shift, .toggleHoverScrub); add(.project, ch("f"), .command, .find)
        return CommandMap(entries: e)
    }()
}
