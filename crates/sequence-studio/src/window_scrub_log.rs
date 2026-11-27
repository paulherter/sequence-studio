//! `SQ_WINDOW_SCRUBLOG=<file>,<pattern>[,<seconds>]`: the real window measures its own scrubbing. Three seconds after the first
//! video picture it begins a scrub (`begin_scrub`, the call the timeline drag makes through `session_bridge`), then asks for one
//! playhead position per display frame (`scrub`, the same call as a pointer move) and records for each request which timeline
//! frame the window really showed and how long that took. Patterns: `slow` (0.5x real time), `normal` (1x), `fast` (4x), all
//! sweeping back and forth over a 10 s span; `jumps` (a random position 1-5 s from the last one every 250 ms). Writes `<file>`
//! (summary) and `<file>.scrub.csv` (one row per request), then quits. Without the variable nothing happens.

use std::path::PathBuf;
use std::time::{Duration, Instant};

/// How long one run lasts when the variable gives no seconds.
const DEFAULT_SECS: f64 = 20.0;
/// The timeline span the sweeps move over, seconds.
const SPAN_SECS: f64 = 10.0;
/// A request whose frame has not come after this long counts as dropped (a later pass over the same frame is not its answer).
const GIVE_UP: Duration = Duration::from_secs(1);
const JUMP_EVERY: Duration = Duration::from_millis(250);
/// `cold`: one jump per this long, so every jump can finish (a cold 4K decode takes 150-350 ms) before the next one.
const COLD_EVERY: Duration = Duration::from_millis(1500);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pattern {
    Slow,
    Normal,
    Fast,
    Jumps,
    /// One jump per `COLD_EVERY` over the whole clip, each into a key-frame interval not visited before in the run.
    Cold,
}

impl Pattern {
    pub fn parse(s: &str) -> Option<Pattern> {
        Some(match s {
            "slow" => Pattern::Slow,
            "normal" => Pattern::Normal,
            "fast" => Pattern::Fast,
            "jumps" => Pattern::Jumps,
            "cold" => Pattern::Cold,
            _ => return None,
        })
    }

    /// Timeline seconds per real second for the sweeps (`None` for jumps).
    fn rate(self) -> Option<f64> {
        match self {
            Pattern::Slow => Some(0.5),
            Pattern::Normal => Some(1.0),
            Pattern::Fast => Some(4.0),
            Pattern::Jumps | Pattern::Cold => None,
        }
    }
}

/// What the window loop must do after this turn.
#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    Nothing,
    /// Start the drag: `begin_scrub`.
    Begin,
    /// A pointer move to this timeline frame: `scrub`.
    Scrub(i64),
    /// The jumps are over: `end_scrub`, then Play for `SQ_WINDOW_SCRUBLOG_PLAY` seconds.
    Play,
    /// The play phase is over: stop playing, `finish`.
    QuitPlaying,
    /// The run is over: `end_scrub`, then `finish`.
    Quit,
    /// No frame reached the screen in time.
    Abort,
}

/// One request and what became of it.
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    pub at_s: f64,
    pub target: i64,
    /// Milliseconds from the request to the first present that showed `target`; `None` when none did within `GIVE_UP`.
    pub matched: Option<f64>,
    /// The newest frame on screen when the request was made.
    pub shown_before: i64,
    /// Milliseconds from the request to the first present of the target frame with its exact pictures (`cold` only).
    pub exact: Option<f64>,
}

/// A position on a back-and-forth sweep: `x` runs on, the result stays inside `0..=span` (ping-pong).
pub fn ping_pong(x: f64, span: f64) -> f64 {
    if span <= 0.0 {
        return 0.0;
    }
    let m = x.rem_euclid(2.0 * span);
    if m <= span { m } else { 2.0 * span - m }
}

/// The next jump target in `0..=span` seconds, 1-5 s from `from`, in the direction that fits (`r` in 0..1 picks the distance,
/// `up` the direction; where one direction has no room the other is taken).
pub fn jump_target(from: f64, span: f64, r: f64, up: bool) -> f64 {
    let dist = 1.0 + 4.0 * r.clamp(0.0, 1.0);
    let (hi, lo) = (from + dist, from - dist);
    let pick = if up {
        if hi <= span { hi } else { lo }
    } else if lo >= 0.0 {
        lo
    } else {
        hi
    };
    pick.clamp(0.0, span)
}

/// The slot (0..n) the k-th cold jump goes to: a stride walk through all `n` slots that hits each once and lands far from the last
/// one (the stride is about 0.618 n, made coprime with n).
pub fn cold_slot(k: u64, n: u64) -> u64 {
    fn gcd(a: u64, b: u64) -> u64 {
        if b == 0 { a } else { gcd(b, a % b) }
    }
    let n = n.max(1);
    let mut stride = ((n as f64 * 0.618) as u64).max(1);
    while gcd(stride, n) != 1 {
        stride += 1;
    }
    (k * stride) % n
}

/// The cold-jump target frame: the clip is cut into `n + 1` equal slots, slot 0 (where the run starts, already decoded) is never
/// used, jump k lands in slot `1 + cold_slot(k, n)` at the position `r` (0..1) inside it. Slots are far wider than a GOP, so no
/// jump falls into a key-frame interval an earlier one (or the start) visited.
pub fn cold_target(k: u64, n: u64, timeline_frames: i64, r: f64) -> i64 {
    let n = n.max(1);
    let width = timeline_frames.max(1) as f64 / (n + 1) as f64;
    let at = (1 + cold_slot(k, n)) as f64 * width + r.clamp(0.0, 0.999) * width;
    (at as i64).clamp(0, (timeline_frames - 1).max(0))
}

fn pct(sorted: &[f64], p: f64) -> f64 {
    sorted.get(((sorted.len().max(1) - 1) as f64 * p).round() as usize).copied().unwrap_or(0.0)
}

/// The play phase of a `cold` run: `(seconds, frames per second, presents (time s, frame))`.
pub type PlayPhase<'a> = (f64, f64, &'a [(f64, i64)]);

/// The summary of a `cold` run: per jump the time to the first picture of the target frame (a stand-in counts) and to its exact
/// pictures. `play` is the optional play phase after the jumps: `(seconds, frames per second, presents (time s, frame))`.
pub fn cold_summary(reqs: &[Request], secs: f64, idle: f64, play: Option<PlayPhase<'_>>) -> String {
    let stat = |v: Vec<f64>| {
        let mut v = v;
        v.sort_by(f64::total_cmp);
        format!("p50 {:.1} p95 {:.1} max {:.1}", pct(&v, 0.5), pct(&v, 0.95), v.last().copied().unwrap_or(0.0))
    };
    let first: Vec<f64> = reqs.iter().filter_map(|r| r.matched).collect();
    let exact: Vec<f64> = reqs.iter().filter_map(|r| r.exact).collect();
    let mut s = format!(
        "window scrub cold {secs:.0} s (idle {idle:.0} s before the first jump), jumps {}\n\
         first picture ms {} (jumps with one {})\n\
         exact frame ms {} (jumps with the exact frame {})\n",
        reqs.len(),
        stat(first.clone()),
        first.len(),
        stat(exact.clone()),
        exact.len()
    );
    if let Some((play_s, fps, presents)) = play {
        let changes: Vec<(f64, i64)> = presents.iter().copied().fold(Vec::new(), |mut v, p| {
            if v.last().is_none_or(|l: &(f64, i64)| l.1 != p.1) {
                v.push(p);
            }
            v
        });
        let mut gaps: Vec<f64> = changes.windows(2).map(|w| (w[1].0 - w[0].0) * 1e3).collect();
        gaps.sort_by(f64::total_cmp);
        let expected = (play_s * fps).round() as i64;
        let advanced = changes.last().zip(changes.first()).map_or(0, |(l, f)| l.1 - f.1);
        s += &format!(
            "playback right after the jumps {play_s:.0} s: frames shown {} of {expected} expected (timeline frames advanced {advanced}, dropped {}), gap ms p50 {:.1} p95 {:.1} max {:.1}\n",
            changes.len(),
            (expected - changes.len() as i64).max(0),
            pct(&gaps, 0.5),
            pct(&gaps, 0.95),
            gaps.last().copied().unwrap_or(0.0)
        );
    }
    s
}

/// The per-request CSV of a `cold` run.
pub fn cold_csv(reqs: &[Request]) -> String {
    let mut s = String::from("t_s,target_frame,shown_before,first_picture_ms,exact_ms\n");
    for r in reqs {
        s += &format!(
            "{:.4},{},{},{},{}\n",
            r.at_s,
            r.target,
            r.shown_before,
            r.matched.map_or(String::new(), |l| format!("{l:.2}")),
            r.exact.map_or(String::new(), |l| format!("{l:.2}"))
        );
    }
    s
}

/// The summary text of a run: request counts by how fast the matching frame arrived, and the latency spread of the matched ones.
/// `display_ms` is one display frame.
pub fn summary(reqs: &[Request], presents: &[(f64, i64)], display_ms: f64, pattern: &str, secs: f64) -> String {
    let asks: Vec<(f64, i64)> = reqs.iter().map(|r| (r.at_s, r.target)).collect();
    let (considered, stale, stall) = stale_stats(&asks, presents, display_ms / 1e3);
    // A frame that was already on screen at the request has no later present of its own (the picture does not change); a match
    // by a later sweep pass over the same frame (up to 1 s on) is no latency either: it counts as 0 ms.
    let lat: Vec<f64> =
        reqs.iter().filter_map(|r| if r.target == r.shown_before { Some(0.0) } else { r.matched }).collect();
    let within = |ms: f64| lat.iter().filter(|l| **l <= ms + 1e-9).count();
    let dropped = reqs.iter().filter(|r| r.matched.is_none() && r.target != r.shown_before).count();
    let (already, superseded, lost) = unmatched_kinds(reqs);
    let mut sorted = lat.clone();
    sorted.sort_by(f64::total_cmp);
    let q = |p: f64| sorted.get(((sorted.len().max(1) - 1) as f64 * p).round() as usize).copied().unwrap_or(0.0);
    let max = sorted.last().copied().unwrap_or(0.0);
    format!(
        "window scrub {pattern} {secs:.0} s, display frame {display_ms:.1} ms\n\
         requests {}\n\
         matched within 1 display frame {}, within 50 ms {}, within 100 ms {}\n\
         never matched (dropped) {dropped}\n\
         (frames already on screen at the request, counted as shown at 0 ms: {already}); of the dropped, superseded by a newer frame shown within 1 s {superseded}, really dropped {lost}\n\
         latency ms p50 {:.1} p95 {:.1} max {:.1} (matched requests only)\n\
         stale presents (shown frame older than the newest request by more than 1 display frame) {stale} of {considered}, max stall {:.0} ms\n",
        reqs.len(),
        within(display_ms),
        within(50.0),
        within(100.0),
        q(0.5),
        q(0.95),
        max,
        stall * 1e3
    )
}

/// Splits the requests that never matched (a present showing their frame after the request) into
/// `(already on screen, superseded, really dropped)` (`summary` counts the first as shown, at 0 ms):
/// - already on screen: the frame was the newest one shown when the request was made; nothing is presented again for an
///   unchanged frame, so a strict "first present after the request" match can never succeed (a counting artifact).
/// - superseded: a later request was shown within `GIVE_UP` of this one, so the pointer had moved on before this frame
///   could be presented (a sweep faster than one frame per display frame skips frames by design).
/// - really dropped: neither.
pub fn unmatched_kinds(reqs: &[Request]) -> (usize, usize, usize) {
    let give_up = GIVE_UP.as_secs_f64();
    let (mut already, mut superseded, mut lost) = (0, 0, 0);
    for (i, r) in reqs.iter().enumerate() {
        if r.matched.is_some() {
            continue;
        }
        if r.target == r.shown_before {
            already += 1;
        } else if reqs[i + 1..].iter().any(|n| n.matched.is_some_and(|l| n.at_s + l / 1e3 <= r.at_s + give_up)) {
            superseded += 1;
        } else {
            lost += 1;
        }
    }
    (already, superseded, lost)
}

/// The fairer metric next to the strict match: over the presents that show a requested frame, how many show a frame that is more
/// than one display frame older than the newest request (`stale`), and the longest time the picture did not change while the
/// newest request asked for another frame (`max_stall_s`). `reqs` are `(time s, target frame)`, `presents` `(time s, shown
/// frame)`, both in time order. Returns `(considered, stale, max_stall_s)`.
pub fn stale_stats(reqs: &[(f64, i64)], presents: &[(f64, i64)], display_s: f64) -> (usize, usize, f64) {
    let (mut considered, mut stale, mut max_stall) = (0, 0, 0.0f64);
    let mut newest = 0; // reqs[..newest] are made at or before the present
    let mut last_shown: Option<i64> = None;
    let mut last_change = 0.0;
    for &(t, shown) in presents {
        while newest < reqs.len() && reqs[newest].0 <= t {
            newest += 1;
        }
        let Some(&(newest_at, newest_target)) = newest.checked_sub(1).map(|i| &reqs[i]) else { continue };
        // The request this picture answers: the latest one for the shown frame.
        if let Some(&(asked_at, _)) = reqs[..newest].iter().rev().find(|r| r.1 == shown) {
            considered += 1;
            if newest_at - asked_at > display_s + 1e-9 {
                stale += 1;
            }
        }
        if last_shown != Some(shown) {
            last_shown = Some(shown);
            last_change = t;
        } else if newest_target != shown {
            max_stall = max_stall.max(t - last_change);
        }
    }
    (considered, stale, max_stall)
}

/// A present showing `shown` at `now_s` (seconds from the begin) answers every still-open request for that frame made within
/// `GIVE_UP`, except those a newer request has already overtaken: once any newer request was shown, an older one that was never
/// shown is superseded (the pointer moved on). Without this a sweep that comes back over the frame ~1 s later matched the old
/// request and reported that return trip as ~980 ms latency.
pub fn match_present(reqs: &mut [Request], shown: i64, now_s: f64) {
    let overtaken_below = reqs.iter().rposition(|r| r.matched.is_some()).unwrap_or(0);
    let give_up = GIVE_UP.as_secs_f64();
    for (i, r) in reqs.iter_mut().enumerate().rev() {
        if r.matched.is_none() && r.target == shown && i >= overtaken_below && now_s - r.at_s <= give_up {
            r.matched = Some((now_s - r.at_s).max(0.0) * 1e3);
        }
    }
}

/// The per-request CSV.
pub fn csv(reqs: &[Request]) -> String {
    let mut s = String::from("t_s,target_frame,shown_before,latency_ms\n");
    for r in reqs {
        s += &format!(
            "{:.4},{},{},{}\n",
            r.at_s,
            r.target,
            r.shown_before,
            r.matched.map_or(String::new(), |l| format!("{l:.2}"))
        );
    }
    s
}

fn env_secs(name: &str) -> f64 {
    std::env::var(name).ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0).max(0.0)
}

pub struct WindowScrubLog {
    path: PathBuf,
    pattern: Pattern,
    secs: f64,
    started: Instant,
    seen_picture: Option<Instant>,
    begun: Option<Instant>,
    presented_any: bool,
    fps: f64,
    display_frame: Duration,
    /// Frame where the span starts and its length in frames.
    span_from: i64,
    span_frames: i64,
    /// Requests made so far and the index of the next time slot.
    reqs: Vec<Request>,
    next_slot: u64,
    last_jump: f64,
    rng: u64,
    shown: i64,
    /// Every present that showed a frame: (seconds from the begin, frame).
    presents: Vec<(f64, i64)>,
    /// The run ended (`Action::Quit` was given).
    over: bool,
    /// Seconds to wait after the first picture before the first jump (`SQ_WINDOW_SCRUBLOG_IDLE`, lets a background pass fill).
    idle: f64,
    /// Seconds of play after the jumps (`SQ_WINDOW_SCRUBLOG_PLAY`, 0 = none).
    play_secs: f64,
    play_began: Option<Instant>,
    /// Presents of the play phase: (seconds from its start, frame).
    play_presents: Vec<(f64, i64)>,
    /// The exact flag of the newest shown composite.
    shown_exact: bool,
}

impl WindowScrubLog {
    /// `None` unless `SQ_WINDOW_SCRUBLOG` is set (`<file>,<pattern>[,<seconds>]`).
    pub fn from_env() -> Option<WindowScrubLog> {
        let v = std::env::var("SQ_WINDOW_SCRUBLOG").ok().filter(|v| !v.is_empty())?;
        let parts: Vec<&str> = v.split(',').collect();
        let pattern = parts.get(1).and_then(|p| Pattern::parse(p)).unwrap_or_else(|| {
            sq_os::errln!("SQ_WINDOW_SCRUBLOG: pattern must be slow, normal, fast, jumps or cold; using normal");
            Pattern::Normal
        });
        let secs = parts.get(2).and_then(|s| s.parse::<f64>().ok()).unwrap_or(DEFAULT_SECS);
        // The window thread builds the log: the loop trace (turn rows, stalls) watches this thread.
        crate::loop_trace::start();
        Some(WindowScrubLog {
            path: PathBuf::from(parts[0]),
            pattern,
            secs,
            started: Instant::now(),
            seen_picture: None,
            begun: None,
            presented_any: false,
            fps: 30.0,
            display_frame: Duration::from_micros(16_667),
            span_from: 0,
            span_frames: 0,
            reqs: Vec::new(),
            next_slot: 0,
            last_jump: 0.0,
            rng: 0x9E37_79B9_7F4A_7C15,
            shown: -1,
            presents: Vec::new(),
            over: false,
            idle: env_secs("SQ_WINDOW_SCRUBLOG_IDLE"),
            play_secs: env_secs("SQ_WINDOW_SCRUBLOG_PLAY"),
            play_began: None,
            play_presents: Vec::new(),
            shown_exact: false,
        })
    }

    fn period(&self) -> Duration {
        match self.pattern {
            Pattern::Jumps => JUMP_EVERY,
            Pattern::Cold => COLD_EVERY,
            _ => self.display_frame,
        }
    }

    fn rand(&mut self) -> f64 {
        // xorshift64: the same positions in every run.
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng >> 11) as f64 / (1u64 << 53) as f64
    }

    /// When the loop should turn next: the next request slot (a pointer drag wakes the loop with every move; a driver that only
    /// calls `scrub` would leave the loop asleep between pictures and measure that, not the scrub).
    pub fn next_wake(&self) -> Option<Instant> {
        let begun = self.begun.filter(|_| !self.over)?;
        if self.play_began.is_some() {
            return Some(Instant::now() + Duration::from_millis(5));
        }
        let period = self.period();
        Some(begun + period.mul_f64(self.next_slot as f64))
    }

    /// The pointer a real drag would have: held and moved while the scrub runs, so the window switches to its drag present path
    /// (`DragPacing`, `Surface::set_interactive`) as it does under a hand. `None` before and after the run.
    pub fn held_pointer(&self) -> Option<(f32, f32)> {
        self.begun.filter(|_| !self.over && self.play_began.is_none())?;
        Some((if self.reqs.len() < 2 { 0.0 } else { 100.0 }, 0.0))
    }

    /// Called once per loop turn. `timeline_frames` is the timeline length, `display_frame` one refresh.
    pub fn step(&mut self, has_picture: bool, fps: f64, timeline_frames: i64, display_frame: Duration) -> Action {
        if self.over {
            return Action::Nothing;
        }
        let Some(begun) = self.begun else {
            if !self.presented_any {
                return if self.started.elapsed() > Duration::from_secs(25) { Action::Abort } else { Action::Nothing };
            }
            if !has_picture {
                return Action::Nothing;
            }
            let seen = *self.seen_picture.get_or_insert_with(Instant::now);
            if seen.elapsed().as_secs_f64() < 3.0 + self.idle {
                return Action::Nothing;
            }
            self.fps = fps;
            self.display_frame = display_frame;
            let from =
                std::env::var("SQ_WINDOW_SCRUBLOG_START").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0);
            self.span_from = ((from * fps).round() as i64).clamp(0, (timeline_frames - 1).max(0));
            self.span_frames = ((SPAN_SECS * fps).round() as i64).min(timeline_frames - 1 - self.span_from).max(0);
            if self.pattern == Pattern::Cold {
                // The cold jumps spread over the whole clip, not over the 10 s span of the sweeps.
                self.span_frames = (timeline_frames - 1 - self.span_from).max(0);
            }
            self.begun = Some(Instant::now());
            return Action::Begin;
        };
        if let Some(pb) = self.play_began {
            if pb.elapsed().as_secs_f64() >= self.play_secs {
                self.over = true;
                return Action::QuitPlaying;
            }
            return Action::Nothing;
        }
        let elapsed = begun.elapsed();
        if elapsed.as_secs_f64() >= self.secs {
            if self.play_secs > 0.0 {
                self.play_began = Some(Instant::now());
                return Action::Play;
            }
            self.over = true;
            return Action::Quit;
        }
        let period = self.period();
        let slot = (elapsed.as_secs_f64() / period.as_secs_f64().max(1e-4)) as u64;
        if slot < self.next_slot {
            return Action::Nothing;
        }
        // One request per time slot; a turn that comes late skips the slots it missed, like a pointer that reports less often.
        self.next_slot = slot + 1;
        let span = self.span_frames as f64 / self.fps;
        let pos = match self.pattern.rate() {
            Some(rate) => ping_pong(rate * elapsed.as_secs_f64(), span),
            None if self.pattern == Pattern::Cold => {
                let n = (self.secs / COLD_EVERY.as_secs_f64()).floor() as u64;
                let r = self.rand();
                let k = self.reqs.len() as u64 % n.max(1);
                let target = cold_target(k, n, self.span_from + self.span_frames, r);
                self.last_jump = target as f64 / self.fps;
                self.reqs.push(Request {
                    at_s: elapsed.as_secs_f64(),
                    target,
                    matched: None,
                    shown_before: self.shown,
                    exact: None,
                });
                return Action::Scrub(target);
            }
            None => {
                let (r, up) = (self.rand(), self.rand() < 0.5);
                self.last_jump = jump_target(self.last_jump, span, r, up);
                self.last_jump
            }
        };
        let target = self.span_from + (pos * self.fps).round() as i64;
        self.reqs.push(Request {
            at_s: elapsed.as_secs_f64(),
            target,
            matched: None,
            shown_before: self.shown,
            exact: None,
        });
        Action::Scrub(target)
    }

    /// One draw: `shown` is the timeline frame the newest composite holds (`None` when none yet).
    pub fn frame(&mut self, shown: Option<i64>, exact: bool, presented: bool, now: Instant) {
        if !presented {
            return;
        }
        self.presented_any = true;
        let Some(shown) = shown else { return };
        self.shown = shown;
        self.shown_exact = exact;
        if let Some(pb) = self.play_began {
            self.play_presents.push((pb.elapsed().as_secs_f64(), shown));
            return;
        }
        if self.pattern == Pattern::Cold {
            // The newest jump only: no give-up time, a cold decode may take longer than a second. `matched` = first picture of
            // the target (a stand-in counts), `exact` = its exact pictures.
            if let (Some(b), Some(r)) = (self.begun, self.reqs.last_mut()) {
                let ms = (now.saturating_duration_since(b).as_secs_f64() - r.at_s).max(0.0) * 1e3;
                if shown == r.target {
                    r.matched.get_or_insert(ms);
                    if exact {
                        r.exact.get_or_insert(ms);
                    }
                }
            }
            return;
        }
        if let Some(b) = self.begun {
            self.presents.push((now.saturating_duration_since(b).as_secs_f64(), shown));
        }
        if let Some(b) = self.begun {
            match_present(&mut self.reqs, shown, now.saturating_duration_since(b).as_secs_f64());
        }
    }

    /// Writes the summary and the CSV; the text is returned for stderr.
    pub fn finish(&mut self) -> String {
        let name = match self.pattern {
            Pattern::Slow => "slow",
            Pattern::Normal => "normal",
            Pattern::Fast => "fast",
            Pattern::Jumps => "jumps",
            Pattern::Cold => "cold",
        };
        let text = if self.reqs.is_empty() {
            "FAILED: the window presented no frame or made no scrub request\n".to_string()
        } else if self.pattern == Pattern::Cold {
            let play = self.play_began.map(|_| (self.play_secs, self.fps, self.play_presents.as_slice()));
            cold_summary(&self.reqs, self.secs, self.idle, play)
        } else {
            summary(&self.reqs, &self.presents, self.display_frame.as_secs_f64() * 1e3, name, self.secs)
        };
        let _ = std::fs::write(
            self.path.with_extension("scrub.csv"),
            if self.pattern == Pattern::Cold { cold_csv(&self.reqs) } else { csv(&self.reqs) },
        );
        if let Some(r) = crate::loop_trace::finish(self.begun) {
            let _ = std::fs::write(self.path.with_extension("turns.csv"), r.turns_csv);
            let _ = std::fs::write(self.path.with_extension("stalls.csv"), r.stalls_csv);
        }
        let _ = std::fs::write(&self.path, &text);
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cold_jumps_visit_every_slot_once_and_never_the_start() {
        for n in [1u64, 2, 12, 24, 40, 97] {
            let mut seen: Vec<u64> = (0..n).map(|k| cold_slot(k, n)).collect();
            seen.sort_unstable();
            assert_eq!(seen, (0..n).collect::<Vec<_>>(), "n={n}");
        }
        // 60 s at 30 fps, 24 jumps: every target in its own slot of 2.4 s (72 frames), none in the first slot, >= 1 s apart.
        let t: Vec<i64> = (0..24).map(|k| cold_target(k, 24, 1800, 0.5)).collect();
        assert!(t.iter().all(|f| *f >= 72 && *f < 1800), "{t:?}");
        let mut sorted = t.clone();
        sorted.sort_unstable();
        assert!(sorted.windows(2).all(|w| w[1] - w[0] >= 60), "{sorted:?}");
        assert!(t.windows(2).all(|w| (w[1] - w[0]).abs() >= 150), "consecutive jumps are far apart: {t:?}");
    }

    #[test]
    fn cold_summary_reports_first_picture_exact_and_playback() {
        let r =
            |f: Option<f64>, e: Option<f64>| Request { at_s: 0.0, target: 1, matched: f, shown_before: 0, exact: e };
        let reqs = vec![r(Some(5.0), Some(200.0)), r(Some(7.0), Some(300.0)), r(Some(6.0), None)];
        let presents: Vec<(f64, i64)> = (0..30).map(|i| (i as f64 / 30.0, i)).collect();
        let s = cold_summary(&reqs, 36.0, 10.0, Some((1.0, 30.0, &presents)));
        assert!(s.contains("first picture ms p50 6.0 p95 7.0 max 7.0 (jumps with one 3)"), "{s}");
        assert!(s.contains("exact frame ms p50 300.0 p95 300.0 max 300.0 (jumps with the exact frame 2)"), "{s}");
        assert!(s.contains("frames shown 30 of 30 expected"), "{s}");
        assert!(s.contains("dropped 0"), "{s}");
    }

    fn req(target: i64, matched: Option<f64>) -> Request {
        Request { at_s: 0.0, target, matched, shown_before: 0, exact: None }
    }

    #[test]
    fn a_sweep_returning_over_a_skipped_frame_does_not_match_the_old_request() {
        // fast_r1.scrub.csv at t=14.5108: frame 59 asked while 60 was shown, the sweep goes down to 0 and back up.
        let at = |at_s: f64, target: i64, shown_before: i64| Request {
            at_s,
            target,
            matched: None,
            shown_before,
            exact: None,
        };
        let mut reqs = vec![at(14.5108, 59, 60), at(14.5275, 56, 60), at(14.5442, 50, 56), at(14.5609, 46, 50)];
        match_present(&mut reqs, 56, 14.540);
        match_present(&mut reqs, 46, 14.570);
        assert!(reqs[0].matched.is_none() && reqs[1].matched.is_some());
        // 1 s later the sweep is back up and presents 59 at 15.50 (989 ms after the request, inside GIVE_UP).
        match_present(&mut reqs, 59, 15.4985);
        assert_eq!(reqs[0].matched, None, "must stay superseded, not a ~987 ms match");
        assert_eq!(unmatched_kinds(&reqs), (0, 2, 0));
    }

    #[test]
    fn the_summary_counts_requests_by_how_fast_they_matched() {
        let reqs = vec![
            req(1, Some(5.0)),
            req(2, Some(16.0)),
            req(3, Some(40.0)),
            req(4, Some(90.0)),
            req(5, Some(300.0)),
            req(6, None),
        ];
        let s = summary(&reqs, &[], 16.7, "normal", 20.0);
        assert!(s.contains("requests 6\n"), "{s}");
        assert!(s.contains("within 1 display frame 2, within 50 ms 3, within 100 ms 4"), "{s}");
        assert!(s.contains("never matched (dropped) 1"), "{s}");
        assert!(s.contains("p50 40.0"), "{s}");
        assert!(s.contains("max 300.0"), "{s}");
    }

    #[test]
    fn unmatched_requests_split_into_already_shown_superseded_and_dropped() {
        let at = |at_s: f64, target: i64, shown_before: i64, matched: Option<f64>| Request {
            at_s,
            target,
            matched,
            shown_before,
            exact: None,
        };
        let reqs = vec![
            at(0.00, 3, 3, None), // frame already on screen
            at(0.01, 5, 3, None), // a newer request is shown 20 ms later
            at(0.02, 6, 3, Some(5.0)),
            at(2.00, 9, 6, None), // nothing newer is shown within 1 s
        ];
        assert_eq!(unmatched_kinds(&reqs), (1, 1, 1));
        let s = summary(&reqs, &[], 8.3, "fast", 5.0);
        assert!(s.contains("never matched (dropped) 2"), "{s}");
        assert!(s.contains("counted as shown at 0 ms: 1); of the dropped, superseded by a newer frame shown within 1 s 1, really dropped 1"), "{s}");
    }

    #[test]
    fn a_run_without_matches_reports_all_dropped_and_zero_latency() {
        let s = summary(&[req(1, None), req(2, None)], &[], 16.7, "fast", 5.0);
        assert!(s.contains("never matched (dropped) 2") && s.contains("max 0.0"), "{s}");
    }

    #[test]
    fn the_csv_has_one_row_per_request_and_an_empty_latency_for_a_drop() {
        let c = csv(&[req(7, Some(12.345)), req(8, None)]);
        let lines: Vec<&str> = c.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[1].ends_with(",7,0,12.35") || lines[1].ends_with(",7,0,12.34"), "{c}");
        assert!(lines[2].ends_with(",8,0,"), "{c}");
    }

    #[test]
    fn stale_presents_and_the_longest_stall_are_counted() {
        let d = 0.0167;
        // Requests every display frame for frames 1..=6; the picture shows 1, 2, then holds 2 while requests move on, then 6.
        let reqs: Vec<(f64, i64)> = (1..=6).map(|i| (i as f64 * d, i)).collect();
        let presents = vec![(1.2 * d, 1), (2.2 * d, 2), (3.2 * d, 2), (4.2 * d, 2), (5.2 * d, 2), (6.5 * d, 6)];
        let (considered, stale, stall) = stale_stats(&reqs, &presents, d);
        assert_eq!(considered, 6);
        // Present 4 (2 asked at 2d, newest 4d): 2d > 1d stale; present 5 stale; present 3 (newest 3d vs 2d: exactly 1d) fine.
        assert_eq!(stale, 2);
        assert!((stall - 3.0 * d).abs() < 1e-9, "stall {stall}");
        // A run that always shows the newest request has no stale present and no stall.
        let ok: Vec<(f64, i64)> = (1..=6).map(|i| (i as f64 * d + 0.001, i)).collect();
        assert_eq!(stale_stats(&reqs, &ok, d), (6, 0, 0.0));
    }

    #[test]
    fn the_sweep_turns_around_at_both_ends() {
        assert_eq!(ping_pong(0.0, 10.0), 0.0);
        assert_eq!(ping_pong(4.0, 10.0), 4.0);
        assert_eq!(ping_pong(13.0, 10.0), 7.0);
        assert_eq!(ping_pong(20.0, 10.0), 0.0);
        assert_eq!(ping_pong(23.0, 10.0), 3.0);
    }

    #[test]
    fn a_jump_is_one_to_five_seconds_and_stays_inside_the_span() {
        for i in 0..100 {
            let r = (i as f64 * 0.37).fract();
            let from = (i as f64 * 0.91).rem_euclid(10.0);
            let to = jump_target(from, 10.0, r, i % 2 == 0);
            assert!((0.0..=10.0).contains(&to));
            let d = (to - from).abs();
            assert!((1.0 - 1e-9..=5.0 + 1e-9).contains(&d), "from {from} to {to}");
        }
    }

    #[test]
    fn a_request_matches_the_first_present_that_shows_its_frame() {
        let mut log = WindowScrubLog::from_env_for_test();
        let t0 = Instant::now();
        log.reqs.push(req(5, None));
        log.begun = Some(t0);
        log.frame(Some(4), false, true, t0 + Duration::from_millis(10));
        assert_eq!(log.reqs[0].matched, None);
        log.frame(Some(5), false, false, t0 + Duration::from_millis(20));
        assert_eq!(log.reqs[0].matched, None, "a draw that did not present shows nothing");
        log.frame(Some(5), false, true, t0 + Duration::from_millis(30));
        assert_eq!(log.reqs[0].matched.map(|m| m.round()), Some(30.0));
        log.frame(Some(5), false, true, t0 + Duration::from_millis(50));
        assert_eq!(log.reqs[0].matched.map(|m| m.round()), Some(30.0), "the first match stays");
    }

    impl WindowScrubLog {
        fn from_env_for_test() -> WindowScrubLog {
            WindowScrubLog {
                path: PathBuf::new(),
                pattern: Pattern::Normal,
                secs: 1.0,
                started: Instant::now(),
                seen_picture: None,
                begun: None,
                presented_any: false,
                fps: 30.0,
                display_frame: Duration::from_millis(16),
                span_from: 0,
                span_frames: 300,
                reqs: Vec::new(),
                next_slot: 0,
                last_jump: 0.0,
                rng: 1,
                shown: -1,
                presents: Vec::new(),
                over: false,
                idle: 0.0,
                play_secs: 0.0,
                play_began: None,
                play_presents: Vec::new(),
                shown_exact: false,
            }
        }
    }
}
