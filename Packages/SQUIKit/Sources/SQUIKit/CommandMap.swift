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

    /// The map the running app uses (preset + the user's `sq.keymap` diff). The app sets it at launch and after every
    /// edit so tooltips and hints that default to it never show a stale key. Tests keep the Premiere default.
    public static var current: CommandMap {
        get { currentBox.get() }
        set { currentBox.set(newValue) }
    }
    private static let currentBox = CurrentMapBox()

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
        add(g, .space, .control, .playToOut)   // Premiere: Play from Playhead to Out
        add(g, .space, [.control, .shift], .playFromStart)   // Play from Start; Ctrl+Space (to Out) and Shift+Space (with rolls) stay
        add(g, .space, .shift, .playInToOutRoll); add(g, ch("k"), .shift, .playAround); add(g, ch("l"), .control, .toggleLoop)
        add(g, ch("e"), .shift, .exportFrame); add(g, ch("/"), .command, .newBin)   // File > Bin (Premiere); Cmd+B in the Project panel below
        add(g, ch("e"), [.command, .shift], .enableClip)         // Premiere: Clip > Enable. (Export Frame is Shift+E only.)
        add(g, ch("/"), [.command, .shift], .duplicate)
        add(g, ch("g"), .command, .group); add(g, ch("g"), [.command, .shift], .ungroup)   // Premiere: Clip > Group / Ungroup
        // Premiere's selection Group under our name (Cmd+G stays the layer Group); Make Subclip and Edit Original keep Premiere's keys.
        add(g, ch("g"), [.command, .option], .bundle); add(g, ch("g"), [.command, .option, .shift], .unbundle)
        add(g, ch("u"), .command, .makeSubclip); add(g, ch("e"), .command, .editOriginal)
        add(g, ch("t"), [.command, .option], .saveAsTemplate)   // Save the selected title layers as a template
        add(g, ch(";"), .lift); add(g, ch("'"), .extract)
        add(g, ch(","), .insert); add(g, ch("."), .overwrite)
        add(g, ch("m"), .addMarker)
        add(g, ch("m"), .option, .clearMarker); add(g, ch("m"), [.control, .option], .clearAllMarkers)   // Premiere: Clear Selected / All Markers (Cmd+Opt+M stays Quick Export)
        add(g, ch("p"), .shift, .togglePunchIn)       // W8.2: static punch-in on/off for the selected clips
        // N5 Keyword at Playhead (transcript word under the playhead -> big text clip) has no key here: Premiere's Shift+T is
        // Trim mode. The SQ set keeps Shift+T for the keyword (see `sqDefault`).
        add(g, ch("t"), .command, .addTitle)          // Premiere's legacy New Title key: two lines + emoji, animated in
        add(g, ch("c"), [.command, .option], .autoCaptions)   // transcribe the sequence + create captions in one go
        // Keyframe easing for the selected keyframes in Effect Controls (After Effects keys; Premiere has none). Needs fn on most Macs.
        add(g, .function(9), .easyEase); add(g, .function(9), .shift, .easeIn); add(g, .function(9), [.command, .shift], .easeOut)
        add(g, ch("s"), .shift, .toggleAudioScrubbing)
        add(g, ch("d"), .command, .applyVideoTransition); add(g, ch("d"), [.command, .shift], .applyAudioTransition)
        add(g, ch("d"), .shift, .applyDefaultTransitions)
        add(g, ch("m"), .shift, .nextMarker); add(g, ch("m"), [.command, .shift], .previousMarker)
        add(g, ch("m"), [.option, .shift], .nextWeakTracking)   // tracked Magic mask: next weak stretch (confidence strip)
        add(g, ch("/"), .markSelection)
        // F7.16 Angles clip: 1-9 switch the angle while the Timeline or the Program monitor has focus (other panels keep
        // the digits for typing and type-select).
        for n in 1...9 { for scope in [t, CommandScope.program] { add(scope, ch(Character(String(n))), .switchAngle(n)) } }
        // Tools
        add(g, ch("v"), .tool(.selection)); add(g, ch("a"), .tool(.trackForward))
        add(g, ch("a"), .shift, .tool(.trackBackward))
        add(g, ch("b"), .tool(.ripple)); add(g, ch("n"), .tool(.rolling))
        add(g, ch("y"), .tool(.slip)); add(g, ch("u"), .tool(.slide))
        add(g, ch("c"), .tool(.razor)); add(g, ch("h"), .tool(.hand))
        add(g, ch("z"), .tool(.zoom)); add(g, ch("t"), .tool(.type)); add(g, ch("r"), .tool(.rateStretch))
        // Create tool modes. R, O, L and P alone are Stretch, Mark Out, Shuttle and Mask: the shapes take Option+Shift.
        add(g, ch("r"), [.option, .shift], .tool(.rectangle)); add(g, ch("e"), [.option, .shift], .tool(.ellipse))
        add(g, ch("l"), [.option, .shift], .tool(.line)); add(g, ch("d"), [.option, .shift], .tool(.draw))
        add(g, ch("p"), .tool(.mask))                  // O is Mark Out; P = Premiere's Pen key, our pen lives in the Mask tool
        // Clipboard / history / file
        add(g, ch("c"), .command, .copy); add(g, ch("x"), .command, .cut); add(g, ch("v"), .command, .paste)
        add(g, ch("v"), [.command, .option], .pasteAttributes)
        add(g, ch("v"), [.command, .shift], .pasteInsert)
        add(g, ch("z"), .command, .undo); add(g, ch("z"), [.command, .shift], .redo)
        add(g, ch("i"), .command, .importMedia); add(g, ch("n"), .command, .newSequence)
        add(g, ch("s"), .command, .save); add(g, ch("m"), .command, .export)
        add(g, ch("m"), [.command, .option], .quickExport)
        add(g, ch("s"), [.command, .shift], .saveAs); add(g, ch("s"), [.command, .option], .saveCopy); add(g, ch("o"), .command, .openProject)
        add(g, ch("n"), [.command, .option], .newProject); add(g, ch("w"), [.command, .shift], .closeProject)
        // UI scale (View > Larger / Smaller / Actual Size): Cmd+= / - / 0 are track height and audio targets in the timeline
        add(g, ch("="), [.command, .option], .uiScaleLarger); add(g, ch("-"), [.command, .option], .uiScaleSmaller); add(g, ch("0"), [.command, .option], .uiScaleReset)
        add(g, ch("k"), [.command, .option], .keyboardShortcuts); add(g, ch(","), .command, .preferences)
        // Panels (Premiere set; 6 maps to the Audio Meter, our only audio-side panel, never to Library; 8 Text/Captions,
        // 9 Graphics: Premiere's Media Browser and Audio Clip Mixer have no panel here, so those keys carry our own panels)
        let panels: [PanelID] = [.project, .sourceMonitor, .timeline, .programMonitor, .effectControls, .audioMeter, .effects, .text, .graphics]
        for (i, p) in panels.enumerated() {
            add(g, ch(Character(String(i + 1))), .shift, .focusPanel(p))
        }
        add(g, ch("0"), .shift, .focusPanel(.colorInspector))   // SH-18: Color and Keystones follow the number row
        add(g, ch(","), .shift, .focusPanel(.keystones))
        add(g, ch("`"), .maximizePanel); add(g, ch("`"), .shift, .maximizeActivePanel)
        add(g, ch("0"), [.option, .shift], .resetLayout)
        // Premiere: Ctrl+Shift+. and ,; Ctrl+Shift+. is Paste Attached backtimed here, so the pair sits on Ctrl+Option
        add(g, ch("."), [.control, .option], .selectNextPanel); add(g, ch(","), [.control, .option], .selectPreviousPanel)
        add(g, .space, .option, .quickApply)

        // Timeline
        add(t, .up, .previousEditPoint); add(t, .down, .nextEditPoint)
        add(t, ch("k"), .command, .addEdit); add(t, ch("k"), [.command, .shift], .addEditAllTracks)
        add(t, ch("k"), .control, .jumpCutAlternate)   // W8.1, next to Add Edit (Ctrl+Option+K is Add Keyframe)
        add(t, ch("a"), [.control, .shift], .splitEditAudio); add(t, ch("v"), [.control, .shift], .splitEditVideo)   // J / L cut
        // Fast cutting (Q-CUT1/2): none of these keys is used in the Premiere set.
        add(g, ch("x"), .shift, .cutOut)
        add(g, ch("."), .shift, .placeOnTop)   // Q-BRL1: b-roll in one key (Resolve F12, which is a media key on a Mac)
        add(t, ch("j"), .option, .jCut); add(t, ch("l"), .option, .lCut)
        add(t, .delete, .control, .closeGapAtPlayhead)
        add(t, ch("q"), .rippleTrimPrevious); add(t, ch("w"), .rippleTrimNext); add(t, ch("e"), .extendEdit)
        add(t, ch("q"), .shift, .rollTrimPrevious); add(t, ch("w"), .shift, .rollTrimNext)
        add(t, ch("q"), .option, .trimPrevious); add(t, ch("w"), .option, .trimNext)
        // Nudge the audio / video half of the nearest cut one frame (J / L cut fine tuning). Opt+Left/Right is Trim 1 frame,
        // so these take Ctrl+Opt (audio) and Ctrl+Opt+Shift (video); Ctrl+Opt+Left/Right was free in both sets.
        add(t, .left, [.control, .option], .nudgeAudioEditLeft); add(t, .right, [.control, .option], .nudgeAudioEditRight)
        add(t, .left, [.control, .option, .shift], .nudgeVideoEditLeft); add(t, .right, [.control, .option, .shift], .nudgeVideoEditRight)
        add(t, ch("t"), .control, .toggleTrimType)
        add(CommandScope.program, ch("t"), .control, .toggleTrimType)   // Trim mode keeps the keys on the Program monitor too
        add(CommandScope.program, ch("t"), .shift, .toggleTrimMode)    // Premiere: Trim Edit
        add(t, ch("t"), .shift, .toggleTrimMode)   // Premiere: Trim Edit (the SQ set moves it to Ctrl+Shift+T)
        add(t, .up, .option, .moveSelectionUp); add(t, .down, .option, .moveSelectionDown)
        // Premiere parity (2026-10): select the next / previous clip on the track, jump to the selected clip's ends, slide by key.
        add(t, .down, .command, .selectNextClip); add(t, .up, .command, .selectPreviousClip)
        add(t, .home, .shift, .goToSelectedClipStart); add(t, .end, .shift, .goToSelectedClipEnd)
        add(t, ch(","), .option, .slideLeft); add(t, ch("."), .option, .slideRight)
        add(t, ch(","), [.option, .shift], .slideLeft5); add(t, ch("."), [.option, .shift], .slideRight5)
        add(t, .left, [.command, .option], .slipLeft); add(t, .right, [.command, .option], .slipRight)
        add(t, .left, [.command, .option, .shift], .slipLeft5); add(t, .right, [.command, .option, .shift], .slipRight5)
        add(t, .delete, .delete); add(t, .delete, .shift, .rippleDelete)
        add(t, ch("s"), .toggleSnapping)
        add(t, ch("g"), .shift, .toggleMagnetic)   // Fast Cut on/off (was Glue): Shift+G was free in both sets
        add(t, ch("e"), .control, .appendToMainTrack); add(t, ch("w"), .control, .insertSpacer)   // Fast Cut verbs
        add(g, ch("v"), .option, .pasteAttached); add(g, ch("."), [.control, .shift], .attachBacktimed)   // Fast Cut: Paste Attached, Place on Top backtimed
        add(t, .up, [.command, .option], .liftOffMainTrack); add(t, .down, [.command, .option], .putOnMainTrack)
        // Fast Cut storylines: Cmd+G is Group, so Create Storyline takes Ctrl+G; Position tool Shift+V (P is Mask).
        add(t, ch("g"), .control, .createStoryline); add(t, .delete, [.control, .shift], .storylineRippleDelete)
        add(t, .left, [.control, .command], .moveClipLeft); add(t, .right, [.control, .command], .moveClipRight)
        add(t, .delete, [.command, .option], .deleteSelectionOnly)
        add(g, ch("v"), .shift, .tool(.position))
        add(t, ch("a"), .command, .selectAll); add(t, ch("a"), [.command, .shift], .deselectAll)
        add(t, ch("d"), .selectClipAtPlayhead)
        add(t, .up, .shift, .previousEditPointAnyTrack); add(t, .down, .shift, .nextEditPointAnyTrack)
        // Nudge the selected clips (Cmd+arrows) or trim the selected edit (Opt+Shift+arrows; Opt+arrows is one frame, see AppController).
        add(t, .left, .command, .nudgeLeft); add(t, .right, .command, .nudgeRight)
        add(t, .left, [.command, .shift], .nudgeLeft10); add(t, .right, [.command, .shift], .nudgeRight10)
        add(t, .left, [.option, .shift], .trimBackward5); add(t, .right, [.option, .shift], .trimForward5)
        add(t, ch("l"), .command, .link)
        add(t, ch("m"), [.control, .shift], .muteTracks); add(t, ch("s"), [.control, .option], .solo); add(t, ch("d"), [.control, .shift], .detachAudio)
        add(t, ch("l"), [.control, .option], .matchLoudness); add(t, ch("d"), [.control, .option], .autoDuck)   // were unbound
        add(t, ch("g"), .audioGain)
        add(t, ch("["), .audioGainDown); add(t, ch("]"), .audioGainUp)
        add(t, ch("["), .shift, .audioGainDown6); add(t, ch("]"), .shift, .audioGainUp6)
        add(t, ch("r"), .command, .speedDuration)
        add(t, ch("r"), [.control, .option], .reverseClip)   // FCP and Resolve ship no key for it; free in both sets
        add(t, ch("f"), .matchFrame); add(t, ch("r"), .shift, .reverseMatchFrame)
        add(t, ch("="), .zoomIn); add(t, ch("-"), .zoomOut); add(t, ch("\\"), .zoomFit)
        // Track heights: modifier combinations only, so plain +/-/\ stay timeline zoom.
        add(t, ch("="), .command, .videoTracksTaller); add(t, ch("-"), .command, .videoTracksShorter)
        add(t, ch("="), .option, .audioTracksTaller); add(t, ch("-"), .option, .audioTracksShorter)
        add(t, ch("="), .control, .allTracksTaller); add(t, ch("-"), .control, .allTracksShorter); add(t, ch("\\"), .control, .toggleFitTracks)
        add(t, ch("="), .shift, .expandAllTracks); add(t, ch("-"), .shift, .minimizeAllTracks)
        // Trim Backward/Forward 1 frame (Premiere: Opt+Left/Right), Ripple Delete is Shift+Delete only.
        add(t, .left, .option, .trimBackward); add(t, .right, .option, .trimForward)
        // Play In to Out (Option+K on the Mac; bound per panel bound per panel).
        for scope in [CommandScope.program, .source, .project, .timeline] { add(scope, ch("k"), .option, .playInToOut) }
        // Go to Timecode (FCP: Ctrl+P) and Toggle Video / Audio Targets (Cmd+9 / Cmd+0): free in both sets.
        add(g, ch("p"), .control, .goToTimecode)
        add(t, ch("9"), .command, .toggleVideoTargets); add(t, ch("0"), .command, .toggleAudioTargets)
        // Add Keyframe (Ctrl+Option+K): the property last used in Controls. Option+K stays Play In to Out (a menu key shows on one item only).
        for scope in [CommandScope.timeline, .effectControls] { add(scope, ch("k"), [.control, .option], .addKeyframe) }
        // Keyframe jumps, Linked Selection and Add Track (audit A8): Ctrl+[ / Ctrl+] step between keyframes of the selected
        // clips; Ctrl+Shift+L toggles Linked Selection; Ctrl+Option+V / A add a video / audio track. All free in both sets.
        add(g, ch("["), .control, .previousKeyframe); add(g, ch("]"), .control, .nextKeyframe)
        add(t, ch("l"), [.control, .shift], .toggleLinkedSelection)
        // Select Layer Above / Below in the open Graphic (Option+] / Option+[; the Final Cut set keeps its trim keys there).
        for scope in [CommandScope.timeline, .program] { add(scope, ch("]"), .option, .selectLayerAbove); add(scope, ch("["), .option, .selectLayerBelow) }
        // Track targeting and lock by key, fades, frame hold, Join Cuts, Paste to Targeted Track (all free in both sets).
        for n in 1...9 {
            let c = ch(Character(String(n)))
            add(t, c, .control, .toggleTrackTarget(.video, n)); add(t, c, [.control, .option], .toggleTrackTarget(.audio, n))
        }
        add(t, ch("k"), [.control, .shift], .toggleLockOfTargets)
        add(t, ch("["), [.control, .option], .videoFadeIn); add(t, ch("]"), [.control, .option], .videoFadeOut)
        add(t, ch("h"), [.control, .shift], .addFrameHold); add(t, ch("j"), [.control, .option], .joinCuts)
        add(t, ch("v"), [.command, .option, .shift], .pasteToTargets)
        add(t, ch("v"), [.control, .option], .addVideoTrack); add(t, ch("a"), [.control, .option], .addAudioTrack)
        add(t, .delete, [.control, .option], .deleteTrack)
        // Replace With Clip (from Source / from Project) and J / L Cut by Offset: three-modifier keys, free in both sets.
        add(t, ch("r"), [.control, .option, .shift], .replaceClipFromSource); add(t, ch("p"), [.control, .option, .shift], .replaceClipFromProject)
        add(t, ch("j"), [.control, .option, .shift], .jCutByOffset); add(t, ch("l"), [.control, .option, .shift], .lCutByOffset)
        // Program monitor
        add(.program, .up, .previousEditPoint); add(.program, .down, .nextEditPoint)
        add(.program, ch("f"), .matchFrame); add(.program, ch("r"), .shift, .reverseMatchFrame)
        // Project panel
        add(.project, .delete, .deleteProjectItems); add(.project, ch("b"), .command, .newBin)
        add(.project, ch("p"), .command, .setPosterFrame); add(.project, ch("p"), .option, .clearPosterFrame)
        add(.project, .pageUp, .command, .projectListView); add(.project, .pageDown, .command, .projectIconView)
        // Premiere uses Shift+[ / Shift+], which the Timeline already has for Audio Gain 6 dB (menu keys must be unique), so Cmd+[ / Cmd+] here.
        add(.project, ch("["), .command, .projectThumbnailSmaller); add(.project, ch("]"), .command, .projectThumbnailLarger)
        add(.project, ch("h"), .shift, .toggleHoverScrub); add(.project, ch("f"), .command, .find)
        return CommandMap(entries: e)
    }()

    /// Sequence Studio's own default set (docs/KEYMAP.md): the Premiere set with the changes the maintainer's workflow asks for.
    /// Written as a diff over Premiere so the two sets cannot drift apart.
    public static let sqDefault: CommandMap = Keymap.apply([
        // Q / E ripple-trim the previous / next edit to the playhead (Premiere: Q / W). Extend Edit moves from E to W.
        KeymapOverride(.timeline, KeyBinding(.char("e")), .rippleTrimNext),
        KeymapOverride(.timeline, KeyBinding(.char("w")), .extendEdit),
        // Shift+T stays Keyword at Playhead (our key since N5); Trim mode moves to Ctrl+Shift+T.
        KeymapOverride(.timeline, KeyBinding(.char("t"), .shift), nil), KeymapOverride(.program, KeyBinding(.char("t"), .shift), nil),
        KeymapOverride(.global, KeyBinding(.char("t"), .shift), .keywordAtPlayhead),
        KeymapOverride(.timeline, KeyBinding(.char("t"), [.control, .shift]), .toggleTrimMode),
        KeymapOverride(.program, KeyBinding(.char("t"), [.control, .shift]), .toggleTrimMode),
    ], to: .premiereDefault)
}

private final class CurrentMapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map = CommandMap.premiereDefault
    func get() -> CommandMap { lock.lock(); defer { lock.unlock() }; return map }
    func set(_ m: CommandMap) { lock.lock(); map = m; lock.unlock() }
}
