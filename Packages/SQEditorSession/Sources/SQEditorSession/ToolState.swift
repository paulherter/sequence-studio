import Foundation
import SQCore

/// Timeline tools (Premiere keys).
public enum TimelineTool: Sendable, Hashable, CaseIterable {
    case selection, trackSelectForward, rippleEdit, rollEdit, slip, slide, razor, hand
    /// Rate Stretch (R): dragging a clip edge changes the speed instead of trimming.
    case rateStretch
    /// Zoom (Z): click zooms in, Option-click out, drag a box to zoom to it.
    case zoom
    /// Position (Shift+V, Fast Cut): a dragged clip lands where it is dropped, overwrites what is there and leaves a hole
    /// behind instead of rippling (`FastCutEdit.positionMove`). In Normal it behaves like Selection.
    case position
    /// `mask` is the Mask tool (Program monitor: Magic / Pen / Ellipse / Rectangle, `ToolState.maskMode`); `type` is the
    /// Create slot (Program monitor: Text / Rectangle / Ellipse / Line / Draw, `ToolState.createMode`; Text is the Type
    /// tool, behavior: C2).
    case mask, type

    /// What the timeline does with this tool: the tools that only act in the monitor (Create, Mask) behave
    /// exactly like Selection there (select, move, trim, marquee, scrub, cursor). The active tool itself does not change.
    public var effectiveTimelineTool: TimelineTool {
        switch self {
        case .mask, .type: .selection
        default: self
        }
    }

    public init?(key: Character) {
        switch Character(key.lowercased()) {
        case "v": self = .selection
        case "a": self = .trackSelectForward
        case "b": self = .rippleEdit
        case "n": self = .rollEdit
        case "y": self = .slip
        case "u": self = .slide
        case "c": self = .razor
        case "h": self = .hand
        case "t": self = .type
        case "r": self = .rateStretch
        case "z": self = .zoom
        case "p": self = .mask
        default: return nil
        }
    }

    public var key: Character {
        switch self {
        case .selection: "v"
        case .trackSelectForward: "a"
        case .rippleEdit: "b"
        case .rollEdit: "n"
        case .slip: "y"
        case .slide: "u"
        case .razor: "c"
        case .hand: "h"
        case .mask: "p"          // O is Mark Out; the Mask tool takes over the pen slot's P (decision 2026-10-05)
        case .type: "t"
        case .rateStretch: "r"
        case .zoom: "z"
        case .position: "v"      // Shift+V: `init(key:)` keeps V for Selection, the key map binds the shifted key
        }
    }
}

/// What the Mask tool makes with a click on the Program monitor.
public enum MaskToolMode: String, Sendable, Hashable, CaseIterable {
    /// Hover highlights the object under the pointer; click picks it (another click adds, Option-click removes, Shift-click
    /// starts a new mask); Track follows the pick.
    case magic
    /// Each click adds a corner point to the active path mask (Shift-click starts a new one).
    case pen
    case ellipse, rectangle

    public var title: String {
        switch self { case .magic: "Magic"; case .pen: "Pen"; case .ellipse: "Ellipse"; case .rectangle: "Rectangle" }
    }
    /// The shape a drag draws in this mode (Ellipse / Rectangle); nil for Magic and Pen.
    public var shapeKind: MaskShapeKind? {
        switch self { case .ellipse: .ellipse; case .rectangle: .rectangle; case .magic, .pen: nil }
    }
    public var symbol: String {
        switch self {
        case .magic: "toolMask"
        case .pen: "pen"
        case .ellipse: "circleDashed"
        case .rectangle: "squareDashed"
        }
    }
}

/// What the Create tool makes with a drag on the Program monitor: an item of a Graphic clip.
public enum CreateToolMode: String, Sendable, Hashable, CaseIterable {
    /// Click places text and types into it (the Type tool).
    case text
    case rectangle, ellipse, line
    /// A freehand stroke, smoothed on release.
    case draw

    public var title: String {
        switch self { case .text: "Text"; case .rectangle: "Rectangle"; case .ellipse: "Ellipse"; case .line: "Line"; case .draw: "Draw" }
    }
    public var symbol: String {
        switch self {
        case .text: "text"
        case .rectangle: "shapeRectangle"
        case .ellipse: "shapeEllipse"
        case .line: "shapeLine"
        case .draw: "draw"
        }
    }
    /// The key-map tool that selects this mode.
    public var editorTool: EditorTool {
        switch self { case .text: .type; case .rectangle: .rectangle; case .ellipse: .ellipse; case .line: .line; case .draw: .draw }
    }
    public init?(editorTool: EditorTool) {
        guard let m = Self.allCases.first(where: { $0.editorTool == editorTool }) else { return nil }
        self = m
    }
    /// The shape a drag makes in this mode; nil for Text and Draw.
    public var shapeKind: ShapeKind? {
        switch self { case .rectangle: .rectangle; case .ellipse: .ellipse; case .line: .line; case .text, .draw: nil }
    }
}

public struct GestureModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = GestureModifiers(rawValue: 1)
    public static let command = GestureModifiers(rawValue: 2)
    public static let option = GestureModifiers(rawValue: 4)
    public static let control = GestureModifiers(rawValue: 8)
}

/// Tool column state: active tool plus the two toggles that change gesture behavior.
public struct ToolState: Sendable, Equatable {
    public var tool: TimelineTool = .selection
    /// `tool` as the timeline sees it (`TimelineTool.effectiveTimelineTool`).
    public var timelineTool: TimelineTool { tool.effectiveTimelineTool }
    /// `S`: clip edges, playhead and markers attract moves and trims.
    public var snapping = true
    /// Linked selection: clicking a clip also selects (and razor also cuts) its linked partners. Option inverts per gesture.
    public var linkedSelection = true
    /// Track Select tool direction: false = forward (A), true = backward (Shift+A).
    public var selectBackward = false
    /// Slip tool variant (long-press menu of the Slip slot): the clip's keyframes stay at their timeline position instead
    /// of moving with the content.
    public var slipKeyframesStay = false
    /// Fast Cut "keep attached" override (hold ` during a delete or drag): the attached clips of the main-track clips the
    /// gesture moves or removes stay on their frame instead of traveling (`TimelineEdit.fastCut(keepAttached:)`).
    public var keepAttached = false
    /// Sequences dropped or inserted land as their own clips instead of one combined clip (Premiere: "insert and overwrite
    /// sequences as nests or individual clips"). Off = one combined clip. App setting `sq.placeSequencesAsClips`.
    public var placeSequencesAsClips = false
    /// Mask tool mode (long-press menu of the Mask slot); Magic by default.
    public var maskMode: MaskToolMode = .magic
    /// Create tool mode (long-press menu of the Create slot); Text by default.
    public var createMode: CreateToolMode = .text
    public init(tool: TimelineTool = .selection, snapping: Bool = true, linkedSelection: Bool = true) {
        self.tool = tool; self.snapping = snapping; self.linkedSelection = linkedSelection
    }
}

/// Snapping and Linked Selection are view state: they survive a relaunch per Mac (AUDIT A7), never enter undo or the
/// project. Both default to on.
extension ToolState {
    public static let snappingDefaultsKey = "sq.timeline.snapping"
    public static let linkedSelectionDefaultsKey = "sq.timeline.linkedSelection"

    /// Takes the two remembered toggles (a missing value keeps the default on).
    public mutating func applyStoredToggles(_ defaults: UserDefaults = .standard) {
        snapping = defaults.object(forKey: Self.snappingDefaultsKey) as? Bool ?? true
        linkedSelection = defaults.object(forKey: Self.linkedSelectionDefaultsKey) as? Bool ?? true
    }

    /// Remembers the two toggles for the next launch.
    public func storeToggles(_ defaults: UserDefaults = .standard) {
        defaults.set(snapping, forKey: Self.snappingDefaultsKey)
        defaults.set(linkedSelection, forKey: Self.linkedSelectionDefaultsKey)
    }
}

/// One clip edge picked with the Selection tool (click on a clip's head or tail).
public struct EdgeRef: Sendable, Hashable {
    public var clip: Clip.ID
    public var edge: ClipEdge
    public init(clip: Clip.ID, edge: ClipEdge) { self.clip = clip; self.edge = edge }
}

/// Selected clip edges. `ripple` (Cmd-click) makes trims ripple; both sides of one edit selected make a rolling edit.
/// `linked` false (Option-click, or Linked Selection off): only these edges' clips trim, linked partners stay.
public struct EdgeSelection: Sendable, Equatable {
    public var edges: [EdgeRef]
    public var ripple: Bool
    public var linked: Bool
    public init(edges: [EdgeRef], ripple: Bool = false, linked: Bool = true) {
        self.edges = edges; self.ripple = ripple; self.linked = linked
    }
    /// Clips an unlinked edge edit is limited to (`TimelineEdit.scoped`); nil when linked partners follow.
    public var scope: Set<Clip.ID>? { linked ? nil : Set(edges.map(\.clip)) }
}

/// A selected gap (click on empty space between clips): Delete closes it.
public struct GapSelection: Sendable, Equatable {
    public var track: Track.ID
    public var range: TimeRange
    public init(track: Track.ID, range: TimeRange) { self.track = track; self.range = range }
}

/// One SQCore edit, replayable. A gesture yields an ordered list that is applied to the timeline as a single undo step.
public enum TimelineEdit: Sendable, Equatable {
    case addTrack(Track)
    case move(Clip.ID, to: Time, track: Track.ID?)
    /// Move with linked partners retargeted to their own tracks (mirrored track change).
    case moveGroup(Clip.ID, to: Time, track: Track.ID?, partners: [Clip.ID: Track.ID])
    /// Cmd+Option-drag "rearrange": lifts the clip, closes its old gap, inserts it at the drop.
    case moveInsert(Clip.ID, to: Time, track: Track.ID?)
    /// Cmd-drag: insert at the drop, the old place stays as a gap.
    case insertMove(Clip.ID, to: Time, track: Track.ID?)
    case lift([Clip.ID])
    case rippleDelete([Clip.ID])
    case trim(Clip.ID, edge: ClipEdge, by: Time)
    case rippleTrim(Clip.ID, edge: ClipEdge, by: Time)
    /// Rate Stretch: the edge moves by `by`, the speed changes to fill the new length.
    case rateStretch(Clip.ID, edge: ClipEdge, by: Time)
    /// Speed/Duration dialog result for these clips (linked partners follow).
    case speed([Clip.ID], SpeedChange)
    case roll(Clip.ID, by: Time)
    /// Opt-drag on a cut between linked A/V clips: only the audio edit moves to `to` (split edit, a roll).
    case splitEditAudio(cut: Time, to: Time)
    /// Extend Edit (E) on a selected edit: rolls it to `to` with the linked partners of both sides, limited to one frame.
    case extendEdit(Clip.ID, edge: ClipEdge, to: Time)
    case slip(Clip.ID, by: Time, keyframes: SlipKeyframes = .followContent)
    case slide(Clip.ID, by: Time)
    case addEdit(at: Time, tracks: [Track.ID]?)
    /// Option-drag: like `moveGroup`, but the originals stay and the copies get the identities in `spec`.
    case copyGroup(Clip.ID, to: Time, track: Track.ID?, partners: [Clip.ID: Track.ID], spec: CopySpec)
    /// Cmd+Option-drag: insert a copy at the drop time, the original stays.
    case insertCopy(Clip.ID, to: Time, track: Track.ID?, spec: CopySpec)
    case nudge([Clip.ID], by: Time)
    case closeGap(Track.ID, at: Time)
    case link([Clip.ID])
    case unlink([Clip.ID])
    case moveCaption(CaptionItem.ID, to: Time)
    case trimCaption(CaptionItem.ID, edge: ClipEdge, to: Time)
    case deleteCaption(CaptionItem.ID)
    /// Drag of a word edge on the caption track. `rolling`: a neighbor touching that edge moves with it.
    case retimeCaptionWord(CaptionItem.ID, index: Int, edge: ClipEdge, to: Time, rolling: Bool)
    /// Runs `edits` on exactly these clips: linked partners outside the set stay put (Premiere "selected unlinked",
    /// `Timeline.editing(only:)`).
    case only([Clip.ID], [TimelineEdit])
    /// A Fast Cut verb (`FastCutEdit`), built by `TimelineEdit.fastCut(_:in:keepAttached:)` in a Fast Cut sequence.
    indirect case fastCut(FastCutEdit)

    /// `edits` limited to `ids` when some linked partner of `ids` is not in `ids` (wrapped in `.only`); otherwise
    /// unchanged. `ids` nil or no held-back partner: the edits follow links as usual.
    public static func scoped(_ edits: [TimelineEdit], to ids: Set<Clip.ID>?, in t: Timeline) -> [TimelineEdit] {
        guard let ids, !edits.isEmpty, !t.heldBackPartners(of: ids).isEmpty else { return edits }
        return [.only(ids.sorted { $0.uuidString < $1.uuidString }, edits)]
    }

    public func apply(to t: inout Timeline) throws {
        switch self {
        case .addTrack(let track): t.tracks.append(track)
        case let .move(id, start, track): try t.move(id, to: start, track: track)
        case let .moveGroup(id, start, track, partners): try t.move(id, to: start, track: track, retarget: partners)
        case let .moveInsert(id, start, track): try t.moveInsert(id, to: start, track: track)
        case let .insertMove(id, start, track): try t.insertMove(id, to: start, track: track)
        case .lift(let ids): try t.lift(ids)
        case .rippleDelete(let ids): _ = try t.rippleDelete(ids)
        case let .trim(id, edge, d): try t.trim(id, edge: edge, by: d)
        case let .rippleTrim(id, edge, d): try t.rippleTrim(id, edge: edge, by: d)
        case let .rateStretch(id, edge, d): try t.rateStretch(id, edge: edge, by: d)
        case let .speed(ids, change): try t.apply(change, to: ids)
        case let .roll(id, d): try t.roll(id, by: d)
        case let .splitEditAudio(cut, to): try t.splitEdit(cut: cut, side: .audio, to: to)
        case let .extendEdit(id, edge, time): try t.extendEdit(id, edge: edge, to: time)
        case let .slip(id, d, keys): try t.slip(id, by: d, keyframes: keys)
        case let .slide(id, d): try t.slide(id, by: d)
        case let .addEdit(at, ids): _ = try t.addEdit(at: at, tracks: ids)
        case let .copyGroup(id, start, track, partners, spec): try t.move(id, to: start, track: track, retarget: partners, copy: spec)
        case let .insertCopy(id, start, track, spec): try t.insertCopy(id, to: start, track: track, copy: spec)
        case let .nudge(ids, d): try t.nudge(Set(ids), by: d)
        case let .closeGap(track, at): try t.closeGap(on: track, at: at)
        case .link(let ids): try t.link(Set(ids))
        case .unlink(let ids): try t.unlink(Set(ids))
        case let .moveCaption(id, start): try t.moveCaption(id, to: start)
        case let .trimCaption(id, edge, time): try t.trimCaption(id, edge: edge, to: time)
        case .deleteCaption(let id): try t.deleteCaption(id)
        case let .retimeCaptionWord(id, index, edge, time, rolling):
            _ = try t.retimeCaptionWord(id, index: index, edge: edge, to: time, rolling: rolling)
        case let .only(ids, edits): try t.editing(only: Set(ids)) { w in for e in edits { try e.apply(to: &w) } }
        case .fastCut(let e): try e.apply(to: &t)
        }
    }

    /// Applies all edits to a copy (the input is never changed; throws when one edit fails).
    public static func apply(_ edits: [TimelineEdit], to t: Timeline) throws -> Timeline {
        var out = t
        for e in edits { try e.apply(to: &out) }
        return out
    }
}

/// A finished gesture: the edit list, the resulting timeline and ONE undo step name.
public struct TimelineCommit: Sendable, Equatable {
    public var timeline: Timeline
    public var edits: [TimelineEdit]
    public var undoName: String
    public var selection: Set<Clip.ID>
    /// Selected caption items after the gesture.
    public var captionSelection: Set<CaptionItem.ID> = []

    public init(timeline: Timeline, edits: [TimelineEdit], undoName: String, selection: Set<Clip.ID>,
                captionSelection: Set<CaptionItem.ID> = []) {
        self.timeline = timeline; self.edits = edits; self.undoName = undoName; self.selection = selection
        self.captionSelection = captionSelection
    }
}

/// Which beat markers snap is a per-Mac view preference (`sq.timeline.beatSnapLevel`), never part of a project.
extension BeatSnapLevel {
    public static let defaultsKey = "sq.timeline.beatSnapLevel"

    public static func stored(_ defaults: UserDefaults = .standard) -> BeatSnapLevel {
        defaults.string(forKey: defaultsKey).flatMap(BeatSnapLevel.init(rawValue:)) ?? .everyBeat
    }

    public func store(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

extension ToolState {
    /// The Tools menu and the tool commands: the key-map tool as the timeline's tool state (the AppKit app and the shell
    /// share it). The Slip slot's variant is off again (Y = plain slip), the Create slot takes the mode of its key.
    @discardableResult
    public mutating func select(_ t: EditorTool) -> Bool {
        let mapped: TimelineTool
        switch t {
        case .selection: mapped = .selection
        case .trackForward, .trackBackward: mapped = .trackSelectForward
        case .ripple: mapped = .rippleEdit
        case .rolling: mapped = .rollEdit
        case .slip: mapped = .slip
        case .slide: mapped = .slide
        case .razor: mapped = .razor
        case .hand: mapped = .hand
        case .type, .rectangle, .ellipse, .line, .draw: mapped = .type
        case .rateStretch: mapped = .rateStretch
        case .zoom: mapped = .zoom
        case .mask: mapped = .mask
        case .position: mapped = .position
        }
        selectBackward = t == .trackBackward
        if t == .slip { slipKeyframesStay = false }
        tool = mapped
        if mapped == .type, let mode = CreateToolMode(editorTool: t) { createMode = mode }
        return true
    }

    /// Tools > Slip Tool (Keyframes Stay): the slip tool with the variant on.
    @discardableResult
    public mutating func selectSlipKeyframesStay() -> Bool {
        select(.slip)
        slipKeyframesStay = true
        return true
    }
}
