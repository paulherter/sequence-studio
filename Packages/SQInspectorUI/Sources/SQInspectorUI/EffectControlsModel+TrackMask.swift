import Foundation
import SQCore

/// Track Mask effect (TrackMaskEffect.swift): the track row of its section. The choices are those of a Picture mask (the other
/// video tracks of the sequence, nearest above first); Mode and Invert are ordinary catalog rows.
extension EffectControlsModel {
    /// Index into `pictureTrackChoices()` the effect shows: its track, "No track" (0) when it has none or the track is gone.
    func trackMaskSelection(_ effect: ClipEffect.ID, in choices: [PictureTrackChoice]) -> Int {
        guard let tr = clip?.effects.first(where: { $0.id == effect })?.maskTrack,
              let i = choices.firstIndex(where: { $0.track == tr }) else { return 0 }
        return i
    }

    /// Track popup of a Track Mask row (nil = No track), one undo step. A track that is not a valid choice is refused.
    func setTrackMaskTrack(_ effect: ClipEffect.ID, _ track: Track.ID?) {
        guard var c = workingClip, let i = c.effects.firstIndex(where: { $0.id == effect }), c.effects[i].isTrackMask,
              c.effects[i].maskTrack != track else { return }
        if let track, !pictureTrackChoices().contains(where: { $0.track == track }) { return }
        c.effects[i].setMaskTrack(track)
        commit(c, "Change Mask Track")
    }
}
