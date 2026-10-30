import Foundation

/// Which selected clip is the reference of Sync Audio to Reference and which clips are lined up to it.
public struct SyncAudioPlan: Sendable, Equatable {
    public var reference: Clip.ID
    public var targets: [Clip.ID]
}

extension Timeline {
    /// The reference is the selected media clip that starts first on the timeline (ties: the audio clip, then the
    /// upper track); every other selected media clip is a target, in that order. A target linked to the reference or to
    /// an earlier target is left out (it moves with its partner). Generators, stills and nested sequences take no part.
    /// nil without a reference and at least one target.
    public func syncAudioPlan(selection: Set<Clip.ID>) -> SyncAudioPlan? {
        var picked: [(track: Int, clip: Clip)] = []
        for (i, t) in tracks.enumerated() {
            for c in t.clips where selection.contains(c.id) && !c.isGenerator && !c.isStill && c.sequence == nil {
                picked.append((i, c))
            }
        }
        let ordered = picked.sorted {
            if $0.clip.start != $1.clip.start { return $0.clip.start < $1.clip.start }
            if $0.clip.kind != $1.clip.kind { return $0.clip.kind == .audio }
            return $0.track < $1.track
        }
        guard let ref = ordered.first?.clip else { return nil }
        var seenLinks: Set<UUID> = ref.link.map { [$0] } ?? []
        var targets: [Clip.ID] = []
        for m in ordered.dropFirst() {
            if let link = m.clip.link {
                guard seenLinks.insert(link).inserted else { continue }
            }
            targets.append(m.clip.id)
        }
        return targets.isEmpty ? nil : SyncAudioPlan(reference: ref.id, targets: targets)
    }
}
