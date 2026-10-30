import Foundation
import SQCore

/// C6 Picture mask UI (T5): the track choices of a Picture mask row, adding one from the Program monitor menu, and the
/// two edits of its row (track, channel). Model, evaluation and rendering are in SQCore / SQExport.
public struct PictureTrackChoice: Equatable, Sendable {
    /// nil = "No track" (the mask covers nothing).
    public var track: Track.ID?
    public var title: String
    /// "V3": the lane label of the track (nil for "No track").
    public var lane: String?
}

extension EffectControlsModel {
    /// The video track of `clip` (nil when it is not in the shown timeline).
    private func trackID(of clip: Clip, in t: Timeline) -> Track.ID? {
        t.tracks.first { $0.clips.contains { $0.id == clip.id } }?.id
    }

    /// "V3" for the third video track of `t`.
    static func laneLabel(of track: Track.ID, in t: Timeline) -> String? {
        let video = t.tracks.filter { $0.kind == .video }
        guard let i = video.firstIndex(where: { $0.id == track }) else { return nil }
        return "V\(i + 1)"
    }

    /// Choices for the track popup of a Picture mask: "No track", then every other video track (nearest above first) as
    /// "V3 \u{2013} clip name" (the clip there at the playhead, else just "V3").
    public func pictureTrackChoices() -> [PictureTrackChoice] {
        var out = [PictureTrackChoice(track: nil, title: "No track", lane: nil)]
        guard let clip, let t = timeline?(), let own = trackID(of: clip, in: t) else { return out }
        for tr in t.pictureMaskTracksNearestFirst(forClipOn: own) {
            guard let lane = Self.laneLabel(of: tr.id, in: t) else { continue }
            let under = tr.clips.first { $0.timeline.contains(playhead) }
            out.append(PictureTrackChoice(track: tr.id, title: under.map { "\(lane) \u{2013} \($0.name)" } ?? lane, lane: lane))
        }
        return out
    }

    /// Index into `pictureTrackChoices()` the mask shows: its track, "No track" (0) when it has none or the track is gone.
    public func pictureTrackSelection(_ id: ClipMask.ID, in choices: [PictureTrackChoice]) -> Int {
        guard let tr = clip?.mask(id)?.pictureTrack, let i = choices.firstIndex(where: { $0.track == tr }) else { return 0 }
        return i
    }

    /// The track a new Picture mask of the shown clip reads (nearest above with a clip at the playhead).
    public var defaultPictureTrack: Track.ID? {
        guard let clip, let t = timeline?(), let own = trackID(of: clip, in: t) else { return nil }
        return t.defaultPictureMaskTrack(forClipOn: own, at: playhead)
    }

    /// Adds a Picture mask reading `track` (nil = No track), one undo step "Add Mask"; selects it. Returns its id.
    @discardableResult
    public func addPictureMask(track: Track.ID?) -> ClipMask.ID? {
        guard var c = workingClip, c.kind == .video else { return nil }
        if let track {
            guard let t = timeline?(), let own = trackID(of: c, in: t), t.acceptsPictureTrack(track, forClipOn: own) else { return nil }
        }
        let m = ClipMask.makePicture(track: track)
        c.masks.append(m)
        commit(c, "Add Mask")
        selectedSection = .mask(m.id)
        return m.id
    }

    /// Track popup of a Picture mask row (nil = No track), one undo step. A track that is not a valid choice is refused.
    public func setMaskPictureTrack(_ id: ClipMask.ID, _ track: Track.ID?) {
        guard var c = workingClip, let m = c.mask(id), m.source == .picture, m.pictureTrack != track else { return }
        if let track {
            guard let t = timeline?(), let own = trackID(of: c, in: t), t.acceptsPictureTrack(track, forClipOn: own) else { return }
        }
        c.updateMask(id) { $0.pictureTrack = track }
        commit(c, "Change Mask Track")
    }

    /// Shape / Brightness popup of a Picture mask row, one undo step.
    public func setMaskPictureChannel(_ id: ClipMask.ID, _ channel: MatteChannel) {
        guard var c = workingClip, let m = c.mask(id), m.source == .picture, m.pictureChannel != channel else { return }
        c.updateMask(id) { $0.pictureChannel = channel }
        commit(c, "Change Mask Channel")
    }
}
