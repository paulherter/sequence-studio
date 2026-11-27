// SPDX-License-Identifier: GPL-3.0-or-later
//! Play diagnostics so Swift and Rust play numbers can be compared (Swift: PlayProbe.swift, PresentProbe.swift).
//! `SQ_PLAY_PROBE=1` switches the seek probe on, `SQ_PLAY_PROBE_HEADLESS=1` ticks from a timer instead of the display
//! (docs/PLAYBACK-PERF.md "Seek in the real app"). The report lines carry the same `PLAYPROBE ...` text as Swift.
//! The main run-loop stall watcher is `StallWatch` (the Mac shell feeds it from a CFRunLoop observer, `sq-platform-mac`); only
//! Swift's stack watchdog (`SQ_PLAY_PROBE_STACKS`, mach thread sampling) is not ported.

use sq_core_time::Time;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// `SQ_PLAY_PROBE=1`, read once per process.
pub fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("SQ_PLAY_PROBE").is_ok_and(|v| v == "1"))
}

/// `SQ_PLAY_PROBE_HEADLESS=1` (needs `enabled`).
pub fn headless() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| enabled() && std::env::var("SQ_PLAY_PROBE_HEADLESS").is_ok_and(|v| v == "1"))
}

/// Host time in seconds (monotonic, from the first call).
pub fn now() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64() + 1.0
}

/// Stages of one jump, in order. t0 is the input event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// The session received the command.
    Session = 0,
    /// The engine issued the seek.
    Request = 1,
    /// The render thread presented the first picture at the target.
    FirstFrame = 2,
    /// The render thread presented the complete exact frame at the target.
    Exact = 3,
    /// The UI applied it.
    Applied = 4,
    /// The drawable with the exact frame reached the glass.
    Glass = 5,
}

impl Stage {
    /// All stages in order.
    pub const ALL: [Stage; 6] =
        [Stage::Session, Stage::Request, Stage::FirstFrame, Stage::Exact, Stage::Applied, Stage::Glass];

    /// Name in the report.
    pub fn title(self) -> &'static str {
        ["session", "request", "firstFrame", "exact", "applied", "glass"][self as usize]
    }
}

/// One jump.
#[derive(Clone, Debug, PartialEq)]
pub struct Seek {
    pub label: String,
    pub t0: f64,
    /// Host time of each stage, 0 = not reached.
    pub marks: [f64; 6],
    pub target: Option<Time>,
}

impl Seek {
    /// Milliseconds from t0 to `stage`, None if not reached.
    pub fn ms(&self, stage: Stage) -> Option<f64> {
        let m = self.marks[stage as usize];
        (m > 0.0).then_some((m - self.t0) * 1000.0)
    }
}

/// p50 / p95 / p99 / worst of a list of milliseconds.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Stats {
    pub count: usize,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
    pub worst: f64,
}

impl Stats {
    pub fn new(values: &[f64]) -> Stats {
        let mut v = values.to_vec();
        v.sort_by(f64::total_cmp);
        if v.is_empty() {
            return Stats::default();
        }
        let at = |q: f64| v[(((q * v.len() as f64).ceil() as i64) - 1).clamp(0, v.len() as i64 - 1) as usize];
        Stats { count: v.len(), p50: at(0.5), p95: at(0.95), p99: at(0.99), worst: v[v.len() - 1] }
    }

    /// Same text as Swift: `n=%d p50 %.1f p95 %.1f p99 %.1f worst %.1f ms`.
    pub fn text(&self) -> String {
        if self.count == 0 {
            return "n=0".into();
        }
        format!(
            "n={} p50 {:.1} p95 {:.1} p99 {:.1} worst {:.1} ms",
            self.count, self.p50, self.p95, self.p99, self.worst
        )
    }
}

#[derive(Default)]
struct State {
    pending: Option<Seek>,
    done: Vec<Seek>,
    apply_delays: Vec<f64>,
    position_costs: Vec<f64>,
    stalls: Vec<f64>,
}

/// Seek-to-glass probe. Off by default: call sites check `enabled()` first.
#[derive(Default)]
pub struct PlayProbe {
    state: Mutex<State>,
}

impl PlayProbe {
    pub fn new() -> PlayProbe {
        PlayProbe::default()
    }

    /// The process-wide probe the engine, the window pump and the stall watcher all feed (Swift `PlayProbe.shared`).
    pub fn shared() -> &'static PlayProbe {
        static SHARED: OnceLock<PlayProbe> = OnceLock::new();
        SHARED.get_or_init(PlayProbe::new)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// t0: the input event. A jump that was still pending is dropped.
    pub fn begin(&self, label: &str, at: f64) {
        self.lock().pending = Some(Seek { label: label.into(), t0: at, marks: [0.0; 6], target: None });
    }

    /// Marks `stage` of the pending jump (first time only). `Session` without a pending jump starts one.
    pub fn note(&self, stage: Stage, target: Option<Time>, at: f64) {
        let mut s = self.lock();
        if s.pending.is_none() {
            if stage != Stage::Session {
                return;
            }
            s.pending = Some(Seek { label: "command".into(), t0: at, marks: [0.0; 6], target: None });
        }
        if let Some(p) = s.pending.as_mut() {
            if p.marks[stage as usize] == 0.0 {
                p.marks[stage as usize] = at;
            }
            if target.is_some() {
                p.target = target;
            }
        }
    }

    /// A jump is pending, the engine has seeked and its target is known.
    pub fn awaiting_frame(&self) -> Option<Time> {
        let s = self.lock();
        let p = s.pending.as_ref()?;
        (p.marks[Stage::Request as usize] > 0.0 && p.marks[Stage::Glass as usize] == 0.0).then_some(p.target).flatten()
    }

    /// The exact frame is published and not applied yet.
    pub fn awaiting_apply(&self) -> bool {
        self.lock()
            .pending
            .as_ref()
            .is_some_and(|p| p.marks[Stage::Exact as usize] > 0.0 && p.marks[Stage::Applied as usize] == 0.0)
    }

    /// The exact-frame drawable reached the glass at `t` (0 = never shown): completes the jump.
    pub fn glass(&self, t: f64) {
        let mut s = self.lock();
        let Some(mut p) = s.pending.take() else { return };
        if p.marks[Stage::Exact as usize] == 0.0 || t <= 0.0 {
            s.pending = Some(p);
            return;
        }
        p.marks[Stage::Glass as usize] = t;
        if p.marks[Stage::Applied as usize] == 0.0 {
            p.marks[Stage::Applied as usize] = t;
        }
        s.done.push(p);
    }

    pub fn completed_count(&self) -> usize {
        self.lock().done.len()
    }

    pub fn completed(&self) -> Vec<Seek> {
        self.lock().done.clone()
    }

    pub fn record_apply_delay(&self, ms: f64) {
        self.lock().apply_delays.push(ms);
    }

    pub fn record_position_cost(&self, ms: f64) {
        self.lock().position_costs.push(ms);
    }

    pub fn record_stall(&self, ms: f64) {
        self.lock().stalls.push(ms);
    }

    pub fn reset(&self) {
        *self.lock() = State::default();
    }

    /// The summary as log lines (same text as Swift).
    pub fn report(&self) -> Vec<String> {
        let s = self.lock();
        let mut out = vec![format!("PLAYPROBE seeks: {} completed", s.done.len())];
        for stage in Stage::ALL {
            let v: Vec<f64> = s.done.iter().filter_map(|k| k.ms(stage)).collect();
            if !v.is_empty() {
                out.push(format!("PLAYPROBE seek t0->{}: {}", stage.title(), Stats::new(&v).text()));
            }
        }
        for (i, k) in s.done.iter().enumerate() {
            let parts: Vec<String> =
                Stage::ALL.iter().filter_map(|&st| k.ms(st).map(|m| format!("{} {:.0}", st.title(), m))).collect();
            out.push(format!("PLAYPROBE seek #{} {}: {}", i + 1, k.label, parts.join(", ")));
        }
        out.push(format!("PLAYPROBE publish->apply: {}", Stats::new(&s.apply_delays).text()));
        out.push(format!("PLAYPROBE enginePositionChanged: {}", Stats::new(&s.position_costs).text()));
        out.push(format!("PLAYPROBE main run-loop iterations > 8 ms: {}", Stats::new(&s.stalls).text()));
        out
    }

    pub fn log_report(&self) {
        for l in self.report() {
            sq_os::errln!("{l}");
        }
    }
}

/// The main run-loop stall watcher (Swift `PlayProbe.watchMainRunLoop`): the shell reports when the loop wakes and when it goes
/// back to sleep; an iteration longer than the threshold is recorded and logged. Only the Mac has a run-loop observer to
/// feed it (as in Swift, where the watcher is Darwin-only); Windows and Linux feed nothing and the report line shows n=0.
pub struct StallWatch {
    threshold: f64,
    started: f64,
    play_start: f64,
}

/// What the loop just did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoopActivity {
    /// The loop woke up and starts its work.
    AfterWaiting,
    /// The loop finished its work and goes to sleep.
    BeforeWaiting,
}

impl StallWatch {
    pub fn new(threshold: f64) -> StallWatch {
        StallWatch { threshold, started: 0.0, play_start: 0.0 }
    }

    /// Play started at host time `t` (`now()` seconds): stalls are placed relative to it in the log.
    pub fn play_started(&mut self, t: f64) {
        self.play_start = t;
    }

    /// One run-loop activity at host time `t`. Returns the stall in ms and its log line when an iteration ran too long.
    pub fn activity(&mut self, activity: LoopActivity, t: f64) -> Option<(f64, String)> {
        if activity == LoopActivity::AfterWaiting {
            self.started = t;
            return None;
        }
        let started = std::mem::take(&mut self.started);
        if started <= 0.0 || t - started <= self.threshold {
            return None;
        }
        let ms = (t - started) * 1000.0;
        let line = if self.play_start > 0.0 && ms > 8.0 {
            format!(
                "PLAYPROBE stall {ms:.1} ms at +{:.0} ms after play start",
                (t - ms / 1000.0 - self.play_start) * 1000.0
            )
        } else {
            format!("PLAYPROBE stall {ms:.1} ms outside the play window (before play start)")
        };
        Some((ms, line))
    }
}

/// One presented frame on glass next to the time the display asked for.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample {
    /// Timeline position of the presented frame, seconds.
    pub time: f64,
    /// Host time the display asked this frame to be shown at.
    pub target: f64,
    /// Host time the frame reached the glass; 0 = never shown.
    pub presented: f64,
    pub tick_start: f64,
    pub tick_duration: f64,
    /// Clock position (seconds, not snapped) the tick read.
    pub clock: Option<f64>,
    /// False: a paused frame (the one a pause, seek or stop parked on).
    pub playing: bool,
}

impl Sample {
    pub fn new(time: f64, target: f64, presented: f64) -> Sample {
        Sample { time, target, presented, tick_start: 0.0, tick_duration: 0.0, clock: None, playing: true }
    }
}

/// What a run of samples looked like on glass. All times in ms.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Summary {
    pub frames: usize,
    pub never_shown: usize,
    /// Sorted intervals between frames on glass.
    pub intervals: Vec<f64>,
    /// Intervals longer than one sequence frame plus half a frame.
    pub late: usize,
    /// Sequence frames never presented (the playhead jumped over them).
    pub skipped: i64,
    /// Sorted distance between the time on glass and the time asked for.
    pub offsets: Vec<f64>,
    /// Sorted picture minus sound on glass (see Swift `PresentProbe.Summary.avOffsets`).
    pub av_offsets: Vec<f64>,
    /// Sequence frames the picture stepped back when a paused frame followed the last playing one.
    pub pause_step_back: i64,
}

impl Summary {
    /// Nearest-rank percentile of a sorted list.
    pub fn percentile(&self, q: f64, v: &[f64]) -> f64 {
        if v.is_empty() {
            return 0.0;
        }
        let r = (q * v.len() as f64).ceil() as i64 - 1;
        v[r.clamp(0, v.len() as i64 - 1) as usize]
    }
}

/// Collects samples of a playing engine.
#[derive(Default)]
pub struct PresentProbe {
    samples: Mutex<Vec<Sample>>,
}

impl PresentProbe {
    pub fn new() -> PresentProbe {
        PresentProbe::default()
    }

    pub fn record(&self, s: Sample) {
        self.samples.lock().unwrap_or_else(|e| e.into_inner()).push(s);
    }

    /// The samples so far, in the order they reached the glass; `reset` forgets them.
    pub fn take(&self, reset: bool) -> Vec<Sample> {
        let mut g = self.samples.lock().unwrap_or_else(|e| e.into_inner());
        let key = |s: &Sample| if s.presented == 0.0 { s.target } else { s.presented };
        let mut out = g.clone();
        out.sort_by(|a, b| key(a).total_cmp(&key(b)));
        if reset {
            g.clear();
        }
        out
    }

    /// `frame_duration` in seconds. Frames that never reached the glass count in `never_shown` and take no part in the
    /// intervals.
    pub fn summarize(samples: &[Sample], frame_duration: f64) -> Summary {
        let mut out = Summary::default();
        let mut on_glass: Vec<Sample> = samples.iter().copied().filter(|s| s.presented > 0.0).collect();
        on_glass.sort_by(|a, b| a.presented.total_cmp(&b.presented));
        let playing = samples.iter().filter(|s| s.playing).count();
        out.frames = playing;
        let shown: Vec<Sample> = on_glass.iter().copied().filter(|s| s.playing).collect();
        out.never_shown = playing - shown.len();
        if frame_duration <= 0.0 {
            return out;
        }
        for w in on_glass.windows(2) {
            if w[0].playing && !w[1].playing {
                out.pause_step_back =
                    out.pause_step_back.max(((w[0].time - w[1].time) / frame_duration).round() as i64);
            }
        }
        for w in shown.windows(2) {
            let dt = (w[1].presented - w[0].presented) * 1000.0;
            out.intervals.push(dt);
            if dt > frame_duration * 1500.0 {
                out.late += 1;
            }
            let step = ((w[1].time - w[0].time) / frame_duration).round() as i64;
            if step > 1 {
                out.skipped += step - 1;
            }
        }
        out.intervals.sort_by(f64::total_cmp);
        out.offsets = shown.iter().map(|s| (s.presented - s.target) * 1000.0).collect();
        out.offsets.sort_by(f64::total_cmp);
        out.av_offsets = shown
            .iter()
            .filter_map(|s| {
                let c = s.clock?;
                if s.tick_start <= 0.0 {
                    return None;
                }
                let at_glass = c + s.presented - s.tick_start;
                Some((s.time + frame_duration / 2.0 - at_glass) * 1000.0)
            })
            .collect();
        out.av_offsets.sort_by(f64::total_cmp);
        out
    }
}

/// One drawable on its way to the glass: the tick fills in the frame, the presented handler the time; the sample is
/// recorded when both are there. A tick that presented nothing discards it.
pub struct Slot<'a> {
    probe: &'a PresentProbe,
    state: Mutex<(Option<Sample>, Option<f64>, bool)>,
}

impl<'a> Slot<'a> {
    pub fn new(probe: &'a PresentProbe) -> Slot<'a> {
        Slot { probe, state: Mutex::new((None, None, false)) }
    }

    pub fn commit(&self, s: Sample) {
        self.finish(|st| st.0 = Some(s));
    }

    pub fn presented(&self, at: f64) {
        self.finish(|st| st.1 = Some(at));
    }

    pub fn discard(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).2 = true;
    }

    fn finish(&self, change: impl FnOnce(&mut (Option<Sample>, Option<f64>, bool))) {
        let done = {
            let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if st.2 {
                return;
            }
            change(&mut st);
            match (st.0, st.1) {
                (Some(mut s), Some(p)) => {
                    st.2 = true;
                    s.presented = p;
                    Some(s)
                }
                _ => None,
            }
        };
        if let Some(s) = done {
            self.probe.record(s);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: f64 = 1.0 / 30.0;

    #[test]
    fn the_shared_probe_is_one_process_wide_instance_and_walks_a_jump_through_every_stage() {
        assert!(std::ptr::eq(PlayProbe::shared(), PlayProbe::shared()));
        let p = PlayProbe::new();
        p.begin("jump", 1.0);
        p.note(Stage::Request, Some(Time::new(5, 30)), 1.01);
        assert_eq!(p.awaiting_frame(), Some(Time::new(5, 30)));
        p.note(Stage::FirstFrame, None, 1.02);
        p.note(Stage::Exact, None, 1.03);
        assert!(p.awaiting_apply());
        p.note(Stage::Applied, None, 1.04);
        p.glass(1.05);
        let done = p.completed();
        assert_eq!(done.len(), 1);
        assert!((done[0].ms(Stage::Glass).unwrap() - 50.0).abs() < 1e-6);
    }

    fn sample(frame: i64, at: f64, target: Option<f64>) -> Sample {
        Sample::new(frame as f64 * FD, target.unwrap_or(at), at)
    }

    #[test]
    fn even_cadence_has_no_late_or_skipped_frames() {
        let s: Vec<Sample> = (0..10).map(|i| sample(i, 100.0 + i as f64 * FD, None)).collect();
        let r = PresentProbe::summarize(&s, FD);
        assert!(r.frames == 10 && r.never_shown == 0 && r.late == 0 && r.skipped == 0);
        assert_eq!(r.intervals.len(), 9);
        assert!((r.percentile(0.5, &r.intervals) - 33.333).abs() < 0.01);
        assert!((r.percentile(0.99, &r.intervals) - 33.333).abs() < 0.01);
    }

    #[test]
    fn a_frame_that_stays_two_frames_is_late_and_the_jump_counts_skipped() {
        let s = [
            sample(0, 0.1, None),
            sample(1, 0.1 + FD, None),
            sample(2, 0.1 + 2.0 * FD, None),
            sample(4, 0.1 + 4.0 * FD, None),
        ];
        let r = PresentProbe::summarize(&s, FD);
        assert_eq!((r.late, r.skipped), (1, 1));
        assert!((r.intervals.last().unwrap() - 66.667).abs() < 0.01);
    }

    #[test]
    fn one_refresh_of_jitter_is_not_late() {
        let s = [sample(0, 0.1, None), sample(1, 0.1 + FD + 1.0 / 120.0, None), sample(2, 0.1 + 2.0 * FD, None)];
        assert_eq!(PresentProbe::summarize(&s, FD).late, 0);
    }

    #[test]
    fn frames_that_never_reached_the_glass_are_counted_apart() {
        let s = [sample(0, 0.1, None), Sample::new(FD, 0.1 + FD, 0.0), sample(2, 0.1 + 2.0 * FD, None)];
        let r = PresentProbe::summarize(&s, FD);
        assert_eq!(r.never_shown, 1);
        assert!(r.intervals.len() == 1 && r.late == 1 && r.skipped == 1);
    }

    #[test]
    fn offset_is_glass_time_minus_the_asked_time() {
        let s = [sample(0, 0.110, Some(0.100)), sample(1, 0.140, Some(0.1333))];
        let r = PresentProbe::summarize(&s, FD);
        assert!((r.offsets[0] - 6.7).abs() < 0.01 && (r.offsets[1] - 10.0).abs() < 0.01);
    }

    #[test]
    fn slot_records_once_both_halves_arrived_in_either_order() {
        let p = PresentProbe::new();
        let a = Slot::new(&p);
        a.commit(Sample::new(0.0, 1.0, 0.0));
        assert!(p.take(false).is_empty());
        a.presented(1.01);
        a.presented(9.0);
        let b = Slot::new(&p);
        b.presented(1.05);
        b.commit(Sample::new(FD, 1.04, 0.0));
        let c = Slot::new(&p);
        c.discard();
        c.presented(2.0);
        c.commit(Sample::new(1.0, 2.0, 0.0));
        assert_eq!(p.take(true).iter().map(|s| s.presented).collect::<Vec<_>>(), vec![1.01, 1.05]);
        assert!(p.take(true).is_empty());
    }

    #[test]
    fn play_probe_report_has_the_swift_lines() {
        let p = PlayProbe::new();
        p.begin("jump", 1.0);
        p.note(Stage::Session, None, 1.001);
        p.note(Stage::Request, Some(Time::new(1, 30)), 1.002);
        p.note(Stage::Exact, None, 1.010);
        assert_eq!(p.awaiting_frame(), Some(Time::new(1, 30)));
        p.glass(1.030);
        let r = p.report();
        assert_eq!(r[0], "PLAYPROBE seeks: 1 completed");
        assert!(r.contains(&"PLAYPROBE seek t0->exact: n=1 p50 10.0 p95 10.0 p99 10.0 worst 10.0 ms".to_string()));
        assert!(r.iter().any(|l| l.starts_with("PLAYPROBE seek #1 jump: session 1, request 2")));
        assert_eq!(r.last().unwrap(), "PLAYPROBE main run-loop iterations > 8 ms: n=0");
    }

    #[test]
    fn the_stall_watch_records_only_iterations_over_the_threshold() {
        let mut w = StallWatch::new(0.008);
        w.play_started(10.0);
        assert!(w.activity(LoopActivity::AfterWaiting, 11.000).is_none());
        assert!(w.activity(LoopActivity::BeforeWaiting, 11.005).is_none(), "5 ms is inside the budget");
        w.activity(LoopActivity::AfterWaiting, 12.000);
        let (ms, line) = w.activity(LoopActivity::BeforeWaiting, 12.020).expect("20 ms stall");
        assert!((ms - 20.0).abs() < 1e-6);
        assert_eq!(line, "PLAYPROBE stall 20.0 ms at +2000 ms after play start");
        assert!(w.activity(LoopActivity::BeforeWaiting, 13.0).is_none(), "a sleep without a wake-up is no iteration");
        let mut before = StallWatch::new(0.008);
        before.activity(LoopActivity::AfterWaiting, 1.0);
        let (_, line) = before.activity(LoopActivity::BeforeWaiting, 1.03).expect("stall");
        assert!(line.ends_with("outside the play window (before play start)"));
    }
}
