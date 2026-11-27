//! `--workflow-bench <out> --script <name>`: the plan, the numbers and the JSON of the editing-while-playing benchmark.
//! A script is a list of phases; each phase is a timed list of the actions a user does while the Program monitor plays
//! (drag a clip, add an effect, change it, remove it, add a Stabilizer or a subject mask, undo, pause, scrub, Play again).
//! `headless::workflow_bench` runs the actions through the session's own commands. This file is pure data and maths
//! (the expansion of a phase into timed actions, the counters, the JSON), so it is tested without an engine.

use serde_json::{Value, json};

/// One thing the user does.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    /// Nudge the selected clip (the clip under the playhead is selected first) by this many frames: one step of a drag.
    Nudge(i64),
    /// Mouse up of a drag or a slider: the undo step is final.
    EndGesture,
    /// Drop a library effect (Gaussian Blur) on the clip under the playhead.
    AddEffect,
    /// Set the Blurriness of that effect (one step of a slider drag).
    SetParam(f64),
    /// Remove the effect again.
    RemoveEffect,
    /// Drop the Stabilizer and press Start (a synthetic camera path stands in for the picture analysis).
    AddStabilizer,
    /// Add a subject (Magic) mask to the clip; its tracked mattes are synthetic.
    AddSubjectMask,
    Undo,
    /// Scrub: jump to this share (0..1000) of the sequence.
    ScrubTo(u32),
    BeginScrub,
    EndScrub,
    Pause,
    Play,
}

/// A phase: whether it starts with Play, how long it lasts and the timed actions (ms from the start of the phase).
#[derive(Clone, Debug, PartialEq)]
pub struct Phase {
    pub name: &'static str,
    pub starts_playing: bool,
    pub total_ms: u64,
    pub actions: Vec<(u64, Action)>,
}

/// A fixed pseudo-random sequence (same inputs, same script).
fn lcg(seed: &mut u64) -> u32 {
    *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    (*seed >> 33) as u32
}

/// The actions of a drag: `steps` nudges `every_ms` apart from `at`, back and forth by a frame, then mouse up.
fn drag(at: u64, steps: u64, every_ms: u64) -> Vec<(u64, Action)> {
    let mut v: Vec<_> =
        (0..steps).map(|i| (at + i * every_ms, Action::Nudge(if i % 6 < 3 { 1 } else { -1 }))).collect();
    v.push((at + steps * every_ms, Action::EndGesture));
    v
}

/// The scripts: `all` is the whole workflow, the others one part of it.
pub fn script(name: &str) -> Option<Vec<Phase>> {
    let play = |name, total_ms, actions| Phase { name, starts_playing: true, total_ms, actions };
    let slider = |from: u64, steps: u64| -> Vec<(u64, Action)> {
        let mut v: Vec<_> = (0..steps).map(|i| (from + i * 40, Action::SetParam(2.0 + 3.0 * i as f64))).collect();
        v.push((from + steps * 40, Action::EndGesture));
        v
    };
    let mut seed = 5u64;
    let burst = |seed: &mut u64, from: u64, n: u64| -> Vec<(u64, Action)> {
        let mut v = vec![(from, Action::Pause), (from + 20, Action::BeginScrub)];
        v.extend((0..n).map(|i| (from + 40 + i * 16, Action::ScrubTo(50 + lcg(seed) % 800))));
        v.push((from + 40 + n * 16 + 16, Action::EndScrub));
        v
    };
    let mut phases = Vec::new();
    let mut want = |p: Phase, part: &str| {
        if name == "all" || name == part {
            phases.push(p);
        }
    };
    want(play("play", 2500, vec![]), "play");
    want(play("drag_clip", 2500, drag(500, 15, 33)), "drag");
    let mut fx = vec![(500, Action::AddEffect)];
    fx.extend(slider(1200, 12));
    fx.push((2200, Action::RemoveEffect));
    want(play("effect_add_tweak_remove", 3000, fx), "effect");
    want(play("stabilizer_add", 3000, vec![(500, Action::AddStabilizer)]), "stabilizer");
    want(play("subject_mask_add", 3000, vec![(500, Action::AddSubjectMask)]), "subjectmask");
    want(play("undo_burst", 2500, vec![(500, Action::Undo), (800, Action::Undo), (1100, Action::Undo)]), "undo");
    let mut scrub = burst(&mut seed, 500, 30);
    scrub.push((1700, Action::Play));
    want(play("pause_scrub_play", 3500, scrub), "scrub");
    // A drag of the playhead across the sequence: slow (one step per 100 ms), fast (one step per 16 ms), both there and back.
    let sweep = |from: u64, n: u64, every: u64, step: u32| -> Vec<(u64, Action)> {
        let mut v = vec![(from, Action::Pause), (from + 20, Action::BeginScrub)];
        v.extend((0..n).map(|i| {
            let k = if i < n / 2 { i } else { n - i } as u32;
            (from + 40 + i * every, Action::ScrubTo(100 + k * step))
        }));
        v.push((from + 40 + n * every + 16, Action::EndScrub));
        v
    };
    want(play("scrub_slow", 7000, sweep(500, 60, 100, 2)), "scrub_slow");
    want(play("scrub_fast", 3500, sweep(500, 120, 16, 12)), "scrub_fast");
    // Pause, scrub, Play three times in a row without a break, then a last Play that has to start at once.
    let mut quick = Vec::new();
    for round in 0..3u64 {
        let from = 300 + round * 700;
        quick.extend(burst(&mut seed, from, 8));
        quick.push((from + 40 + 8 * 16 + 60, Action::Play));
    }
    want(play("quick_pause_scrub_play", 3000, quick), "quick");
    (!phases.is_empty()).then_some(phases)
}

/// Process CPU time in seconds (user + system): `/proc/self/stat` on Linux (10 ms ticks), `ps` elsewhere.
pub fn cpu_seconds() -> f64 {
    #[cfg(target_os = "linux")]
    if let Ok(text) = std::fs::read_to_string("/proc/self/stat")
        && let Some(rest) = text.rsplit(')').next()
    {
        let f: Vec<&str> = rest.split_whitespace().collect();
        if let (Some(u), Some(s)) = (f.get(11), f.get(12)) {
            return (u.parse::<f64>().unwrap_or(0.0) + s.parse::<f64>().unwrap_or(0.0)) / 100.0;
        }
    }
    crate::play_bench::cpu_seconds().unwrap_or(0.0)
}

/// Peak resident memory of the process so far in MB: `VmHWM` on Linux, the current size elsewhere.
pub fn peak_rss_mb() -> f64 {
    #[cfg(target_os = "linux")]
    if let Ok(text) = std::fs::read_to_string("/proc/self/status")
        && let Some(kb) = text.lines().find_map(|l| l.strip_prefix("VmHWM:"))
        && let Ok(kb) = kb.trim().trim_end_matches("kB").trim().parse::<f64>()
    {
        return kb / 1024.0;
    }
    crate::play_bench::rss_mb().unwrap_or(0.0)
}

/// What one phase measured.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhaseResult {
    pub phase: String,
    pub wall_ms: f64,
    pub playing_ms: f64,
    /// New frame positions on screen while playing.
    pub shown: u32,
    pub expected: f64,
    pub standins: u64,
    pub dropped: u64,
    pub gaps_over_50: u32,
    pub max_gap_ms: f64,
    /// From the first Play of the phase to the first new picture.
    pub play_first_ms: Option<f64>,
    /// From the last Play after a pause to its first new picture.
    pub replay_first_ms: Option<f64>,
    pub cpu_pct: f64,
    pub rss_peak_mb: f64,
    pub ui_over_25ms: u32,
    pub max_ui_ms: f64,
    /// Edit actions that changed the timeline, and the slowest call of an action (the UI thread is blocked this long).
    pub applied: u32,
    pub max_call_ms: f64,
    pub call_of: String,
    /// Each paused seek: from the request to the first different picture on screen (ms).
    pub seek_ms: Vec<f64>,
    pub stages: Vec<String>,
}

/// The p50 / p95 / max of `values` (nearest rank), `None` when empty.
pub fn percentiles(values: &[f64]) -> Option<(f64, f64, f64)> {
    if values.is_empty() {
        return None;
    }
    let mut v = values.to_vec();
    v.sort_by(f64::total_cmp);
    let rank = |p: f64| v[(((v.len() as f64) * p).ceil() as usize).clamp(1, v.len()) - 1];
    Some((rank(0.5), rank(0.95), v[v.len() - 1]))
}

impl PhaseResult {
    pub fn pct_shown(&self) -> f64 {
        if self.expected <= 0.0 { 100.0 } else { 100.0 * f64::from(self.shown) / self.expected }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "phase": self.phase, "wall_ms": round1(self.wall_ms), "playing_ms": round1(self.playing_ms),
            "shown": self.shown, "expected": round1(self.expected), "pct_shown": round1(self.pct_shown()),
            "standins": self.standins, "dropped": self.dropped, "gaps_over_50": self.gaps_over_50,
            "max_gap_ms": round1(self.max_gap_ms), "play_first_ms": self.play_first_ms.map(round1),
            "replay_first_ms": self.replay_first_ms.map(round1), "cpu_pct": round1(self.cpu_pct),
            "rss_peak_mb": round1(self.rss_peak_mb), "ui_over_25ms": self.ui_over_25ms, "max_ui_ms": round1(self.max_ui_ms),
            "applied": self.applied, "max_call_ms": round1(self.max_call_ms), "call_of": self.call_of,
            "seeks": self.seek_ms.len(),
            "seek_p50_ms": percentiles(&self.seek_ms).map(|p| round1(p.0)),
            "seek_p95_ms": percentiles(&self.seek_ms).map(|p| round1(p.1)),
            "seek_max_ms": percentiles(&self.seek_ms).map(|p| round1(p.2)),
            "stages": self.stages,
        })
    }
}

fn round1<T: Into<f64>>(v: T) -> f64 {
    (v.into() * 10.0).round() / 10.0
}

/// The summary line: the phases below 99 % shown, any gap over 50 ms, and the totals.
pub fn summary(results: &[PhaseResult]) -> Value {
    let shown: u32 = results.iter().map(|r| r.shown).sum();
    let expected: f64 = results.iter().map(|r| r.expected).sum();
    let worst = results.iter().min_by(|a, b| a.pct_shown().total_cmp(&b.pct_shown()));
    json!({
        "summary": true, "phases": results.len(),
        "pct_shown": round1(if expected > 0.0 { 100.0 * f64::from(shown) / expected } else { 100.0 }),
        "gaps_over_50": results.iter().map(|r| r.gaps_over_50).sum::<u32>(),
        "max_gap_ms": round1(results.iter().map(|r| r.max_gap_ms).fold(0.0, f64::max)),
        "standins": results.iter().map(|r| r.standins).sum::<u64>(),
        "cpu_pct_max": round1(results.iter().map(|r| r.cpu_pct).fold(0.0, f64::max)),
        "rss_peak_mb": round1(results.iter().map(|r| r.rss_peak_mb).fold(0.0, f64::max)),
        "worst_phase": worst.map(|r| r.phase.clone()),
        "below_99": results.iter().filter(|r| r.pct_shown() < 99.0).map(|r| r.phase.clone()).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seek_latency_percentiles_use_the_nearest_rank() {
        assert_eq!(percentiles(&[]), None);
        assert_eq!(percentiles(&[7.0]), Some((7.0, 7.0, 7.0)));
        let v: Vec<f64> = (1..=20).map(f64::from).collect();
        assert_eq!(percentiles(&v), Some((10.0, 19.0, 20.0)));
    }

    #[test]
    fn the_script_is_deterministic_and_every_action_fits_in_its_phase() {
        let a = script("all").expect("all");
        assert_eq!(a, script("all").expect("all"));
        assert_eq!(
            a.len(),
            10,
            "play, drag, effect, stabilizer, subject mask, undo, scrub, scrub_slow, scrub_fast, quick"
        );
        for p in &a {
            assert!(p.actions.windows(2).all(|w| w[0].0 <= w[1].0), "{} is not in time order", p.name);
            assert!(p.actions.iter().all(|(at, _)| *at < p.total_ms), "{} has an action after its end", p.name);
        }
        assert!(script("nope").is_none());
    }

    #[test]
    fn a_drag_is_fifteen_steps_over_half_a_second_ending_with_mouse_up() {
        let p = &script("drag").expect("drag")[0];
        let nudges = p.actions.iter().filter(|(_, a)| matches!(a, Action::Nudge(_))).count();
        assert_eq!(nudges, 15);
        assert_eq!(p.actions.last().map(|x| x.1), Some(Action::EndGesture));
        assert!(p.actions.last().map(|x| x.0).unwrap_or(0) - p.actions[0].0 <= 550);
    }

    #[test]
    fn scrub_phases_pause_scrub_and_play_again() {
        let q = &script("quick").expect("quick")[0];
        let count = |f: fn(&Action) -> bool| q.actions.iter().filter(|(_, a)| f(a)).count();
        assert_eq!(count(|a| *a == Action::Pause), 3);
        assert_eq!(count(|a| *a == Action::Play), 3);
        assert_eq!(count(|a| *a == Action::BeginScrub), count(|a| *a == Action::EndScrub));
    }

    #[test]
    fn the_summary_names_the_worst_phase_and_the_phases_below_99_percent() {
        let r = |name: &str, shown| PhaseResult {
            phase: name.into(),
            shown,
            expected: 100.0,
            gaps_over_50: u32::from(shown < 90),
            ..Default::default()
        };
        let s = summary(&[r("a", 100), r("b", 80)]);
        assert_eq!(s["worst_phase"], "b");
        assert_eq!(s["below_99"], json!(["b"]));
        assert_eq!(s["gaps_over_50"], 1);
        assert_eq!(s["pct_shown"], 90.0);
        assert_eq!(r("c", 50).to_json()["pct_shown"], 50.0);
    }
}
