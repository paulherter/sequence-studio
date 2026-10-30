import Foundation

/// What a reel fill did (Reel to fillable template, PALMIER-PRS #576).
public struct ReelFillReport: Sendable, Hashable {
    /// Slots that now play new media.
    public var filled: [Clip.ID] = []
    /// Filled slots whose new media was shorter than the slot: the clip was cut short (a gap follows it).
    public var shortened: [Clip.ID] = []
    /// Slots that could not take their media (generator, nest, held frame, locked track, wrong stream).
    public var skipped: [Clip.ID] = []
    /// Slots left with their old media because the list had fewer items.
    public var unfilled: [Clip.ID] = []
    /// Media items beyond the last slot.
    public var unusedMedia = 0
}

extension Timeline {
    /// An independent copy for a new sequence: fresh ids for the sequence, tracks, clips, links, bundles and transitions
    /// (same remap a title template gets when it is applied).
    public func copyWithFreshIDs(name: String) -> Timeline {
        var t = TitleTemplate(name: name, content: self).instantiated().0
        t.name = name
        // A grade link must not reach back into the template: members keep their grouping under new link ids.
        var linkMap: [UUID: UUID] = [:]
        for i in t.tracks.indices {
            t.tracks[i].mapClipsKeepingTiming { c in
                var c = c
                if let l = c.gradeLink {
                    if linkMap[l] == nil { linkMap[l] = UUID() }
                    c.gradeLink = linkMap[l]
                }
                return c
            }
        }
        return t
    }

    /// The slots of a reel: the fillable clips of the base video track (the first video track with such clips) in time
    /// order. A reel is a plain sequence; every clip on its base track is a slot that keeps position, length, speed,
    /// effects, keys and transitions when new media is poured in.
    public var reelSlots: [Clip.ID] {
        for t in tracks where t.kind == .video {
            let slots = t.clips.filter { !$0.isNested && !$0.isGenerator && $0.holdFrame == nil }
            if !slots.isEmpty { return slots.sorted { $0.start < $1.start }.map(\.id) }
        }
        return []
    }

    /// Fills the slots in order with `media` (media i into slot i, each from its first frame). Media shorter than the
    /// slot shortens the slot (tail trim, at normal speed only) instead of failing; slots that cannot take their media
    /// are skipped and left as they were. Nothing is added or removed, so the template stays reusable.
    @discardableResult
    public mutating func fillReel(slots: [Clip.ID], with media: [ReplacementMedia]) -> ReelFillReport {
        var report = ReelFillReport()
        for (i, id) in slots.enumerated() {
            guard i < media.count else { report.unfilled.append(id); continue }
            let m = media[i]
            if m.isStill {
                // replaceMedia refuses stills (different clip model), so a still gets its own path here.
                if pourStill(m, into: id) { report.filled.append(id) } else { report.skipped.append(id) }
                continue
            }
            var work = self
            do {
                guard var old = work.find(id)?.clip else { throw EditError.clipNotFound }
                if old.isStill {
                    // A slot that holds a still takes video again: it becomes a normal clip of the slot length, then
                    // replaceMedia below swaps in the new media (replaceMedia itself still refuses stills).
                    guard let ti = work.tracks.firstIndex(where: { $0.clip(id) != nil }), !work.tracks[ti].isLocked else {
                        throw EditError.trackLocked
                    }
                    var c = old
                    c.isStill = false; c.mediaDuration = m.duration
                    c.source = TimeRange(start: .zero, duration: old.duration); c.speed = .normal
                    work.tracks[ti].replace(c)
                    old = c
                }
                // Link partners that replaceMedia will not swap (other media, no matching stream) stay exactly as they were.
                let untouched = work.tracks.flatMap(\.clips).filter { p in
                    guard let l = old.link, p.link == l, p.id != id else { return false }
                    let takes = p.media == old.media && p.kind != old.kind && (p.kind == .video ? m.hasVideo : m.hasAudio)
                    return !takes
                }
                var short = false
                let usable = m.duration.flooredToFrame(frameDuration)
                if usable < old.source.duration {
                    guard old.speed == .normal else { throw EditError.insufficientMedia }
                    try work.trim(id, edge: .tail, by: usable - old.source.duration)
                    short = true
                }
                try work.replaceMedia(of: id, with: m, alignment: .clipStart(sourceIn: .zero))
                for p in untouched {
                    if let ti = work.tracks.firstIndex(where: { $0.clip(p.id) != nil }) { work.tracks[ti].replace(p) }
                }
                self = work
                report.filled.append(id)
                if short { report.shortened.append(id) }
            } catch {
                report.skipped.append(id)
            }
        }
        report.unusedMedia = max(0, media.count - slots.count)
        return report
    }

    /// A still in a slot: the slot keeps position, timeline length, effects and keys but becomes a still clip (no source
    /// range to speak of, normal speed). Linked partners that played the old media (its audio) are removed, a still is
    /// silent; the slot and any remaining partner lose the link. False (nothing changed) for a locked track, a locked
    /// partner track, a nest/generator slot or a slot without a video stream.
    private mutating func pourStill(_ m: ReplacementMedia, into id: Clip.ID) -> Bool {
        guard m.hasVideo, let ti = tracks.firstIndex(where: { $0.clip(id) != nil }), let old = tracks[ti].clip(id),
              !tracks[ti].isLocked, old.kind == .video, !old.isNested, !old.isGenerator, old.holdFrame == nil else { return false }
        var work = self
        if let link = old.link {
            for pi in work.tracks.indices where pi != ti {
                for p in work.tracks[pi].clips where p.link == link {
                    if p.media == old.media && p.kind != old.kind {
                        guard !work.tracks[pi].isLocked else { return false }
                        work.tracks[pi].remove(p.id)
                    } else if !work.tracks[pi].isLocked {       // a locked track's clip stays exactly as it was
                        var q = p; q.link = nil
                        work.tracks[pi].replace(q)
                    }
                }
            }
        }
        var n = old
        n.media = m.id; n.name = m.name; n.isStill = true; n.mediaDuration = nil
        n.source = TimeRange(start: .zero, duration: old.duration)
        n.speed = .normal; n.speedKeys = nil; n.reversed = false
        n.link = nil
        n.footageColor = ClipFootageColor(); n.markers = nil
        work.tracks[ti].replace(n)
        self = work
        return true
    }
}
