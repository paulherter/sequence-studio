//! `SQ_WINDOW_PLAYLOG=<file>[,<seconds>]`: the real window measures its own playback. Three seconds after the first video
//! picture it presses Play (project at its start), logs every presented frame for the given seconds (default 30), writes
//! `<file>` (summary), `<file>.frames.csv` (one row per presented frame) and `<file>.engine.csv` (the engine's per-frame
//! stages) and `<file>.turns.csv` / `<file>.stalls.csv` (the window loop, `loop_trace.rs`), then quits. It is the window path the offscreen `--play-bench` does not cover: the GPU UI draw, the present
//! call pacing on the system display and the real audio clock. Without the variable nothing happens.

use std::path::PathBuf;
use std::time::{Duration, Instant};

/// What the window loop must do after this turn.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    Nothing,
    Play,
    Quit,
    /// No frame reached the screen in time (or none during the whole run): the report says why, then the app quits.
    Abort,
}

/// What a draw did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Draw {
    Presented,
    /// The system gave no drawable because the window is hidden or behind another (`CurrentSurfaceTexture::Occluded`).
    Occluded,
    /// No drawable for another reason (resizing, lost surface).
    NoDrawable,
    Failed,
}

/// What the window knows about one present besides the frame it shows (host times in us on the display timing's epoch, the
/// same as `pacing.csv` and `engine.csv`), to tell a late frame choice from a missed vsync: the draw's start against the next
/// vsync, the slot the model gave the present against the glass time that arrived, the frame the pacer chose against the
/// frame the draw showed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PresentTrace {
    pub start_us: i64,
    pub ret_us: i64,
    pub interval_us: i64,
    /// From the draw's start to the next vsync of the display grid (small: the draw started late for it).
    pub to_vsync_us: Option<i64>,
    /// The earliest vsync the present could show at, and the slot the model gave it.
    pub first_us: Option<i64>,
    pub pred_us: Option<i64>,
    /// The newest frame the pacer had chosen when the draw started.
    pub chosen: Option<i64>,
    /// Where the draw spent its time: waiting for the drawable, recording and submitting the UI, the present call (us).
    pub acquire_us: i64,
    pub draw_us: i64,
    pub present_us: i64,
}

/// How many refreshes the glass time lies after the slot the model gave the present (0: as predicted).
pub fn slot_miss(pred_us: i64, glass_us: i64, interval_us: i64) -> i64 {
    (glass_us - pred_us + interval_us.max(1) / 2).div_euclid(interval_us.max(1))
}

struct Row {
    /// Seconds from Play to the return of the present call.
    at: f64,
    /// The timeline frame the newest shown composite holds (-1 when none yet).
    frame: i64,
    /// UI draw plus present, ms.
    ui_ms: f64,
    presented: bool,
    /// The present's sequence number (`PresentSlots`), to match it with its glass time.
    seq: Option<u64>,
    trace: Option<PresentTrace>,
}

pub struct WindowPlayLog {
    path: PathBuf,
    secs: f64,
    seen_picture: Option<Instant>,
    played: Option<Instant>,
    rows: Vec<Row>,
    fps: f64,
    started: Instant,
    /// Draw outcomes over the whole run: presented, occluded, no drawable, failed.
    counts: [u32; 4],
    /// Glass times (seconds from Play) by present sequence number, where the platform reports them (Mac `presentedTime`).
    glass: std::collections::HashMap<u64, f64>,
    /// The same glass times in host microseconds (for `slot_miss` and the join with `pacing.csv`).
    glass_us: std::collections::HashMap<u64, i64>,
    next_seq: Option<u64>,
    /// First timeline frame of the run and the project's last frame (`set_range`).
    start_frame: i64,
    end_frame: Option<i64>,
}

impl WindowPlayLog {
    /// `None` unless `SQ_WINDOW_PLAYLOG` is set.
    pub fn from_env() -> Option<WindowPlayLog> {
        let v = std::env::var("SQ_WINDOW_PLAYLOG").ok().filter(|v| !v.is_empty())?;
        // The window thread builds the log: the loop trace and its watchdog watch this thread.
        crate::loop_trace::start();
        let (path, secs) = match v.rsplit_once(',') {
            Some((p, s)) if s.parse::<f64>().is_ok() => (p, s.parse::<f64>().unwrap_or(30.0)),
            _ => (v.as_str(), 30.0),
        };
        Some(WindowPlayLog {
            path: PathBuf::from(path),
            secs,
            seen_picture: None,
            played: None,
            rows: Vec::new(),
            fps: 30.0,
            started: Instant::now(),
            counts: [0; 4],
            glass: std::collections::HashMap::new(),
            glass_us: std::collections::HashMap::new(),
            next_seq: None,
            start_frame: 0,
            end_frame: None,
        })
    }

    /// Called once per loop turn.
    pub fn step(&mut self, has_picture: bool, fps: f64) -> Step {
        if let Some(t) = self.played {
            return if t.elapsed().as_secs_f64() >= self.secs { Step::Quit } else { Step::Nothing };
        }
        // Play only once a frame really reached the screen; a window that never presents (hidden, behind others) is a failed
        // run, not a run of zeros.
        if self.counts[0] == 0 {
            return if self.started.elapsed() > Duration::from_secs(25) { Step::Abort } else { Step::Nothing };
        }
        if !has_picture {
            return Step::Nothing;
        }
        let seen = *self.seen_picture.get_or_insert_with(Instant::now);
        if seen.elapsed() < Duration::from_secs(3) {
            return Step::Nothing;
        }
        self.fps = fps;
        self.played = Some(Instant::now());
        sq_playback::engine::frame_trace::set_enabled(true);
        Step::Play
    }

    /// Where the run starts and where the project ends (timeline frames): the report counts from the start and expects no
    /// frame past the end.
    pub fn set_range(&mut self, start_frame: i64, end_frame: Option<i64>) {
        self.start_frame = start_frame;
        self.end_frame = end_frame;
    }

    /// The next `frame` call belongs to present `seq`.
    pub fn note_present(&mut self, seq: u64) {
        self.next_seq = Some(seq);
    }

    /// Present `seq` reached the glass at `at` (`at_us` on the display timing's epoch).
    pub fn glass(&mut self, seq: u64, at: Instant, at_us: i64) {
        if let Some(t) = self.played {
            self.glass.insert(seq, at.saturating_duration_since(t).as_secs_f64());
            self.glass_us.insert(seq, at_us);
        }
    }

    /// One presented (or tried) frame; `frame` is the position the engine shows, in seconds.
    pub fn frame(&mut self, shown_secs: Option<f64>, ui_ms: f64, draw: Draw, trace: Option<PresentTrace>) {
        let presented = draw == Draw::Presented;
        self.counts[match draw {
            Draw::Presented => 0,
            Draw::Occluded => 1,
            Draw::NoDrawable => 2,
            Draw::Failed => 3,
        }] += 1;
        let Some(t) = self.played else { return };
        let frame = shown_secs.map_or(-1, |s| (s * self.fps).round() as i64);
        let seq = self.next_seq.take().filter(|_| presented);
        self.rows.push(Row { at: t.elapsed().as_secs_f64(), frame, ui_ms, presented, seq, trace });
    }

    /// Writes the three files; the summary text is also returned for stderr.
    pub fn finish(&mut self) -> String {
        // Rows first: `set_enabled` clears what was recorded (the first version wrote an empty engine file).
        let engine = sq_playback::engine::frame_trace::rows();
        sq_playback::engine::frame_trace::set_enabled(false);
        let _ =
            std::fs::write(self.path.with_extension("engine.csv"), sq_playback::engine::frame_trace::to_csv(&engine));
        let mut csv = String::from(FRAMES_HEADER);
        csv.push('\n');
        for r in &self.rows {
            let glass = r.seq.and_then(|s| self.glass.get(&s)).map_or(String::new(), |g| format!("{g:.4}"));
            let glass_us = r.seq.and_then(|s| self.glass_us.get(&s).copied());
            csv += &format!(
                "{:.4},{},{:.2},{},{glass},{}\n",
                r.at,
                r.frame,
                r.ui_ms,
                u8::from(r.presented),
                trace_cells(r.trace.as_ref(), r.frame, glass_us)
            );
        }
        let _ = std::fs::write(self.path.with_extension("frames.csv"), csv);
        let _ =
            std::fs::write(self.path.with_extension("pacing.csv"), sq_playback::engine::frame_trace::take_pacing_csv());
        // The loop trace: one row per loop turn and one per stall of the window thread (`loop_trace.rs`).
        let loop_text = crate::loop_trace::finish(self.played).map_or(String::new(), |r| {
            let _ = std::fs::write(self.path.with_extension("turns.csv"), r.turns_csv);
            let _ = std::fs::write(self.path.with_extension("stalls.csv"), r.stalls_csv);
            r.text
        });
        let glass_rows: Vec<(i64, Option<f64>)> = self
            .rows
            .iter()
            .filter(|r| r.presented)
            .map(|r| (r.frame, r.seq.and_then(|s| self.glass.get(&s)).copied()))
            .collect();
        let text = summary_from(
            &self.rows.iter().map(|r| (r.at, r.frame, r.ui_ms, r.presented)).collect::<Vec<_>>(),
            self.secs,
            self.fps,
            self.start_frame,
            self.end_frame,
        ) + &glass_summary(&glass_rows);
        let [ok, occluded, none, failed] = self.counts;
        let text = if ok == 0 || self.rows.iter().all(|r| !r.presented) {
            format!(
                "FAILED: the window presented no frame (presented {ok}, occluded {occluded}, no drawable {none}, draw errors {failed}). \
                 Occluded means the window was hidden or behind another one: keep it visible on its display and run again.\n{text}"
            )
        } else {
            format!(
                "{text}draw outcomes over the run: presented {ok}, occluded {occluded}, no drawable {none}, errors {failed}\n"
            )
        };
        let text = text + &loop_text;
        let _ = std::fs::write(&self.path, &text);
        text
    }
}

const FRAMES_HEADER: &str = "t_s,timeline_frame,ui_ms,presented,glass_s,start_us,ret_us,to_vsync_us,first_us,pred_us,glass_us,slot_miss,chosen,ready,acquire_us,draw_us,present_us";

/// The per-present cells after `glass_s` (empty where unknown): host times of the draw's start and return, us from the start to
/// the next vsync, the earliest and the predicted slot, the glass time, refreshes the glass lies after the prediction, the
/// frame the pacer had chosen and whether the draw showed it (1) or an older one (0).
fn trace_cells(trace: Option<&PresentTrace>, shown: i64, glass_us: Option<i64>) -> String {
    let opt = |v: Option<i64>| v.map_or(String::new(), |v| v.to_string());
    let Some(t) = trace else { return ",,,,,,,,,,,".into() };
    let miss = t.pred_us.zip(glass_us).map(|(p, g)| slot_miss(p, g, t.interval_us));
    let ready = t.chosen.map(|c| i64::from(shown >= c));
    format!(
        "{},{},{},{},{},{},{},{},{},{},{},{}",
        t.start_us,
        t.ret_us,
        opt(t.to_vsync_us),
        opt(t.first_us),
        opt(t.pred_us),
        opt(glass_us),
        opt(miss),
        opt(t.chosen),
        opt(ready),
        t.acquire_us,
        t.draw_us,
        t.present_us
    )
}

/// What the display really showed, from `(timeline frame, glass time in seconds)` of each present: how many presents have a
/// glass time, the spread of the time between two glass times, and how many refreshes each timeline frame was on the glass
/// (the refresh being the median glass interval). Says so loudly where nothing was timed.
pub fn glass_summary(rows: &[(i64, Option<f64>)]) -> String {
    let timed: Vec<(i64, f64)> = rows.iter().filter_map(|(f, g)| g.map(|g| (*f, g))).collect();
    if timed.len() < 3 {
        return format!(
            "glass: {} of {} presents timed (no present timestamps: the platform reports none, or the hook did not attach)\n",
            timed.len(),
            rows.len()
        );
    }
    let mut gaps: Vec<f64> = timed.windows(2).map(|w| (w[1].1 - w[0].1) * 1000.0).filter(|g| *g > 0.5).collect();
    gaps.sort_by(f64::total_cmp);
    let at = |q: usize| gaps.get((gaps.len() * q / 100).min(gaps.len().saturating_sub(1))).copied().unwrap_or(0.0);
    let refresh = at(50).max(1.0);
    // Per new timeline frame: the glass time of its first present; the hold is the distance to the next one in refreshes.
    let mut first: Vec<(i64, f64)> = Vec::new();
    for (f, g) in &timed {
        if first.last().is_none_or(|l| l.0 != *f) {
            first.push((*f, *g));
        }
    }
    let mut hist = std::collections::BTreeMap::new();
    for w in first.windows(2) {
        *hist.entry(((w[1].1 - w[0].1) * 1000.0 / refresh).round() as i64).or_insert(0u32) += 1;
    }
    format!(
        "glass: {} of {} presents timed; glass interval ms p50 {:.1} p95 {:.1} p99 {:.1} max {:.1}\n\
         refreshes per timeline frame on the glass (cadence): {hist:?}\n",
        timed.len(),
        rows.len(),
        at(50),
        at(95),
        at(99),
        gaps.last().copied().unwrap_or(0.0),
    )
}

/// The report from `(seconds, frame, ui ms, presented)` rows: frames shown against expected, skipped timeline frames,
/// gaps between new timeline frames over 50/100/300 ms, how many presents each frame was held (60 Hz on 30 fps = 2) and the
/// present interval spread.
#[cfg(test)]
pub fn summary(rows: &[(f64, i64, f64, bool)], secs: f64, fps: f64) -> String {
    summary_from(rows, secs, fps, 0, None)
}

/// Longest wait Play may take before the first picture moves (the intended pre-roll).
const PRE_ROLL_ALLOWED_MS: f64 = 500.0;

/// `summary` for a run that starts at timeline frame `start` (`SQ_WINDOW_PLAYLOG_START`) on a project that ends at frame `end`:
/// pictures before the start frame (the window still shows the old position while the seek lands) are not part of the run,
/// frames are expected only up to the project end, and the wait before the first picture moves is reported as the pre-roll
/// instead of counting as a gap or as skipped frames.
pub fn summary_from(rows: &[(f64, i64, f64, bool)], secs: f64, fps: f64, start: i64, end: Option<i64>) -> String {
    let shown: Vec<&(f64, i64, f64, bool)> = rows.iter().filter(|r| r.3 && r.1 >= start.max(0)).collect();
    // New timeline frames: first present of each frame number.
    let mut firsts: Vec<(f64, i64)> = Vec::new();
    let mut holds: Vec<u32> = Vec::new();
    for r in &shown {
        if firsts.last().map(|f| f.1) == Some(r.1) {
            if let Some(h) = holds.last_mut() {
                *h += 1;
            }
        } else {
            firsts.push((r.0, r.1));
            holds.push(1);
        }
    }
    let skipped: i64 = firsts.windows(2).map(|w| (w[1].1 - w[0].1 - 1).max(0)).sum();
    let backwards = firsts.windows(2).filter(|w| w[1].1 < w[0].1).count();
    // The wait until the first picture moves is the pre-roll, not a gap of the run.
    let gaps: Vec<f64> = firsts.windows(2).skip(1).map(|w| (w[1].0 - w[0].0) * 1e3).collect();
    let pre_roll = match (firsts.first(), firsts.get(1)) {
        (Some(a), Some(b)) => {
            let flag = if b.0 * 1e3 > PRE_ROLL_ALLOWED_MS { " (over the 500 ms allowed)" } else { "" };
            format!("pre-roll: first picture {:.0} ms, first move {:.0} ms{flag}\n", a.0 * 1e3, b.0 * 1e3)
        }
        _ => String::new(),
    };
    let expected = {
        let run = secs * fps;
        end.map_or(run, |e| run.min((e - start.max(0) + 1) as f64))
    };
    let over = |ms: f64| gaps.iter().filter(|g| **g > ms).count();
    let mut hold_hist = std::collections::BTreeMap::new();
    for h in &holds {
        *hold_hist.entry(*h).or_insert(0u32) += 1;
    }
    let mut pres: Vec<f64> = shown.windows(2).map(|w| (w[1].0 - w[0].0) * 1e3).collect();
    pres.sort_by(f64::total_cmp);
    let q = |p: f64| pres.get(((pres.len().max(1) - 1) as f64 * p).round() as usize).copied().unwrap_or(0.0);
    let mut ui: Vec<f64> = rows.iter().map(|r| r.2).collect();
    ui.sort_by(f64::total_cmp);
    let uq = |p: f64| ui.get(((ui.len().max(1) - 1) as f64 * p).round() as usize).copied().unwrap_or(0.0);
    format!(
        "window play {secs:.0} s at {fps:.2} fps: {} distinct timeline frames shown of {:.0} expected, {skipped} skipped, {backwards} backwards, {} presents\n\
         gaps between new timeline frames: >50 ms {}, >100 ms {}, >300 ms {}, max {:.1} ms\n\
         {pre_roll}presents per timeline frame (cadence): {hold_hist:?}\n\
         present interval ms p50 {:.1} p95 {:.1} p99 {:.1} max {:.1}\n\
         UI draw+present ms p50 {:.1} p95 {:.1} max {:.1}\n",
        firsts.len(),
        expected,
        shown.len(),
        over(50.0),
        over(100.0),
        over(300.0),
        gaps.iter().copied().fold(0.0, f64::max),
        q(0.5),
        q(0.95),
        q(0.99),
        q(1.0),
        uq(0.5),
        uq(0.95),
        uq(1.0),
    )
}

#[cfg(test)]
mod tests {
    use super::{PresentTrace, glass_summary, slot_miss, summary, trace_cells};

    #[test]
    fn a_smooth_30_fps_play_on_60_hz_holds_every_frame_twice_and_has_no_gaps() {
        let rows: Vec<_> = (0..120).map(|i| (i as f64 / 60.0, i64::from(i / 2), 3.0, true)).collect();
        let s = summary(&rows, 2.0, 30.0);
        assert!(s.contains("60 distinct timeline frames shown of 60 expected, 0 skipped, 0 backwards"), "{s}");
        assert!(s.contains(">50 ms 0, >100 ms 0, >300 ms 0"), "{s}");
        assert!(s.contains("{2: 60}"), "{s}");
    }

    #[test]
    fn a_run_from_a_later_start_counts_from_the_start_frame_and_reports_the_pre_roll_apart() {
        // Play from frame 300 on a project that ends at frame 330: the window shows frame 0 for 0.36 s while the seek lands,
        // frame 300 until 0.50 s (the pre-roll), then plays 301..=330 at 30 fps.
        let mut rows = vec![(0.02, 0, 1.0, true), (0.2, 0, 1.0, true), (0.362, 300, 1.0, true)];
        rows.extend((301..=330).map(|f| (0.50 + f64::from(f as i32 - 301) / 30.0, f, 1.0, true)));
        let s = super::summary_from(&rows, 30.0, 30.0, 300, Some(330));
        assert!(s.contains("31 distinct timeline frames shown of 31 expected, 0 skipped, 0 backwards"), "{s}");
        assert!(s.contains(">50 ms 0, >100 ms 0, >300 ms 0"), "{s}");
        assert!(s.contains("pre-roll: first picture 362 ms, first move 500 ms"), "{s}");
        assert!(!s.contains("over the 500 ms"), "{s}");
    }

    #[test]
    fn a_pre_roll_over_half_a_second_is_flagged_and_a_gap_after_the_first_move_still_counts() {
        let rows = vec![
            (0.1, 0, 1.0, true),
            (0.2, 300, 1.0, true),
            (0.7, 301, 1.0, true),
            (0.733, 302, 1.0, true),
            (0.9, 303, 1.0, true),
        ];
        let s = super::summary_from(&rows, 1.0, 30.0, 300, None);
        assert!(s.contains("over the 500 ms"), "{s}");
        assert!(s.contains(">50 ms 1, >100 ms 1, >300 ms 0"), "{s}");
    }

    #[test]
    fn a_stall_and_skipped_frames_are_counted() {
        // frames 0,1,2 then a 400 ms hold on 2 and a jump to 12.
        let rows = vec![(0.0, 0, 3.0, true), (0.033, 1, 3.0, true), (0.066, 2, 3.0, true), (0.466, 12, 3.0, true)];
        let s = summary(&rows, 1.0, 30.0);
        assert!(s.contains("9 skipped"), "{s}");
        assert!(s.contains(">300 ms 1"), "{s}");
    }

    #[test]
    fn a_run_without_a_presented_frame_fails_loudly_and_never_plays() {
        use super::{Draw, Step, WindowPlayLog};
        let dir = std::env::temp_dir().join(format!("sq-playlog-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let mut log = WindowPlayLog {
            path: dir.join("r.txt"),
            secs: 1.0,
            seen_picture: None,
            played: None,
            rows: Vec::new(),
            fps: 30.0,
            started: std::time::Instant::now(),
            counts: [0; 4],
            glass: std::collections::HashMap::new(),
            glass_us: std::collections::HashMap::new(),
            next_seq: None,
            start_frame: 0,
            end_frame: None,
        };
        for _ in 0..5 {
            log.frame(Some(0.0), 0.02, Draw::Occluded, None);
            assert_eq!(log.step(true, 30.0), Step::Nothing, "no Play while nothing is presented");
        }
        let text = log.finish();
        assert!(text.starts_with("FAILED: the window presented no frame (presented 0, occluded 5"), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_glass_summary_counts_refreshes_per_frame_and_says_nothing_without_times() {
        let none = glass_summary(&[(0, None), (0, None), (1, None)]);
        assert!(none.starts_with("glass: 0 of 3 presents timed"), "{none}");
        // 120 Hz glass: frames held 4, 4, 5 refreshes.
        let mut rows = Vec::new();
        let mut t = 0.0;
        for (frame, hold) in [(0, 4), (1, 4), (2, 5), (3, 4)] {
            for _ in 0..hold {
                rows.push((frame, Some(t)));
                t += 1.0 / 120.0;
            }
        }
        let text = glass_summary(&rows);
        assert!(text.contains("{4: 2, 5: 1}"), "{text}");
        assert!(text.contains("17 of 17 presents timed"), "{text}");
    }

    #[test]
    fn the_per_present_cells_tell_a_missed_vsync_from_a_frame_that_was_not_ready() {
        // 120 Hz: slot 100_000, glass 108_333 = one refresh later than predicted; chosen frame 7, shown 6 = not ready.
        assert_eq!(slot_miss(100_000, 108_333, 8_333), 1);
        assert_eq!(slot_miss(100_000, 100_400, 8_333), 0);
        assert_eq!(slot_miss(100_000, 91_667, 8_333), -1);
        let t = PresentTrace {
            start_us: 90_000,
            ret_us: 95_000,
            interval_us: 8_333,
            to_vsync_us: Some(1_500),
            first_us: Some(91_667),
            pred_us: Some(100_000),
            chosen: Some(7),
            acquire_us: 3_000,
            draw_us: 1_200,
            present_us: 300,
        };
        assert_eq!(trace_cells(Some(&t), 6, Some(108_333)), "90000,95000,1500,91667,100000,108333,1,7,0,3000,1200,300");
        assert_eq!(trace_cells(Some(&t), 7, None), "90000,95000,1500,91667,100000,,,7,1,3000,1200,300");
        assert_eq!(trace_cells(None, 7, None).matches(',').count(), 11, "as many cells as with a trace");
        assert_eq!(super::FRAMES_HEADER.matches(',').count() - 4, trace_cells(None, 0, None).matches(',').count() + 1);
    }
}
