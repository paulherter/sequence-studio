import Foundation

extension Project {
    /// New Sequence From Clip: an empty-format-locked sequence in the clip's own size and frame rate holding the whole
    /// clip (linked video and audio) at 0, named after the clip. Added to the project and the root bin by the caller
    /// (`normalizeBins`). nil for media without a known duration.
    public func sequence(fromMedia id: MediaRef.ID, name: String? = nil) -> Timeline? {
        guard let ref = media(id) else { return nil }
        let still = ref.info?.isStill == true
        guard let total = still ? Time(5, 1) : (ref.info?.duration ?? ref.duration) else { return nil }
        let v = ref.info?.video
        let fd = still ? Time(1, 30) : (v?.nominalFrameDuration ?? Time(1001, 30000))
        let format = SequenceFormat(width: v?.displayWidth ?? 1920, height: v?.displayHeight ?? 1080, frameDuration: fd,
                                    audioSampleRate: ref.info?.audio?.sampleRate ?? 48_000).sanitized()
        var t = Timeline(name: name ?? NSString(string: ref.name).deletingPathExtension, format: format,
                         tracks: Timeline.defaultTracks(), formatLocked: true)
        var targets = t.sourceEditTargets(hasVideo: v != nil || ref.info == nil, hasAudio: ref.info?.audio != nil) ?? []
        if targets.isEmpty, let first = t.tracks.first?.id { targets = [first] }
        try? t.threePointEdit(source: TimeRange(start: .zero, duration: total), media: id, name: ref.name,
                              mediaDuration: still ? nil : total, isStill: still, targets: targets, at: .zero, mode: .overwrite)
        return t
    }

    /// Replace Footage / Link Media: the item keeps its identity (clips, bin position, label, marks) and points at the
    /// new file. Name and label stay; path, bookmark, fingerprint, duration and probe info come from `replacement`.
    @discardableResult
    public mutating func replaceMedia(_ id: MediaRef.ID, with replacement: MediaRef) -> Bool {
        guard let i = media.firstIndex(where: { $0.id == id }) else { return false }
        media[i].path = replacement.path
        media[i].bookmark = replacement.bookmark
        media[i].fingerprint = replacement.fingerprint
        media[i].duration = replacement.duration
        // A pixel aspect chosen for the item is how the item is read: it survives the new file.
        // A replacement that is not probed yet keeps the item's old info while a choice exists (the choice lives in it).
        let chosen = media[i].info?.video?.pixelAspectOverride
        let channels = media[i].info?.audio?.channelMap      // F7.10: likewise, when the new file has the channels
        let deinterlaceOff = media[i].info?.video?.deinterlaceOff ?? false   // the item's Deinterlace switch survives too
        if replacement.info != nil || (chosen == nil && channels == nil && !deinterlaceOff) { media[i].info = replacement.info }
        if let a = media[i].info?.audio, let channels {
            let kept = channels.stored(audio: a, path: replacement.path)   // nil: it does not fit
            media[i].info?.audio?.channelMap = kept
        }
        if deinterlaceOff { media[i].info?.video?.deinterlaceOff = true }
        if let chosen, chosen != media[i].info?.video?.pixelAspect { media[i].info?.video?.pixelAspectOverride = chosen }
        fitUsage(of: id)
        applyPendingScaleMigration()   // a v9 clip that waited for probe info gets its v10 Scale now (H6)
        return true
    }

    /// After a replace: clips of `id` learn the new media length; a clip that reaches past it is trimmed at the tail, one
    /// that starts past it is removed (linked partners follow, they use the same media); source marks are clamped to the
    /// new length and re-snapped to the new frame rate (a mark that no longer fits is dropped).
    private mutating func fitUsage(of id: MediaRef.ID) {
        guard let ref = media(id) else { return }
        let still = ref.info?.isStill == true
        let total: Time? = still ? nil : (ref.info?.duration ?? ref.duration)
        for ti in timelines.indices {
            for tri in timelines[ti].tracks.indices {
                for c in timelines[ti].tracks[tri].clips where c.media == id && !c.isNested && !c.isGenerator {
                    var n = c
                    n.mediaDuration = total
                    if let total, !c.isStill {
                        if c.source.start >= total { timelines[ti].tracks[tri].remove(c.id); continue }
                        if c.source.end > total {
                            if let keys = c.speedKeys {
                                // Remapped: cut the tail until the whole speed track lies inside the shortened media.
                                guard let fit = keys.fitting(media: total, frameDuration: timelines[ti].frameDuration) else {
                                    timelines[ti].tracks[tri].remove(c.id); continue
                                }
                                n.setSpeedKeys(fit)
                            } else if c.speed.isNormal && !c.reversed {
                                n.source = TimeRange(start: c.source.start, end: total)
                            } else {
                                // Retimed: keep the length a whole number of timeline frames at the clip's speed. The end
                                // that plays last is cut (tail); a reversed clip plays its source end first, so its head is
                                // cut and the clip starts later (the remaining picture stays where it was).
                                let fd = timelines[ti].frameDuration
                                let excess = c.source.end - total
                                if c.reversed {
                                    let cut = c.speed.unscale(excess).frameIndex(frameDuration: fd)
                                    let frames = cut + (c.speed.unscale(excess) > fd * cut ? 1 : 0)
                                    let removed = fd * frames
                                    if removed >= c.duration { timelines[ti].tracks[tri].remove(c.id); continue }
                                    n.extendHead(by: .zero - removed)
                                    n.start = c.start + removed
                                } else {
                                    let keep = c.speed.unscale(total - c.source.start).frameIndex(frameDuration: fd)
                                    if keep < 1 { timelines[ti].tracks[tri].remove(c.id); continue }
                                    n.extendTail(by: fd * keep - c.duration)
                                }
                            }
                        }
                    }
                    timelines[ti].tracks[tri].replace(n)
                }
            }
        }
        guard var m = sourceMarks[id] else { return }
        if let total {
            let fd = ref.info?.video?.nominalFrameDuration ?? Time(1, 30)
            let last = max(.zero, total - fd)
            if let i = m.markIn { m.markIn = i >= total ? nil : min(i.snapped(to: fd), last) }
            if let o = m.markOut { m.markOut = o.snapped(to: fd) > total ? total : max(o.snapped(to: fd), fd) }
            if let i = m.markIn, let o = m.markOut, o <= i { m.markOut = nil }
        }
        sourceMarks[id] = m.isEmpty ? nil : m
    }
}

extension Project {
    /// Names of the sequences that hold clips of `media`, in project order (empty = unused).
    public func sequenceNames(using media: MediaRef.ID) -> [String] {
        timelines.filter { $0.tracks.contains { $0.clips.contains { $0.media == media && !$0.isNested && !$0.isGenerator } } }.map(\.name)
    }

    /// Names of the other sequences that nest sequence `id` as a clip.
    public func sequenceNames(nesting id: Timeline.ID) -> [String] {
        timelines.filter { $0.id != id && $0.tracks.contains { $0.clips.contains { $0.sequence == id } } }.map(\.name)
    }

    /// Deletes a sequence. Refused (false) for the last sequence, for an unknown id and for a sequence another sequence
    /// nests (`sequenceNames(nesting:)` names those). `activeTimeline` moves to the neighbor when the active one goes.
    /// The caller wraps this in one undo step.
    @discardableResult
    public mutating func deleteSequence(_ id: Timeline.ID) -> Bool {
        guard timelines.count > 1, let i = timelines.firstIndex(where: { $0.id == id }),
              sequenceNames(nesting: id).isEmpty else { return false }
        timelines.remove(at: i)
        if activeTimeline == id || !timelines.contains(where: { $0.id == activeTimeline }) {
            activeTimeline = timelines[min(i, timelines.count - 1)].id
        }
        normalizeBins()
        return true
    }
}

extension Project {
    /// Folder that holds the path of media made offline on purpose (`makeOffline`). Nothing is ever created there.
    public static let offlineFolderName = ".sq-offline"

    /// Clear used media: the item stays in the project and its clips stay on the timelines, but its file is no longer
    /// referenced, so it is offline until Relink attaches a file again. The name, fingerprint (size) and probe info are
    /// kept, so Relink matches by file name and size as for any missing file. Returns false for an unknown id or an item
    /// that is already offline-by-clear.
    /// shortcut: offline is derived from "nothing at the stored path" (no persisted flag, no ProjectFile bump); the path
    /// is moved to a folder that does not exist. Upgrade to a real flag when a version bump is free.
    @discardableResult
    public mutating func makeOffline(_ id: MediaRef.ID) -> Bool {
        guard let i = media.firstIndex(where: { $0.id == id }) else { return false }
        let path = media[i].path
        let name = MediaPathResolver.fileName(of: path)
        guard !name.isEmpty, !path.contains("/\(Self.offlineFolderName)/") else { return false }
        let dir = path.hasSuffix(name) ? String(path.dropLast(name.count)) : "/"
        media[i].path = dir + Self.offlineFolderName + "/" + name
        media[i].bookmark = nil
        return true
    }
}
