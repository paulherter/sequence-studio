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
                                    audioSampleRate: ref.info?.audio?.sampleRate ?? 48_000)
        var t = Timeline(name: name ?? (ref.name as NSString).deletingPathExtension, format: format,
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
        media[i].info = replacement.info
        return true
    }
}
