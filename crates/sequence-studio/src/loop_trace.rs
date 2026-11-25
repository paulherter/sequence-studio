//! Window-loop trace, behind `SQ_WINDOW_PLAYLOG` (`window_play_log.rs` starts and finishes it; without the variable every call
//! here is one atomic load and returns). It answers one question of the loaded-machine runs: WHY did the window thread start
//! no draw for up to 1.6 s?
//!
//! * One row per event-loop turn (`<report>.turns.csv`): when the turn began and ended, how long the thread was blocked in the
//!   system waiting for events before it, how late the wake was against the requested deadline (`late_us`: a timer that fires
//!   late means the thread was not scheduled), the events handled, the time inside the app root borrow (`hold_us`), the time
//!   waiting for a drawable (`acquire_us`), and the decision of the turn (why a draw was or was not requested).
//! * A watchdog thread (`<report>.stalls.csv`, and the stall lines of the report): when the window thread has not finished a
//!   turn for more than 200 ms, or a requested wake is more than 200 ms overdue, it records the phase tag the window thread
//!   was in, the lock tag, and the thread's CPU time over the stall (`ThreadCpu`). CPU about equal to wall time says the
//!   thread was busy in that phase; (almost) no CPU says it was blocked (the phase names where) or not scheduled.
//!
//! The app root is a single-threaded `Rc<RefCell>` (`sq_runtime::UiRoot`): no worker can hold it, so there is no lock WAIT to
//! measure; `hold_us` and the `lock` tag (`app.turn`, `app.present`) show the time the window thread itself spent inside it.

use sq_os::thread::ThreadCpu;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering::Relaxed};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// A turn (or a wake overdue) longer than this is a stall.
pub const STALL: Duration = Duration::from_millis(200);
const POLL: Duration = Duration::from_millis(10);
/// shortcut: turn rows stop at this many (about 50 minutes at 120 turns a second), raise when longer runs are measured.
const MAX_TURNS: usize = 400_000;

/// Where the window thread is, set at phase boundaries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Phase {
    /// Blocked in the system waiting for events (between `about_to_wait` and `new_events`).
    Waiting,
    WindowEvent,
    UserEvent,
    /// The loop turn (`about_to_wait`): inbox, tasks, frame decision, cursor.
    Turn,
    /// The redraw path: layout of the frame.
    Redraw,
    /// `get_current_texture`: waiting for a free drawable.
    Acquire,
    /// Recording, submitting and presenting the UI.
    Draw,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Waiting => "waiting",
            Phase::WindowEvent => "window_event",
            Phase::UserEvent => "user_event",
            Phase::Turn => "turn",
            Phase::Redraw => "redraw",
            Phase::Acquire => "acquire",
            Phase::Draw => "draw",
        }
    }

    fn from_u8(v: u8) -> Phase {
        match v {
            1 => Phase::WindowEvent,
            2 => Phase::UserEvent,
            3 => Phase::Turn,
            4 => Phase::Redraw,
            5 => Phase::Acquire,
            6 => Phase::Draw,
            _ => Phase::Waiting,
        }
    }
}

/// What the loop asked the system for at the end of a turn.
#[derive(Clone, Copy, Debug)]
pub enum Wake {
    /// Until an event arrives.
    Wait,
    Until(Instant),
    Poll,
}

/// One loop turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnRow {
    pub turn: u64,
    pub start_us: u64,
    pub dur_us: u64,
    /// Time in the system's wait before this turn.
    pub blocked_us: u64,
    /// How far the wake was past the deadline the previous turn asked for (0: an event woke it, or on time).
    pub late_us: u64,
    pub cause: &'static str,
    pub events: u32,
    /// Time inside window and user event handlers (includes the redraw they ran).
    pub event_us: u64,
    /// Time inside the app root borrow (`Hold` guards).
    pub hold_us: u64,
    pub acquire_us: u64,
    /// Draws (presents) made in this turn.
    pub drew: u32,
    pub decision: &'static str,
    pub animating: bool,
    pub may_draw: bool,
    /// The wake the turn asked for, in us from its end (-1: until an event).
    pub wake_in_us: i64,
}

const TURNS_HEADER: &str = "t_s,turn,dur_us,blocked_us,late_us,cause,events,event_us,hold_us,acquire_us,drew,decision,animating,may_draw,wake_in_us";
const STALLS_HEADER: &str = "t_s,kind,dur_ms,phase,phase_last,lock,cpu_ms,cpu_wall_ms,cpu_pct,verdict";

fn secs(us: u64, play_us: u64) -> f64 {
    (us as f64 - play_us as f64) / 1e6
}

/// The turn rows as CSV; times in seconds from `play_us` (the window play log's Play, on this trace's clock).
pub fn turns_csv(rows: &[TurnRow], play_us: u64) -> String {
    let mut out = format!("{TURNS_HEADER}\n");
    for r in rows {
        out += &format!(
            "{:.4},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
            secs(r.start_us, play_us),
            r.turn,
            r.dur_us,
            r.blocked_us,
            r.late_us,
            r.cause,
            r.events,
            r.event_us,
            r.hold_us,
            r.acquire_us,
            r.drew,
            r.decision,
            u8::from(r.animating),
            u8::from(r.may_draw),
            r.wake_in_us
        );
    }
    out
}

/// One stall of the window thread.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StallRow {
    /// `busy`: a turn did not finish; `late_wake`: the requested wake did not come.
    pub kind: &'static str,
    pub start_us: u64,
    pub end_us: u64,
    /// The phase when the stall was first seen (200 ms in), and the last one seen before it ended.
    pub phase: &'static str,
    pub phase_last: &'static str,
    pub lock: &'static str,
    /// The thread's CPU time and the wall time of the same stretch (`None`: the system gave no thread times).
    pub cpu_us: Option<u64>,
    pub cpu_wall_us: u64,
}

impl StallRow {
    pub fn dur_us(&self) -> u64 {
        self.end_us.saturating_sub(self.start_us)
    }

    pub fn cpu_pct(&self) -> Option<u64> {
        self.cpu_us.map(|c| c * 100 / self.cpu_wall_us.max(1))
    }

    /// `no_cpu` (blocked in the phase, or not scheduled), `busy` (CPU about equal to wall), `mixed`, `unknown`.
    pub fn verdict(&self) -> &'static str {
        match self.cpu_pct() {
            None => "unknown",
            Some(p) if p < 25 => "no_cpu",
            Some(p) if p >= 75 => "busy",
            Some(_) => "mixed",
        }
    }

    fn line(&self, play_us: u64) -> String {
        format!(
            "stall at {:+.2} s: {} {:.0} ms in {} (last {}), lock {}, cpu {}, {}",
            secs(self.start_us, play_us),
            self.kind,
            self.dur_us() as f64 / 1e3,
            self.phase,
            self.phase_last,
            self.lock,
            self.cpu_pct().map_or("n/a".into(), |p| format!("{p}%")),
            self.verdict()
        )
    }
}

/// The stall rows as CSV.
pub fn stalls_csv(rows: &[StallRow], play_us: u64) -> String {
    let mut out = format!("{STALLS_HEADER}\n");
    for r in rows {
        out += &format!(
            "{:.4},{},{:.1},{},{},{},{},{:.1},{},{}\n",
            secs(r.start_us, play_us),
            r.kind,
            r.dur_us() as f64 / 1e3,
            r.phase,
            r.phase_last,
            r.lock,
            r.cpu_us.map_or(String::new(), |c| format!("{:.1}", c as f64 / 1e3)),
            r.cpu_wall_us as f64 / 1e3,
            r.cpu_pct().map_or(String::new(), |p| p.to_string()),
            r.verdict()
        );
    }
    out
}

/// What the watchdog sees at one poll (all times in us on the trace's clock).
#[derive(Clone, Copy, Debug)]
pub struct Snapshot {
    pub now_us: u64,
    pub turn: u64,
    pub in_turn: bool,
    pub turn_start_us: u64,
    /// The deadline the last turn asked to be woken at (0: none).
    pub wake_us: u64,
    pub phase: Phase,
    pub lock: &'static str,
    pub cpu_us: Option<u64>,
}

struct Base {
    sig: (u64, bool, u64),
    now_us: u64,
    cpu_us: Option<u64>,
}

struct Open {
    id: (u64, &'static str, u64),
    kind: &'static str,
    since: u64,
    base_now: u64,
    base_cpu: Option<u64>,
    phase: &'static str,
    phase_last: &'static str,
    lock: &'static str,
}

impl Open {
    fn close(self, now_us: u64, cpu_us: Option<u64>) -> StallRow {
        StallRow {
            kind: self.kind,
            start_us: self.since,
            end_us: now_us,
            phase: self.phase,
            phase_last: self.phase_last,
            lock: self.lock,
            cpu_us: cpu_us.zip(self.base_cpu).map(|(now, base)| now.saturating_sub(base)),
            cpu_wall_us: now_us.saturating_sub(self.base_now),
        }
    }
}

/// The watchdog's decision logic on plain snapshots (no thread, no clock: tests feed it times).
pub struct Detector {
    threshold_us: u64,
    base: Option<Base>,
    open: Option<Open>,
}

impl Detector {
    pub fn new(threshold: Duration) -> Detector {
        Detector { threshold_us: u64::try_from(threshold.as_micros()).unwrap_or(u64::MAX), base: None, open: None }
    }

    /// Feeds one poll; returns the stall that ended with it, if any (one row per stall, written when it is over).
    pub fn observe(&mut self, s: &Snapshot) -> Option<StallRow> {
        let cand = if s.in_turn {
            (s.now_us.saturating_sub(s.turn_start_us) > self.threshold_us).then_some(("busy", s.turn_start_us))
        } else if s.wake_us > 0 {
            (s.now_us.saturating_sub(s.wake_us) > self.threshold_us).then_some(("late_wake", s.wake_us))
        } else {
            None
        };
        let id = cand.map(|(kind, since)| (s.turn, kind, since));
        let mut closed = None;
        if let Some(open) = self.open.as_mut() {
            if Some(open.id) == id {
                open.phase_last = s.phase.name();
                return None;
            }
            closed = self.open.take().map(|o| o.close(s.now_us, s.cpu_us));
        }
        // The CPU reading to compare with starts when the thread's state last changed (a new turn, a new wait).
        let sig = (s.turn, s.in_turn, s.wake_us);
        if self.base.as_ref().is_none_or(|b| b.sig != sig) {
            self.base = Some(Base { sig, now_us: s.now_us, cpu_us: s.cpu_us });
        }
        if let (Some((kind, since)), Some(base)) = (cand, self.base.as_ref()) {
            self.open = Some(Open {
                id: (s.turn, kind, since),
                kind,
                since,
                base_now: base.now_us,
                base_cpu: base.cpu_us,
                phase: s.phase.name(),
                phase_last: s.phase.name(),
                lock: s.lock,
            });
        }
        closed
    }

    /// The run ends: a stall still open ends now.
    pub fn flush(&mut self, now_us: u64, cpu_us: Option<u64>) -> Option<StallRow> {
        self.open.take().map(|o| o.close(now_us, cpu_us))
    }
}

/// The turn being built (window thread only).
#[derive(Default)]
struct Cur {
    began: Option<Instant>,
    last_end: Option<Instant>,
    blocked: Duration,
    late: Duration,
    cause: &'static str,
    events: u32,
    event_us: u64,
    hold_us: u64,
    acquire_us: u64,
    drew: u32,
    decision: &'static str,
    animating: bool,
    may_draw: bool,
}

fn lk<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn us(d: Duration) -> u64 {
    u64::try_from(d.as_micros()).unwrap_or(u64::MAX)
}

/// The trace of one run. Create it on the window thread (its CPU clock is the one watched).
pub struct Trace {
    origin: Instant,
    cpu: Option<ThreadCpu>,
    turn: AtomicU64,
    in_turn: AtomicBool,
    turn_start: AtomicU64,
    wake: AtomicU64,
    phase: AtomicU8,
    lock: Mutex<&'static str>,
    cur: Mutex<Cur>,
    turns: Mutex<Vec<TurnRow>>,
    stalls: Mutex<Vec<StallRow>>,
    stop: AtomicBool,
    watchdog: Mutex<Option<std::thread::JoinHandle<()>>>,
}

/// Restores the phase when dropped; handler phases also count their event and time.
pub struct Guard {
    trace: Option<&'static Trace>,
    prev: Phase,
    began: Instant,
    event: bool,
    /// SQ_TRACE_JSON: the phase as a span (inert when off).
    _span: sq_os::trace::Span,
}

impl Drop for Guard {
    fn drop(&mut self) {
        if let Some(t) = self.trace {
            t.phase.store(self.prev as u8, Relaxed);
            if self.event {
                lk(&t.cur).event_us += us(self.began.elapsed());
            }
        }
    }
}

/// Names the lock the window thread holds while it lives, and books the time (`hold_us`).
pub struct Hold {
    trace: Option<&'static Trace>,
    prev: &'static str,
    began: Instant,
}

impl Drop for Hold {
    fn drop(&mut self) {
        if let Some(t) = self.trace {
            *lk(&t.lock) = self.prev;
            lk(&t.cur).hold_us += us(self.began.elapsed());
        }
    }
}

impl Trace {
    pub fn new() -> Trace {
        Trace {
            origin: Instant::now(),
            cpu: ThreadCpu::of_current(),
            turn: AtomicU64::new(0),
            in_turn: AtomicBool::new(false),
            turn_start: AtomicU64::new(0),
            wake: AtomicU64::new(0),
            phase: AtomicU8::new(Phase::Waiting as u8),
            lock: Mutex::new("-"),
            cur: Mutex::new(Cur::default()),
            turns: Mutex::new(Vec::new()),
            stalls: Mutex::new(Vec::new()),
            stop: AtomicBool::new(false),
            watchdog: Mutex::new(None),
        }
    }

    /// The trace's clock in us.
    pub fn micros(&self, at: Instant) -> u64 {
        us(at.saturating_duration_since(self.origin))
    }

    /// `new_events`: a turn begins. `requested` is the deadline the previous turn asked for, when a timer woke the loop.
    pub fn turn_begin(&self, cause: &'static str, requested: Option<Instant>) {
        let now = Instant::now();
        {
            let mut c = lk(&self.cur);
            let last_end = c.last_end;
            *c = Cur {
                began: Some(now),
                last_end,
                blocked: last_end.map_or(Duration::ZERO, |e| now.saturating_duration_since(e)),
                late: requested.map_or(Duration::ZERO, |r| now.saturating_duration_since(r)),
                cause,
                decision: "-",
                ..Cur::default()
            };
        }
        self.turn_start.store(self.micros(now), Relaxed);
        self.turn.fetch_add(1, Relaxed);
        self.phase.store(Phase::Turn as u8, Relaxed);
        self.in_turn.store(true, Relaxed);
    }

    /// The end of `about_to_wait`: the turn is over, the thread goes back to the system's wait.
    pub fn turn_end(&self, wake: Wake) {
        let now = Instant::now();
        let mut c = lk(&self.cur);
        let Some(began) = c.began.take() else { return };
        c.last_end = Some(now);
        let wake_in_us = match wake {
            Wake::Wait => -1,
            Wake::Poll => 0,
            Wake::Until(t) => i64::try_from(us(t.saturating_duration_since(now))).unwrap_or(i64::MAX),
        };
        let row = TurnRow {
            turn: self.turn.load(Relaxed),
            start_us: self.micros(began),
            dur_us: us(now.saturating_duration_since(began)),
            blocked_us: us(c.blocked),
            late_us: us(c.late),
            cause: c.cause,
            events: c.events,
            event_us: c.event_us,
            hold_us: c.hold_us,
            acquire_us: c.acquire_us,
            drew: c.drew,
            decision: c.decision,
            animating: c.animating,
            may_draw: c.may_draw,
            wake_in_us,
        };
        drop(c);
        // The deadline the thread must be woken by, set before the turn counts as over: the watchdog reads it with `in_turn`.
        self.wake.store(
            match wake {
                Wake::Wait => 0,
                Wake::Poll => self.micros(now).max(1),
                Wake::Until(t) => self.micros(t).max(1),
            },
            Relaxed,
        );
        self.phase.store(Phase::Waiting as u8, Relaxed);
        self.in_turn.store(false, Relaxed);
        let mut turns = lk(&self.turns);
        if turns.len() < MAX_TURNS {
            turns.push(row);
        }
    }

    pub fn enter(&'static self, phase: Phase) -> Guard {
        let prev = Phase::from_u8(self.phase.swap(phase as u8, Relaxed));
        let event = matches!(phase, Phase::WindowEvent | Phase::UserEvent);
        if event {
            lk(&self.cur).events += 1;
        }
        Guard {
            trace: Some(self),
            prev,
            began: Instant::now(),
            event,
            _span: sq_os::trace::span_args("ui", "loop phase", || format!("{phase:?}")),
        }
    }

    pub fn hold(&'static self, tag: &'static str) -> Hold {
        let prev = std::mem::replace(&mut *lk(&self.lock), tag);
        Hold { trace: Some(self), prev, began: Instant::now() }
    }

    /// Why this turn asked for a draw or not.
    pub fn decide(&self, decision: &'static str, animating: bool, may_draw: bool) {
        let mut c = lk(&self.cur);
        c.decision = decision;
        c.animating = animating;
        c.may_draw = may_draw;
    }

    /// A present finished; `acquire` is what it waited for the drawable.
    pub fn note_draw(&self, acquire: Duration) {
        let mut c = lk(&self.cur);
        c.drew += 1;
        c.acquire_us += us(acquire);
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            now_us: self.micros(Instant::now()),
            turn: self.turn.load(Relaxed),
            in_turn: self.in_turn.load(Relaxed),
            turn_start_us: self.turn_start.load(Relaxed),
            wake_us: self.wake.load(Relaxed),
            phase: Phase::from_u8(self.phase.load(Relaxed)),
            lock: *lk(&self.lock),
            cpu_us: self.cpu.as_ref().and_then(ThreadCpu::read).map(us),
        }
    }

    /// Starts the watchdog thread: a stall is a turn (or a wake) overdue by more than `threshold`.
    pub fn start_watchdog(&'static self, threshold: Duration) {
        let spawned = std::thread::Builder::new().name("sq-loop-watchdog".into()).spawn(move || {
            let mut detector = Detector::new(threshold);
            while !self.stop.load(Relaxed) {
                std::thread::park_timeout(POLL);
                let snap = self.snapshot();
                if let Some(row) = detector.observe(&snap) {
                    lk(&self.stalls).push(row);
                }
            }
            let snap = self.snapshot();
            if let Some(row) = detector.flush(snap.now_us, snap.cpu_us) {
                lk(&self.stalls).push(row);
            }
        });
        *lk(&self.watchdog) = spawned.ok();
    }

    /// Stops the watchdog and returns the rows; `play_us` is Play on this trace's clock (0: times from the start).
    pub fn finish(&self, play_us: u64) -> Report {
        self.stop.store(true, Relaxed);
        if let Some(handle) = lk(&self.watchdog).take() {
            handle.thread().unpark();
            let _ = handle.join();
        }
        let turns = std::mem::take(&mut *lk(&self.turns));
        let stalls = std::mem::take(&mut *lk(&self.stalls));
        let mut text = format!("window loop: {} turns", turns.len());
        let max = |f: fn(&TurnRow) -> u64| turns.iter().map(f).max().unwrap_or(0) as f64 / 1e3;
        text += &format!(
            ", longest turn {:.1} ms, longest wait {:.1} ms, latest wake {:.1} ms, longest drawable wait in a turn {:.1} ms\n",
            max(|r| r.dur_us),
            max(|r| r.blocked_us),
            max(|r| r.late_us),
            max(|r| r.acquire_us)
        );
        text += &format!("window thread stalls over {} ms: {}\n", STALL.as_millis(), stalls.len());
        for s in &stalls {
            text += &s.line(play_us);
            text.push('\n');
        }
        Report { turns_csv: turns_csv(&turns, play_us), stalls_csv: stalls_csv(&stalls, play_us), text }
    }
}

impl Default for Trace {
    fn default() -> Trace {
        Trace::new()
    }
}

/// What a run leaves behind.
pub struct Report {
    pub turns_csv: String,
    pub stalls_csv: String,
    pub text: String,
}

static TRACE: OnceLock<Trace> = OnceLock::new();

fn trace() -> Option<&'static Trace> {
    TRACE.get()
}

/// Starts the trace and its watchdog; call on the window thread, once, when the play log is on.
pub fn start() {
    let t = TRACE.get_or_init(Trace::new);
    if lk(&t.watchdog).is_none() {
        t.start_watchdog(STALL);
    }
}

pub fn turn_begin(cause: &'static str, requested: Option<Instant>) {
    if let Some(t) = trace() {
        t.turn_begin(cause, requested);
    }
}

pub fn turn_end(wake: Wake) {
    if let Some(t) = trace() {
        t.turn_end(wake);
    }
}

/// Marks a phase until the guard drops.
pub fn enter(phase: Phase) -> Guard {
    match trace() {
        Some(t) => t.enter(phase),
        None => Guard {
            trace: None,
            prev: Phase::Waiting,
            began: Instant::now(),
            event: false,
            _span: sq_os::trace::span_args("ui", "loop phase", || format!("{phase:?}")),
        },
    }
}

/// Names the app-root borrow until the guard drops.
pub fn hold(tag: &'static str) -> Hold {
    match trace() {
        Some(t) => t.hold(tag),
        None => Hold { trace: None, prev: "-", began: Instant::now() },
    }
}

pub fn decide(decision: &'static str, animating: bool, may_draw: bool) {
    if let Some(t) = trace() {
        t.decide(decision, animating, may_draw);
    }
}

pub fn note_draw(acquire: Duration) {
    if let Some(t) = trace() {
        t.note_draw(acquire);
    }
}

/// Stops and collects; `None` when the trace never ran.
pub fn finish(played: Option<Instant>) -> Option<Report> {
    let t = trace()?;
    Some(t.finish(played.map_or(0, |p| t.micros(p))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(now_ms: u64, turn: u64, in_turn: bool, start_ms: u64, wake_ms: u64, cpu_ms: u64) -> Snapshot {
        Snapshot {
            now_us: now_ms * 1000,
            turn,
            in_turn,
            turn_start_us: start_ms * 1000,
            wake_us: wake_ms * 1000,
            phase: if in_turn { Phase::Acquire } else { Phase::Waiting },
            lock: "-",
            cpu_us: Some(cpu_ms * 1000),
        }
    }

    #[test]
    fn a_turn_over_200_ms_is_one_busy_stall_written_when_it_ends() {
        let mut d = Detector::new(STALL);
        // Turn 7 begins at 1000 ms; polls every 50 ms; the thread used 10 ms of CPU in 700 ms.
        assert_eq!(d.observe(&snap(1000, 7, true, 1000, 0, 500)), None);
        assert_eq!(d.observe(&snap(1150, 7, true, 1000, 0, 502)), None);
        assert_eq!(d.observe(&snap(1250, 7, true, 1000, 0, 504)), None, "detected here, row comes at the end");
        assert_eq!(d.observe(&snap(1500, 7, true, 1000, 0, 508)), None, "still the same stall");
        let row = d.observe(&snap(1700, 7, false, 1000, 0, 510)).expect("the stall ended");
        assert_eq!((row.kind, row.phase), ("busy", "acquire"));
        assert_eq!((row.start_us, row.end_us), (1_000_000, 1_700_000));
        assert_eq!(row.cpu_us, Some(10_000));
        assert_eq!(row.cpu_wall_us, 700_000);
        assert_eq!(row.verdict(), "no_cpu");
        assert_eq!(d.observe(&snap(1800, 7, false, 1000, 0, 511)), None, "one row per stall");
    }

    #[test]
    fn a_turn_that_burns_cpu_is_busy_and_a_quick_turn_is_no_stall() {
        let mut d = Detector::new(STALL);
        assert_eq!(d.observe(&snap(0, 1, true, 0, 0, 0)), None);
        assert_eq!(d.observe(&snap(250, 1, true, 0, 0, 240)), None);
        let row = d.observe(&snap(400, 1, false, 0, 0, 390)).expect("stall");
        assert_eq!(row.verdict(), "busy");
        assert_eq!(row.cpu_pct(), Some(97));
        let mut d = Detector::new(STALL);
        for (t, turn) in [(0, 1), (100, 2), (190, 3), (300, 4)] {
            assert_eq!(d.observe(&snap(t, turn, true, t, 0, t)), None);
        }
        assert_eq!(d.flush(400_000 / 1000, Some(0)), None);
    }

    #[test]
    fn a_wake_that_does_not_come_is_a_late_wake_stall_and_waiting_forever_is_not() {
        let mut d = Detector::new(STALL);
        // The turn asked to be woken at 500 ms; the thread sleeps without CPU until 1900 ms.
        assert_eq!(d.observe(&snap(450, 3, false, 400, 500, 50)), None);
        assert_eq!(d.observe(&snap(800, 3, false, 400, 500, 50)), None);
        assert_eq!(d.observe(&snap(1200, 3, false, 400, 500, 50)), None);
        let row = d.observe(&snap(1900, 4, true, 1900, 500, 52)).expect("the wake came, the stall is over");
        assert_eq!((row.kind, row.phase, row.start_us), ("late_wake", "waiting", 500_000));
        assert_eq!(row.verdict(), "no_cpu");
        let mut d = Detector::new(STALL);
        assert_eq!(d.observe(&snap(0, 1, false, 0, 0, 0)), None);
        assert_eq!(d.observe(&snap(5000, 1, false, 0, 0, 0)), None, "no deadline, no stall");
        assert_eq!(d.flush(5_000_000, None), None);
    }

    #[test]
    fn a_stall_open_at_the_end_of_the_run_is_flushed_and_unknown_cpu_says_so() {
        let mut d = Detector::new(STALL);
        let mut s = snap(0, 1, true, 0, 0, 0);
        s.cpu_us = None;
        assert_eq!(d.observe(&s), None);
        s.now_us = 300_000;
        assert_eq!(d.observe(&s), None);
        let row = d.flush(500_000, None).expect("open stall");
        assert_eq!(row.verdict(), "unknown");
        assert_eq!(row.dur_us(), 500_000);
    }

    #[test]
    fn the_csv_writers_name_every_column_and_count_from_play() {
        let turn = TurnRow {
            turn: 4,
            start_us: 2_500_000,
            dur_us: 1200,
            blocked_us: 15_000,
            late_us: 3000,
            cause: "timer",
            events: 2,
            event_us: 800,
            hold_us: 900,
            acquire_us: 400,
            drew: 1,
            decision: "tick",
            animating: true,
            may_draw: true,
            wake_in_us: 16_000,
        };
        let csv = turns_csv(&[turn], 2_000_000);
        let mut lines = csv.lines();
        let header = lines.next().expect("header");
        let row = lines.next().expect("row");
        assert_eq!(header.split(',').count(), 15);
        assert_eq!(row, "0.5000,4,1200,15000,3000,timer,2,800,900,400,1,tick,1,1,16000");
        let stall = StallRow {
            kind: "busy",
            start_us: 3_000_000,
            end_us: 4_600_000,
            phase: "acquire",
            phase_last: "draw",
            lock: "app.present",
            cpu_us: Some(16_000),
            cpu_wall_us: 1_600_000,
        };
        let csv = stalls_csv(&[stall], 2_000_000);
        assert_eq!(csv.lines().next().map(|h| h.split(',').count()), Some(10));
        assert_eq!(csv.lines().nth(1), Some("1.0000,busy,1600.0,acquire,draw,app.present,16.0,1600.0,1,no_cpu"));
    }

    #[test]
    fn the_watchdog_catches_a_sleeping_stand_in_for_the_window_thread() {
        // This test thread is the "window thread": it begins a turn, then sleeps inside the acquire phase.
        let trace: &'static Trace = Box::leak(Box::new(Trace::new()));
        trace.start_watchdog(Duration::from_millis(60));
        trace.turn_begin("test", None);
        {
            let _hold = trace.hold("app.present");
            let _acquire = trace.enter(Phase::Acquire);
            std::thread::sleep(Duration::from_millis(250));
        }
        trace.turn_end(Wake::Until(Instant::now() + Duration::from_millis(5)));
        // Then the wake is overdue: sleep past the deadline without starting a turn.
        std::thread::sleep(Duration::from_millis(200));
        trace.turn_begin("timer", None);
        trace.turn_end(Wake::Wait);
        std::thread::sleep(Duration::from_millis(30));
        let report = trace.finish(0);
        let stalls: Vec<&str> = report.stalls_csv.lines().skip(1).collect();
        assert_eq!(stalls.len(), 2, "{}", report.stalls_csv);
        assert!(stalls[0].contains(",busy,") && stalls[0].contains(",acquire,"), "{}", stalls[0]);
        assert!(stalls[0].contains("app.present"), "{}", stalls[0]);
        assert!(stalls[1].contains(",late_wake,") && stalls[1].contains(",waiting,"), "{}", stalls[1]);
        if trace.cpu.is_some() {
            assert!(stalls[0].ends_with(",no_cpu"), "a sleeping thread uses no CPU: {}", stalls[0]);
        }
        assert_eq!(report.turns_csv.lines().count(), 3, "header and two turns:\n{}", report.turns_csv);
        assert!(report.text.contains("stalls over 200 ms: 2"), "{}", report.text);
    }

    #[test]
    fn a_turn_row_books_the_events_holds_and_draws_of_its_turn() {
        let trace: &'static Trace = Box::leak(Box::new(Trace::new()));
        trace.turn_begin("init", None);
        {
            let _e = trace.enter(Phase::WindowEvent);
            let _h = trace.hold("app.turn");
            std::thread::sleep(Duration::from_millis(5));
        }
        trace.decide("tick", true, true);
        trace.note_draw(Duration::from_micros(700));
        trace.turn_end(Wake::Wait);
        trace.turn_begin("wait_cancelled", None);
        trace.turn_end(Wake::Poll);
        let report = trace.finish(0);
        let rows: Vec<Vec<&str>> = report.turns_csv.lines().skip(1).map(|l| l.split(',').collect()).collect();
        assert_eq!(rows.len(), 2);
        assert_eq!((rows[0][5], rows[0][6], rows[0][9], rows[0][10], rows[0][11]), ("init", "1", "700", "1", "tick"));
        assert!(rows[0][7].parse::<u64>().unwrap_or(0) >= 4000, "event time: {:?}", rows[0]);
        assert!(rows[0][8].parse::<u64>().unwrap_or(0) >= 4000, "hold time: {:?}", rows[0]);
        assert_eq!(rows[0][14], "-1", "Wait asks for no wake");
        assert!(rows[1][4].parse::<u64>().is_ok());
    }
}
