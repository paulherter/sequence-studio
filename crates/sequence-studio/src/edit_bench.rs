//! `--edit-bench`: the plan and the numbers of the editing-feel benchmark. A fixed script of edit operations (blade, ripple
//! delete, trim, move, seek) each followed by a 2 s Play, run through the session's own commands by `headless::edit_bench`.
//! This file is pure data and maths (the plan, the per-operation result, the JSON), so it is tested without an engine.

use serde_json::{Value, json};

/// One kind of edit the script performs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    /// Add Edit at the playhead (all tracks).
    Blade,
    /// Two edits 0.5 s apart, then Ripple Delete of the piece between them.
    RippleDelete,
    /// Ripple trim of the tail of the clip under the playhead by 6 frames.
    Trim,
    /// Nudge the clip under the playhead by 5 frames.
    Move,
    /// Jump somewhere (a click in the ruler).
    Seek,
}

impl Op {
    pub fn name(self) -> &'static str {
        match self {
            Op::Blade => "blade",
            Op::RippleDelete => "ripple_delete",
            Op::Trim => "trim",
            Op::Move => "move",
            Op::Seek => "seek",
        }
    }
}

/// The script: `cycles` operations, kinds in a fixed rotation, positions from a fixed generator as a fraction of the
/// sequence (never the last 3 %, so a 2 s Play and a 0.5 s piece fit). Same inputs, same plan.
pub fn plan(cycles: usize, length_ms: i64) -> Vec<(Op, i64)> {
    const KINDS: [Op; 5] = [Op::Blade, Op::Seek, Op::RippleDelete, Op::Trim, Op::Move];
    let mut seed = 11u64;
    let usable = (length_ms as f64 * 0.97) as i64;
    (0..cycles)
        .map(|i| {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let at = ((seed >> 33) as i64 % usable.max(1)).max(0);
            (KINDS[i % KINDS.len()], at)
        })
        .collect()
}

/// What one operation and the Play after it measured.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OpResult {
    pub op: &'static str,
    pub at_ms: i64,
    /// The edit changed the timeline (clip count or position), so the numbers belong to a real edit.
    pub applied: bool,
    /// The call itself (the UI thread is blocked this long).
    pub call_ms: f64,
    /// From the call to the next new monitor picture; `None` when none came within the wait (an edit that does not change the picture).
    pub to_frame_ms: Option<f64>,
    /// From Play to the first new picture position.
    pub play_first_ms: Option<f64>,
    /// Gaps between new picture positions over 300 ms while playing.
    pub gaps_over_300: u32,
    pub max_gap_ms: f64,
    pub shown: u32,
    pub dropped: u32,
    pub late: u32,
    pub quality: String,
}

impl OpResult {
    pub fn to_json(&self) -> Value {
        json!({
            "op": self.op, "at_ms": self.at_ms, "applied": self.applied, "call_ms": self.call_ms,
            "to_frame_ms": self.to_frame_ms, "play_first_ms": self.play_first_ms,
            "gaps_over_300": self.gaps_over_300, "max_gap_ms": self.max_gap_ms,
            "shown": self.shown, "dropped": self.dropped, "late": self.late, "quality": self.quality,
        })
    }
}

/// The p50 and max of the values (milliseconds), `None` for none.
fn spread(v: impl Iterator<Item = f64>) -> Value {
    let mut v: Vec<f64> = v.filter(|x| x.is_finite()).collect();
    if v.is_empty() {
        return Value::Null;
    }
    v.sort_by(f64::total_cmp);
    json!({ "n": v.len(), "p50": v[(v.len() - 1) / 2], "max": v[v.len() - 1] })
}

/// The whole run: every operation plus a summary per kind of operation.
pub fn report(results: &[OpResult]) -> Value {
    let mut by_op = serde_json::Map::new();
    for name in ["blade", "ripple_delete", "trim", "move", "seek"] {
        let of: Vec<&OpResult> = results.iter().filter(|r| r.op == name).collect();
        if of.is_empty() {
            continue;
        }
        by_op.insert(
            name.into(),
            json!({
                "applied": of.iter().filter(|r| r.applied).count(), "of": of.len(),
                "call_ms": spread(of.iter().map(|r| r.call_ms)),
                "to_frame_ms": spread(of.iter().filter_map(|r| r.to_frame_ms)),
                "play_first_ms": spread(of.iter().filter_map(|r| r.play_first_ms)),
                "gaps_over_300": of.iter().map(|r| r.gaps_over_300).sum::<u32>(),
                "dropped": of.iter().map(|r| r.dropped).sum::<u32>(),
            }),
        );
    }
    json!({
        "schema": 1,
        "summary": by_op,
        "worst_play_first_ms": results.iter().filter_map(|r| r.play_first_ms).fold(0.0, f64::max),
        "gaps_over_300": results.iter().map(|r| r.gaps_over_300).sum::<u32>(),
        "ops": results.iter().map(OpResult::to_json).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plan_is_deterministic_rotates_the_kinds_and_stays_inside_the_sequence() {
        let a = plan(20, 30_000);
        assert_eq!(a, plan(20, 30_000));
        assert_eq!(a.len(), 20);
        assert_eq!(a[0].0, Op::Blade);
        assert_eq!(a[5].0, Op::Blade);
        assert_eq!(a[2].0, Op::RippleDelete);
        assert!(a.iter().all(|(_, at)| (0..29_100).contains(at)));
    }

    #[test]
    fn the_report_summarizes_per_kind_and_counts_long_gaps() {
        let r = |op, play: f64, gaps| OpResult {
            op,
            applied: true,
            play_first_ms: Some(play),
            gaps_over_300: gaps,
            ..Default::default()
        };
        let j = report(&[r("blade", 100.0, 0), r("blade", 500.0, 2), r("seek", 50.0, 0)]);
        assert_eq!(j["summary"]["blade"]["play_first_ms"]["max"], 500.0);
        assert_eq!(j["summary"]["blade"]["gaps_over_300"], 2);
        assert_eq!(j["gaps_over_300"], 2);
        assert_eq!(j["worst_play_first_ms"], 500.0);
        assert!(j["summary"]["trim"].is_null());
        assert_eq!(j["ops"].as_array().map(Vec::len), Some(3));
    }
}
