import Foundation

/// W5.1: working in a format variant. Edits made on a clip as the variant shows it land in that variant's override
/// (motion, overridden effect parameters, an overridden generator) or in the shared base (everything else); playback
/// and export evaluate a materialised copy of the sequence in the variant (`Project.variantView`), so no clip is
/// resolved per frame.
extension Timeline {
    /// Applies `edited`, a clip as it is displayed in `variant` (`resolvedClip(_:variant:)` plus the user's change),
    /// to the stored clip: Position / Scale / Rotation / Anchor Point that differ from the displayed values are written
    /// into the variant's override (only those, the rest stays automatic); effect parameters and the generator go to
    /// the override where it already overrides them, else to the base clip; every other change is shared. Overrides
    /// of effects the clip no longer has are dropped. nil, an unknown variant or an audio clip: a plain `replaceClip`.
    /// `conformsPicture`: `Project.conformsPicture(of:in:)` for the clip (false for a nested clip whose inner sequence
    /// renders in the same variant), so the displayed values compared against are the ones render shows.
    public mutating func applyDisplayedEdit(_ edited: Clip, variant id: FormatVariant.ID?, conformsPicture: Bool) throws {
        guard let v = variant(id), edited.kind == .video, let m = find(edited.id) else { try replaceClip(edited); return }
        let base = m.clip
        let shown = base.resolved(for: v, base: format, conformsPicture: conformsPicture)
        var o = base.variantOverrides[v.id] ?? VariantOverride()
        var n = edited

        if edited.animation.position != shown.animation.position { o.position = edited.animation.position }
        if edited.animation.scale != shown.animation.scale { o.scale = edited.animation.scale }
        if edited.animation.rotation != shown.animation.rotation { o.rotation = edited.animation.rotation }
        if edited.animation.anchor != shown.animation.anchor { o.anchor = edited.animation.anchor }
        if edited.animation.tiltX != shown.animation.tiltX { o.tiltX = edited.animation.tiltX }
        if edited.animation.tiltY != shown.animation.tiltY { o.tiltY = edited.animation.tiltY }
        n.animation.tiltX = base.animation.tiltX
        n.animation.tiltY = base.animation.tiltY
        n.animation.position = base.animation.position
        n.animation.scale = base.animation.scale
        n.animation.rotation = base.animation.rotation
        n.animation.anchor = base.animation.anchor

        if let g = o.generator, g.kind == base.generator?.kind {
            if let eg = edited.generator, eg != shown.generator { o.generator = eg }
            n.generator = base.generator
        }

        for i in n.effects.indices {
            let eid = n.effects[i].id
            guard let keys = o.effectParameters[eid]?.keys else { continue }
            let baseFx = base.effects.first { $0.id == eid }, shownFx = shown.effects.first { $0.id == eid }
            for k in Array(keys) {
                if n.effects[i].parameters[k] != shownFx?.parameters[k] {
                    o.effectParameters[eid]?[k] = n.effects[i].parameters[k]
                }
                n.effects[i].parameters[k] = baseFx?.parameters[k]
            }
        }
        let kept = Set(n.effects.map(\.id))
        o.effectParameters = o.effectParameters.filter { kept.contains($0.key) && !$0.value.isEmpty }

        var all = base.variantOverrides
        all[v.id] = o
        n.variantOverrides = all
        try replaceClip(n)
    }

    /// This sequence evaluated in `variant` (format, every video clip resolved, no variants left); `nestedVariant(id)`
    /// says whether a nested clip's inner sequence is rendered in the same variant (its clip is then not conformed).
    func materialized(in v: FormatVariant, innerHasVariant: (Timeline.ID) -> Bool) -> Timeline {
        var out = self
        out.format = v.format(base: format)
        out.variants = []
        for i in out.tracks.indices where out.tracks[i].kind == .video {
            out.tracks[i].mapClipsKeepingTiming { c in
                var r = c.resolved(for: v, base: format, conformsPicture: !(c.sequence.map(innerHasVariant) ?? false))
                r.variantOverrides = [:]
                return r
            }
        }
        return out
    }
}

extension Project {
    /// What the Program monitor and export evaluate for sequence `id` in `variant`: the sequence materialised in the
    /// variant and every sequence reachable from it by nesting. Inner sequences that have a variant with the same id
    /// are materialised in theirs (followed only through such sequences, like `Timeline.videoLayers(at:variant:)`);
    /// the others stay as they are. nil variant or an unknown id: the sequence itself. nil for an unknown sequence.
    /// Edge case: a sequence reachable both through a chain that has the variant and one that has not is materialised.
    public func variantView(of id: Timeline.ID, variant: FormatVariant.ID?) -> (timeline: Timeline, sequences: [Timeline.ID: Timeline])? {
        guard let t = timeline(id) else { return nil }
        var sequences: [Timeline.ID: Timeline] = [:]
        for s in reachableSequences(from: id) { if let x = timeline(s) { sequences[s] = x } }
        guard let vid = variant, let v = t.variant(vid) else { return (t, sequences) }
        // Asks the stored project, never the materialised copies (variants = []), so a sequence reachable two ways is
        // not conformed a second time.
        let has: (Timeline.ID) -> Bool = { self.timeline($0)?.variant(vid) != nil }
        let top = t.materialized(in: v, innerHasVariant: has)
        var done = Set<Timeline.ID>([id])
        var queue = [t]
        while let s = queue.popLast() {
            for inner in Set(s.tracks.filter { $0.kind == .video }.flatMap(\.clips).compactMap(\.sequence)) {
                guard !done.contains(inner), let x = sequences[inner], let xv = x.variant(vid) else { continue }
                done.insert(inner)
                sequences[inner] = x.materialized(in: xv, innerHasVariant: has)
                queue.append(x)
            }
        }
        return (top, sequences)
    }

    /// Whether `clip` gets the automatic picture conform in `variant`: not for a nested clip whose inner sequence has a
    /// variant with the same id (it is rendered in that variant, already at its size). The one rule Evaluation,
    /// `variantView`, the display and the edit path share.
    public func conformsPicture(of clip: Clip, in variant: FormatVariant.ID?) -> Bool {
        guard let v = variant, let s = clip.sequence else { return true }
        return timeline(s)?.variant(v) == nil
    }

    /// `clip` (of `timeline`) as `variant` shows it, exactly as render resolves it; unchanged for nil or an unknown id.
    public func displayedClip(_ clip: Clip, in timeline: Timeline, variant: FormatVariant.ID?) -> Clip {
        guard let v = timeline.variant(variant) else { return clip }
        return clip.resolved(for: v, base: timeline.format, conformsPicture: conformsPicture(of: clip, in: v.id))
    }

    /// Picture size of `clip` as rendered in `variant`: a nested clip whose inner sequence has that variant shows the
    /// inner variant's canvas; otherwise `pictureSize(of:)`.
    public func pictureSize(of clip: Clip, variant: FormatVariant.ID?) -> (width: Int, height: Int)? {
        if let s = clip.sequence, let v = variant, let inner = timeline(s), let iv = inner.variant(v) {
            let f = iv.format(base: inner.format)
            return (f.displayWidth, f.height)
        }
        return pictureSize(of: clip)
    }

    /// The variant the Program monitor shows for sequence `id`; nil = the sequence's own format (also when the stored
    /// variant no longer exists).
    public func activeVariant(of id: Timeline.ID) -> FormatVariant.ID? {
        guard let v = activeVariants[id], timeline(id)?.variant(v) != nil else { return nil }
        return v
    }
}
