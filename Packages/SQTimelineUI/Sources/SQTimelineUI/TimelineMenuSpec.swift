import Foundation
import SQCore

/// What a context-menu item asks the host to do.
public enum TimelineMenuAction: Sendable, Hashable {
    case cut, copy, paste, pasteInsert, pasteAttributes, delete, rippleDelete, unlink, link, nest, group, ungroup, rename
    /// Bundle / Unbundle (Premiere's selection groups) and Edit Original (open the source file in its default app).
    case bundle, unbundle, editOriginal
    /// Reveal in Project: selects the clip's media in the Project panel.
    case revealInProject
    /// Unnest: replaces a nested sequence clip by its content.
    case unnest
    /// Add Clip Marker: a flag on the selected clip at the pointer (the host knows where).
    case addClipMarker
    /// Enable / Disable Clip (Shift+Cmd+E).
    case enable
    /// Use Take for In to Out: this clip's take plays in the In..Out range, the other takes there are off.
    case useTake
    case setToFrameSize, setToFillFrame
    case editCaption, splitCaption, mergeCaptions
    /// Clip > Speed/Duration.
    case speed
    /// Clip > Reverse Clip (toggles reverse playback on the selected clips).
    case reverse
    /// Clip > Audio Options > Audio Gain, and the short-form pause remover.
    case audioGain, removeSilences
    /// Short-form helpers (same commands as the Sequence menu): filler-word remover and zoom alternation over the shots.
    case removeFillerWords, punchInCuts
    /// Clip > Beat Edits > Fit Music to Length… (one audio clip).
    case fitMusicToLength
    /// Show Clip Keyframes > Time Remapping (the speed band on the clip).
    case timeRemapping
    /// Opens the label color submenu (its choices go to `makeMenu`'s `labelHandler`).
    case label
    /// Saves the one selected video clip's Motion/Opacity and effects (keys + easing) as a Library preset.
    case saveAsPreset
    case saveTitleBlock
    /// Text or shape clip -> graphics clip with one layer (G9).
    case makeGraphic
    /// New Color Matte… at the playhead (the dialog is the host's).
    case newColorMatte
    /// Save the selected title layers as a template (slots and animation zones), and the zones toggle (check mark).
    case saveTemplate, toggleZones
    /// Clip > Speed Ramp Presets (same command as the Clip menu entry).
    case speedRamp(SpeedRampPreset, onBeat: Bool)
    /// Adjustment Layers: the layer follows the end of the sequence (check mark when on).
    case extendToSequenceEnd
    /// Empty track space: "Place Sequences as Clips" toggle (check mark when on); the header bar has no button for it.
    case togglePlaceSequencesAsClips
}

public struct TimelineMenuItem: Sendable, Equatable {
    public var action: TimelineMenuAction
    public var title: String
    public var isEnabled: Bool
    /// A separator line goes above this item.
    public var separatorBefore: Bool
    public var key: String
    /// Modifiers of `key` (portable; the Mac reads them as `modifiers`, NSEvent flags).
    public var keyModifiers: KeyModifiers
    /// Shows a check mark (toggle items).
    public var isChecked: Bool = false
    /// Title of the submenu this item lives in (nil = top level). Items of one submenu are listed together.
    public var submenu: String?

    /// The item's key as the menu shows it, taken from the key map (never hard-coded, so a rebinding cannot go stale).
    public init(_ action: TimelineMenuAction, _ title: String, enabled: Bool, separatorBefore: Bool = false,
                command: EditorCommand, map: CommandMap) {
        let eq = map.binding(for: command).flatMap(Self.portableKeyEquivalent)
        self.init(action, title, enabled: enabled, separatorBefore: separatorBefore,
                  key: eq?.key ?? "", keyModifiers: eq?.modifiers ?? [])
    }

    /// Menu key text and modifiers of a binding; nil for keys a menu cannot show as an equivalent.
    public static func portableKeyEquivalent(_ b: KeyBinding) -> (key: String, modifiers: KeyModifiers)? {
        switch b.key {
        case .char(let c): return (String(c), b.modifiers)
        case .delete: return ("\u{8}", b.modifiers)
        case .space: return (" ", b.modifiers)
        default: return nil
        }
    }

    public func separatorBefore(_ on: Bool) -> TimelineMenuItem { var c = self; c.separatorBefore = on; return c }
    public func checked(_ on: Bool) -> TimelineMenuItem { var c = self; c.isChecked = on; return c }

    public init(_ action: TimelineMenuAction, _ title: String, enabled: Bool, separatorBefore: Bool = false,
                key: String = "", keyModifiers: KeyModifiers = .command) {
        self.action = action; self.title = title; self.isEnabled = enabled
        self.separatorBefore = separatorBefore; self.key = key; self.keyModifiers = keyModifiers
    }
}

/// Pure spec of the timeline context menu (portable: the Windows panel builds the same rows) (Premiere order) plus the SQ menu row builder.
public enum TimelineContextMenu {
    /// Items for the current selection. `clipboardHasClips` enables Paste; `groups` (the project's group sequences) enables Ungroup.
    public static func items(timeline: Timeline, selection: Set<Clip.ID>, captionSelection: Set<CaptionItem.ID> = [],
                             clipboardHasClips: Bool, groups: Set<Timeline.ID> = [], map: CommandMap = .current) -> [TimelineMenuItem] {
        let clips = timeline.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        let hasClips = !clips.isEmpty
        let onlyAdjustments = hasClips && clips.allSatisfy(\.isAdjustment)
        let hasGroups = clips.contains { $0.sequence.map(groups.contains) ?? false }
        let hasNested = clips.contains { c in c.angle == nil && c.sequence.map { !groups.contains($0) } == true }
        let hasAny = hasClips || !captionSelection.isEmpty
        let links = Set(clips.compactMap(\.link))
        // Linking needs two or more clips that are not already one group.
        let canLink = clips.count >= 2 && !(links.count == 1 && clips.allSatisfy { $0.link == links.first })
        let linkItem = links.isEmpty
            ? TimelineMenuItem(.link, "Link", enabled: canLink, command: .link, map: map)
            : TimelineMenuItem(.unlink, "Unlink", enabled: true, command: .link, map: map)
        // Generators (text) have no picture size to fit.
        let hasPictures = clips.contains { !$0.isGenerator && $0.kind == .video }
        let hasAudio = clips.contains { $0.kind == .audio }
        let hasCaptionWords = timeline.captionTracks.contains { $0.isVisible && !$0.items.isEmpty }
        let canRetime = clips.contains { Timeline.canRetime($0) }
        let hasVideoMedia = clips.contains { Timeline.canRetime($0) && $0.kind == .video }
        // A bundle needs two units: a linked pair counts once, and a bundle already holding the whole selection is one.
        let units = Set(clips.map { $0.bundle ?? $0.link ?? $0.id })
        let canBundle = units.count >= 2
        let hasOriginal = clips.contains { !$0.isGenerator && $0.sequence == nil }
        // Order (INTERACTION-AUDIT section 5): edit group, object group, destructive last. Keys come from the key map.
        return [
            TimelineMenuItem(.cut, "Cut", enabled: hasClips, command: .cut, map: map),
            TimelineMenuItem(.copy, "Copy", enabled: hasClips, command: .copy, map: map),
            TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, command: .paste, map: map),
            TimelineMenuItem(.pasteInsert, "Paste Insert", enabled: clipboardHasClips, command: .pasteInsert, map: map),
            TimelineMenuItem(.pasteAttributes, "Paste Settings", enabled: clipboardHasClips && hasClips, command: .pasteAttributes, map: map),
            linkItem.separatorBefore(true),
            TimelineMenuItem(.enable, clips.contains { !$0.isEnabled } ? "Enable" : "Disable", enabled: hasClips,
                             command: .enableClip, map: map),
            TimelineMenuItem(.useTake, "Use Take for In to Out", enabled: clips.count == 1 && timeline.inOut.map {
                timeline.canCompTake(of: clips[0].id, range: $0)
            } == true),
            TimelineMenuItem(.group, "Group", enabled: hasClips, separatorBefore: true, command: .group, map: map),
            TimelineMenuItem(.ungroup, "Ungroup", enabled: hasGroups, command: .ungroup, map: map),
            TimelineMenuItem(.bundle, "Bundle", enabled: canBundle, command: .bundle, map: map),
            TimelineMenuItem(.unbundle, "Unbundle", enabled: clips.contains { $0.bundle != nil }, command: .unbundle, map: map),
            TimelineMenuItem(.nest, "Combine…", enabled: hasClips),
            TimelineMenuItem(.unnest, "Unnest", enabled: hasNested),
            TimelineMenuItem(.extendToSequenceEnd, "Extend to Sequence End", enabled: onlyAdjustments,
                             command: .extendToSequenceEnd, map: map).checked(onlyAdjustments && clips.allSatisfy(\.extendsToSequenceEnd)),
            TimelineMenuItem(.speed, "Speed…", enabled: canRetime, command: .speedDuration, map: map),
            TimelineMenuItem(.reverse, "Reverse Clip", enabled: canRetime, command: .reverseClip, map: map),
            TimelineMenuItem(.audioGain, "Audio Gain…", enabled: hasAudio, command: .audioGain, map: map),
            TimelineMenuItem(.removeSilences, "Remove Silences…", enabled: hasAudio),
            // Same rules as the commands: filler words need a visible caption track with words, punch-in two or more shots.
            TimelineMenuItem(.removeFillerWords, "Remove Filler Words", enabled: hasAudio && hasCaptionWords),
            TimelineMenuItem(.fitMusicToLength, "Fit Music to Length…", enabled: clips.count == 1 && hasAudio && !clips[0].isGenerator
                                                                          && clips[0].speed.isNormal && clips[0].speedKeys == nil && !clips[0].reversed),
            TimelineMenuItem(.punchInCuts, "Punch In Cuts…", enabled: punchInShots(timeline: timeline, selection: selection) >= 2),
            TimelineMenuItem(.timeRemapping, "Show Speed Ramp", enabled: hasVideoMedia, command: .toggleTimeRemapping, map: map),
            // The ten presets are the Clip menu's `speedRampPreset` commands; the host runs the same command.
        ] + speedRampItems(clips: clips, hasBeats: !timeline.beatTimes.isEmpty, hasVideoMedia: hasVideoMedia) + [
            TimelineMenuItem(.setToFrameSize, "Fit to Frame", enabled: hasPictures, separatorBefore: true, command: .setToFrameSize, map: map),
            TimelineMenuItem(.setToFillFrame, "Fill Frame", enabled: hasPictures, command: .setToFillFrame, map: map),
            TimelineMenuItem(.label, "Label", enabled: hasClips, separatorBefore: true),
            TimelineMenuItem(.rename, "Rename…", enabled: clips.count == 1),
            TimelineMenuItem(.addClipMarker, "Add Clip Marker", enabled: clips.count == 1 && clips[0].holdFrame == nil),
            TimelineMenuItem(.editOriginal, "Edit Original", enabled: hasOriginal, command: .editOriginal, map: map),
            TimelineMenuItem(.revealInProject, "Reveal in Project", enabled: hasOriginal),
            TimelineMenuItem(.makeGraphic, "Make Graphic", enabled: clips.count == 1 && timeline.makeGraphicBlocker(clips[0]) == nil,
                             separatorBefore: true),
            TimelineMenuItem(.saveAsPreset, "Save as Preset…", enabled: timeline.primaryClip(of: selection)?.kind == .video),
            TimelineMenuItem(.saveTitleBlock, "Save to Library…", enabled: timeline.isMediaFree(selection)),
            TimelineMenuItem(.saveTemplate, "Save as Template…", enabled: timeline.isMediaFree(selection),
                             command: .saveAsTemplate, map: map),
            TimelineMenuItem(.toggleZones, "Keep Intro and Outro When Trimmed", enabled: timeline.isMediaFree(selection) || clips.contains { $0.zones != nil },
                             command: .toggleAnimationZones, map: map).checked(!clips.isEmpty && clips.allSatisfy { $0.zones != nil }),
            TimelineMenuItem(.newColorMatte, "New Color Matte…", enabled: true, separatorBefore: true),
            TimelineMenuItem(.delete, "Delete", enabled: hasAny, separatorBefore: true, command: .delete, map: map),
        ] + (timeline.isFastCut ? [] : [   // Fast Cut: Delete already closes the gap, a second item would do the same
            TimelineMenuItem(.rippleDelete, "Ripple Delete", enabled: hasClips, command: .rippleDelete, map: map),
        ])
    }

    /// Shots Punch In Cuts would work on (EditorSession.punchInCutsClips): two or more selected video clips, else the
    /// enabled clips of the targeted (or first) video track.
    static func punchInShots(timeline: Timeline, selection: Set<Clip.ID>) -> Int {
        let videos = timeline.tracks.filter { $0.kind == .video }
        let selected = videos.flatMap(\.clips).filter { selection.contains($0.id) && !$0.isGenerator }
        if selected.count >= 2 { return selected.count }
        guard let track = videos.first(where: \.isTargeted) ?? videos.first else { return 0 }
        return track.clips.filter { $0.isEnabled && !$0.isGenerator }.count
    }

    /// "Speed Ramp Presets" submenu: the five shapes, then the on-Beat variants (need beat markers on the sequence).
    static func speedRampItems(clips: [Clip], hasBeats: Bool, hasVideoMedia: Bool) -> [TimelineMenuItem] {
        let sub = "Speed Ramp Presets"
        var out: [TimelineMenuItem] = []
        for onBeat in [false, true] {
            for (i, p) in SpeedRampPreset.allCases.enumerated() {
                var it = TimelineMenuItem(.speedRamp(p, onBeat: onBeat), EditorCommand.speedRampPreset(p, onBeat: onBeat).title,
                                          enabled: hasVideoMedia && (!onBeat || hasBeats), separatorBefore: onBeat && i == 0)
                it.submenu = sub
                out.append(it)
            }
        }
        return out
    }

    /// Menu of caption segments (right-click on a caption): edit the text, split at the playhead, merge, delete.
    public static func captionItems(timeline: Timeline, captionSelection: Set<CaptionItem.ID>, playhead: Time,
                                    map: CommandMap = .current) -> [TimelineMenuItem] {
        let underPlayhead = timeline.captions(at: playhead).contains { captionSelection.isEmpty || captionSelection.contains($0.item.id) }
        // Merging needs two or more captions of the same track.
        let tracksOfSelection = Set(timeline.captionTracks.filter { t in t.items.contains { captionSelection.contains($0.id) } }.map(\.id))
        return [
            TimelineMenuItem(.editCaption, "Edit in Text", enabled: captionSelection.count == 1),
            TimelineMenuItem(.splitCaption, "Split Caption at Playhead", enabled: underPlayhead, separatorBefore: true),
            TimelineMenuItem(.mergeCaptions, "Merge Captions", enabled: captionSelection.count >= 2 && tracksOfSelection.count == 1),
            TimelineMenuItem(.delete, "Delete", enabled: !captionSelection.isEmpty, separatorBefore: true, command: .delete, map: map),
        ]
    }

    /// Right-click on a gap between clips: Paste first, Ripple Delete (closes the gap) last.
    public static func gapItems(clipboardHasClips: Bool, map: CommandMap = .current) -> [TimelineMenuItem] {
        [TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, command: .paste, map: map),
         TimelineMenuItem(.pasteInsert, "Paste Insert", enabled: clipboardHasClips, command: .pasteInsert, map: map),
         TimelineMenuItem(.rippleDelete, "Ripple Delete", enabled: true, separatorBefore: true, command: .rippleDelete, map: map)]
    }

    /// Right-click on empty track space.
    public static func emptyItems(clipboardHasClips: Bool, placeSequencesAsClips: Bool = false,
                                  map: CommandMap = .current) -> [TimelineMenuItem] {
        [TimelineMenuItem(.paste, "Paste", enabled: clipboardHasClips, command: .paste, map: map),
         TimelineMenuItem(.pasteInsert, "Paste Insert", enabled: clipboardHasClips, command: .pasteInsert, map: map),
         TimelineMenuItem(.togglePlaceSequencesAsClips, "Place Sequences as Clips", enabled: true, separatorBefore: true, key: "")
            .checked(placeSequencesAsClips)]
    }

    /// Builds the SQ menu rows (own design, no native menu). `handler` runs on the main actor with the chosen action; the label
    /// submenu reports through `labelHandler`. Submenu items are grouped under one parent row in order of first appearance.
    @MainActor
    public static func makeSQItems(items: [TimelineMenuItem], labelHandler: (@MainActor (LabelColor?) -> Void)? = nil,
                                   currentLabel: LabelColor? = nil,
                                   handler: @escaping @MainActor (TimelineMenuAction) -> Void) -> [SQMenuItem] {
        var out: [SQMenuItem] = []
        var hostIndex: [String: Int] = [:]
        func leaf(_ it: TimelineMenuItem) -> SQMenuItem {
            SQMenuItem(title: it.title, shortcut: SQMenuShortcut.glyphs(key: it.key, keyModifiers: it.keyModifiers),
                       isEnabled: it.isEnabled, isChecked: it.isChecked, action: { handler(it.action) })
        }
        for it in items {
            if let sub = it.submenu {
                let i: Int
                if let h = hostIndex[sub] { i = h } else {
                    out.append(SQMenuItem(title: sub, submenu: []))
                    i = out.count - 1; hostIndex[sub] = i
                }
                if it.separatorBefore { out[i].submenu?.append(.separator) }
                out[i].submenu?.append(leaf(it))
                continue
            }
            if it.separatorBefore, !out.isEmpty { out.append(.separator) }
            if it.action == .label {
                var rows: [SQMenuItem] = []
                for (n, c) in ([nil] + LabelColor.allCases.map(Optional.some)).enumerated() {
                    var row = SQMenuItem(title: c?.displayName ?? "Default", isChecked: c != nil && c == currentLabel,
                                         action: { labelHandler?(c) })
                    if let c { row.icon = .swatch(c.rgb) }
                    rows.append(row)
                    if n == 0 { rows.append(.separator) }
                }
                out.append(SQMenuItem(title: it.title, isEnabled: it.isEnabled && labelHandler != nil, submenu: rows))
                continue
            }
            out.append(leaf(it))
        }
        return out
    }
}


/// "Combine…" sheet: one name field, default "Combined NN", OK / Cancel (the sheet itself is per platform).
public enum NestSheet {
    /// First free "Combined NN" among `existing` names.
    public static func defaultName(existing: [String]) -> String {
        let names = Set(existing)
        var n = 1
        while names.contains(String(format: "Combined %02d", n)) { n += 1 }
        return String(format: "Combined %02d", n)
    }

    /// Trimmed name, or the default for a blank field.
    public static func resolvedName(_ input: String, existing: [String]) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultName(existing: existing) : t
    }
}

/// "Save as Preset…" sheet: name plus where the keys land on other clips (Premiere's preset type).
public enum PresetSaveSheet {
    public static let anchorTitles: [(EffectPreset.Anchor, String)] = [
        (.start, "Anchor to In Point"), (.end, "Anchor to Out Point"), (.stretch, "Scale to Clip Length"),
    ]

    /// Trimmed name, or `fallback` for a blank field.
    public static func resolvedName(_ input: String, fallback: String) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }
}

/// "Save to Library…" sheet for a title block: just a name.
public enum TitleBlockSaveSheet {}

/// One entry of the ruler's right-click menu for the In/Out range (board: Mark In, Mark Out, Remove In and Out,
/// keys shown). Keys come from the key map, so a rebinding shows at once.
public struct RulerRangeEntry: Sendable, Equatable {
    public var title: String
    public var command: EditorCommand
    public var isEnabled: Bool
    public var key: String
    public var keyModifiers: KeyModifiers
    public var separatorBefore: Bool

    public static func entries(hasInOut: Bool, map: CommandMap = .current) -> [RulerRangeEntry] {
        func entry(_ title: String, _ c: EditorCommand, enabled: Bool = true, separator: Bool = false) -> RulerRangeEntry {
            let eq = map.binding(for: c).flatMap(TimelineMenuItem.portableKeyEquivalent)
            return RulerRangeEntry(title: title, command: c, isEnabled: enabled, key: eq?.key ?? "", keyModifiers: eq?.modifiers ?? [],
                                   separatorBefore: separator)
        }
        return [entry("Mark In", .markIn), entry("Mark Out", .markOut), entry("Remove In and Out", .clearInOut, enabled: hasInOut)]
    }
}
