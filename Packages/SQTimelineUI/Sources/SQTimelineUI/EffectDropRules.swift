import SQCore
import SQText

/// Whether a clip lights up for an effect drag: the drop must be one `EditorSession.addEffect` can carry out, so the ghost
/// never promises something the drop then refuses (locked track, a picture effect over an audio clip).
public enum EffectDropRules {
    /// `effectIDs`: the dragged ids (a dragged folder carries several). Accepts when at least one of them can land.
    public static func accepts(effectIDs: [String], clip: Clip, trackLocked: Bool) -> Bool {
        guard !trackLocked else { return false }
        return effectIDs.contains { accepts(effectID: $0, clip: clip) }
    }

    static func accepts(effectID id: String, clip: Clip) -> Bool {
        if PresetDrop.presetID(fromEffectID: id) != nil { return true }                  // Library presets decide on apply
        if TextPresetCatalog.isTextPresetID(id) || EffectStackPresets.preset(rowID: id) != nil { return true }
        if ClipEffect.isAudioKind(id) { return clip.kind == .audio || clip.link != nil }   // a video clip's linked sound
        return clip.kind == .video || clip.link != nil                                   // or a selection that holds its picture
    }
}
