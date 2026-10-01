import Foundation
import SSCore

/// Timeline tools (Premiere keys).
public enum TimelineTool: Sendable, Hashable, CaseIterable {
    case selection, trackSelectForward, rippleEdit, rollEdit, slip, slide, razor, hand
    /// Rate Stretch (R): dragging a clip edge changes the speed instead of trimming.
    case rateStretch
    /// Pen, shape and mask are column slots only (scope addition, later); `type` is the Type tool (behaviour: C2).
    case pen, shape, mask, type

    /// False for the slots that only reserve their place in the column.
    public var isAvailable: Bool { self != .pen && self != .shape && self != .mask }

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
        case .pen: "p"
        case .shape: "r"
        case .mask: "o"
        case .type: "t"
        case .rateStretch: "r"
        }
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

/// Tool column state: active tool plus the two toggles that change gesture behaviour.
public struct ToolState: Sendable, Equatable {
    public var tool: TimelineTool = .selection
    /// `S`: clip edges, playhead and markers attract moves and trims.
    public var snapping = true
    /// Linked selection: clicking a clip also selects (and razor also cuts) its linked partners. Option inverts per gesture.
    public var linkedSelection = true
    /// Track Select tool direction: false = forward (A), true = backward (Shift+A).
    public var selectBackward = false
    public init(tool: TimelineTool = .selection, snapping: Bool = true, linkedSelection: Bool = true) {
        self.tool = tool; self.snapping = snapping; self.linkedSelection = linkedSelection
    }
}

/// One clip edge picked with the Selection tool (click on a clip's head or tail).
public struct EdgeRef: Sendable, Hashable {
    public var clip: Clip.ID
    public var edge: ClipEdge
    public init(clip: Clip.ID, edge: ClipEdge) { self.clip = clip; self.edge = edge }
}

/// Selected clip edges. `ripple` (Cmd-click) makes trims ripple; both sides of one edit selected make a rolling edit.
public struct EdgeSelection: Sendable, Equatable {
    public var edges: [EdgeRef]
    public var ripple: Bool
    public init(edges: [EdgeRef], ripple: Bool = false) { self.edges = edges; self.ripple = ripple }
}

/// A selected gap (click on empty space between clips): Delete closes it.
public struct GapSelection: Sendable, Equatable {
    public var track: Track.ID
    public var range: TimeRange
    public init(track: Track.ID, range: TimeRange) { self.track = track; self.range = range }
}

/// One SSCore edit, replayable. A gesture yields an ordered list that is applied to the timeline as a single undo step.
public enum TimelineEdit: Sendable, Equatable {
    case addTrack(Track)
    case move(Clip.ID, to: Time, track: Track.ID?)
    /// Move with linked partners retargeted to their own tracks (mirrored track change).
    case moveGroup(Clip.ID, to: Time, track: Track.ID?, partners: [Clip.ID: Track.ID])
    case moveInsert(Clip.ID, to: Time, track: Track.ID?)
    case lift([Clip.ID])
    case rippleDelete([Clip.ID])
    case trim(Clip.ID, edge: ClipEdge, by: Time)
    case rippleTrim(Clip.ID, edge: ClipEdge, by: Time)
    /// Rate Stretch: the edge moves by `by`, the speed changes to fill the new length.
    case rateStretch(Clip.ID, edge: ClipEdge, by: Time)
    /// Speed/Duration dialog result for these clips (linked partners follow).
    case speed([Clip.ID], SpeedChange)
    case roll(Clip.ID, by: Time)
    case slip(Clip.ID, by: Time)
    case slide(Clip.ID, by: Time)
    case addEdit(at: Time, tracks: [Track.ID]?)
    /// Option-drag: like `moveGroup`, but the originals stay and the copies get the identities in `spec`.
    case copyGroup(Clip.ID, to: Time, track: Track.ID?, partners: [Clip.ID: Track.ID], spec: CopySpec)
    case nudge([Clip.ID], by: Time)
    case closeGap(Track.ID, at: Time)
    case link([Clip.ID])
    case unlink([Clip.ID])
    case moveCaption(CaptionItem.ID, to: Time)
    case trimCaption(CaptionItem.ID, edge: ClipEdge, to: Time)
    case deleteCaption(CaptionItem.ID)

    public func apply(to t: inout Timeline) throws {
        switch self {
        case .addTrack(let track): t.tracks.append(track)
        case let .move(id, start, track): try t.move(id, to: start, track: track)
        case let .moveGroup(id, start, track, partners): try t.move(id, to: start, track: track, retarget: partners)
        case let .moveInsert(id, start, track): try t.moveInsert(id, to: start, track: track)
        case .lift(let ids): try t.lift(ids)
        case .rippleDelete(let ids): _ = try t.rippleDelete(ids)
        case let .trim(id, edge, d): try t.trim(id, edge: edge, by: d)
        case let .rippleTrim(id, edge, d): try t.rippleTrim(id, edge: edge, by: d)
        case let .rateStretch(id, edge, d): try t.rateStretch(id, edge: edge, by: d)
        case let .speed(ids, change): try t.apply(change, to: ids)
        case let .roll(id, d): try t.roll(id, by: d)
        case let .slip(id, d): try t.slip(id, by: d)
        case let .slide(id, d): try t.slide(id, by: d)
        case let .addEdit(at, ids): _ = try t.addEdit(at: at, tracks: ids)
        case let .copyGroup(id, start, track, partners, spec): try t.move(id, to: start, track: track, retarget: partners, copy: spec)
        case let .nudge(ids, d): try t.nudge(Set(ids), by: d)
        case let .closeGap(track, at): try t.closeGap(on: track, at: at)
        case .link(let ids): try t.link(Set(ids))
        case .unlink(let ids): try t.unlink(Set(ids))
        case let .moveCaption(id, start): try t.moveCaption(id, to: start)
        case let .trimCaption(id, edge, time): try t.trimCaption(id, edge: edge, to: time)
        case .deleteCaption(let id): try t.deleteCaption(id)
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
}
