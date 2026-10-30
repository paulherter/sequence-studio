import Foundation

// C6 Picture mask: another video track's picture (same timeline, same sequence time) as a mask source (`MaskSource.picture`).
// Linked by track id. Rules, editing (Delete Track, paste remap) and the evaluation helpers live here; DECISIONS 2026-10-07
// "C6 Picture mask", ProjectFile v65.

extension Timeline {
    /// Tracks a Picture mask of a clip on `track` may read: the other video tracks of this timeline, bottom first.
    public func pictureMaskTracks(forClipOn track: Track.ID) -> [Track] {
        tracks.filter { $0.kind == .video && $0.id != track }
    }

    /// The same tracks for a menu: those above `track` nearest first, then those below nearest first.
    public func pictureMaskTracksNearestFirst(forClipOn track: Track.ID) -> [Track] {
        guard let i = tracks.firstIndex(where: { $0.id == track }) else { return pictureMaskTracks(forClipOn: track) }
        let above = tracks[(i + 1)...].filter { $0.kind == .video }
        let below = tracks[..<i].filter { $0.kind == .video }.reversed()
        return above + below
    }

    /// The track a new Picture mask reads: the nearest video track above with a clip at `t`, else the nearest above, else
    /// the nearest below, else nil.
    public func defaultPictureMaskTrack(forClipOn track: Track.ID, at t: Time) -> Track.ID? {
        let list = pictureMaskTracksNearestFirst(forClipOn: track)
        guard let i = tracks.firstIndex(where: { $0.id == track }) else { return list.first?.id }
        let above = Set(tracks[(i + 1)...].map(\.id))
        let up = list.filter { above.contains($0.id) }
        return up.first { $0.clips.contains { $0.timeline.contains(t) } }?.id ?? list.first?.id
    }

    /// Tracks the enabled Picture masks of the clips `ids` read (the timeline marks them while those clips are selected).
    public func pictureMatteTracks(ofClips ids: Set<Clip.ID>) -> Set<Track.ID> {
        guard !ids.isEmpty else { return [] }
        var out = Set<Track.ID>()
        for tr in tracks { for c in tr.clips where ids.contains(c.id) {
            for m in c.masks where m.enabled && m.source == .picture { if let t = m.pictureTrack { out.insert(t) } }
            for e in c.effects where e.enabled && e.isTrackMask { if let t = e.maskTrack { out.insert(t) } }
        } }
        return out
    }

    /// Enabled Picture masks of enabled clips on visible video tracks that read no track ("No track": they cover nothing),
    /// nested sequences (`sequences`) included. For the export warning.
    public func unlinkedPictureMaskCount(sequences: [Timeline.ID: Timeline] = [:]) -> Int {
        unlinkedPictureMaskCount(sequences: sequences, depth: 0)
    }

    public var unlinkedPictureMaskCount: Int { unlinkedPictureMaskCount(sequences: [:], depth: 0) }

    private func unlinkedPictureMaskCount(sequences: [Timeline.ID: Timeline], depth: Int) -> Int {
        var n = 0
        for tr in tracks where tr.kind == .video && tr.isVisible {
            for c in tr.clips where c.isEnabled {
                n += c.masks.filter { $0.enabled && $0.source == .picture && $0.pictureTrack == nil }.count
                if let id = c.sequence, depth < 8, let inner = sequences[id].map(c.angleView(of:)) {
                    n += inner.unlinkedPictureMaskCount(sequences: sequences, depth: depth + 1)
                }
            }
        }
        return n
    }

    /// `id` is a video track of this timeline other than `track`.
    public func acceptsPictureTrack(_ id: Track.ID, forClipOn track: Track.ID) -> Bool {
        id != track && tracks.contains { $0.id == id && $0.kind == .video }
    }

    /// Delete Track: removes the track with its clips (a locked track is refused), drops broken links and clears every
    /// Picture mask that read it, in one mutation (one undo step).
    public mutating func removeTrack(_ id: Track.ID) throws {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        if tracks[i].isLocked { throw EditError.trackLocked }
        tracks.remove(at: i)
        dropOrphanLinks()
        clearPictureMasks(readingTrack: id)
        sourcePatch = sourcePatch                 // a patch that pointed at the deleted track falls back (v88 gate)
    }

    /// Remove Empty Tracks: deletes every unlocked track without clips, except the lowest track of each kind (a sequence
    /// always keeps one video and one audio track) and the main track of a Fast Cut sequence. Returns the removed IDs.
    @discardableResult
    public mutating func removeEmptyTracks() -> [Track.ID] {
        var keep = Set<Track.ID>()
        for kind in [TrackKind.video, .audio] { if let t = tracks.first(where: { $0.kind == kind }) { keep.insert(t.id) } }
        if let m = mainTrackID { keep.insert(m) }
        let doomed = tracks.filter { $0.clips.isEmpty && !$0.isLocked && !keep.contains($0.id) }.map(\.id)
        for id in doomed { try? removeTrack(id) }
        return doomed
    }

    /// Clears `pictureTrack` on every mask that reads `id` (the masks stay, covering nothing).
    public mutating func clearPictureMasks(readingTrack id: Track.ID) {
        for ti in tracks.indices where tracks[ti].clips.contains(where: { $0.readsPicture(of: id) }) {
            tracks[ti].mapClipsKeepingTiming { c in
                guard c.readsPicture(of: id) else { return c }
                var n = c.mappingTrackMasks { $0 == id ? nil : $0 }
                n.masks = c.masks.map { m in
                    var m = m
                    if m.pictureTrack == id { m.pictureTrack = nil }
                    return m
                }
                return n
            }
        }
    }

    /// After tracks were copied with new ids (`map`: old -> new): every Picture mask follows the map; a link to a track
    /// that is neither in the map nor a video track of this timeline (not copied along) is cleared.
    public mutating func remapPictureMasks(trackIDs map: [Track.ID: Track.ID]) {
        let video = Set(tracks.filter { $0.kind == .video }.map(\.id))
        func remapped(_ id: Track.ID?) -> Track.ID? {
            guard let id else { return nil }
            if let n = map[id] { return n }
            return video.contains(id) ? id : nil
        }
        func linked(_ c: Clip) -> Bool {
            c.masks.contains { $0.source == .picture && $0.pictureTrack != nil } || c.effects.contains { $0.isTrackMask && $0.maskTrack != nil }
        }
        for ti in tracks.indices where tracks[ti].clips.contains(where: linked) {
            tracks[ti].mapClipsKeepingTiming { c in
                guard linked(c) else { return c }
                var n = c.mappingTrackMasks(remapped)
                n.masks = c.masks.map { m in
                    guard m.source == .picture else { return m }
                    var m = m
                    m.pictureTrack = remapped(m.pictureTrack)
                    return m
                }
                return n
            }
        }
    }

    /// `c` (a clip of this timeline) with its Picture masks' tracks remapped for its place here (`Clip.remapPictureTrack`).
    public func remappingPictureTracks(of c: Clip, sourceLane: Int?, pictureLanes: [Track.ID: Int]) -> Clip {
        guard c.kind == .video, c.masks.contains(where: { $0.source == .picture }) || c.effects.contains(where: \.isTrackMask) else { return c }
        let video = tracks.filter { $0.kind == .video }
        guard let lane = video.firstIndex(where: { $0.clip(c.id) != nil }) else { return c }
        return c.remappingPictureTracks(sourceLane: sourceLane, sourceLanes: pictureLanes, targetLane: lane,
                                        targetVideoTracks: video.map(\.id))
    }

    /// Video lane (index among the video tracks) of every track the Picture masks of `clips` read; nil when none does.
    /// Stored with a copy so a paste elsewhere can keep the matte at the same lane offset.
    /// `copied`: only these tracks' lanes are recorded (a track whose content is left out would map the mask onto an
    /// unrelated clip in the target); nil = every video track.
    func pictureTrackLanes(for clips: [Clip], copied: Set<Track.ID>? = nil) -> [String: Int]? {
        let video = tracks.filter { $0.kind == .video }.map(\.id)
        var out: [String: Int] = [:]
        for c in clips {
            for m in c.masks where m.source == .picture {
                if let id = m.pictureTrack, copied?.contains(id) ?? true, let lane = video.firstIndex(of: id) {
                    out[id.uuidString] = lane
                }
            }
        }
        return out.isEmpty ? nil : out
    }
}

extension TimelineClipboard {
    /// The source lanes of the tracks the copied Picture masks read (`pictureTrackLanes`).
    public var pictureLanes: [Track.ID: Int] {
        var out: [Track.ID: Int] = [:]
        for (k, v) in pictureTrackLanes ?? [:] { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }
}

extension Clip {
    /// Any mask of this clip is a Picture mask reading `track`.
    func readsPicture(of track: Track.ID) -> Bool {
        masks.contains { $0.source == .picture && $0.pictureTrack == track } || trackMaskReads(track)
    }

    /// Where a pasted Picture mask's track lands: kept when that track is a video track of the target (`targetVideoTracks`,
    /// bottom first) and not the clip's own (`targetLane`); else the same lane offset from the clip as in the source
    /// (`sourceLane`, `sourceLanes`); else nil.
    public static func remapPictureTrack(_ id: Track.ID?, sourceLane: Int?, sourceLanes: [Track.ID: Int], targetLane: Int,
                                         targetVideoTracks: [Track.ID]) -> Track.ID? {
        guard let id else { return nil }
        let own = targetVideoTracks.indices.contains(targetLane) ? targetVideoTracks[targetLane] : nil
        if id != own, targetVideoTracks.contains(id) { return id }
        guard let sourceLane, let matteLane = sourceLanes[id] else { return nil }
        let lane = targetLane + (matteLane - sourceLane)
        guard lane != targetLane, targetVideoTracks.indices.contains(lane) else { return nil }
        return targetVideoTracks[lane]
    }

    /// This clip with every Picture mask's track remapped (`remapPictureTrack`).
    public func remappingPictureTracks(sourceLane: Int?, sourceLanes: [Track.ID: Int], targetLane: Int,
                                       targetVideoTracks: [Track.ID]) -> Clip {
        guard masks.contains(where: { $0.source == .picture && $0.pictureTrack != nil }) else { return self }
        var c = self
        c.masks = masks.map { m in
            guard m.source == .picture else { return m }
            var m = m
            m.pictureTrack = Self.remapPictureTrack(m.pictureTrack, sourceLane: sourceLane, sourceLanes: sourceLanes,
                                                    targetLane: targetLane, targetVideoTracks: targetVideoTracks)
            return m
        }
        return c
    }
}

// MARK: Evaluation

extension LayerRequest {
    /// The Picture masks this request reads at nesting level `level` (its own masks when it lives at that level, else the
    /// masks of its enclosing clip there), with the track of the clip that owns them.
    fileprivate func pictureTracks(atLevel level: Int) -> (owner: Track.ID, tracks: [Track.ID])? {
        let fx: ClipEffects, owner: Track.ID
        if groups.count == level { fx = effects; owner = track }
        else if groups.count > level { fx = groups[level].effects; owner = groups[level].track }
        else { return nil }
        var ids: [Track.ID] = []
        for m in fx.masks where m.source == .picture { if let id = m.pictureTrack { ids.append(id) } }
        for s in fx.segments { for m in s.scope where m.source == .picture { if let id = m.pictureTrack { ids.append(id) } } }
        return ids.isEmpty ? nil : (owner, ids)
    }

    /// No chains: a matte layer's own Picture masks (and those of the clips it sits in from `level` on) read nothing.
    fileprivate func droppingPictureLinks(fromLevel level: Int) -> LayerRequest {
        func drop(_ fx: inout ClipEffects) {
            guard fx.masks.contains(where: { $0.source == .picture })
                    || fx.segments.contains(where: { $0.scope.contains { $0.source == .picture } }) else { return }
            for i in fx.masks.indices where fx.masks[i].source == .picture { fx.masks[i].pictureTrack = nil }
            for s in fx.segments.indices {
                for i in fx.segments[s].scope.indices where fx.segments[s].scope[i].source == .picture {
                    fx.segments[s].scope[i].pictureTrack = nil
                }
            }
        }
        var r = self
        drop(&r.effects)
        for g in r.groups.indices where g >= level { drop(&r.groups[g].effects) }
        return r
    }
}

extension Timeline {
    /// The distinct tracks (first use first) that Picture masks of `layers` read at nesting level `level`: video tracks of
    /// this timeline, never the owner's own track. Matte layers themselves ask for nothing.
    func pictureMatteTracks(of layers: [LayerRequest], level: Int) -> [Track.ID] {
        var out: [Track.ID] = []
        for l in layers where l.matteFor == nil {
            guard let (owner, ids) = l.pictureTracks(atLevel: level) else { continue }
            for id in ids where !out.contains(id) && acceptsPictureTrack(id, forClipOn: owner) { out.append(id) }
        }
        return out
    }

    /// The matte layers of `track`, evaluated alone (`layers`): adjustment layers of that track dropped (no picture of their
    /// own), Picture links on them cleared (no chains), each tagged `matteFor`.
    static func matteLayers(_ layers: [LayerRequest], track: Track.ID, level: Int) -> [LayerRequest] {
        layers.compactMap { l in
            if l.groups.count == level, l.isAdjustment { return nil }
            var r = l.droppingPictureLinks(fromLevel: level)
            r.matteFor = track
            r.matteDepth = level
            // Never grouped with drawn layers into a pair (the compositor groups neighboring requests by pair id) and
            // never a held transition frame. A dissolve on the matte track is drawn as plain "over" in the matte.
            if let p = r.pair, p.depth <= level { r.pair = nil }
            r.inTransition = false
            return r
        }
    }
}
