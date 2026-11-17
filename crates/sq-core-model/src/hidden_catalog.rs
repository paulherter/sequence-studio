// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: HiddenCatalog.swift (the keystone check by id waits for Keystone, see notes/m4.md)

//! Consolidation round 1 (DECISIONS 2026-10-07): things that duplicate another feature are HIDDEN, not deleted. Hidden means
//! not listed (Effects panel, Quick Apply palette, Add Effect lists, Keystones panel), but still decoded, applied and rendered
//! when a project, preset or Library item holds it. One switch brings them all back: `is_active() == false`, or the
//! environment variable `SQ_SHOW_HIDDEN=1` for a run. Ids are stored strings: never rename.

use std::sync::OnceLock;

/// true = the hidden items below are left out of every list.
pub fn is_active() -> bool {
    static ACTIVE: OnceLock<bool> = OnceLock::new();
    *ACTIVE.get_or_init(|| std::env::var("SQ_SHOW_HIDDEN").map_or(true, |v| v != "1"))
}

// Effect kinds are the strings stored in `ClipEffect::kind` (Swift `ClipEffect.vignetteKind` and so on).
const VIGNETTE: &str = "vignette";
const BRIGHTNESS_CONTRAST: &str = "brightnessContrast";
const BLACK_AND_WHITE: &str = "blackAndWhite";
const NOISE: &str = "noise";
const AUDIO_GAIN: &str = "audio.gain";
const AUDIO_EQ: &str = "audio.eq";
const AUDIO_PARAMETRIC_EQ: &str = "audio.parametricEQ";

/// Effects the Color effect (grade), Film Grain, Audio Gain and EQ (5 band) already cover.
pub const EFFECT_KINDS: [&str; 6] = [VIGNETTE, BRIGHTNESS_CONTRAST, BLACK_AND_WHITE, NOISE, AUDIO_GAIN, AUDIO_EQ];

/// What covers a hidden effect (DECISIONS 2026-10-07): the canonical effect kind, or a description where the cover is
/// not an effect (the Color effect's sections, the Audio Gain command on key G).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cover {
    /// Another effect, by kind.
    Effect(&'static str),
    /// A section of the Color effect.
    ColorSection(&'static str),
    /// A command.
    Command(&'static str),
}

/// What covers each hidden effect. Every `EFFECT_KINDS` entry has one.
pub fn cover(kind: &str) -> Option<Cover> {
    Some(match kind {
        VIGNETTE => Cover::ColorSection("Vignette"),
        BRIGHTNESS_CONTRAST => Cover::ColorSection("Basic Correction"),
        BLACK_AND_WHITE => Cover::ColorSection("Saturation 0"),
        NOISE => Cover::ColorSection("Film Grain"),
        AUDIO_GAIN => Cover::Command("Audio Gain (G)"),
        AUDIO_EQ => Cover::Effect(AUDIO_PARAMETRIC_EQ),
        _ => return None,
    })
}

/// Built-in motion presets (`MotionPresets` ids) that equal an element transition, a marker or an effect.
pub const MOTION_PRESET_IDS: [&str; 21] = [
    "moveFromLeft",
    "moveFromRight",
    "moveFromTop",
    "moveFromBottom",
    "moveToLeft",
    "moveToRight",
    "moveToTop",
    "moveToBottom",
    "slideIn",
    "popIn",
    "pop50",
    "pop0120100",
    "zoomInOut",
    "zoomOutIn",
    "whipBlurIn",
    "whipBlurOut",
    "punchIn",
    "drift",
    "cameraShake",
    "rgbSplitHit",
    "rgbGlitch",
];

/// Built-in Keystones (`Keystone.builtInID(n)`) that equal a marker, an effect, a command or a Move transition.
/// Kept: Spin In (n = 10).
pub const KEYSTONE_NUMBERS: [i64; 10] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11];

/// Whether the effect kind is hidden. `active` is the app-level switch (`is_active()`); tests pass it explicitly so they
/// do not depend on the environment.
pub fn is_hidden_effect_kind(kind: &str, active: bool) -> bool {
    active && EFFECT_KINDS.contains(&kind)
}

/// Whether the built-in motion preset is hidden.
pub fn is_hidden_motion_preset(id: &str) -> bool {
    is_active() && MOTION_PRESET_IDS.contains(&id)
}

/// Whether the built-in Keystone number `n` is hidden.
pub fn is_hidden_keystone_number(n: i64) -> bool {
    is_active() && KEYSTONE_NUMBERS.contains(&n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_hidden_effect_names_what_covers_it() {
        assert!(EFFECT_KINDS.iter().all(|k| cover(k).is_some()));
        assert_eq!(cover("crop"), None);
    }

    #[test]
    fn effect_covers_are_not_themselves_hidden() {
        for kind in EFFECT_KINDS {
            if let Some(Cover::Effect(canonical)) = cover(kind) {
                assert!(!EFFECT_KINDS.contains(&canonical), "{kind} is covered by a hidden effect");
            }
        }
        assert_eq!(cover("audio.eq"), Some(Cover::Effect("audio.parametricEQ")));
    }

    #[test]
    fn the_switch_decides() {
        assert!(is_hidden_effect_kind("noise", true));
        assert!(!is_hidden_effect_kind("noise", false));
        assert!(!is_hidden_effect_kind("crop", true));
        assert!(is_hidden_keystone_number(1) || !is_active());
        assert!(!is_hidden_keystone_number(10));
        assert!(!is_hidden_motion_preset("unknown"));
    }
}
