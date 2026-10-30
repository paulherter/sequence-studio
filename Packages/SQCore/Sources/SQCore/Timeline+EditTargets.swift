import Foundation

// W6.1 EditTargetRules. Documented in docs/ARCHITECTURE.md, "Edit target rule".
//
// One track-targeting rule for the playhead commands Cmd+K (add edit), Up/Down (edit navigation) and X (mark clip):
//   1. the tracks holding a selected clip, if any selected clip is in this sequence;
//   2. else the targeted tracks, if any track is targeted;
//   3. else all tracks.
// Locked tracks stay in the scope: reading commands (Up/Down, X) use them; Cmd+K skips them and throws
// `.trackLocked` only when every track in the scope is locked. Q/W are not covered (they trim all unlocked tracks).
//
// Ripple clamps never limit silently: the `...Outcome` variants return `.clamped(reason)` when clips on another
// track kept the edit short of what was asked.

/// Why an edit did less than asked.
public enum ClampReason: Sendable, Hashable {
    /// Clips on this track left too little room; the edit ran `shortfall` shorter than asked.
    case clipOnTrack(Track.ID, shortfall: Time)
}

/// Result of an edit that can be limited.
public enum EditOutcome: Sendable, Hashable {
    case applied
    case clamped(ClampReason)

    public var clampReason: ClampReason? {
        if case .clamped(let r) = self { return r }
        return nil
    }
}

/// Which tracks a playhead command acts on, and which tier of the rule picked them.
public struct EditTargets: Sendable, Hashable {
    public enum Source: Sendable, Hashable { case selection, targeted, all }
    public var source: Source
    /// In timeline order; locked tracks included.
    public var tracks: [Track.ID]
}

/// Internal clamp report of a ripple: the limiting track (index) and how much less the edit did.
struct RippleClamp {
    var track: Int
    var shortfall: Time
}

extension Timeline {
    // MARK: The rule

    /// The edit target rule: tracks of the selected clips, else the targeted tracks, else all tracks.
    public func editTargets(selection: Set<Clip.ID>) -> EditTargets {
        let selected = tracks.filter { tr in tr.clips.contains { selection.contains($0.id) } }.map(\.id)
        if !selected.isEmpty { return EditTargets(source: .selection, tracks: selected) }
        let targeted = tracks.filter(\.isTargeted).map(\.id)
        if !targeted.isEmpty { return EditTargets(source: .targeted, tracks: targeted) }
        return EditTargets(source: .all, tracks: tracks.map(\.id))
    }

    /// Cmd+K: cuts at `t` on the tracks the rule picks, skipping locked ones. Throws `.trackLocked` when every track in
    /// the scope is locked. Returns the ids of the new right halves.
    @discardableResult
    public mutating func addEdit(at t: Time, selection: Set<Clip.ID>) throws -> [Clip.ID] {
        let scope = editTargets(selection: selection).tracks
        let open = scope.filter { id in track(id).map { !$0.isLocked } ?? false }
        if open.isEmpty && !scope.isEmpty { throw EditError.trackLocked }
        return try addEdit(at: t, tracks: open)
    }

    /// Up/Down: sorted, unique clip starts and ends on the tracks the rule picks.
    public func editPoints(selection: Set<Clip.ID>) -> [Time] {
        let scope = Set(editTargets(selection: selection).tracks)
        var set = Set<Time>()
        for tr in tracks where scope.contains(tr.id) {
            for c in tr.clips { set.insert(c.start); set.insert(c.timeline.end) }
        }
        return set.sorted()
    }

    /// X: In/Out around the clips under `t` on the tracks the rule picks; nil when none is under `t`.
    public func markClipRange(at t: Time, selection: Set<Clip.ID>) -> TimeRange? {
        markClipRange(at: t, tracks: editTargets(selection: selection).tracks)
    }

    // MARK: Clamp reporting

    /// "V3" / "A2": the track's number among the tracks of its kind, counted from 1.
    public func trackLabel(_ id: Track.ID) -> String? {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return nil }
        let kind = tracks[i].kind
        let n = tracks[...i].filter { $0.kind == kind }.count
        return (kind == .video ? "V" : "A") + "\(n)"
    }

    /// Status-line text for a clamp, without the verb: "limited by clip on V3".
    public func describe(_ reason: ClampReason) -> String {
        switch reason {
        case .clipOnTrack(let id, _): "limited by clip on \(trackLabel(id) ?? "another track")"
        }
    }

    private func outcome(_ clamp: RippleClamp?) -> EditOutcome {
        guard let clamp, clamp.shortfall > .zero else { return .applied }
        return .clamped(.clipOnTrack(tracks[clamp.track].id, shortfall: clamp.shortfall))
    }

    /// Q/W (`rippleTrimToPlayhead`) with the clamp reported.
    @discardableResult
    public mutating func rippleTrimToPlayheadOutcome(_ edge: ClipEdge, at t: Time, tracks ids: [Track.ID]?)
        throws -> (moved: Time, outcome: EditOutcome) {
        let r = try rippleTrimToPlayheadDetailed(edge, at: t, tracks: ids)
        guard let id = r.limitedBy, r.shortfall > .zero else { return (r.moved, .applied) }
        return (r.moved, .clamped(.clipOnTrack(id, shortfall: r.shortfall)))
    }

    /// Ripple delete with the clamp reported (the gap closed less than the deleted span).
    @discardableResult
    public mutating func rippleDeleteOutcome(_ ids: [Clip.ID]) throws -> (closed: Time, outcome: EditOutcome) {
        var work = self
        let r = try work.rippleDeleteDetailed(ids)
        let o = work.outcome(r.clamp)
        self = work
        return (r.closed, o)
    }

    /// Extract (In/Out) with the clamp reported (the gap closed less than the range).
    @discardableResult
    public mutating func extractOutcome(_ range: TimeRange, tracks ids: [Track.ID]) throws -> (closed: Time, outcome: EditOutcome) {
        var work = self
        let r = try work.extractDetailed(range, tracks: ids)
        let o = work.outcome(r.clamp)
        self = work
        return (r.closed, o)
    }
}
