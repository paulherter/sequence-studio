// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectStackPreset.swift, KeyingPresets.swift, FilmPresets.swift, AudioPresets.swift
//! A built-in, ready-made stack of effects: keying presets, film and tape looks and the Voice chains are all this one type,
//! applied through the one effect-preset path (`EffectPreset` / `Timeline::apply_preset`): one undo step, the effects
//! appended with fresh ids, keys placed by `anchor`. Afterwards they are ordinary effects; nothing stores the preset itself
//! (a project only holds the applied effects).
//!
//! The built-ins hold placeholder ids (`SequentialIds`): applying a preset copies every effect and key with a fresh id.

use crate::effect_preset::{Anchor, EffectPreset};
use crate::motion_presets::MotionPresets;
use sq_core_model::{AnimatedProperty, ClipEffect, EffectColor, TrackKind, hidden_catalog};
use sq_core_time::{IdSource, SequentialIds, Time};
use std::collections::BTreeSet;

/// Where a preset is listed. Display only: the panel folder and icon come from the bin, the id never does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum StackBin {
    /// Live motion effects on the clip's transform stage.
    Motion,
    /// Key starting points.
    Keying,
    /// Film and tape looks.
    Looks,
    /// Audio chains: applied to audio clips (and the linked audio of video clips).
    Voice,
}

impl StackBin {
    /// Every bin, in panel order.
    pub const ALL: [StackBin; 4] = [StackBin::Motion, StackBin::Keying, StackBin::Looks, StackBin::Voice];
}

/// A built-in stack of effects.
#[derive(Clone, Debug, PartialEq)]
pub struct EffectStackPreset {
    /// Stable id, a stored string (Quick Apply recents, Effects panel folders, pasteboard): never rename. Motion and
    /// keying: a bare name (`popIn`); looks: `preset.<name>`; audio: `audio.preset.<name>`.
    pub id: String,
    /// Shown name.
    pub name: String,
    /// Where it is listed.
    pub bin: StackBin,
    /// The effects, in apply order.
    pub effects: Vec<ClipEffect>,
    /// Where the keys of `effects` sit: from the clip's start (default) or from its end (the keys are written against a 1 s
    /// reference clip, so the last second of any clip gets them).
    pub anchor: Anchor,
}

impl EffectStackPreset {
    /// A preset whose keys sit from the clip's start.
    pub fn new(id: &str, name: &str, bin: StackBin, effects: Vec<ClipEffect>) -> EffectStackPreset {
        EffectStackPreset { id: id.to_string(), name: name.to_string(), bin, effects, anchor: Anchor::Start }
    }

    /// As an effect preset: effects only, no Motion properties, keys against a 1 s reference clip.
    pub fn preset(&self) -> EffectPreset {
        EffectPreset { effects: self.effects.clone(), ..EffectPreset::new(self.anchor, Time::new(1, 1)) }
    }

    /// The clips it goes onto: audio for an audio chain, else video.
    pub fn track_kind(&self) -> TrackKind {
        self.preset().track_kind()
    }

    /// Effects panel row / pasteboard id. Motion and keying rows carry `EffectStackPresets::ROW_PREFIX` (they were listed
    /// apart from the effects); looks and audio chains are listed among the effects under their own id.
    pub fn row_id(&self) -> String {
        if matches!(self.bin, StackBin::Motion | StackBin::Keying) {
            format!("{}{}", EffectStackPresets::ROW_PREFIX, self.id)
        } else {
            self.id.clone()
        }
    }

    /// One effect of a stack: the kind's factory instance with `values` / `colors` set as static values.
    pub fn effect(kind: &str, values: &[(&str, f64)], colors: &[(&str, EffectColor)]) -> ClipEffect {
        let id = SequentialIds::default().next_id();
        let made = ClipEffect::make(id, kind);
        debug_assert!(made.is_some(), "unknown effect kind in a built-in preset: {kind}");
        // Swift traps on an unknown kind; a bare effect keeps release builds running.
        let mut e = made.unwrap_or_else(|| ClipEffect::new(id, kind));
        for (k, v) in values {
            let mut p = e.parameters.get(*k).cloned().unwrap_or_else(|| AnimatedProperty::new(*v));
            p.value = *v;
            e.parameters.insert((*k).to_string(), p);
        }
        for (k, c) in colors {
            let mut p = e.colors.get(*k).cloned().unwrap_or_else(|| AnimatedProperty::new(*c));
            p.value = *c;
            e.colors.insert((*k).to_string(), p);
        }
        e
    }
}

/// Every built-in effect-stack preset, in panel order per bin.
pub struct EffectStackPresets;

impl EffectStackPresets {
    /// Row id prefix of motion and keying presets (`EffectStackPreset::row_id`).
    pub const ROW_PREFIX: &'static str = "preset.builtin.";

    /// All of them, hidden ones included (`hidden_catalog`): lookups find every one, so stored ids keep applying.
    /// Order as in Swift: motion, keying, looks, audio.
    pub fn all() -> Vec<EffectStackPreset> {
        let mut out = MotionPresets::built_ins();
        out.extend(KeyingPresets::built_ins());
        out.extend(FilmPresets::all());
        out.extend(AudioPresets::all());
        out
    }

    /// What the panels and the palette list: without the hidden ones.
    pub fn offered() -> Vec<EffectStackPreset> {
        Self::all().into_iter().filter(|p| !hidden_catalog::is_hidden_motion_preset(&p.id)).collect()
    }

    /// What the panels list for these bins.
    pub fn offered_in(bins: &BTreeSet<StackBin>) -> Vec<EffectStackPreset> {
        Self::offered().into_iter().filter(|p| bins.contains(&p.bin)).collect()
    }

    /// The preset with this id.
    pub fn preset(id: &str) -> Option<EffectStackPreset> {
        Self::all().into_iter().find(|p| p.id == id)
    }

    /// By Effects panel row id (`row_id`), e.g. `preset.builtin.greenScreen` or `preset.vhs`.
    pub fn preset_by_row_id(row_id: &str) -> Option<EffectStackPreset> {
        Self::all().into_iter().find(|p| p.row_id() == row_id)
    }
}

/// One-click starting points for the chroma key: apply, then tune Tolerance and Shrink / Grow with Output set to Alpha.
/// Values follow Premiere's documented Ultra Key defaults and usage ranges where our controls have the same meaning
/// (Black level 10, Shrink under 25, Soften under 20 in Premiere's units); Keep Highlights / Keep Shadows are our own
/// controls, so their values are a tuned starting point.
pub struct KeyingPresets;

impl KeyingPresets {
    fn screen(hue: f64) -> ClipEffect {
        EffectStackPreset::effect(
            ClipEffect::ULTRA_KEY_KIND,
            &[
                (ClipEffect::KEY_HUE_KEY, hue),
                (ClipEffect::TOLERANCE_KEY, 45.0),
                (ClipEffect::SOFTEN_KEY, 20.0),
                (ClipEffect::KEY_HIGHLIGHT_KEY, 10.0),
                (ClipEffect::KEY_SHADOW_KEY, 20.0),
                (ClipEffect::PEDESTAL_KEY, 10.0),
                (ClipEffect::CHOKE_KEY, 15.0),
                (ClipEffect::KEY_CONTRAST_KEY, 20.0),
                (ClipEffect::KEY_MIDPOINT_KEY, 50.0),
                (ClipEffect::SPILL_KEY, 60.0),
                (ClipEffect::SPILL_RANGE_KEY, 60.0),
            ],
            &[],
        )
    }

    /// Green Screen and Blue Screen.
    pub fn built_ins() -> Vec<EffectStackPreset> {
        vec![
            EffectStackPreset::new("greenScreen", "Green Screen", StackBin::Keying, vec![Self::screen(125.0)]),
            EffectStackPreset::new("blueScreen", "Blue Screen", StackBin::Keying, vec![Self::screen(225.0)]),
        ]
    }
}

/// Film and tape looks: presets of the `Looks` bin. Applying one adds an instance of each effect, in order, to the clip
/// (one undo step); the instances are ordinary effects afterwards.
pub struct FilmPresets;

impl FilmPresets {
    /// Prefix of every look id.
    pub const ID_PREFIX: &'static str = "preset.";
    /// Film halation: the red-orange glow around bright parts.
    const HALATION_COLOR: EffectColor = EffectColor { red: 1.0, green: 0.45, blue: 0.2, alpha: 1.0 };

    /// Film Look, VHS and Bad TV. Gaussian Blur comes first: the look pass always runs after every other effect, so the
    /// order only matters for blur against crop / key, and a softened picture is what the tape and TV looks start from.
    pub fn all() -> Vec<EffectStackPreset> {
        let fx = |kind: &str, values: &[(&str, f64)]| EffectStackPreset::effect(kind, values, &[]);
        let look = |name: &str, title: &str, effects| {
            EffectStackPreset::new(&format!("{}{name}", Self::ID_PREFIX), title, StackBin::Looks, effects)
        };
        vec![
            look(
                "filmLook",
                "Film Look",
                vec![
                    // Halation: a red-orange Glow of the bright parts (Glow is also the Bloom; one glow keeps the preset cheap).
                    EffectStackPreset::effect(
                        ClipEffect::GLOW_KIND,
                        &[
                            (ClipEffect::GLOW_THRESHOLD_KEY, 60.0),
                            (ClipEffect::GLOW_RADIUS_KEY, 56.0),
                            (ClipEffect::GLOW_INTENSITY_KEY, 0.6),
                            (ClipEffect::GLOW_COLORS_KEY, 1.0),
                        ],
                        &[(ClipEffect::GLOW_COLOR_KEY, Self::HALATION_COLOR)],
                    ),
                    fx(
                        ClipEffect::GRAIN_KIND,
                        &[(ClipEffect::GRAIN_AMOUNT_KEY, 28.0), (ClipEffect::GRAIN_SIZE_KEY, 1.4)],
                    ),
                    fx(ClipEffect::GATE_WEAVE_KIND, &[(ClipEffect::AMOUNT_KEY, 2.0), (ClipEffect::ROTATION_KEY, 0.1)]),
                ],
            ),
            look(
                "vhs",
                "VHS",
                vec![
                    fx(ClipEffect::GAUSSIAN_BLUR_KIND, &[(ClipEffect::BLURRINESS_KEY, 0.8)]),
                    fx(ClipEffect::CHROMA_BLEED_KIND, &[(ClipEffect::BLEED_KEY, 8.0), (ClipEffect::SHIFT_KEY, 3.0)]),
                    fx(
                        ClipEffect::SCANLINES_KIND,
                        &[(ClipEffect::INTENSITY_KEY, 18.0), (ClipEffect::SPACING_KEY, 3.0)],
                    ),
                    fx(
                        ClipEffect::TRACKING_NOISE_KIND,
                        &[(ClipEffect::AMOUNT_KEY, 35.0), (ClipEffect::BAND_HEIGHT_KEY, 10.0)],
                    ),
                    fx(
                        ClipEffect::GRAIN_KIND,
                        &[
                            (ClipEffect::GRAIN_AMOUNT_KEY, 20.0),
                            (ClipEffect::GRAIN_SIZE_KEY, 2.0),
                            (ClipEffect::GRAIN_SOFTNESS_KEY, 20.0),
                            (ClipEffect::GRAIN_RESPONSE_KEY, 30.0),
                        ],
                    ),
                ],
            ),
            look(
                "badTV",
                "Bad TV",
                vec![
                    fx(ClipEffect::GAUSSIAN_BLUR_KIND, &[(ClipEffect::BLURRINESS_KEY, 1.2)]),
                    fx(ClipEffect::CHROMA_BLEED_KIND, &[(ClipEffect::BLEED_KEY, 4.0), (ClipEffect::SHIFT_KEY, 1.0)]),
                    fx(
                        ClipEffect::SCANLINES_KIND,
                        &[
                            (ClipEffect::INTENSITY_KEY, 45.0),
                            (ClipEffect::SPACING_KEY, 4.0),
                            (ClipEffect::THICKNESS_KEY, 55.0),
                        ],
                    ),
                    fx(
                        ClipEffect::TRACKING_NOISE_KIND,
                        &[
                            (ClipEffect::AMOUNT_KEY, 60.0),
                            (ClipEffect::BAND_HEIGHT_KEY, 18.0),
                            (ClipEffect::SPEED_KEY, 0.7),
                        ],
                    ),
                    fx(
                        ClipEffect::GLOW_KIND,
                        &[
                            (ClipEffect::GLOW_THRESHOLD_KEY, 50.0),
                            (ClipEffect::GLOW_RADIUS_KEY, 24.0),
                            (ClipEffect::GLOW_INTENSITY_KEY, 0.45),
                        ],
                    ),
                    fx(
                        ClipEffect::GRAIN_KIND,
                        &[
                            (ClipEffect::GRAIN_AMOUNT_KEY, 45.0),
                            (ClipEffect::GRAIN_SIZE_KEY, 2.2),
                            (ClipEffect::GRAIN_SOFTNESS_KEY, 15.0),
                            (ClipEffect::GRAIN_RESPONSE_KEY, 20.0),
                        ],
                    ),
                ],
            ),
        ]
    }

    /// The look with this id.
    pub fn preset(id: &str) -> Option<EffectStackPreset> {
        Self::all().into_iter().find(|p| p.id == id)
    }

    /// The id is a look id.
    pub fn is_preset_id(id: &str) -> bool {
        id.starts_with(Self::ID_PREFIX)
    }
}

/// One-click audio stacks: presets of the `Voice` bin. Applying one adds an instance of each audio effect, in order, to
/// the audio clip (one undo step). The instances are ordinary effects afterwards.
pub struct AudioPresets;

impl AudioPresets {
    /// Starts with `audio.` like every audio effect id, so the Effects panel, drops and Quick Apply send it to audio clips.
    pub const VOICE_ID: &'static str = "audio.preset.voice";
    /// Id of the Rode NTG chain.
    pub const RODE_NTG_INDOOR_ID: &'static str = "audio.preset.rodeNTGIndoor";

    /// Dialogue chain: 80 Hz Low Cut first (rumble and plosive thump out before anything reacts to it), then noise
    /// reduction, de-esser and compressor, and a -3 dB limiter last so a hot sentence never goes past -3 dBFS.
    pub fn voice() -> EffectStackPreset {
        let fx = |kind: &str, values: &[(&str, f64)]| EffectStackPreset::effect(kind, values, &[]);
        EffectStackPreset::new(
            Self::VOICE_ID,
            "Voice",
            StackBin::Voice,
            vec![
                fx(ClipEffect::AUDIO_LOW_CUT_KIND, &[(ClipEffect::LOW_CUT_FREQ_KEY, 80.0)]),
                fx(ClipEffect::AUDIO_NOISE_REDUCTION_KIND, &[(ClipEffect::NOISE_AMOUNT_REDUCTION_KEY, 60.0)]),
                fx(ClipEffect::AUDIO_DE_ESSER_KIND, &[(ClipEffect::DE_ESS_REDUCTION_KEY, 8.0)]),
                fx(
                    ClipEffect::AUDIO_COMPRESSOR_KIND,
                    &[
                        (ClipEffect::COMP_THRESHOLD_KEY, -22.0),
                        (ClipEffect::COMP_RATIO_KEY, 3.0),
                        (ClipEffect::COMP_MAKEUP_KEY, 3.0),
                    ],
                ),
                fx(ClipEffect::AUDIO_LIMITER_KIND, &[(ClipEffect::LIMITER_CEILING_KEY, -3.0)]),
            ],
        )
    }

    /// Shotgun mic recorded indoors (the maintainer's Rode NTG chain): noise reduction, then a four-band Multiband that
    /// tames the room (thresholds -15/-11/-17/-15 dB, ratios 3/2/2/3, attack 1 ms, release 100 ms, bands +4/-2/-4/-2 dB,
    /// crossovers 137 / 1147 / 6910 Hz). Same values the Premiere preset import maps.
    pub fn rode_ntg_indoor() -> EffectStackPreset {
        let mut mb: Vec<(String, f64)> = vec![(ClipEffect::MB_OUTPUT_GAIN_KEY.to_string(), 0.0)];
        let (thr, ratio, gain) = ([-15.0, -11.0, -17.0, -15.0], [3.0, 2.0, 2.0, 3.0], [4.0, -2.0, -4.0, -2.0]);
        for i in 1..=4 {
            mb.push((ClipEffect::mb_threshold_key(i), thr[i - 1]));
            mb.push((ClipEffect::mb_ratio_key(i), ratio[i - 1]));
            mb.push((ClipEffect::mb_attack_key(i), 1.0));
            mb.push((ClipEffect::mb_release_key(i), 100.0));
            mb.push((ClipEffect::mb_gain_key(i), gain[i - 1]));
        }
        mb.push((ClipEffect::mb_crossover_key(1), 137.0));
        mb.push((ClipEffect::mb_crossover_key(2), 1147.0));
        mb.push((ClipEffect::mb_crossover_key(3), 6910.0));
        let mb: Vec<(&str, f64)> = mb.iter().map(|(k, v)| (k.as_str(), *v)).collect();
        EffectStackPreset::new(
            Self::RODE_NTG_INDOOR_ID,
            "Rode NTG Indoor",
            StackBin::Voice,
            vec![
                EffectStackPreset::effect(
                    ClipEffect::AUDIO_NOISE_REDUCTION_KIND,
                    &[(ClipEffect::NOISE_AMOUNT_REDUCTION_KEY, 60.0)],
                    &[],
                ),
                EffectStackPreset::effect(ClipEffect::AUDIO_MULTIBAND_KIND, &mb, &[]),
            ],
        )
    }

    /// Both chains.
    pub fn all() -> Vec<EffectStackPreset> {
        vec![Self::voice(), Self::rode_ntg_indoor()]
    }

    /// The chain with this id.
    pub fn preset(id: &str) -> Option<EffectStackPreset> {
        Self::all().into_iter().find(|p| p.id == id)
    }

    /// The id is an audio chain id.
    pub fn is_preset_id(id: &str) -> bool {
        id == Self::VOICE_ID || id == Self::RODE_NTG_INDOOR_ID
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect_preset::ClipEffectPresetExt;
    use crate::effect_preset::{ApplyMode, TimelineEffectPresetExt};
    use sq_core_model::{AnimatedProperty, Clip, SequenceFormat, Timeline, Track};
    use sq_core_time::{Id, IdSource, TimeRange};

    fn applied(id: &str, ids: &mut SequentialIds) -> Vec<ClipEffect> {
        let p = EffectStackPresets::preset(id).unwrap();
        let kind = p.track_kind();
        let c =
            Clip::new(ids.next_id(), "c", ids.next_id(), kind, TimeRange::new(Time::ZERO, Time::new(3, 1)), Time::ZERO);
        let cid = c.id;
        let mut t = Track::new(ids.next_id(), kind);
        assert!(t.overwrite(c, ids).is_ok());
        let mut tl = Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), vec![t]);
        let set: BTreeSet<Id> = [cid].into();
        assert_eq!(tl.apply_preset(&p.preset(), &set, ApplyMode::Absolute, ids), Ok(1));
        tl.tracks[0].clips()[0].effects.clone()
    }

    #[test]
    fn every_built_in_applies_its_effects_to_a_clip_of_its_kind() {
        let mut ids = SequentialIds::default();
        let want: [(&str, TrackKind, &[&str]); 7] = [
            ("greenScreen", TrackKind::Video, &[ClipEffect::ULTRA_KEY_KIND]),
            ("blueScreen", TrackKind::Video, &[ClipEffect::ULTRA_KEY_KIND]),
            (
                "preset.filmLook",
                TrackKind::Video,
                &[ClipEffect::GLOW_KIND, ClipEffect::GRAIN_KIND, ClipEffect::GATE_WEAVE_KIND],
            ),
            (
                "preset.vhs",
                TrackKind::Video,
                &[
                    ClipEffect::GAUSSIAN_BLUR_KIND,
                    ClipEffect::CHROMA_BLEED_KIND,
                    ClipEffect::SCANLINES_KIND,
                    ClipEffect::TRACKING_NOISE_KIND,
                    ClipEffect::GRAIN_KIND,
                ],
            ),
            (
                "preset.badTV",
                TrackKind::Video,
                &[
                    ClipEffect::GAUSSIAN_BLUR_KIND,
                    ClipEffect::CHROMA_BLEED_KIND,
                    ClipEffect::SCANLINES_KIND,
                    ClipEffect::TRACKING_NOISE_KIND,
                    ClipEffect::GLOW_KIND,
                    ClipEffect::GRAIN_KIND,
                ],
            ),
            (
                "audio.preset.voice",
                TrackKind::Audio,
                &[
                    ClipEffect::AUDIO_LOW_CUT_KIND,
                    ClipEffect::AUDIO_NOISE_REDUCTION_KIND,
                    ClipEffect::AUDIO_DE_ESSER_KIND,
                    ClipEffect::AUDIO_COMPRESSOR_KIND,
                    ClipEffect::AUDIO_LIMITER_KIND,
                ],
            ),
            (
                "audio.preset.rodeNTGIndoor",
                TrackKind::Audio,
                &[ClipEffect::AUDIO_NOISE_REDUCTION_KIND, ClipEffect::AUDIO_MULTIBAND_KIND],
            ),
        ];
        for (id, kind, kinds) in want {
            let p = EffectStackPresets::preset(id).unwrap();
            assert_eq!(p.track_kind(), kind, "{id}");
            let fx = applied(id, &mut ids);
            assert_eq!(fx.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(), kinds, "{id}");
        }
    }

    #[test]
    fn values_are_set_and_row_ids_follow_the_bin() {
        let green = EffectStackPresets::preset("greenScreen").unwrap();
        let hue = green.effects[0].parameters.get(ClipEffect::KEY_HUE_KEY).map(|p| p.value);
        assert_eq!(hue, Some(125.0));
        assert_eq!(green.row_id(), "preset.builtin.greenScreen");
        assert_eq!(
            EffectStackPresets::preset_by_row_id("preset.builtin.blueScreen").map(|p| p.id),
            Some("blueScreen".into())
        );
        assert_eq!(EffectStackPresets::preset_by_row_id("preset.vhs").map(|p| p.name), Some("VHS".into()));
        let rode = AudioPresets::rode_ntg_indoor();
        let mb = &rode.effects[1];
        assert_eq!(mb.parameters.get(&ClipEffect::mb_crossover_key(3)).map(|p| p.value), Some(6910.0));
        assert_eq!(mb.parameters.get(&ClipEffect::mb_threshold_key(2)).map(|p| p.value), Some(-11.0));
        let glow = &FilmPresets::all()[0].effects[0];
        assert_eq!(glow.colors.get(ClipEffect::GLOW_COLOR_KEY).map(|p| p.value.green), Some(0.45));
    }

    #[test]
    fn applying_twice_gives_fresh_ids_and_lookups_find_every_preset() {
        let mut ids = SequentialIds::default();
        let a = applied("preset.vhs", &mut ids);
        let b = applied("preset.vhs", &mut ids);
        assert!(a.iter().all(|x| b.iter().all(|y| x.id != y.id)));
        assert!(FilmPresets::is_preset_id("preset.vhs") && !FilmPresets::is_preset_id("vhs"));
        assert!(AudioPresets::is_preset_id(AudioPresets::VOICE_ID) && AudioPresets::preset("nope").is_none());
        assert_eq!(EffectStackPresets::all().len(), MotionPresets::built_ins().len() + 7);
        let bins: BTreeSet<_> = [StackBin::Keying].into();
        assert_eq!(EffectStackPresets::offered_in(&bins).len(), 2);
    }

    // Film and tape looks: the evaluation of the look effects and the presets built from them.

    use crate::effects_editing::ClipEffectsEditingExt;
    use crate::effects_evaluation::{ClipEffects, ClipEffectsEval};
    use sq_core_color::FilmLook;
    use sq_core_model::EffectCatalog;

    fn s(n: i64, d: i64) -> Time {
        Time::new(n, d)
    }

    fn look_clip(kinds: &[(&str, &[(&str, f64)])]) -> Clip {
        let mut ids = SequentialIds::default();
        let mut c = Clip::new(
            ids.next_id(),
            "v",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(10, 1)),
            Time::ZERO,
        );
        for (kind, values) in kinds {
            let id = c.add_effect(kind, None, &mut ids).unwrap();
            for (key, v) in *values {
                c.set_parameter(id, key, *v);
            }
        }
        c
    }

    fn effects(c: &Clip, t: Time) -> ClipEffects {
        c.effects_at(t)
    }

    #[test]
    fn every_look_effect_is_in_the_catalog_with_defaults_in_range() {
        for k in [
            ClipEffect::GRAIN_KIND,
            ClipEffect::GATE_WEAVE_KIND,
            ClipEffect::SCANLINES_KIND,
            ClipEffect::CHROMA_BLEED_KIND,
            ClipEffect::TRACKING_NOISE_KIND,
            ClipEffect::AGED_FILM_KIND,
        ] {
            let spec = EffectCatalog::spec_for(k).unwrap();
            assert!(!spec.params.is_empty(), "{k}");
            for p in &spec.params {
                assert!(p.range.contains(&p.default_value), "{k}.{}", p.key);
            }
        }
    }

    #[test]
    fn defaults_evaluate_to_a_visible_look_and_zero_amounts_are_identity() {
        use ClipEffect as E;
        let c = look_clip(&[
            (E::GRAIN_KIND, &[]),
            (E::SCANLINES_KIND, &[]),
            (E::CHROMA_BLEED_KIND, &[]),
            (E::TRACKING_NOISE_KIND, &[]),
            (E::GATE_WEAVE_KIND, &[]),
        ]);
        let e = effects(&c, s(1, 1));
        assert!(e.segments.is_empty() && !e.is_identity() && e.look.needs_pass() && !e.is_empty());
        let g = e.look.grain.unwrap();
        assert!((g.amount - 0.3).abs() < 1e-9 && (g.softness - 0.4).abs() < 1e-9 && (g.luma_weight - 0.6).abs() < 1e-9);
        assert!(g.color == 0.0 && g.seed == FilmLook::seed_at_local(s(1, 1)));
        assert!(e.look.weave.is_some());

        let zero = look_clip(&[
            (E::GRAIN_KIND, &[(E::GRAIN_AMOUNT_KEY, 0.0)]),
            (E::SCANLINES_KIND, &[(E::INTENSITY_KEY, 0.0)]),
            (E::CHROMA_BLEED_KIND, &[(E::BLEED_KEY, 0.0), (E::SHIFT_KEY, 0.0)]),
            (E::TRACKING_NOISE_KIND, &[(E::AMOUNT_KEY, 0.0)]),
            (E::GATE_WEAVE_KIND, &[(E::AMOUNT_KEY, 0.0), (E::ROTATION_KEY, 0.0)]),
        ]);
        assert_eq!(effects(&zero, s(1, 1)), ClipEffects::none());
        let mut off = look_clip(&[(E::GRAIN_KIND, &[])]);
        off.effects[0].enabled = false;
        assert_eq!(effects(&off, s(1, 1)), ClipEffects::none());
    }

    #[test]
    fn grain_steps_at_24_per_second_static_grain_does_not_and_the_seed_is_clip_local() {
        use ClipEffect as E;
        let anim = look_clip(&[(E::GRAIN_KIND, &[])]);
        let seed = |c: &Clip, t: Time| effects(c, t).look.grain.unwrap().seed;
        let seeds: BTreeSet<u32> = (0..48).map(|i| seed(&anim, s(i, 48))).collect();
        assert_eq!(seeds.len(), 24);
        assert_eq!(seed(&anim, s(1, 100)), seed(&anim, s(2, 100)));
        assert_ne!(seed(&anim, s(0, 1)), seed(&anim, s(1, 24)));
        let still = look_clip(&[(E::GRAIN_KIND, &[(E::GRAIN_ANIMATE_KEY, 0.0)])]);
        assert_eq!(seed(&still, s(0, 1)), seed(&still, s(5, 1)));
        let mut c = look_clip(&[(E::GRAIN_KIND, &[])]);
        c.start = s(100, 1);
        assert_eq!(seed(&c, s(100, 1)), 0);
    }

    #[test]
    fn parameters_are_clamped_old_grain_keys_still_work_and_the_later_instance_wins() {
        use ClipEffect as E;
        let c = look_clip(&[(E::GRAIN_KIND, &[(E::GRAIN_AMOUNT_KEY, 900.0), (E::GRAIN_SIZE_KEY, 99.0)])]);
        let g = effects(&c, s(1, 1)).look.grain.unwrap();
        assert!(g.amount == 1.0 && g.size == 20.0);

        let mut old = look_clip(&[(E::GRAIN_KIND, &[])]);
        old.effects[0].parameters = [
            (E::GRAIN_AMOUNT_KEY, 40.0),
            (E::GRAIN_SIZE_KEY, 3.0),
            (E::GRAIN_COLOR_KEY, 50.0),
            (E::GRAIN_RESPONSE_KEY, 20.0),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), AnimatedProperty::new(v)))
        .collect();
        let g = effects(&old, s(1, 1)).look.grain.unwrap();
        assert!(
            (g.amount - 0.4).abs() < 1e-9
                && g.size == 3.0
                && (g.color - 0.5).abs() < 1e-9
                && (g.luma_weight - 0.2).abs() < 1e-9
        );
        assert!((g.softness - 0.4).abs() < 1e-9 && g.seed == FilmLook::seed_at_local(s(1, 1)));
        for k in ["filmLookGrain", "halation", "bloom"] {
            assert!(EffectCatalog::spec_for(k).is_none());
        }
        let two = look_clip(&[
            (E::GRAIN_KIND, &[(E::GRAIN_AMOUNT_KEY, 10.0)]),
            (E::GRAIN_KIND, &[(E::GRAIN_AMOUNT_KEY, 60.0)]),
        ]);
        assert!((effects(&two, s(1, 1)).look.grain.unwrap().amount - 0.6).abs() < 1e-9);
    }

    #[test]
    fn the_look_does_not_cut_the_segment_list() {
        use ClipEffect as E;
        let blur = (E::GAUSSIAN_BLUR_KIND, &[(E::BLURRINESS_KEY, 4.0)][..]);
        let crop = (E::CROP_KIND, &[(E::CROP_LEFT_KEY, 10.0)][..]);
        let with = look_clip(&[blur, (E::GRAIN_KIND, &[]), crop]);
        let plain = look_clip(&[blur, crop]);
        let e = effects(&with, s(1, 1));
        assert_eq!(e.segments, effects(&plain, s(1, 1)).segments);
        assert!(e.look.grain.is_some());
    }

    #[test]
    fn tracking_rolls_aged_film_is_deterministic_and_gate_weave_stays_inside_its_amount() {
        use ClipEffect as E;
        let t = look_clip(&[(E::TRACKING_NOISE_KIND, &[(E::SPEED_KEY, 0.5)])]);
        let phase = |t0: Time| effects(&t, t0).look.tracking.unwrap().phase;
        assert!(phase(s(0, 1)) == 0.0 && (phase(s(1, 1)) - 0.5).abs() < 1e-9 && phase(s(2, 1)).abs() < 1e-9);

        let c = look_clip(&[(E::AGED_FILM_KIND, &[])]);
        let aged = |t0: Time| effects(&c, t0).look.aged.unwrap();
        let a = aged(s(7, 24));
        assert_eq!(a, aged(s(7, 24)));
        assert!(a.seed == FilmLook::seed_at_local(s(7, 24)) && (a.dust - 0.4).abs() < 1e-9);
        assert!((a.scratches - 0.3).abs() < 1e-9 && (a.flicker - 0.25).abs() < 1e-9);
        assert_eq!(aged(s(1, 100)).seed, aged(s(2, 100)).seed);
        assert_eq!((0..48).map(|i| aged(s(i, 48)).seed).collect::<BTreeSet<_>>().len(), 24);
        let e = effects(&c, s(1, 1));
        assert!(e.look.needs_pass() && e.segments.is_empty());
        let zero = [(E::DUST_KEY, 0.0), (E::SCRATCHES_KEY, 0.0), (E::FLICKER_KEY, 0.0)];
        assert_eq!(effects(&look_clip(&[(E::AGED_FILM_KIND, &zero)]), s(1, 1)), ClipEffects::none());
        for (i, _) in zero.iter().enumerate() {
            let mut v = zero;
            v[i].1 = 50.0;
            assert!(effects(&look_clip(&[(E::AGED_FILM_KIND, &v)]), s(1, 1)).look.aged.is_some());
        }

        let w = look_clip(&[(E::GATE_WEAVE_KIND, &[(E::AMOUNT_KEY, 6.0), (E::ROTATION_KEY, 0.5)])]);
        let mut xs = BTreeSet::new();
        for i in 0..240 {
            let g = effects(&w, s(i, 24)).look.weave.unwrap();
            assert!(g.offset_x.abs() <= 6.0 && g.offset_y.abs() <= 6.0 && g.rotation.abs() <= 0.5);
            xs.insert(g.offset_x.to_bits());
        }
        assert!(xs.len() > 100);
        assert_eq!(effects(&w, s(7, 24)).look.weave, effects(&w, s(7, 24)).look.weave);
    }

    #[test]
    fn presets_use_only_known_effects_and_values_in_range() {
        let looks = FilmPresets::all();
        assert_eq!(looks.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Film Look", "VHS", "Bad TV"]);
        for p in looks.iter().chain(KeyingPresets::built_ins().iter()).chain(AudioPresets::all().iter()) {
            for item in &p.effects {
                let spec = EffectCatalog::spec_for(&item.kind).unwrap_or_else(|| panic!("{} {}", p.id, item.kind));
                for k in item.colors.keys() {
                    assert!(spec.params.iter().any(|x| &x.key == k));
                }
                for (k, v) in &item.parameters {
                    if let Some(param) = EffectCatalog::param(&item.kind, k) {
                        assert!(param.range.contains(&v.value), "{} {}.{k}", p.id, item.kind);
                    }
                }
            }
        }
        for p in &looks {
            assert!(
                p.bin == StackBin::Looks
                    && FilmPresets::is_preset_id(&p.id)
                    && FilmPresets::preset(&p.id).as_ref() == Some(p)
            );
        }
    }

    #[test]
    fn applying_a_look_adds_its_effects_in_order_with_its_values() {
        let mut ids = SequentialIds::default();
        let mut c = look_clip(&[]);
        let vhs = FilmPresets::preset("preset.vhs").unwrap();
        c.apply_preset(&vhs.preset(), ApplyMode::Absolute, None, &mut ids);
        assert_eq!(
            c.effects.iter().map(|e| &e.kind).collect::<Vec<_>>(),
            vhs.effects.iter().map(|e| &e.kind).collect::<Vec<_>>()
        );
        assert_eq!(c.effects[0].kind, ClipEffect::GAUSSIAN_BLUR_KIND);
        let bleed = c.effects.iter().find(|e| e.kind == ClipEffect::CHROMA_BLEED_KIND).unwrap();
        assert_eq!(bleed.parameters.get(ClipEffect::BLEED_KEY).map(|p| p.value), Some(8.0));
        assert_eq!(bleed.parameters.get(ClipEffect::SHIFT_KEY).map(|p| p.value), Some(3.0));
        let e = effects(&c, s(1, 1));
        assert!(
            e.look.chroma_bleed.is_some()
                && e.look.scanlines.is_some()
                && e.look.tracking.is_some()
                && e.look.grain.is_some()
        );
        assert!((e.blur() - ClipEffect::gaussian_sigma(0.8)).abs() < 1e-9);

        let mut film = look_clip(&[]);
        film.apply_preset(
            &FilmPresets::preset("preset.filmLook").unwrap().preset(),
            ApplyMode::Absolute,
            None,
            &mut ids,
        );
        let kinds: Vec<&str> = film.effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [ClipEffect::GLOW_KIND, ClipEffect::GRAIN_KIND, ClipEffect::GATE_WEAVE_KIND]);
        assert_eq!(
            film.effects[0].colors.get(ClipEffect::GLOW_COLOR_KEY).map(|p| p.value),
            Some(FilmPresets::HALATION_COLOR)
        );
        assert_eq!(film.effects[0].parameters.get(ClipEffect::GLOW_COLORS_KEY).map(|p| p.value), Some(1.0));
    }

    #[test]
    fn green_and_blue_screen_presets_key_with_their_hue() {
        let g = EffectStackPresets::preset("greenScreen").unwrap();
        let b = EffectStackPresets::preset("blueScreen").unwrap();
        assert!(g.name == "Green Screen" && b.name == "Blue Screen");
        assert!(g.effects.len() == 1 && g.effects[0].kind == ClipEffect::ULTRA_KEY_KIND);
        let mut c = look_clip(&[]);
        c.effects = g.effects.clone();
        let kg = &effects(&c, s(1, 1)).keys()[0];
        assert!(kg.hue == 125.0 && kg.choke > 0.0 && kg.pedestal == 0.1 && kg.keep_highlights == 0.1 && kg.spill > 0.5);
        c.effects = b.effects.clone();
        assert_eq!(effects(&c, s(1, 1)).keys()[0].hue, 225.0);
    }
}
