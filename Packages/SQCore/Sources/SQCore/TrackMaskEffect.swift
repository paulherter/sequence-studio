import Foundation

// Track Mask: an effect that takes another video track of the sequence as the clip's mask. The track's composite at the same
// sequence time limits the clip: Alpha = where the track has picture, Luma = how bright it is (times its alpha); Invert flips
// it. It is not a renderer feature of its own: it evaluates into a Picture mask (`MaskSource.picture`, PictureMask.swift) that
// intersects everything the clip's own masks leave, so preview and export read the same matte layers. v90 gate.

extension ClipEffect {
    public static let trackMaskKind = "trackMask"
    public static let trackMaskModeKey = "trackMaskMode", trackMaskInvertKey = "trackMaskInvert"

    /// Mode values of `trackMaskModeKey`.
    public static let trackMaskAlpha = 0.0, trackMaskLuma = 1.0

    public var isTrackMask: Bool { kind == Self.trackMaskKind }

    /// The Picture mask this effect stands for at clip-local `t`; nil while off, without a track, or not a Track Mask.
    func trackMaskShape(atLocal t: Time) -> MaskShape? {
        guard isTrackMask, enabled, let track = maskTrack else { return nil }
        var s = MaskShape(polygon: [], inverted: scalar(Self.trackMaskInvertKey, atLocal: t) >= 0.5, mode: .intersect, source: .picture)
        s.pictureTrack = track
        s.pictureChannel = scalar(Self.trackMaskModeKey, atLocal: t) >= 0.5 ? .brightness : .shape
        return s
    }

    /// Sets the track of a Track Mask (nil = none).
    public mutating func setMaskTrack(_ id: Track.ID?) { if isTrackMask { maskTrack = id } }
}

extension Clip {
    /// The Picture masks of this clip's enabled Track Mask effects at clip-local `t`, in list order. Added after the clip's own
    /// masks as Intersect, so they limit whatever those leave.
    func trackMaskShapes(atLocal t: Time) -> [MaskShape] {
        effects.compactMap { $0.trackMaskShape(atLocal: t) }
    }

    /// Some Track Mask effect of this clip reads `track`.
    func trackMaskReads(_ track: Track.ID) -> Bool { effects.contains { $0.isTrackMask && $0.maskTrack == track } }

    /// Every Track Mask effect's track runs through `f` (nil result = cleared).
    func mappingTrackMasks(_ f: (Track.ID) -> Track.ID?) -> Clip {
        guard effects.contains(where: { $0.isTrackMask && $0.maskTrack != nil }) else { return self }
        var c = self
        for i in c.effects.indices where c.effects[i].isTrackMask {
            if let t = c.effects[i].maskTrack { c.effects[i].maskTrack = f(t) }
        }
        return c
    }
}
