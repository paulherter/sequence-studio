// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRMapper.swift (audio). Premiere audio components -> clip volume, Audio Gain and audio effects.

use super::{ClipContext, Mapping};
use crate::prdocument::{PRComponent, PRItem, PRParamValue};
use crate::primport_report::Status;
use sq_core_audio::audio_effects as ae;
use sq_core_audio::audio_gain::AudioGain;
use sq_core_model::{AnimatedProperty, Clip, ClipEffect};
use sq_core_time::IdSource;

const NOISE_REDUCTION_MATCH_NAME: &str = "c6762838-e451-4d22-9c90-b0eaa734605a";
const MULTIBAND_MATCH_PREFIX: &str = "3981e750-";
/// Largest multiband limiter drive (margin - threshold, dB) the importer sets up.
const MAX_LIMITER_DRIVE_DB: f64 = 12.0;
const PARAMETRIC_EQ_MATCH_PREFIX: &str = "8edcd326-";

fn static_value(comp: &PRComponent, i: usize) -> Option<&str> {
    comp.param_at(i).and_then(|p| p.static_value.as_deref())
}

/// Stores the params of one component, by position, into an effect.
struct Put<'a, 'b> {
    ids: &'a mut dyn IdSource,
    ctx: &'a ClipContext<'b>,
    comp: &'a PRComponent,
}

impl Put<'_, '_> {
    /// Parameter `i` converted by `f` and stored under `key`.
    fn put(&mut self, e: &mut ClipEffect, key: &str, i: usize, fallback: f64, f: impl Fn(f64) -> f64) {
        e.parameters.insert(
            key.to_string(),
            self.ctx.animated(self.ids, self.comp.param_at(i), fallback, PRParamValue::double, f),
        );
    }
}

impl Mapping<'_> {
    pub(crate) fn audio(&mut self, item: &PRItem, ctx: &ClipContext, c: &mut Clip) {
        // Audio Gain (linear, 1 = 0 dB) is Premiere's input level: it feeds the clip's effects, the Volume level comes after
        // them. SQ has the same thing, `Clip.audioGainDB` (applied in front of the effect chain, AudioFeeder), so it maps
        // there (clamped to SQ's range; any rest stays in the volume). Folded into the volume, +6 dB of Audio Gain lifted a
        // limiter held at -0.1 dBFS to +5.9 dBFS (hard clipping).
        let gain_db = if item.clip_gain > 0.0 { 20.0 * item.clip_gain.log10() } else { 0.0 };
        c.audio_gain_db =
            if item.clip_gain != 1.0 { gain_db.clamp(AudioGain::MIN_GAIN_DB, AudioGain::MAX_GAIN_DB) } else { 0.0 };
        let gain = item.clip_gain / 10f64.powf(c.audio_gain_db / 20.0);
        let mut has_volume = false;
        for comp in item.components.iter().filter(|c| c.is_audio) {
            let bypassed = PRParamValue::bool(static_value(comp, 0)) == Some(true);
            match comp.match_name.as_str() {
                "Internal Volume Stereo" | "Internal Volume Mono" | "Internal Volume 5.1" => {
                    // Level is linear with 1.0 = +15 dB.
                    has_volume = true;
                    c.animation.volume = ctx.animated(self.ids, comp.param_at(1), gain, PRParamValue::double, |v| {
                        gain * 10f64.powf((20.0 * v.max(1e-9).log10() + 15.0) / 20.0)
                    });
                    self.report.note("Clip volume", Status::Mapped, "");
                }
                "Internal Channel Volume Stereo" | "Internal Channel Volume Mono" => {}
                NOISE_REDUCTION_MATCH_NAME => {
                    // "Stärke" / Amount: Premiere stores the percentage as 0...1.
                    let mut e = self.make_effect(ae::AUDIO_NOISE_REDUCTION_KIND);
                    e.parameters.insert(
                        ae::NOISE_AMOUNT_REDUCTION_KEY.to_string(),
                        ctx.animated(self.ids, comp.param_at(1), 0.0, PRParamValue::double, |v| {
                            (v * 100.0).clamp(0.0, 100.0)
                        }),
                    );
                    e.enabled = !bypassed;
                    c.effects.push(e);
                    self.report.note(
                        &comp.display_name,
                        Status::Approximated,
                        "Amount = Strength x 100 %; Makeup / Auto Gain / Boost Type not mapped",
                    );
                }
                m if m.starts_with(MULTIBAND_MATCH_PREFIX) => {
                    let mut e = self.make_effect(ae::AUDIO_MULTIBAND_KIND);
                    map_multiband(comp, ctx, &mut e, self.ids);
                    e.enabled = !bypassed;
                    c.effects.push(e);
                    self.report.note(&comp.display_name, Status::Approximated, "Multiband: output gain, thresholds, ratios, band gains, attack (x 500 ms), release (x 5 s), crossovers (20 Hz + x 19980 Hz) exact; band bypass / solo / link mapped; Limiter = gain margin - threshold + brickwall at the margin (LMAX positions 48-53; threshold, margin and attack scales assumed); band mute and LMAX ratio not mapped");
                }
                m if m.starts_with(PARAMETRIC_EQ_MATCH_PREFIX) => {
                    let mut e = self.make_effect(ae::AUDIO_PARAMETRIC_EQ_KIND);
                    map_parametric_eq(comp, ctx, &mut e, self.ids);
                    e.enabled = !bypassed;
                    c.effects.push(e);
                    let mut notes = vec!["Parametric EQ: band / shelf / HP / LP frequency, gain, Q and on/off exact; HP / LP slope fixed at 12 dB/oct".to_string()];
                    if let Some(g) = PRParamValue::double(static_value(comp, 25))
                        && (g - 0.6667).abs() > 0.001
                    {
                        notes.push("output gain not mapped".to_string());
                    }
                    self.report.note(&comp.display_name, Status::Approximated, &notes.join("; "));
                }
                _ => self.report.note(&comp.display_name, Status::Dropped, "audio effect has no SQ counterpart yet"),
            }
        }
        if !has_volume && gain != 1.0 {
            c.animation.volume = AnimatedProperty::new(gain);
        }
        if item.clip_gain != 1.0 {
            self.report.note("Audio Gain", Status::Mapped, "");
        }
    }
}

/// Multiband Compressor, normalized params by position (docs/PRPROJ-IMPORT.md "Audio mapping"): 1 output gain, 2-5
/// thresholds, 6-9 ratios, 10-13 attack, 14-17 release, 18-21 band gains, 24 link, 25-28 bypass, 29-32 solo, 34-36
/// crossovers, 37-40 crossover band bypass, 41-44 band mute (not mapped), 48-53 LMAX limiter (threshold, margin, ratio,
/// attack, release, bypass). The order is Premiere's own parameter table (dvaaudiofilters "MultiBandCompressor/..."
/// strings); scales are Audition's panel ranges (MultiBandCompressor.adm): threshold -60...0 dB, gain -18...18 dB, ratio
/// 1...30, attack 0...500 ms, release 0...5000 ms, crossover 20...20000 Hz.
fn map_multiband(comp: &PRComponent, ctx: &ClipContext, e: &mut ClipEffect, ids: &mut dyn IdSource) {
    let mut p = Put { ids, ctx, comp };
    let flag = |i: usize| PRParamValue::double(static_value(comp, i)).unwrap_or(0.0) != 0.0;
    p.put(e, ae::MB_OUTPUT_GAIN_KEY, 1, 0.0, |v| v * 36.0 - 18.0);
    for b in 1..=4usize {
        p.put(e, &ae::mb_threshold_key(b), 1 + b, -20.0, |v| v * 60.0 - 60.0);
        p.put(e, &ae::mb_ratio_key(b), 5 + b, 2.0, |v| 1.0 + 29.0 * v);
        p.put(e, &ae::mb_attack_key(b), 9 + b, 10.0, |v| (v * 500.0).clamp(0.1, 500.0));
        p.put(e, &ae::mb_release_key(b), 13 + b, 100.0, |v| (v * 5_000.0).clamp(5.0, 2_000.0));
        p.put(e, &ae::mb_gain_key(b), 17 + b, 0.0, |v| v * 36.0 - 18.0);
        // 25-28 Bypass, 37-40 crossover band bypass (either one bypasses the band), 29-32 Solo. 41-44 band mute: no SQ counterpart.
        e.parameters
            .insert(ae::mb_bypass_key(b), AnimatedProperty::new(if flag(24 + b) || flag(36 + b) { 1.0 } else { 0.0 }));
        e.parameters.insert(ae::mb_solo_key(b), AnimatedProperty::new(if flag(28 + b) { 1.0 } else { 0.0 }));
    }
    e.parameters.insert(ae::MB_LINK_KEY.to_string(), AnimatedProperty::new(if flag(24) { 1.0 } else { 0.0 }));
    for x in 1..=3usize {
        p.put(e, &ae::mb_crossover_key(x), 33 + x, [120.0, 700.0, 3_000.0][x - 1], |v| {
            (20.0 + v * 19_980.0).clamp(20.0, 20_000.0)
        });
    }
    // Limiter (LMAX): on when its threshold is stored and its bypass is not set.
    if comp.param_at(48).is_some() && comp.param_at(49).is_some() {
        let bypassed = PRParamValue::double(static_value(comp, 53)).unwrap_or(0.0) != 0.0;
        e.parameters.insert(ae::MB_LIMITER_ON_KEY.to_string(), AnimatedProperty::new(if bypassed { 0.0 } else { 1.0 }));
        p.put(e, ae::MB_LIMITER_MARGIN_KEY, 49, -0.1, |v| (v * 36.0 - 18.0).clamp(-18.0, 0.0));
        // Drive = margin - threshold. Conservative: at most `MAX_LIMITER_DRIVE_DB` (the maintainer's Broadcast: 8.9 dB), so
        // an unknown preset can never push tens of dB into the limiter.
        // Keyed margin: the cap holds against its highest key (so at every moment the drive is <= the cap).
        let margin = e
            .parameters
            .get(ae::MB_LIMITER_MARGIN_KEY)
            .map_or(-0.1, |m| m.track.keys.iter().map(|k| k.value).fold(m.value, f64::max));
        p.put(e, ae::MB_LIMITER_THRESHOLD_KEY, 48, -10.0, |v| {
            (margin - MAX_LIMITER_DRIVE_DB).max((v * 60.0 - 60.0).clamp(-60.0, 0.0))
        });
        p.put(e, ae::MB_LIMITER_ATTACK_KEY, 51, 0.0, |v| (v * 500.0).clamp(0.0, 500.0)); // ASSUMED: the band attack scale
        p.put(e, ae::MB_LIMITER_RELEASE_KEY, 52, 500.0, |v| (v * 5_000.0).clamp(5.0, 5_000.0));
    }
}

/// Parametric EQ, normalized params by position: 1/2 low shelf freq/gain, 3/4 high shelf, bands 1-5 at 5+4k (freq, Q, gain,
/// enable), 30/31 shelf enable, 32 original sample rate / 192 kHz, 38/39 HP enable/freq, 41/42 LP enable/freq. A checkbox
/// without a stored value is on; a stored 0 is off. Scales confirmed on a real preset (docs/PRPROJ-IMPORT.md): frequency =
/// 20 Hz + value x (sample rate / 2 - 20 Hz) (defaults 50/200/800/3200/12800 Hz land exactly), Q = value x 5000 (the
/// bandwidth readouts 33-37 = value x 20 kHz equal frequency / Q), gain = (value - 0.5) x 48 dB. Not mapped: 25 output
/// gain (0.6667 = 0 dB, scale unknown), 26 constant Q / constant width, 40/43 HP/LP slope (SQ: 12 dB/oct).
fn map_parametric_eq(comp: &PRComponent, ctx: &ClipContext, e: &mut ClipEffect, ids: &mut dyn IdSource) {
    let mut p = Put { ids, ctx, comp };
    let sample_rate = PRParamValue::double(static_value(comp, 32)).unwrap_or(0.25) * 192_000.0;
    let nyquist = sample_rate.max(8_000.0) / 2.0;
    let on = |i: usize| {
        let off = PRParamValue::double(static_value(comp, i))
            .map_or_else(|| static_value(comp, i) == Some("false"), |v| v == 0.0);
        AnimatedProperty::new(if off { 0.0 } else { 1.0 })
    };
    let freq = |p: &mut Put, e: &mut ClipEffect, key: &str, i: usize, fallback: f64| {
        p.put(e, key, i, fallback, |v| (20.0 + v * (nyquist - 20.0)).clamp(20.0, 20_000.0));
    };
    let gain = |p: &mut Put, e: &mut ClipEffect, key: &str, i: usize| p.put(e, key, i, 0.0, |v| (v - 0.5) * 48.0);
    let q = |p: &mut Put, e: &mut ClipEffect, key: &str, i: usize| {
        p.put(e, key, i, 1.0, |v| (v * 5_000.0).clamp(0.1, 10.0))
    };
    let k = ae::peq_key;
    e.parameters.insert(k("ls", "On"), on(30));
    freq(&mut p, e, &k("ls", "Freq"), 1, 120.0);
    gain(&mut p, e, &k("ls", "Gain"), 2);
    e.parameters.insert(k("hs", "On"), on(31));
    freq(&mut p, e, &k("hs", "Freq"), 3, 8_000.0);
    gain(&mut p, e, &k("hs", "Gain"), 4);
    for b in 1..=5usize {
        let base = 5 + 4 * (b - 1);
        let id = format!("b{b}");
        freq(&mut p, e, &k(&id, "Freq"), base, [100.0, 400.0, 1_500.0, 4_000.0, 10_000.0][b - 1]);
        q(&mut p, e, &k(&id, "Q"), base + 1);
        gain(&mut p, e, &k(&id, "Gain"), base + 2);
        e.parameters.insert(k(&id, "On"), on(base + 3));
    }
    e.parameters.insert(k("hp", "On"), on(38));
    freq(&mut p, e, &k("hp", "Freq"), 39, 80.0);
    e.parameters.insert(k("lp", "On"), on(41));
    freq(&mut p, e, &k("lp", "Freq"), 42, 16_000.0);
}
