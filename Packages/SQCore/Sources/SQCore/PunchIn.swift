import Foundation

/// W8.2 Punch-in toggle: one key puts a static scale-up on the selected video clips, the same key takes it off. Built from
/// what the model already has (an effect of kind `transform`, Scale = `defaultScale` %, multiplying onto Motion), so no file
/// format change. The stage carries a marker parameter (`markerKey`), so it is recognized on every clip that carries it:
/// renames, trims, moves, and the copies made by a razor cut, copy/paste or duplicate (new clip id, same effect), so the
/// toggle never stacks a second stage. A user's own Transform effects are never touched. Stages written before the marker
/// existed are still recognized by the id derived from their clip's id.
public enum PunchIn {
    /// Scale in percent (hard cut). The maintainer has not named his value yet (115, 110 or 126.5): change here only.
    public static let defaultScale = 115.0
    /// Parameter that marks a transform stage as the punch-in (value 1, never animated or shown).
    public static let markerKey = "sqPunchIn"

    /// True when `effect` is the punch-in stage of `clip`.
    public static func isPunchIn(_ effect: ClipEffect, of clip: Clip.ID) -> Bool {
        effect.kind == ClipEffect.transformKind && (effect.parameters[markerKey] != nil || effect.id == effectID(for: clip))
    }

    public static func effectID(for clip: Clip.ID) -> UUID {
        var b = withUnsafeBytes(of: clip.uuid) { Array($0) }
        for i in b.indices { b[i] = b[i] &+ 0x3D &+ UInt8(truncatingIfNeeded: i &* 31) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension PunchIn {
    /// The marked punch-in stage for `clip` with the given scale property (percent). Shared by Shift+P and Punch In Cuts.
    static func makeStage(for clip: Clip.ID, scale: AnimatedProperty<Double>) -> ClipEffect? {
        guard var e = ClipEffect.make(kind: ClipEffect.transformKind) else { return nil }
        e.id = effectID(for: clip)
        e.parameters[ClipEffect.stageScaleKey] = scale
        e.parameters[markerKey] = AnimatedProperty(1)
        return e
    }
}

extension Timeline {
    public func isPunchedIn(_ clip: Clip) -> Bool {
        clip.effects.contains { PunchIn.isPunchIn($0, of: clip.id) }
    }

    /// Toggles the punch-in on the given clips: when every one has it, it is removed from all; otherwise the clips without it
    /// get it. Returns true when the clips are punched in afterwards. Throws `.clipNotFound`, `.wrongTrackKind` (audio or
    /// generator) and `.trackLocked`; nothing changes then.
    @discardableResult
    public mutating func togglePunchIn(_ ids: [Clip.ID], scale: Double = PunchIn.defaultScale) throws -> Bool {
        var work = self
        var targets: [(track: Int, clip: Clip)] = []
        for id in ids {
            guard let m = work.find(id) else { throw EditError.clipNotFound }
            guard m.clip.kind == .video, !m.clip.isGenerator else { throw EditError.wrongTrackKind }
            guard !work.tracks[m.track].isLocked else { throw EditError.trackLocked }
            targets.append((m.track, m.clip))
        }
        guard !targets.isEmpty else { return false }
        let remove = targets.allSatisfy { isPunchedIn($0.clip) }
        for (ti, c) in targets {
            var c = c
            if remove {
                c.effects.removeAll { PunchIn.isPunchIn($0, of: c.id) }
            } else if !isPunchedIn(c) {
                guard let e = PunchIn.makeStage(for: c.id, scale: AnimatedProperty(scale)) else { throw EditError.clipNotFound }
                c.effects.append(e)
            }
            work.tracks[ti].replace(c)
        }
        self = work
        return !remove
    }
}
