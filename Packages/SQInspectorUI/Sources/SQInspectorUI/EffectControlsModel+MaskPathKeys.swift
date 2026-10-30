import Foundation
import SQAnalysis
import SQCore

// Mask keys in the keyframe lanes: a path mask's Path keys (`EffectProperty.maskPath`, drawn on its controls row) and a
// Magic mask's tracked frames (read from the matte store, on the same row). Path keys move, ease, copy and delete like any
// key; tracked frames are only selectable and deletable.

extension EffectProperty {
    /// The mask of a `.maskPath` property.
    public var maskPathID: ClipMask.ID? {
        if case .maskPath(let id) = self { return id }
        return nil
    }
}

extension EffectSection {
    /// The properties whose keys the section's summary and the timeline clip lane show: `properties`, plus a mask's Path.
    public var keyProperties: [EffectProperty] {
        if case .mask(let id) = self { return properties + [.maskPath(id)] }
        return properties
    }
}

extension EffectControlsModel {
    // MARK: Path stopwatch and key button

    /// The Path stopwatch: on keys the path at the playhead; off removes every Path key, so it asks first
    /// (`.needsConfirmation`, then again with `confirmRemoval`), like any other property.
    func toggleMaskPathStopwatch(_ id: ClipMask.ID, confirmRemoval: Bool) -> StopwatchOutcome {
        guard let m = clip?.mask(id), m.source == .path else { return .unavailable }
        if m.path.isAnimated {
            guard confirmRemoval else { return .needsConfirmation }
            selection = selection.filter { $0.property != EffectProperty.maskPath(id).id }
            setMaskPathAnimated(id, false)
            return .removed
        }
        guard playheadInClip else { return .unavailable }
        setMaskPathAnimated(id, true)
        return .added
    }

    /// The Path's key button: adds or removes the key at the playhead; on a still path it is the stopwatch.
    func toggleMaskPathKey(_ id: ClipMask.ID) -> StopwatchOutcome {
        guard let m = clip?.mask(id), m.source == .path else { return .unavailable }
        guard m.path.isAnimated else { return toggleMaskPathStopwatch(id, confirmRemoval: false) }
        guard playheadInClip else { return .unavailable }
        let on = maskPathKeyTimes(id).contains(localPlayhead)
        toggleMaskPathKeyAtPlayhead(id)
        return on ? .removed : .added
    }

    // MARK: Magic mask tracked frames

    /// The tracked frames of a Magic mask inside the clip, as lane keys (clip-local, sorted). Empty for any other mask.
    public func magicKeys(_ id: ClipMask.ID) -> [MagicFrameKey] {
        guard let c = clip, let m = c.mask(id), let key = Self.magicCacheKey(m, in: c) else { return [] }
        return magicFrames.keys(clip: c, mask: m, key: key, frameDuration: frameDuration)
    }

    /// The matte cache key of a picked Magic mask of `c`, nil otherwise.
    static func magicCacheKey(_ m: ClipMask, in c: Clip) -> String? {
        guard m.source == .magic, c.sequence == nil, let sel = m.magic, !sel.points.isEmpty else { return nil }
        return sel.cacheKey(media: c.media)
    }

    /// Every key a lane row of `p` shows: the track's keys, and for a Magic mask's Path row its tracked frames.
    func laneKeys(_ p: EffectProperty) -> [(id: UUID, time: Time)] {
        let own = track(p)?.times ?? []
        guard let id = p.maskPathID, clip?.mask(id)?.source == .magic else { return own }
        return own + magicKeys(id).map { ($0.id, $0.time) }
    }

    /// The members of `sel` that are tracked frames still shown (the selection keeps them across edits).
    func liveMagicMembers(_ sel: Set<SummaryMember>) -> Set<SummaryMember> {
        guard let c = clip else { return [] }
        var out = Set<SummaryMember>()
        for m in c.masks where m.source == .magic {
            let pid = EffectProperty.maskPath(m.id).id
            let wanted = sel.filter { $0.property == pid }
            guard !wanted.isEmpty else { continue }
            let ids = Set(magicKeys(m.id).map(\.id))
            out.formUnion(wanted.filter { ids.contains($0.keyID) })
        }
        return out
    }

    /// Collapsed Magic mask section: its tracked frames as summary keys.
    func magicSummaryKeys(_ section: EffectSection) -> [SummaryKey] {
        guard case .mask(let id) = section else { return [] }
        let pid = EffectProperty.maskPath(id).id
        return magicKeys(id).map { SummaryKey(time: $0.time, members: [SummaryMember(property: pid, keyID: $0.id)]) }
    }

    /// Summary keys of the tracks merged with `extra` (same time = one key).
    static func mergingMagic(_ groups: [SummaryKey], _ extra: [SummaryKey]) -> [SummaryKey] {
        guard !extra.isEmpty else { return groups }
        var byTime: [Time: Set<SummaryMember>] = [:]
        for g in groups + extra { byTime[g.time, default: []].formUnion(g.members) }
        return byTime.keys.sorted().map { SummaryKey(time: $0, members: byTime[$0]!) }
    }

    /// Deleting selected tracked frames (part of `deleteSelection`): their mattes leave the store; a frame that carries a
    /// correction point also loses that point (`c`, the same undo step as the rest of the delete). The pick's own points
    /// always stay, whichever frames go: without them the mask has nothing to track from.
    func removeSelectedMagicFrames(_ c: inout Clip) -> [MagicFrameSnapshot] {
        var gone: [MagicFrameSnapshot] = []
        for m in c.masks where m.source == .magic {
            let ids = selectedKeyIDs(.maskPath(m.id))
            guard !ids.isEmpty, let key = Self.magicCacheKey(m, in: c) else { continue }
            let keys = magicKeys(m.id).filter { ids.contains($0.id) }
            guard !keys.isEmpty else { continue }
            let corrections = keys.filter(\.isCorrection)
            let plain = keys.filter { !$0.isCorrection }.map(\.pts)
            gone.append(magicFrames.remove(key: key, times: plain))
            // A Face / Skin mask: the narrowed mattes of those frames go too (the mask then covers them by estimate).
            if let part = m.magic?.partKey(media: c.media) { gone.append(magicFrames.remove(key: part, times: plain)) }
            if !corrections.isEmpty {
                let anchor = m.magic?.anchorTime
                c.updateMask(m.id) { mask in
                    mask.magic?.points.removeAll { p in corrections.contains { $0.holdsCorrection(p, anchor: anchor) } }
                }
            }
        }
        return gone
    }

    // MARK: Previous / next key of a mask row

    /// Clip-local key times of a mask's row: its Path keys, or a Magic mask's tracked frames.
    func maskRowKeyTimes(_ id: ClipMask.ID) -> [Time] {
        guard clip?.mask(id)?.source == .magic else { return maskPathKeyTimes(id) }
        return magicKeys(id).map(\.time)
    }

    /// The mask row's `KeyframeControls`: the Path's, or for a Magic mask previous / next tracked frame.
    public func maskRowKeyframeState(_ id: ClipMask.ID) -> KeyframeControlState {
        guard clip?.mask(id)?.source == .magic else { return maskPathKeyframeState(id) }
        let times = maskRowKeyTimes(id), l = localPlayhead
        return KeyframeControlState.resolve(animated: !times.isEmpty, onKey: times.contains(l),
                                            hasPrevious: times.contains { $0 < l }, hasNext: times.contains { $0 > l },
                                            playheadInRange: playheadInClip)
    }

    public func goToPreviousMaskRowKey(_ id: ClipMask.ID) {
        guard let t = maskRowKeyTimes(id).last(where: { $0 < localPlayhead }) else { return }
        let g = t + (clip?.start ?? .zero)
        revealPlayhead(g); onSeek?(g)
    }

    public func goToNextMaskRowKey(_ id: ClipMask.ID) {
        guard let t = maskRowKeyTimes(id).first(where: { $0 > localPlayhead }) else { return }
        let g = t + (clip?.start ?? .zero)
        revealPlayhead(g); onSeek?(g)
    }
}
