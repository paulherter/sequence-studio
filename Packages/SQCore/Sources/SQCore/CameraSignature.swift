import Foundation

/// What identifies "the same camera" without a camera ID in the file: color space, frame size, frame rate, codec and
/// embedded look name. shortcut: a heuristic, two cameras of one model and one setting are one signature (which is what
/// "grade all from this camera" wants); upgrade when the probe reads the make/model/serial metadata.
public struct CameraSignature: Sendable, Hashable {
    public var colorSpace: ColorSpaceID?
    public var width: Int
    public var height: Int
    public var frameDuration: Time
    public var codec: String
    public var embeddedLUTName: String?

    /// nil for stills, audio-only media and media not probed yet.
    public init?(_ info: MediaInfo?) {
        guard let info, !info.isStill, let v = info.video else { return nil }
        colorSpace = info.detectedColorSpace; width = v.width; height = v.height
        frameDuration = v.nominalFrameDuration; codec = v.codec; embeddedLUTName = info.embeddedLUTName
    }
}

extension Timeline {
    /// Grade From Previous Clip: the Color effects and footage interpretation of the clip `back` places before `id` on
    /// its track (1 = the previous clip, 2 = the clip before that) replace the clip's own. Throws when there is none.
    public mutating func gradeFromPreviousClip(_ id: Clip.ID, back: Int = 1) throws {
        guard let ti = tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }) else { throw EditError.clipNotFound }
        if tracks[ti].isLocked { throw EditError.trackLocked }
        let ordered = tracks[ti].clips.sorted { $0.start < $1.start }
        guard let i = ordered.firstIndex(where: { $0.id == id }), i - back >= 0 else { throw EditError.emptyClip }
        let src = ordered[i - back]
        var c = ordered[i]
        guard c.acceptsColor, src.acceptsColor else { throw EditError.emptyClip }
        for e in c.colorGradeEffects.map(\.id) { c.removeEffect(e) }
        var at = 0
        for e in src.colorGradeEffects {
            var copy = e
            copy.id = UUID()
            c.effects.insert(copy, at: min(at, c.effects.count))
            at += 1
        }
        c.footageColor = src.footageColor
        tracks[ti].replace(c)
    }

    /// Copies the Color effects (and the footage interpretation) of clip `sourceID` onto every other video clip of this
    /// timeline whose media has the same camera signature (`signature(media)`). Returns how many clips changed. The
    /// target's own Color effects are replaced; its other effects stay. Throws when nothing matched.
    @discardableResult
    public mutating func gradeAllFromCamera(of sourceID: Clip.ID, signature: (UUID) -> CameraSignature?) throws -> Int {
        guard let src = tracks.flatMap(\.clips).first(where: { $0.id == sourceID }),
              let sig = signature(src.media) else { throw EditError.emptyClip }
        let fx = src.colorGradeEffects
        var changed = 0
        for ti in tracks.indices where !tracks[ti].isLocked {
            for ci in tracks[ti].clips.indices {
                var c = tracks[ti].clips[ci]
                guard c.id != sourceID, c.acceptsColor, signature(c.media) == sig else { continue }
                for id in c.colorGradeEffects.map(\.id) { c.removeEffect(id) }
                var at = 0
                for e in fx {
                    var copy = e
                    copy.id = UUID()
                    c.effects.insert(copy, at: min(at, c.effects.count))
                    at += 1
                }
                c.footageColor = src.footageColor
                tracks[ti].replace(c)
                changed += 1
            }
        }
        if changed == 0 { throw EditError.emptyClip }
        return changed
    }
}
