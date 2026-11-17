// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnglesAudioSync.swift
//! Sync by audio for Create Angles Clip: finds how far one recording's loudness envelope is shifted against another's.
//! Plain maths on envelopes (one value per time step, same step for both), no audio decoding here: the caller builds the
//! envelopes.
//!
//! Method: mean-removed, normalized cross-correlation. The search runs on envelopes thinned to at most `coarse_limit`
//! values (every lag with enough overlap), then the best lag is refined level by level back up to the full rate.

use sq_core_time::Time;
use std::collections::HashMap;
use std::hash::Hash;

/// Swift `AnglesAudioSync` (namespace).
pub struct AnglesAudioSync;

/// Where an envelope lines up against the reference.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SyncMatch {
    /// `other[i]` lines up with `reference[i + lag]`: positive = `other` started later than `reference`.
    pub lag: i64,
    /// Correlation at that lag, 0...1 (1 = identical shape).
    pub confidence: f64,
}

/// What the sound sync made of one angle.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SyncOutcome {
    /// The first envelope.
    Reference,
    /// Placed by sound.
    Synced { confidence: f64 },
    /// Not placed by sound; `confidence` is the best correlation found, `None` when nothing correlated (silence, too short).
    NotSynced { confidence: Option<f64> },
}

/// A verdict per angle.
#[derive(Clone, Debug, PartialEq)]
pub struct SyncReport<Id: Eq + Hash> {
    /// One per angle that took part.
    pub outcomes: HashMap<Id, SyncOutcome>,
    /// Angles that did not sync, in input order.
    pub failed: Vec<Id>,
    /// File origin per angle that synced (the reference at zero).
    pub origins: HashMap<Id, Time>,
}

impl AnglesAudioSync {
    /// Below this confidence the recordings most likely do not share sound.
    pub const WEAK_CONFIDENCE: f64 = 0.3;

    /// `None` when an envelope is too short, silent, or nothing correlates positively.
    /// `min_overlap`: values both envelopes must share at a lag (default: a quarter of the shorter one).
    pub fn find_match(
        reference: &[f32],
        other: &[f32],
        min_overlap: Option<usize>,
        coarse_limit: usize,
    ) -> Option<SyncMatch> {
        if reference.len() < 16 || other.len() < 16 {
            return None;
        }
        let a0 = centered(reference);
        let b0 = centered(other);
        let mut factor = 1usize;
        while a0.len().max(b0.len()) / factor > coarse_limit.max(64) {
            factor *= 2;
        }
        let need = min_overlap.unwrap_or(a0.len().min(b0.len()) / 4).max(8);

        // Coarse: every lag with enough overlap.
        let (a, b) = (thinned(&a0, factor), thinned(&b0, factor));
        let need_coarse = (need / factor).max(4);
        if a.len() < need_coarse || b.len() < need_coarse {
            return None;
        }
        let mut best = f64::NEG_INFINITY;
        let mut best_lag = 0i64;
        for lag in (need_coarse as i64 - b.len() as i64)..=(a.len() as i64 - need_coarse as i64) {
            let s = score(&a, &b, lag, need_coarse);
            if s > best {
                best = s;
                best_lag = lag;
            }
        }
        if best <= 0.0 {
            return None;
        }

        // Refine: at each finer level the lag is known to about one coarse step.
        let mut f = factor;
        while f > 1 {
            f /= 2;
            let (x, y) = if f == 1 { (a0.clone(), b0.clone()) } else { (thinned(&a0, f), thinned(&b0, f)) };
            let center = best_lag * 2;
            best = f64::NEG_INFINITY;
            for lag in (center - 2)..=(center + 2) {
                let s = score(&x, &y, lag, (need / f).max(4));
                if s > best {
                    best = s;
                    best_lag = lag;
                }
            }
        }
        (best > 0.0 && best.is_finite()).then(|| SyncMatch { lag: best_lag, confidence: best.min(1.0) })
    }

    /// `find_match` with the defaults (no overlap override, coarse limit 4096).
    pub fn find_default(reference: &[f32], other: &[f32]) -> Option<SyncMatch> {
        Self::find_match(reference, other, None, 4096)
    }

    /// The lag as time for envelopes of `rate` values per second.
    pub fn time(lag: i64, rate: i64) -> Time {
        Time::new(lag, rate.max(1))
    }

    /// The file origins a sound sync found, with a verdict per angle. `envelopes`: one per angle whose sound could be
    /// read, in angle order; the first is the reference (origin 0). An angle whose match is missing or below
    /// `WEAK_CONFIDENCE` gets no origin (it is lined up by its In point), never a silent guess. Fewer than two
    /// envelopes: no origin at all.
    pub fn report<Id: Clone + Eq + Hash>(envelopes: &[(Id, Vec<f32>)], rate: i64) -> SyncReport<Id> {
        let mut report = SyncReport { outcomes: HashMap::new(), failed: Vec::new(), origins: HashMap::new() };
        let Some((ref_id, ref_env)) = envelopes.first().filter(|_| envelopes.len() >= 2) else { return report };
        report.origins.insert(ref_id.clone(), Time::ZERO);
        report.outcomes.insert(ref_id.clone(), SyncOutcome::Reference);
        for (id, env) in &envelopes[1..] {
            if report.outcomes.contains_key(id) {
                continue;
            }
            match Self::find_default(ref_env, env) {
                Some(m) if m.confidence >= Self::WEAK_CONFIDENCE => {
                    report.origins.insert(id.clone(), Self::time(m.lag, rate));
                    report.outcomes.insert(id.clone(), SyncOutcome::Synced { confidence: m.confidence });
                }
                m => {
                    report.outcomes.insert(id.clone(), SyncOutcome::NotSynced { confidence: m.map(|m| m.confidence) });
                    report.failed.push(id.clone());
                }
            }
        }
        report
    }

    /// `report` reduced to the origins and the count of angles that did not sync.
    pub fn origins<Id: Clone + Eq + Hash>(envelopes: &[(Id, Vec<f32>)], rate: i64) -> (HashMap<Id, Time>, usize) {
        let r = Self::report(envelopes, rate);
        (r.origins, r.failed.len())
    }

    /// Status text for a sync by sound; `None` when there is nothing to say. `failed`: name and best confidence.
    pub fn note(failed: &[(&str, Option<f64>)], synced: &[f64], silent: usize, unreadable: usize) -> Option<String> {
        let pct = |c: f64| (c * 100.0).round() as i64;
        let mut problems: Vec<String> = failed
            .iter()
            .map(|(name, c)| match c {
                Some(c) => format!("{name} (confidence {} %)", pct(*c)),
                None => format!("{name} (no match)"),
            })
            .collect();
        if unreadable > 0 {
            problems.push(if unreadable == 1 {
                "1 file whose sound could not be read".to_string()
            } else {
                format!("{unreadable} files whose sound could not be read")
            });
        }
        let mut parts: Vec<String> = Vec::new();
        if !problems.is_empty() {
            parts.push(format!("Could not sync by sound: {}.", problems.join(", ")));
        }
        if silent > 0 {
            parts.push(format!("{silent} without sound."));
        }
        if !problems.is_empty() || silent > 0 {
            parts.push("Those are lined up by In point.".to_string());
        }
        if let Some(weakest) = synced.iter().copied().min_by(f64::total_cmp) {
            parts.push(format!("Synced {} by sound, weakest {} %.", synced.len(), pct(weakest)));
        }
        (!parts.is_empty()).then(|| parts.join(" "))
    }
}

fn centered(v: &[f32]) -> Vec<f64> {
    let mean = v.iter().fold(0.0, |a, &x| a + f64::from(x)) / v.len() as f64;
    v.iter().map(|&x| f64::from(x) - mean).collect()
}

fn thinned(v: &[f64], by: usize) -> Vec<f64> {
    if by <= 1 {
        return v.to_vec();
    }
    v.chunks(by).map(|c| c.iter().sum::<f64>() / c.len() as f64).collect()
}

/// Normalized correlation of `b[i]` against `a[i + lag]` over their overlap; -inf with too little overlap or silence.
fn score(a: &[f64], b: &[f64], lag: i64, min_overlap: usize) -> f64 {
    let from = (-lag).max(0);
    let to = (b.len() as i64).min(a.len() as i64 - lag);
    if to - from < min_overlap as i64 {
        return f64::NEG_INFINITY;
    }
    let (mut dot, mut ea, mut eb) = (0.0, 0.0, 0.0);
    for i in from..to {
        let (x, y) = (a[(i + lag) as usize], b[i as usize]);
        dot += x * y;
        ea += x * x;
        eb += y * y;
    }
    let norm = (ea * eb).sqrt();
    if norm > 1e-12 { dot / norm } else { f64::NEG_INFINITY }
}

/// Deterministic "speech-like" envelope: bursts of varying length and level (no audio is played or decoded).
#[cfg(test)]
pub(crate) fn test_envelope(count: usize, seed: u64) -> Vec<f32> {
    let mut state = seed;
    let mut next = || {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        state >> 33
    };
    let mut out: Vec<f32> = Vec::new();
    while out.len() < count {
        let level = (next() % 1000) as f32 / 1000.0;
        let length = (next() % 40) as usize + 5;
        for k in 0..length {
            out.push(level * (0.6 + 0.4 * ((k * 7) % 5) as f32 / 5.0));
        }
    }
    out.truncate(count);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    use super::test_envelope as envelope;

    fn silent() -> Vec<f32> {
        vec![0.0; 3000]
    }

    #[test]
    fn finds_a_later_start() {
        let scene = envelope(3000, 1);
        // The second camera started 437 steps later and recorded quieter, with its own noise floor.
        let other: Vec<f32> =
            scene[437..2600].iter().enumerate().map(|(i, x)| x * 0.4 + 0.05 + (i % 3) as f32 * 0.01).collect();
        let m = AnglesAudioSync::find_default(&scene, &other).expect("match");
        assert_eq!(m.lag, 437);
        assert!(m.confidence > 0.9);
    }

    #[test]
    fn finds_an_earlier_start() {
        let scene = envelope(3000, 2);
        let m = AnglesAudioSync::find_default(&scene[600..], &scene[..2000]).expect("match");
        assert_eq!(m.lag, -600);
    }

    #[test]
    fn coarse_search_is_refined_to_the_exact_step() {
        let scene = envelope(20_000, 3);
        // Forced thinning (factor 8) must still land on the exact lag.
        let m = AnglesAudioSync::find_match(&scene, &scene[3333..18_000], None, 2500).expect("match");
        assert_eq!(m.lag, 3333);
        assert!(m.confidence > 0.99);
    }

    #[test]
    fn unrelated_sound_is_weak() {
        let m = AnglesAudioSync::find_default(&envelope(3000, 4), &envelope(3000, 99));
        assert!(m.map_or(0.0, |m| m.confidence) < AnglesAudioSync::WEAK_CONFIDENCE);
    }

    #[test]
    fn silence_and_short_input_give_nothing() {
        assert!(AnglesAudioSync::find_default(&vec![0.0; 500], &envelope(500, 5)).is_none());
        assert!(AnglesAudioSync::find_default(&envelope(8, 6), &envelope(500, 6)).is_none());
    }

    fn four_angles() -> Vec<(&'static str, Vec<f32>)> {
        let scene = envelope(3000, 1);
        vec![
            ("ref", scene.clone()),
            ("later", scene[437..2600].to_vec()),
            ("other", envelope(3000, 8)),
            ("silent", silent()),
        ]
    }

    #[test]
    fn origins_only_for_angles_that_really_match() {
        let (origins, unmatched) = AnglesAudioSync::origins(&four_angles(), 100);
        // A weak or missing match gets no origin: such an angle is lined up by its In point.
        let want: HashMap<_, _> = [("ref", Time::ZERO), ("later", Time::new(437, 100))].into();
        assert_eq!(origins, want);
        assert_eq!(unmatched, 2);
        // One readable sound alone places nothing.
        let (alone, none) = AnglesAudioSync::origins(&[("ref", envelope(3000, 1))], 100);
        assert!(alone.is_empty() && none == 0);
    }

    #[test]
    fn report_says_which_angles_could_not_be_synced() {
        let r = AnglesAudioSync::report(&four_angles(), 100);
        assert_eq!(r.outcomes["ref"], SyncOutcome::Reference);
        assert!(matches!(r.outcomes["later"], SyncOutcome::Synced { confidence } if confidence > 0.9));
        assert!(matches!(
            r.outcomes["other"],
            SyncOutcome::NotSynced { confidence } if confidence.unwrap_or(0.0) < AnglesAudioSync::WEAK_CONFIDENCE
        ));
        assert_eq!(r.outcomes["silent"], SyncOutcome::NotSynced { confidence: None });
        assert_eq!(r.origins.len(), 2);
        assert_eq!(r.failed, vec!["other", "silent"]);
    }

    #[test]
    fn note_names_failures_with_confidence() {
        let note = AnglesAudioSync::note(&[("B.mov", Some(0.12)), ("C.mov", None)], &[0.93, 0.71], 1, 0);
        assert_eq!(
            note.as_deref(),
            Some(
                "Could not sync by sound: B.mov (confidence 12 %), C.mov (no match). 1 without sound. Those are lined up by In point. Synced 2 by sound, weakest 71 %."
            )
        );
        assert_eq!(AnglesAudioSync::note(&[], &[0.9], 0, 0).as_deref(), Some("Synced 1 by sound, weakest 90 %."));
        assert_eq!(AnglesAudioSync::note(&[], &[], 0, 0), None);
        assert_eq!(
            AnglesAudioSync::note(&[], &[], 0, 2).as_deref(),
            Some("Could not sync by sound: 2 files whose sound could not be read. Those are lined up by In point.")
        );
    }

    #[test]
    fn lag_as_time() {
        assert_eq!(AnglesAudioSync::time(437, 100), Time::new(437, 100));
        assert_eq!(AnglesAudioSync::time(-50, 100), Time::new(-1, 2));
    }
}
