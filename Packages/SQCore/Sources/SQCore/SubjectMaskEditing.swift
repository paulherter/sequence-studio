import Foundation

// W9.8 SubjectMask wiring: Clip > Add Subject Mask and the ProjectFile v37 gate query.

extension Clip {
    /// Media video only: the person matte is computed on the decoded source frame (no generators, no nested sequences).
    public var acceptsSubjectMask: Bool { kind == .video && !isGenerator && !isNested }

    /// True when any mask (enabled or not) takes its shape from the person matte.
    public var hasSubjectMask: Bool { masks.contains { $0.source == .subject } }
}

extension ClipEffects {
    /// An enabled subject mask is evaluated: the renderer has to segment the decoded frame (`RenderLayer.subjectMatte`).
    public var needsSubjectMatte: Bool {
        masks.contains { $0.source == .subject } || segments.contains { $0.scope.contains { $0.source == .subject } }
    }
}

extension Timeline {
    /// Adds a Subject mask (named "Subject", on top of the clip's other masks) to each clip of `ids` that takes one and has
    /// none yet. Clips on locked tracks, generators and nests are skipped. Returns how many clips changed (0 = no change).
    /// The clips of `ids` that Add Subject Mask would change (unlocked track, takes one, has none yet), in `ids` order.
    public func subjectMaskTargets(_ ids: [Clip.ID]) -> [Clip.ID] {
        ids.filter { id in
            guard let m = find(id), !tracks[m.track].isLocked else { return false }
            return m.clip.acceptsSubjectMask && !m.clip.hasSubjectMask
        }
    }

    @discardableResult
    public mutating func addSubjectMask(_ ids: [Clip.ID]) throws -> Int {
        var work = self
        var changed = 0
        for id in subjectMaskTargets(ids) {
            guard var c = work.find(id)?.clip else { continue }
            c.masks.append(ClipMask.makeSubject(name: "Subject"))
            try work.replaceClip(c)
            changed += 1
        }
        guard changed > 0 else { return 0 }
        self = work
        return changed
    }
}

extension Project {
    /// Any clip in any sequence holds a subject mask (ProjectFile v37 gate).
    public var containsSubjectMask: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains(where: \.hasSubjectMask) } }
    }
}
