import Foundation
import SQCore

/// Where Apply Video Transition / Apply Audio Transition / Apply Default Transitions to Selection put transitions.
public enum TransitionTargets {
    public struct Target: Sendable, Hashable {
        public var track: Track.ID
        public var point: TransitionPoint
    }

    /// Premiere's order of precedence: the selected edit(s), else the edges of the selected clips, else the edit nearest to the
    /// playhead on every targeted track. Only tracks of `kinds` (video / audio) that are not locked take part.
    /// `clipEdgesOnly` (element transitions, FB-G): a clip edge at a cut stays that clip's head / tail.
    public static func resolve(in t: Timeline, kinds: Set<TrackKind>, edges: EdgeSelection?, selection: Set<Clip.ID>,
                               playhead: Time, clipEdgesOnly: Bool = false) -> [Target] {
        var out: [Target] = []
        var seen = Set<Target>()
        func add(_ target: Target) { if seen.insert(target).inserted { out.append(target) } }

        func point(for clip: Clip.ID, edge: ClipEdge, on track: Track) -> TransitionPoint? {
            guard let i = track.clips.firstIndex(where: { $0.id == clip }) else { return nil }
            if clipEdgesOnly { return edge == .head ? .head(clip) : .tail(clip) }
            let cs = track.clips
            switch edge {
            case .head:
                if i > 0, cs[i - 1].timeline.end == cs[i].start { return .cut(outgoing: cs[i - 1].id, incoming: clip) }
                return .head(clip)
            case .tail:
                if i + 1 < cs.count, cs[i].timeline.end == cs[i + 1].start { return .cut(outgoing: clip, incoming: cs[i + 1].id) }
                return .tail(clip)
            }
        }
        func usable(_ track: Track) -> Bool { kinds.contains(track.kind) && !track.isLocked }
        func owner(of clip: Clip.ID) -> Track? { t.tracks.first { $0.clips.contains { $0.id == clip } } }

        if let edges, !edges.edges.isEmpty {
            for ref in edges.edges {
                guard let track = owner(of: ref.clip), usable(track), let p = point(for: ref.clip, edge: ref.edge, on: track) else { continue }
                add(Target(track: track.id, point: p))
            }
            return out
        }
        if !selection.isEmpty {
            for track in t.tracks where usable(track) {
                for c in track.clips where selection.contains(c.id) {
                    for edge in [ClipEdge.head, .tail] {
                        if let p = point(for: c.id, edge: edge, on: track) { add(Target(track: track.id, point: p)) }
                    }
                }
            }
            return out
        }
        for track in t.tracks where usable(track) && track.isTargeted {
            guard var p = t.transitionPoint(near: playhead, on: track.id) else { continue }
            if clipEdgesOnly, case let .cut(_, incoming) = p { p = .head(incoming) }
            add(Target(track: track.id, point: p))
        }
        return out
    }
}

/// Default transition lengths (Preferences). Premiere's initial default is one second for both kinds.
public struct TransitionDefaults: Sendable, Equatable {
    /// Video: frames of the sequence; 0 = one second.
    public var videoFrames: Int
    /// Audio: seconds.
    public var audioSeconds: Double

    public static let standard = TransitionDefaults(videoFrames: 0, audioSeconds: 1)

    public init(videoFrames: Int = 0, audioSeconds: Double = 1) { self.videoFrames = videoFrames; self.audioSeconds = audioSeconds }

    public enum Key {
        public static let video = "settings.videoTransitionFrames"
        public static let audio = "settings.audioTransitionSeconds"
    }

    public static func load(from d: UserDefaults = .standard) -> TransitionDefaults {
        var s = TransitionDefaults.standard
        if d.object(forKey: Key.video) != nil { let v = d.integer(forKey: Key.video); if v >= 0, v <= 10_000 { s.videoFrames = v } }
        if d.object(forKey: Key.audio) != nil {
            let v = d.double(forKey: Key.audio)
            if v.isFinite, v > 0, v <= 600 { s.audioSeconds = v }
        }
        return s
    }

    public func save(to d: UserDefaults = .standard) {
        d.set(videoFrames, forKey: Key.video)
        d.set(audioSeconds, forKey: Key.audio)
    }

    /// Whole frames of the sequence.
    public func duration(for kind: TrackKind, frameDuration fd: Time) -> Time {
        switch kind {
        case .video:
            return videoFrames > 0 ? fd * Int64(videoFrames) : Timeline.defaultTransitionDuration(frameDuration: fd)
        case .audio:
            let frames = max(1, Int64((audioSeconds * Double(fd.timescale) / Double(fd.value)).rounded()))
            return fd * frames
        }
    }
}
