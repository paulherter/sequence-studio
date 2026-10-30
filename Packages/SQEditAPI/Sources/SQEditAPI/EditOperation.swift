import Foundation
import SQCore

/// One edit an agent asks for. JSON: `{"op": "<name>", ...fields}`; times are `{"value": Int, "timescale": Int}` (never
/// seconds as a double). Every case maps onto one existing SQCore `Timeline` edit, the same ones the timeline gestures
/// replay (`TimelineEdit`), so the API adds no edit logic of its own.
public enum EditOperation: Sendable, Equatable {
    /// Add Edit (Cmd+K) at `at`; `tracks` nil = every unlocked track.
    case razor(at: Time, tracks: [Track.ID]?)
    case rippleDelete(clips: [Clip.ID])
    /// Delete leaving a gap.
    case lift(clips: [Clip.ID])
    /// Removes a range and closes the gap; `tracks` nil = every unlocked track.
    case extract(range: TimeRange, tracks: [Track.ID]?)
    /// Removes a range and leaves a gap; `tracks` nil = every unlocked track.
    case liftRange(range: TimeRange, tracks: [Track.ID]?)
    case trim(clip: Clip.ID, edge: ClipEdge, by: Time)
    case rippleTrim(clip: Clip.ID, edge: ClipEdge, by: Time)
    /// Moves a clip (with its linked partners) to `to`, optionally onto another track.
    case move(clip: Clip.ID, to: Time, track: Track.ID?)
    case slip(clip: Clip.ID, by: Time)
    case slide(clip: Clip.ID, by: Time)
    /// Rolls the cut at the clip's tail by `by`.
    case roll(clip: Clip.ID, by: Time)
    /// Clip > Enable on these clips and their linked partners.
    case toggleEnabled(clips: [Clip.ID])
    case addMarker(at: Time, name: String)
    /// Source settings > Pixel Aspect of a media item (all its clips; nil = what the file says). One ratio num/den
    /// within 1:4 ... 4:1. A media setting, not a timeline edit: it shows in `pixelAspectChanges` of the diff.
    case setPixelAspect(media: MediaRef.ID, aspect: PixelAspect?)

    public var name: String {
        switch self {
        case .razor: "razor"
        case .rippleDelete: "rippleDelete"
        case .lift: "lift"
        case .extract: "extract"
        case .liftRange: "liftRange"
        case .trim: "trim"
        case .rippleTrim: "rippleTrim"
        case .move: "move"
        case .slip: "slip"
        case .slide: "slide"
        case .roll: "roll"
        case .toggleEnabled: "toggleEnabled"
        case .addMarker: "addMarker"
        case .setPixelAspect: "setPixelAspect"
        }
    }

    /// Every time the operation carries (validated before any arithmetic).
    public var times: [Time] {
        switch self {
        case let .razor(at, _), let .addMarker(at, _): [at]
        case .rippleDelete, .lift, .toggleEnabled, .setPixelAspect: []
        case let .extract(r, _), let .liftRange(r, _): [r.start, r.duration]
        case let .trim(_, _, by), let .rippleTrim(_, _, by), let .slip(_, by), let .slide(_, by), let .roll(_, by): [by]
        case let .move(_, to, _): [to]
        }
    }

    public static let allNames = ["razor", "rippleDelete", "lift", "extract", "liftRange", "trim", "rippleTrim", "move",
                                  "slip", "slide", "roll", "toggleEnabled", "addMarker", "setPixelAspect"]
}

/// `head` / `tail` on the wire.
private enum WireEdge: String, Codable {
    case head, tail
    init(_ e: ClipEdge) { self = e == .head ? .head : .tail }
    var edge: ClipEdge { self == .head ? .head : .tail }
}

/// Rejects JSON object keys outside `allowed`.
enum StrictKeys {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func check(_ decoder: Decoder, allowed: Set<String>, what: String) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let unknown = c.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let list = unknown.map { "'\($0)'" }.joined(separator: ", ")
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "unknown key\(unknown.count > 1 ? "s" : "") \(list) in \(what); known: \(allowed.sorted().joined(separator: ", "))"))
        }
    }
}

extension EditOperation: Codable {
    private enum K: String, CodingKey { case op, at, tracks, clips, clip, range, edge, by, to, track, name, media, aspect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let op = try c.decode(String.self, forKey: .op)
        // An unknown key is almost always a typo ("clips" on a razor widens it to every track): refuse, never ignore.
        let allowed: Set<String>? = switch op {
        case "razor": ["op", "at", "tracks"]
        case "rippleDelete", "lift", "toggleEnabled": ["op", "clips"]
        case "extract", "liftRange": ["op", "range", "tracks"]
        case "trim", "rippleTrim": ["op", "clip", "edge", "by"]
        case "move": ["op", "clip", "to", "track"]
        case "slip", "slide", "roll": ["op", "clip", "by"]
        case "addMarker": ["op", "at", "name"]
        case "setPixelAspect": ["op", "media", "aspect"]
        default: nil
        }
        if let allowed { try StrictKeys.check(decoder, allowed: allowed, what: "operation '\(op)'") }
        func time(_ k: K) throws -> Time { try c.decode(WireTime.self, forKey: k).time }
        func range() throws -> TimeRange { try c.decode(WireRange.self, forKey: .range).range }
        func clip() throws -> Clip.ID { try c.decode(UUID.self, forKey: .clip) }
        func clips() throws -> [Clip.ID] { try c.decode([UUID].self, forKey: .clips) }
        func tracks() throws -> [Track.ID]? { try c.decodeIfPresent([UUID].self, forKey: .tracks) }
        func edge() throws -> ClipEdge { try c.decode(WireEdge.self, forKey: .edge).edge }
        switch op {
        case "razor": self = .razor(at: try time(.at), tracks: try tracks())
        case "rippleDelete": self = .rippleDelete(clips: try clips())
        case "lift": self = .lift(clips: try clips())
        case "extract": self = .extract(range: try range(), tracks: try tracks())
        case "liftRange": self = .liftRange(range: try range(), tracks: try tracks())
        case "trim": self = .trim(clip: try clip(), edge: try edge(), by: try time(.by))
        case "rippleTrim": self = .rippleTrim(clip: try clip(), edge: try edge(), by: try time(.by))
        case "move": self = .move(clip: try clip(), to: try time(.to), track: try c.decodeIfPresent(UUID.self, forKey: .track))
        case "slip": self = .slip(clip: try clip(), by: try time(.by))
        case "slide": self = .slide(clip: try clip(), by: try time(.by))
        case "roll": self = .roll(clip: try clip(), by: try time(.by))
        case "toggleEnabled": self = .toggleEnabled(clips: try clips())
        case "addMarker": self = .addMarker(at: try time(.at), name: try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        case "setPixelAspect":
            self = .setPixelAspect(media: try c.decode(UUID.self, forKey: .media), aspect: try c.decodeIfPresent(PixelAspect.self, forKey: .aspect))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c,
                debugDescription: "unknown op '\(op)'; known: \(EditOperation.allNames.joined(separator: ", "))")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .op)
        switch self {
        case let .razor(at, tracks): try c.encode(at, forKey: .at); try c.encodeIfPresent(tracks, forKey: .tracks)
        case let .rippleDelete(ids), let .lift(ids), let .toggleEnabled(ids): try c.encode(ids, forKey: .clips)
        case let .extract(r, tracks), let .liftRange(r, tracks):
            try c.encode(r, forKey: .range); try c.encodeIfPresent(tracks, forKey: .tracks)
        case let .trim(id, e, by), let .rippleTrim(id, e, by):
            try c.encode(id, forKey: .clip); try c.encode(WireEdge(e), forKey: .edge); try c.encode(by, forKey: .by)
        case let .move(id, to, track):
            try c.encode(id, forKey: .clip); try c.encode(to, forKey: .to); try c.encodeIfPresent(track, forKey: .track)
        case let .slip(id, by), let .slide(id, by), let .roll(id, by):
            try c.encode(id, forKey: .clip); try c.encode(by, forKey: .by)
        case let .addMarker(at, name): try c.encode(at, forKey: .at); try c.encode(name, forKey: .name)
        case let .setPixelAspect(media, aspect): try c.encode(media, forKey: .media); try c.encodeIfPresent(aspect, forKey: .aspect)
        }
    }
}
