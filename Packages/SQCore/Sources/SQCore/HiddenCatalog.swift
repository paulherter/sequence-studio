import Foundation

/// Consolidation round 1 (DECISIONS 2026-10-07): things that duplicate another feature are HIDDEN, not deleted. Hidden means
/// not listed (Effects panel, Quick Apply palette, Add Effect lists, Keystones panel), but still decoded, applied and rendered
/// when a project, preset or Library item holds it. One switch brings them all back: `isActive = false`, or the environment
/// variable `SQ_SHOW_HIDDEN=1` for a run. Ids are stored strings: never rename.
public enum HiddenCatalog {
    /// true = the hidden items below are left out of every list.
    public static let isActive: Bool = ProcessInfo.processInfo.environment["SQ_SHOW_HIDDEN"] != "1"

    /// Effects the Color effect (grade), Film Grain, Audio Gain and EQ (5 band) already cover.
    public static let effectKinds: Set<String> = [
        ClipEffect.vignetteKind, ClipEffect.brightnessContrastKind, ClipEffect.blackAndWhiteKind, ClipEffect.noiseKind,
        ClipEffect.audioGainKind, ClipEffect.audioEQKind,
    ]

    /// What covers each hidden effect (DECISIONS 2026-10-07): the canonical effect kind, or a description where the cover is
    /// not an effect (the Color effect's sections, the Audio Gain command on key G). Every `effectKinds` entry has one.
    public enum Cover: Sendable, Equatable {
        case effect(String)
        case colorSection(String)
        case command(String)
    }
    public static let covers: [String: Cover] = [
        ClipEffect.vignetteKind: .colorSection("Vignette"),
        ClipEffect.brightnessContrastKind: .colorSection("Basic Correction"),
        ClipEffect.blackAndWhiteKind: .colorSection("Saturation 0"),
        ClipEffect.noiseKind: .colorSection("Film Grain"),
        ClipEffect.audioGainKind: .command("Audio Gain (G)"),
        ClipEffect.audioEQKind: .effect(ClipEffect.audioParametricEQKind),
    ]

    /// Built-in motion presets (`MotionPresets` ids) that equal an element transition, a marker or an effect.
    public static let motionPresetIDs: Set<String> = [
        "moveFromLeft", "moveFromRight", "moveFromTop", "moveFromBottom", "moveToLeft", "moveToRight", "moveToTop", "moveToBottom",
        "slideIn", "popIn", "pop50", "pop0120100", "zoomInOut", "zoomOutIn", "whipBlurIn", "whipBlurOut",
        "punchIn", "drift", "cameraShake", "rgbSplitHit", "rgbGlitch",
    ]

    /// Built-in Keystones (`Keystone.builtInID(n)`) that equal a marker, an effect, a command or a Move transition.
    /// Kept: Spin In (n = 10).
    public static let keystoneNumbers: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11]

    /// `active` defaults to the app-level switch; tests pass it explicitly so they do not depend on the environment.
    public static func isHidden(effectKind kind: String, active: Bool = isActive) -> Bool { active && effectKinds.contains(kind) }
    public static func isHidden(motionPresetID id: String) -> Bool { isActive && motionPresetIDs.contains(id) }
    public static func isHidden(keystone id: UUID) -> Bool { isActive && keystoneNumbers.contains { Keystone.builtInID($0) == id } }
}
