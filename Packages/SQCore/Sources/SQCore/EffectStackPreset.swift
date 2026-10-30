import Foundation

/// A built-in, ready-made stack of effects (consolidation step 8, DECISIONS 2026-10-07): the motion presets, the keying
/// presets, the film and tape looks and the Voice chain are all this one type, applied through the one effect-preset path
/// (`EffectPreset` / `Timeline.applyPreset`): one undo step, the effects appended with fresh ids, keys placed by `anchor`.
/// Afterwards they are ordinary effects; nothing stores the preset itself (a project only holds the applied effects).
public struct EffectStackPreset: Sendable, Hashable, Identifiable {
    /// Where the preset is listed. Display only: the panel folder and icon come from the bin, the id never does.
    public enum Bin: String, Sendable, Hashable, CaseIterable {
        /// Live motion effects on the clip's transform stage (`MotionPresets`).
        case motion
        /// Key starting points (`KeyingPresets`).
        case keying
        /// Film and tape looks (`FilmPresets`).
        case looks
        /// Audio chains (`AudioPresets`): applied to audio clips (and the linked audio of video clips).
        case voice
    }

    /// Stable id, a stored string (Quick Apply recents, Effects panel folders, pasteboard): never rename.
    /// Motion and keying: a bare name (`popIn`); looks: `preset.<name>`; audio: `audio.preset.<name>`.
    public var id: String
    public var name: String
    public var bin: Bin
    public var effects: [ClipEffect]
    /// Where the keys of `effects` sit: from the clip's start (default) or from its end (the keys are written against a
    /// 1 s reference clip, so the last second of any clip gets them).
    public var anchor: EffectPreset.Anchor = .start

    public init(id: String, name: String, bin: Bin, effects: [ClipEffect], anchor: EffectPreset.Anchor = .start) {
        self.id = id; self.name = name; self.bin = bin; self.effects = effects; self.anchor = anchor
    }

    /// As an effect preset: effects only, no Motion properties, keys against a 1 s reference clip.
    public var preset: EffectPreset { EffectPreset(anchor: anchor, referenceDuration: Time(1, 1), effects: effects) }

    /// The clips it goes onto: audio for an audio chain, else video.
    public var trackKind: TrackKind { preset.trackKind }

    /// Effects panel row / pasteboard id. Motion and keying rows carry `EffectStackPresets.rowPrefix` (they were listed
    /// apart from the effects); looks and audio chains are listed among the effects under their own id. Both stay as they were.
    public var rowID: String { bin == .motion || bin == .keying ? EffectStackPresets.rowPrefix + id : id }

    /// One effect of a stack: the kind's factory instance with `values` / `colors` set as static values.
    public static func effect(_ kind: String, _ values: [String: Double] = [:], colors: [String: EffectColor] = [:]) -> ClipEffect {
        var e = ClipEffect.make(kind: kind)!
        for (k, v) in values { var p = e.parameters[k] ?? AnimatedProperty(v); p.value = v; e.parameters[k] = p }
        for (k, c) in colors { var p = e.colors[k] ?? AnimatedProperty(c); p.value = c; e.colors[k] = p }
        return e
    }
}

/// Every built-in effect-stack preset, in panel order per bin.
public enum EffectStackPresets {
    /// Row id prefix of motion and keying presets (`EffectStackPreset.rowID`).
    public static let rowPrefix = "preset.builtin."

    /// All of them, hidden ones included (`HiddenCatalog`): lookups find every one, so stored ids keep applying.
    public static let all: [EffectStackPreset] = MotionPresets.builtIns + KeyingPresets.builtIns + FilmPresets.all + AudioPresets.all

    /// What the panels and the palette list: without the hidden ones.
    public static var offered: [EffectStackPreset] { all.filter { !HiddenCatalog.isHidden(motionPresetID: $0.id) } }

    public static func offered(in bins: Set<EffectStackPreset.Bin>) -> [EffectStackPreset] { offered.filter { bins.contains($0.bin) } }

    public static func preset(id: String) -> EffectStackPreset? { all.first { $0.id == id } }

    /// By Effects panel row id (`rowID`), e.g. `preset.builtin.popIn` or `preset.vhs`.
    public static func preset(rowID: String) -> EffectStackPreset? { all.first { $0.rowID == rowID } }
}
