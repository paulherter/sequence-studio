import Foundation

// Fast Cut model (docs/research/FCP-MAGNETIC-TIMELINE.md section 5.3, docs/ARCHITECTURE.md "Fast Cut model").
//
// A sequence is either Normal (classic tracks) or magnetic ("Fast Cut" in the UI). In Fast Cut the first video track (V1)
// is the main track; a clip on any other track is an attached clip that stores which main-track clip it belongs to
// (`ClipAttachment.host`) and where (`point`, from the attached clip's own start). Positions stay the only truth for where
// a clip is: an attachment is checked against the positions (`isAttachmentValid`) and re-derived when it no longer fits
// (`deriveAttachments`). Normal mode ignores attachments but keeps them.

/// The edit rules a sequence uses. Stored per sequence (v67); only `.magnetic` is written to the file.
public enum TimelineEditMode: String, Sendable, Codable, CaseIterable {
    /// Classic tracks (Premiere): every edit verb as it has always been.
    case normal
    /// Fast Cut: V1 is magnetic, clips on other tracks are attached to V1 clips.
    case magnetic
}

/// Ties a clip on a non-main track to a main-track clip (v67).
public struct ClipAttachment: Sendable, Hashable, Codable {
    /// The main-track (V1) clip this clip follows.
    public var host: Clip.ID
    /// The attach point, as timeline time from the attached clip's own start (0 = its first frame). Members of a linked
    /// group share one attach time, so a member that starts after it stores a negative point.
    public var point: Time

    public init(host: Clip.ID, point: Time = .zero) {
        self.host = host
        self.point = point
    }
}

extension Timeline {
    /// The sequence's edit rules (v67). Default `.normal`, which stores nothing.
    public var editMode: TimelineEditMode {
        get { editModeStore ?? .normal }
        set { editModeStore = newValue == .normal ? nil : newValue }
    }

    /// The main track of Fast Cut: the first video track (V1), empty or not. nil when the sequence has no video track.
    public var mainTrackID: Track.ID? { tracks.first { $0.kind == .video }?.id }

    /// Index of `mainTrackID` in `tracks`.
    public var mainTrackIndex: Int? { tracks.firstIndex { $0.kind == .video } }

    /// True when the clip can carry an attachment: it is not on the main track and not linked to a main-track clip (camera
    /// audio linked to a V1 clip is part of the main track through its link). False for an unknown id.
    public func isAttachable(_ id: Clip.ID) -> Bool {
        guard let m = find(id) else { return false }
        guard let mi = mainTrackIndex else { return false }
        if m.track == mi { return false }
        if let l = m.clip.link, tracks[mi].clips.contains(where: { $0.link == l }) { return false }
        return true
    }

    /// The main-track clip an attach time `t` belongs to: the clip under `t`, in a hole the clip before it, before the
    /// first clip the first clip. nil when the main track is empty or missing.
    public func attachHost(at t: Time) -> Clip.ID? {
        guard let mi = mainTrackIndex else { return nil }
        let main = tracks[mi].clips
        return (main.last { $0.start <= t } ?? main.first)?.id
    }

    /// True when `id`'s attachment fits the positions: the clip is attachable, its host is on the main track, the attach
    /// time (`start + point`) lies on the host or in the hole right after it (for the first main-track clip also in the
    /// leading hole before it), the attach time lies within the clip (within its linked group's span for a group), and
    /// every attachable member of its linked group stores the same host and attach time. False without an attachment.
    public func isAttachmentValid(_ id: Clip.ID) -> Bool {
        guard let c = find(id)?.clip, let a = c.attachment, isAttachable(id), let mi = mainTrackIndex else { return false }
        let main = tracks[mi].clips
        guard let hi = main.firstIndex(where: { $0.id == a.host }) else { return false }
        let t = c.start + a.point
        if hi > 0, t < main[hi].start { return false }
        if hi + 1 < main.count, t >= main[hi + 1].start { return false }
        let group = attachGroup(of: c)
        let lo = group.map(\.start).min()!, hi2 = group.map { $0.timeline.end }.max()!
        guard t >= lo, t <= hi2 else { return false }
        return group.allSatisfy { m in m.attachment.map { $0.host == a.host && m.start + $0.point == t } ?? false }
    }

    /// The attachable clips that attach as one with `c`: its linked partners off the main track, `c` included.
    private func attachGroup(of c: Clip) -> [Clip] {
        guard let l = c.link, let mi = mainTrackIndex else { return [c] }
        return tracks.indices.filter { $0 != mi }.flatMap { tracks[$0].clips.filter { $0.link == l } }
    }

    /// Makes every attachment fit the positions; moves no clip. Valid attachments stay as they are. A clip on the main
    /// track or linked to a main-track clip loses its attachment. Every other clip (a linked group as one) whose
    /// attachment is missing or invalid gets one derived from where it is: the attach time is the stored one when it
    /// still lies within the clip (group), else the clip's (group's earliest) start, and the host is `attachHost(at:)`.
    /// With an empty or missing main track every attachment is dropped. Fast Cut edits call this first (phase 1B).
    public mutating func deriveAttachments() {
        guard let mi = mainTrackIndex else {
            for i in tracks.indices { tracks[i].mapClipsKeepingTiming { var c = $0; c.attachment = nil; return c } }
            return
        }
        let mainLinks = Set(tracks[mi].clips.compactMap(\.link))
        var decided: [Clip.ID: ClipAttachment?] = [:]
        // Groups in timeline order, keyed by link (or the clip itself).
        var groups: [UUID: [Clip]] = [:], order: [UUID] = []
        for (i, t) in tracks.enumerated() where i != mi {
            for c in t.clips {
                if let l = c.link, mainLinks.contains(l) { decided[c.id] = .some(nil); continue }
                let key = c.link ?? c.id
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(c)
            }
        }
        // `isAttachmentValid` per member, with the lookups indexed once (it searches every track per call: O(N²)).
        let main = tracks[mi].clips
        var mainIndex: [Clip.ID: Int] = [:]
        for (k, c) in main.enumerated() where mainIndex[c.id] == nil { mainIndex[c.id] = k }
        var linked: [UUID: [Clip]] = [:]                   // `attachGroup(of:)` of a linked clip
        for (i, t) in tracks.enumerated() where i != mi {
            for c in t.clips { if let l = c.link { linked[l, default: []].append(c) } }
        }
        func isValid(_ c: Clip) -> Bool {
            guard let a = c.attachment, let hi = mainIndex[a.host] else { return false }
            let t = c.start + a.point
            if hi > 0, t < main[hi].start { return false }
            if hi + 1 < main.count, t >= main[hi + 1].start { return false }
            let group = c.link.flatMap { linked[$0] } ?? [c]
            let lo = group.map(\.start).min()!, hi2 = group.map { $0.timeline.end }.max()!
            guard t >= lo, t <= hi2 else { return false }
            return group.allSatisfy { m in m.attachment.map { $0.host == a.host && m.start + $0.point == t } ?? false }
        }
        for key in order {
            let members = groups[key]!.sorted { $0.start < $1.start }
            if members.allSatisfy(isValid) {
                for m in members { decided[m.id] = .some(m.attachment) }
                continue
            }
            let lo = members.map(\.start).min()!, hi = members.map { $0.timeline.end }.max()!
            let stored = members.lazy.compactMap { m in m.attachment.map { m.start + $0.point } }.first { $0 >= lo && $0 <= hi }
            let t = stored ?? lo
            let host = attachHost(at: t)
            for m in members { decided[m.id] = .some(host.map { ClipAttachment(host: $0, point: t - m.start) }) }
        }
        for i in tracks.indices {
            tracks[i].mapClipsKeepingTiming { c in
                var c = c
                c.attachment = i == mi ? nil : (decided[c.id] ?? nil)
                return c
            }
        }
    }

    /// Switches the edit rules; moves no clip. Entering Fast Cut derives the attachments from where the clips are
    /// (`deriveAttachments`); leaving it keeps them (Normal ignores them). One call = one undo step for the caller.
    public mutating func setEditMode(_ mode: TimelineEditMode) {
        editMode = mode
        if mode == .magnetic { deriveAttachments() }
    }

    /// Rewrites attachment hosts through `map` (old clip id to new) after clips got new ids. A host missing from the map
    /// drops the attachment (re-derived at the next Fast Cut edit) unless `keepUnmapped`. `only`: limit to these clips
    /// (nil = every clip).
    mutating func remapAttachments(_ map: [Clip.ID: Clip.ID], only: Set<Clip.ID>? = nil, keepUnmapped: Bool = false) {
        for i in tracks.indices where tracks[i].clips.contains(where: { $0.attachment != nil }) {
            tracks[i].mapClipsKeepingTiming { c in
                guard let a = c.attachment, only?.contains(c.id) ?? true else { return c }
                if keepUnmapped, map[a.host] == nil { return c }
                var c = c
                c.remapAttachment(map)
                return c
            }
        }
    }

    /// True when any clip carries an attachment.
    public var hasAttachments: Bool { tracks.contains { $0.clips.contains { $0.attachment != nil } } }

    /// Drops every attachment whose host is not a clip of this sequence (clips moved into a new sequence).
    mutating func dropAttachmentsToMissingHosts() {
        let ids = Set(tracks.flatMap(\.clips).map(\.id))
        remapAttachments(Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }))
    }
}

extension Clip {
    /// `attachment` with its host rewritten through `map`; nil when the host is not in it.
    mutating func remapAttachment(_ map: [Clip.ID: Clip.ID]) {
        attachment = attachment.flatMap { a in map[a.host].map { ClipAttachment(host: $0, point: a.point) } }
    }
}

extension Project {
    /// Switches one sequence's edit rules (`Timeline.setEditMode`); moves no clip.
    public mutating func setEditMode(_ mode: TimelineEditMode, of timelineID: Timeline.ID) throws {
        guard let i = timelines.firstIndex(where: { $0.id == timelineID }) else { throw EditError.timelineNotFound }
        timelines[i].setEditMode(mode)
    }
}

extension Array where Element == Track {
    /// Fast Cut invariant: a clip on the main track (first video track) carries no attachment. Edits that place clips
    /// (move, insert, overwrite, paste, lane moves) end with this, so a clip moved or copied onto V1 drops its attachment.
    mutating func clearMainTrackAttachments() {
        guard let mi = firstIndex(where: { $0.kind == .video }), self[mi].clips.contains(where: { $0.attachment != nil }) else { return }
        self[mi].mapClipsKeepingTiming { c in var c = c; c.attachment = nil; return c }
    }
}
