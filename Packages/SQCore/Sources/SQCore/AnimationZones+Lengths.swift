import Foundation

extension Project {
    /// Sets the lengths of a clip's intro and outro zones (the first N seconds are the in animation, the last M the out
    /// animation). Each is at least 0 and together at most the clip's duration: the intro is limited first, the outro takes
    /// what is left. Keys are not moved: the zones only decide what a later trim keeps, and the clip can no longer be
    /// trimmed below intro + outro (`Clip.minimumDuration`). A clip without zones gets them.
    /// Throws `.clipNotFound`, `.trackLocked`.
    public mutating func setAnimationZoneLengths(intro: Time, outro: Time, clip id: Clip.ID) throws {
        try modifyClipForZones(id) { c in
            let i = min(max(intro, .zero), c.duration)
            let o = min(max(outro, .zero), c.duration - i)
            var z = c.zones ?? AnimationZones(introEnd: .zero, outroLength: .zero)
            z.introEnd = i
            z.outroLength = o
            c.zones = z
        }
    }
}
