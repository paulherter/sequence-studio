// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ScrubAudio.swift
//! Scrub audio (E-12): short grains of timeline audio at the scrub/step position, in the direction of motion,
//! overlap-added with raised-cosine crossfades.
//!
//! - `ScrubGrainPlanner` (pure): scrub/step events -> grain requests (start, direction, length, speed).
//! - `ScrubAudio`: owns the planner and a worker that mixes a requested grain (dry timeline mix: clip volume, mute/solo,
//!   gaps; clip effects, no track FX) into the voice, windowed, and hands it over. Requests are latest-wins: a newer one
//!   replaces an older one that was not mixed yet.
//! - `ScrubVoice` / `ScrubPlayer`: the real-time side. Fixed slots, lock-free handoff (one pending slot, atomic exchange),
//!   no allocation. The player is owned by the render thread.
//!
//! The scrub voice has its own output path (the play ring belongs to the clock), so grains start within one render call.
//! Grains are read at 1x (pitch preserved) and placed at the current scrub position; `ScrubSettings::max_varispeed` > 1
//! optionally raises the grain's playback speed with the drag velocity.

use super::feeder::{AudioFeeder, FeederHandle, Resolver, SharedSilences, ceil_frame, round_frame};
use super::track_mix::Sequences;
use sq_core_model::{ProjectLiveDucking, SequenceFormat, Timeline};
use sq_core_time::{Id, Time};
use std::collections::HashSet;
use std::sync::atomic::{AtomicI64, AtomicU32, AtomicU64, AtomicUsize, Ordering::*};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Tuning for scrub grains.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrubSettings {
    /// Shortest grain (hop between grain starts). Grains are one sequence frame long, but never shorter than this.
    pub min_grain: Time,
    /// Raised-cosine crossfade at each grain join (and fade in/out at the ends), in frames at the mixer rate. 5 ms.
    pub fade_frames: usize,
    /// |drag velocity| (timeline s per s) at or above which grains use `min_grain` (quicker position updates).
    pub fast_speed: f64,
    /// Upper bound of the grain playback speed. 1 = always 1x, pitch preserved.
    pub max_varispeed: f64,
    /// A pause between scrub events longer than this restarts the velocity estimate.
    pub hold_nanos: i64,
}

impl Default for ScrubSettings {
    fn default() -> Self {
        ScrubSettings {
            min_grain: Time::new(1, 25),
            fade_frames: 240,
            fast_speed: 2.0,
            max_varispeed: 1.0,
            hold_nanos: 250_000_000,
        }
    }
}

/// One grain request. Frames are timeline frames at the mixer rate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrubGrain {
    /// Forward: first frame played. Reverse: exclusive upper end; frame `start - 1` plays first, then backwards.
    pub start: i64,
    pub reverse: bool,
    /// Output frames before the next grain may start (the grain length).
    pub hop: usize,
    /// Crossfade frames; the grain renders `hop + fade` frames (fade-in over the first, fade-out over the last `fade`).
    pub fade: usize,
    /// Source frames per output frame (1 = pitch preserved).
    pub speed: f64,
}

impl ScrubGrain {
    pub fn frames(&self) -> usize {
        self.hop + self.fade
    }

    /// Source frames the grain reads (plus one for interpolation).
    pub fn source_span(&self) -> usize {
        ((self.frames() - 1) as f64 * self.speed).ceil() as usize + 2
    }
}

/// Pure: turns scrub and step events into grain requests.
///
/// - Direction = sign of the last movement; no movement = no grain.
/// - Length (hop) = one sequence frame, at least `min_grain`; `min_grain` when |velocity| >= `fast_speed`.
/// - Velocity = timeline time moved / host time elapsed, smoothed (EMA 0.5) and restarted after a hold > `hold_nanos`.
/// - Speed = clamp(|velocity|, 1, `max_varispeed`).
#[derive(Clone, Debug)]
pub struct ScrubGrainPlanner {
    pub settings: ScrubSettings,
    pub sample_rate: i64,
    velocity: f64,
    last: Option<(i64, i64)>,
    has_velocity: bool,
}

impl ScrubGrainPlanner {
    pub fn new(settings: ScrubSettings, sample_rate: i64) -> ScrubGrainPlanner {
        ScrubGrainPlanner { settings, sample_rate, velocity: 0.0, last: None, has_velocity: false }
    }

    /// Smoothed drag velocity (timeline seconds per second, signed). 0 before the first movement.
    pub fn velocity(&self) -> f64 {
        self.velocity
    }

    pub fn begin(&mut self, position: Time, host_nanos: i64) {
        self.last = Some((self.frame(position), host_nanos));
        self.velocity = 0.0;
        self.has_velocity = false;
    }

    /// Next grain for a drag to `position` at host time `host_nanos`, or `None` when the position did not move.
    pub fn scrub(&mut self, position: Time, host_nanos: i64, frame_duration: Time) -> Option<ScrubGrain> {
        let f = self.frame(position);
        let prev = self.last.replace((f, host_nanos))?; // first event without begin: anchor only
        let moved = f - prev.0;
        if moved == 0 {
            return None;
        }
        let dt = host_nanos - prev.1;
        if dt > self.settings.hold_nanos {
            self.has_velocity = false;
        }
        if dt > 0 {
            let raw = moved as f64 / (dt as f64 * self.sample_rate as f64 / 1e9);
            self.velocity = if self.has_velocity { 0.5 * self.velocity + 0.5 * raw } else { raw };
            self.has_velocity = true;
        }
        let speed = self.velocity.abs().max(1.0).min(self.settings.max_varispeed.max(1.0));
        Some(self.grain(f, moved < 0, self.grain_length(self.velocity.abs(), frame_duration), speed))
    }

    /// Grain for a step from `from` to `to` (grid times): forward plays the new frame from its start, backward plays it
    /// reversed from its end. `None` when the step did not move.
    pub fn step(&self, from: Time, to: Time, frame_duration: Time) -> Option<ScrubGrain> {
        if to == from {
            return None;
        }
        let reverse = to < from;
        let at = self.frame(if reverse { to + frame_duration } else { to });
        Some(self.grain(at, reverse, self.grain_length(1.0, frame_duration), 1.0))
    }

    /// Hop in frames at |velocity| `speed`: one frame (rounded up), at least `min_grain`; `min_grain` when fast.
    pub fn grain_length(&self, speed: f64, frame_duration: Time) -> usize {
        let minimum = ceil_frame(self.settings.min_grain, self.sample_rate) as usize;
        let frame_len = ceil_frame(frame_duration, self.sample_rate) as usize;
        let hop = if speed >= self.settings.fast_speed { minimum } else { minimum.max(frame_len) };
        hop.max(self.settings.fade_frames) // a join never overlaps more than two grains
    }

    fn grain(&self, start: i64, reverse: bool, hop: usize, speed: f64) -> ScrubGrain {
        ScrubGrain { start, reverse, hop, fade: self.settings.fade_frames, speed }
    }

    fn frame(&self, t: Time) -> i64 {
        round_frame(t, self.sample_rate)
    }
}

/// Raised cosine 0 -> 1 over `n` frames; `ramp_value(k) + ramp_value(n - 1 - k) == 1`.
fn ramp_value(k: usize, n: usize) -> f32 {
    (0.5 - 0.5 * (std::f64::consts::PI * (k as f64 + 0.5) / n as f64).cos()) as f32
}

const SLOT_COUNT: usize = 4;

#[derive(Default)]
struct SlotInfo {
    frames: AtomicUsize,
    hop: AtomicUsize,
    generation: AtomicI64,
    tag: AtomicI64,
}

struct VoiceShared {
    capacity: usize,
    fade_frames: usize,
    left: Vec<AtomicU32>,
    right: Vec<AtomicU32>,
    info: [SlotInfo; SLOT_COUNT],
    /// Bit i set = slot i is free.
    free: AtomicU32,
    pending: AtomicI64,
    cancel_generation: AtomicI64,
    started: AtomicU64,
    started_tag: AtomicI64,
}

impl VoiceShared {
    fn release(&self, slot: usize) {
        self.free.fetch_or(1 << slot, Release);
    }
}

/// Producer side of the grain player (one thread at a time): `publish` writes a windowed grain into a free slot and hands
/// it over. Slot ownership is a free bitmask plus one `pending` slot (atomic exchange), so a newer grain replaces an
/// unplayed one and nothing queues up. Cheap to clone.
#[derive(Clone)]
pub struct ScrubVoice {
    shared: Arc<VoiceShared>,
}

/// Render side (audio render thread): owns the playing state. The voice takes the pending grain when the playing one
/// reaches its hop (join crossfade: outgoing fade-out + incoming fade-in sum to 1), or right away when idle.
pub struct ScrubPlayer {
    shared: Arc<VoiceShared>,
    ramp: Vec<f32>,
    cur: Option<usize>,
    cur_off: usize,
    old: Option<usize>,
    old_off: usize,
    seen_generation: i64,
    stop_fade: Option<usize>,
}

impl ScrubVoice {
    /// At most: 2 rendering (playing + fading tail), 1 pending, 1 being written.
    pub const SLOT_COUNT: usize = SLOT_COUNT;

    pub fn new(capacity: usize, fade_frames: usize) -> (ScrubVoice, ScrubPlayer) {
        assert!(capacity > 0 && fade_frames > 0);
        let n = capacity * SLOT_COUNT;
        let slots = |n: usize| (0..n).map(|_| AtomicU32::new(0)).collect::<Vec<_>>();
        let shared = Arc::new(VoiceShared {
            capacity,
            fade_frames,
            left: slots(n),
            right: slots(n),
            info: Default::default(),
            free: AtomicU32::new((1 << SLOT_COUNT) - 1),
            pending: AtomicI64::new(-1),
            cancel_generation: AtomicI64::new(0),
            started: AtomicU64::new(0),
            started_tag: AtomicI64::new(-1),
        });
        let player = ScrubPlayer {
            shared: Arc::clone(&shared),
            ramp: (0..fade_frames).map(|k| ramp_value(k, fade_frames)).collect(),
            cur: None,
            cur_off: 0,
            old: None,
            old_off: 0,
            seen_generation: 0,
            stop_fade: None,
        };
        (ScrubVoice { shared }, player)
    }

    pub fn capacity(&self) -> usize {
        self.shared.capacity
    }

    pub fn fade_frames(&self) -> usize {
        self.shared.fade_frames
    }

    /// Current cancel generation: stamp grains with the value read when their request was made.
    pub fn generation(&self) -> i64 {
        self.shared.cancel_generation.load(Acquire)
    }

    /// Writes the grain (`left.len()` frames, `hop` of them before the next grain may start) into a free slot and hands it
    /// to the player; an older pending grain goes back to the free set. `false` = no free slot (cannot happen with one
    /// producer).
    pub fn publish(&self, left: &[f32], right: &[f32], hop: usize, generation: i64, tag: i64) -> bool {
        let s = &*self.shared;
        let frames = left.len().min(right.len());
        assert!(frames <= s.capacity && hop >= s.fade_frames && hop <= frames);
        let mut f = s.free.load(Acquire);
        let slot = loop {
            if f == 0 {
                return false;
            }
            let bit = f.isolate_lowest_one();
            match s.free.compare_exchange(f, f & !bit, AcqRel, Acquire) {
                Ok(_) => break bit.trailing_zeros() as usize,
                Err(cur) => f = cur,
            }
        };
        let base = slot * s.capacity;
        for i in 0..frames {
            s.left[base + i].store(left[i].to_bits(), Relaxed);
            s.right[base + i].store(right[i].to_bits(), Relaxed);
        }
        let info = &s.info[slot];
        info.frames.store(frames, Relaxed);
        info.hop.store(hop, Relaxed);
        info.generation.store(generation, Relaxed);
        info.tag.store(tag, Relaxed);
        let replaced = s.pending.swap(slot as i64, AcqRel);
        if replaced >= 0 {
            s.release(replaced as usize);
        }
        true
    }

    /// Any thread: fade out what plays (within `fade_frames`), drop pending and older-generation grains.
    pub fn cancel(&self) {
        self.shared.cancel_generation.fetch_add(1, AcqRel);
    }

    pub fn grains_started(&self) -> u64 {
        self.shared.started.load(Acquire)
    }

    pub fn last_started_tag(&self) -> i64 {
        self.shared.started_tag.load(Acquire)
    }

    pub fn free_slots(&self) -> u32 {
        self.shared.free.load(Acquire).count_ones()
    }
}

/// The player rides on the output's callback next to the play ring (`AudioOut::set_side_voice`).
impl sq_audio_out::output::SideVoice for ScrubPlayer {
    fn render(&mut self, l: &mut [f32], r: &mut [f32]) -> bool {
        ScrubPlayer::render(self, l, r)
    }
}

impl ScrubPlayer {
    fn frames(&self, slot: usize) -> usize {
        self.shared.info[slot].frames.load(Relaxed)
    }

    fn hop(&self, slot: usize) -> usize {
        self.shared.info[slot].hop.load(Relaxed)
    }

    fn take(&self, gen_now: i64) -> Option<usize> {
        let p = self.shared.pending.swap(-1, AcqRel);
        if p < 0 {
            return None;
        }
        let p = p as usize;
        if self.shared.info[p].generation.load(Relaxed) != gen_now {
            self.shared.release(p);
            return None;
        }
        Some(p)
    }

    /// Overwrites `l.len()` frames. Returns true when the output is pure silence (nothing playing).
    pub fn render(&mut self, l: &mut [f32], r: &mut [f32]) -> bool {
        let s = Arc::clone(&self.shared);
        let count = l.len().min(r.len());
        let generation = s.cancel_generation.load(Acquire);
        if generation != self.seen_generation {
            self.seen_generation = generation;
            if self.cur.is_some() || self.old.is_some() {
                self.stop_fade = Some(0);
            }
            // Only a grain of an older generation is dropped: one published for the new generation (the next scrub
            // started within this render quantum) stays, unless a newer one has replaced it meanwhile.
            let p = s.pending.swap(-1, AcqRel);
            if p >= 0 {
                let keep = s.info[p as usize].generation.load(Relaxed) == generation
                    && s.pending.compare_exchange(-1, p, AcqRel, Acquire).is_ok();
                if !keep {
                    s.release(p as usize);
                }
            }
        }
        if self.cur.is_none() && self.old.is_none() && s.pending.load(Relaxed) < 0 {
            l[..count].fill(0.0);
            r[..count].fill(0.0);
            return true;
        }
        let (mut tried, mut sounded) = (false, false);
        for i in 0..count {
            if self.stop_fade.is_none() {
                let at_hop = self.cur.is_some_and(|c| self.cur_off == self.hop(c));
                let past = self.cur.is_none_or(|c| self.cur_off > self.hop(c));
                if at_hop || (!tried && past) {
                    tried = true;
                    if let Some(n) = self.take(generation) {
                        if let Some(o) = self.old {
                            s.release(o); // finished already (hop >= fade), defensive
                        }
                        self.old = self.cur;
                        self.old_off = self.cur_off;
                        self.cur = Some(n);
                        self.cur_off = 0;
                        s.started.fetch_add(1, Relaxed);
                        s.started_tag.store(s.info[n].tag.load(Relaxed), Release);
                    }
                }
            }
            let (mut sl, mut sr) = (0.0f32, 0.0f32);
            if let Some(c) = self.cur {
                sounded = true;
                let at = c * s.capacity + self.cur_off;
                sl += f32::from_bits(s.left[at].load(Relaxed));
                sr += f32::from_bits(s.right[at].load(Relaxed));
                self.cur_off += 1;
                if self.cur_off >= self.frames(c) {
                    s.release(c);
                    self.cur = None;
                }
            }
            if let Some(o) = self.old {
                sounded = true;
                let at = o * s.capacity + self.old_off;
                sl += f32::from_bits(s.left[at].load(Relaxed));
                sr += f32::from_bits(s.right[at].load(Relaxed));
                self.old_off += 1;
                if self.old_off >= self.frames(o) {
                    s.release(o);
                    self.old = None;
                }
            }
            if let Some(f) = self.stop_fade {
                let g = 1.0 - self.ramp[f];
                sl *= g;
                sr *= g;
                self.stop_fade = Some(f + 1);
                if f + 1 >= s.fade_frames {
                    if let Some(c) = self.cur.take() {
                        s.release(c);
                    }
                    if let Some(o) = self.old.take() {
                        s.release(o);
                    }
                    self.stop_fade = None;
                }
            }
            l[i] = sl;
            r[i] = sr;
        }
        if self.cur.is_none() && self.old.is_none() {
            self.stop_fade = None;
        }
        !sounded
    }
}

struct Request {
    grain: ScrubGrain,
    generation: i64,
    tag: i64,
}

struct Control {
    planner: ScrubGrainPlanner,
    timeline: Option<Arc<Timeline>>,
    sequences: Arc<Sequences>,
    request: Option<Request>,
    draining: bool,
    next_tag: i64,
    last_grain: Option<ScrubGrain>,
}

/// The mixing side: the dry feeder and the grain buffers (worker thread only, or the caller when inline).
struct Mixer {
    feeder: AudioFeeder,
    src_l: Vec<f32>,
    src_r: Vec<f32>,
    out_l: Vec<f32>,
    out_r: Vec<f32>,
    ramp: Vec<f32>,
}

struct Inner {
    voice: ScrubVoice,
    settings: ScrubSettings,
    inline: bool,
    control: Mutex<Control>,
    mixer: Mutex<Mixer>,
    handle: FeederHandle,
    submitted: AtomicUsize,
    produced: AtomicUsize,
    dropped: AtomicUsize,
}

enum Msg {
    Drain,
    Idle(Sender<()>),
}

/// Scrub/step audio: planner + grain mixing worker + `ScrubVoice`. Control calls are cheap and never block on mixing
/// (except with `inline: true`, used by tests, which mixes on the calling thread).
pub struct ScrubAudio {
    inner: Arc<Inner>,
    tx: Sender<Msg>,
}

impl ScrubAudio {
    /// `resolver` provides the sources (48 kHz), like `AudioFeeder`'s. Returns the control side and the player the render
    /// thread calls. De-click and live ducking are set through `feeder_handle` (the host follows Preferences).
    pub fn new(
        resolver: Resolver,
        settings: ScrubSettings,
        sample_rate: i64,
        inline: bool,
    ) -> (ScrubAudio, ScrubPlayer) {
        // Longest grain: a 1/10 s frame (10 fps) is the longest hop the app uses; longer frames are clamped to it.
        let capacity = sample_rate as usize / 10 + settings.fade_frames;
        let (voice, player) = ScrubVoice::new(capacity, settings.fade_frames);
        let span_capacity = (capacity as f64 * settings.max_varispeed.max(1.0)).ceil() as usize + 2;
        let empty = Timeline::new(Id::from_u128(0), "", SequenceFormat::new(Time::new(1, 30)), Vec::new());
        let feeder = AudioFeeder::new(empty, 4096, resolver);
        let handle = feeder.handle();
        let mixer = Mixer {
            feeder,
            src_l: vec![0.0; span_capacity],
            src_r: vec![0.0; span_capacity],
            out_l: vec![0.0; capacity],
            out_r: vec![0.0; capacity],
            ramp: (0..settings.fade_frames).map(|k| ramp_value(k, settings.fade_frames)).collect(),
        };
        let inner = Arc::new(Inner {
            voice,
            settings,
            inline,
            control: Mutex::new(Control {
                planner: ScrubGrainPlanner::new(settings, sample_rate),
                timeline: None,
                sequences: Arc::new(Sequences::new()),
                request: None,
                draining: false,
                next_tag: 0,
                last_grain: None,
            }),
            mixer: Mutex::new(mixer),
            handle,
            submitted: AtomicUsize::new(0),
            produced: AtomicUsize::new(0),
            dropped: AtomicUsize::new(0),
        });
        let (tx, rx) = channel();
        let worker = Arc::clone(&inner);
        // The thread ends when the ScrubAudio (the sender) is dropped. Without it requests are never mixed.
        let _ = std::thread::Builder::new().name("sq-scrub-audio".into()).spawn(move || run_worker(&worker, &rx));
        (ScrubAudio { inner, tx }, player)
    }

    /// The producer side of the voice (stats, `cancel`).
    pub fn voice(&self) -> &ScrubVoice {
        &self.inner.voice
    }

    pub fn settings(&self) -> ScrubSettings {
        self.inner.settings
    }

    /// The scrub mixer's feeder controls: de-click fade, live ducking, dialogue silences, changed media.
    pub fn feeder_handle(&self) -> &FeederHandle {
        &self.inner.handle
    }

    pub fn set_timeline(&self, timeline: Timeline, sequences: Sequences) {
        let mut c = lock(&self.inner.control);
        c.timeline = Some(Arc::new(timeline));
        c.sequences = Arc::new(sequences);
    }

    /// The files behind these media changed (relink): the scrub mixer reopens their sources at its next grain.
    pub fn media_changed(&self, ids: &HashSet<Id>) {
        self.inner.handle.media_changed(ids);
    }

    /// N8b: the project's own live ducking.
    pub fn set_project_live_ducking(&self, setting: Option<ProjectLiveDucking>) {
        self.inner.handle.set_project_live_ducking(setting);
    }

    /// N8b: dialogue pauses for the live duck.
    pub fn set_dialogue_silences(&self, provider: Option<SharedSilences>) {
        self.inner.handle.set_dialogue_silences(provider);
    }

    /// Start of a drag at `position` (no sound yet).
    pub fn begin(&self, position: Time, host_nanos: i64) {
        lock(&self.inner.control).planner.begin(position, host_nanos);
    }

    /// Drag moved to `position` at host time `host_nanos` (same base as `AudioPlaying::host_nanoseconds`).
    pub fn scrub(&self, position: Time, host_nanos: i64) {
        let g = {
            let mut c = lock(&self.inner.control);
            let Some(fd) = c.timeline.as_ref().map(|t| t.format.frame_duration) else { return };
            c.planner.scrub(position, host_nanos, fd)
        };
        if let Some(g) = g {
            self.submit(g);
        }
    }

    /// Step from `from` to `to` (grid times): one grain of the new frame in step direction.
    pub fn step(&self, from: Time, to: Time) {
        let g = {
            let c = lock(&self.inner.control);
            let Some(fd) = c.timeline.as_ref().map(|t| t.format.frame_duration) else { return };
            c.planner.step(from, to, fd)
        };
        if let Some(g) = g {
            self.submit(g);
        }
    }

    /// Stops scrub audio: the voice fades out (5 ms), queued and in-flight grains are dropped.
    pub fn stop(&self) {
        self.inner.voice.cancel();
        lock(&self.inner.control).request = None;
    }

    /// Blocks until the worker has mixed every submitted request (tests).
    pub fn wait_until_idle(&self) {
        let (tx, rx) = channel();
        if self.tx.send(Msg::Idle(tx)).is_ok() {
            let _ = rx.recv();
        }
    }

    pub fn submitted_grains(&self) -> usize {
        self.inner.submitted.load(Acquire)
    }

    pub fn produced_grains(&self) -> usize {
        self.inner.produced.load(Acquire)
    }

    /// Requests that found no free voice slot (should stay 0).
    pub fn dropped_requests(&self) -> usize {
        self.inner.dropped.load(Acquire)
    }

    /// Source reads that failed while mixing grains (rendered as silence).
    pub fn failed_reads(&self) -> usize {
        self.inner.handle.failed_reads()
    }

    /// Tag of the most recent request (compare with `voice().last_started_tag()`).
    pub fn last_tag(&self) -> i64 {
        lock(&self.inner.control).next_tag - 1
    }

    pub fn last_grain(&self) -> Option<ScrubGrain> {
        lock(&self.inner.control).last_grain
    }

    fn submit(&self, g0: ScrubGrain) {
        let inner = &self.inner;
        let mut g = g0;
        g.hop = g.hop.min(inner.voice.capacity() - g.fade);
        let generation = inner.voice.generation();
        inner.submitted.fetch_add(1, Relaxed);
        if inner.inline {
            let tag = {
                let mut c = lock(&inner.control);
                c.last_grain = Some(g);
                c.next_tag += 1;
                c.next_tag - 1
            };
            inner.produce(g, generation, tag);
            return;
        }
        let start_drain = {
            let mut c = lock(&inner.control);
            let tag = c.next_tag;
            c.request = Some(Request { grain: g, generation, tag });
            c.next_tag += 1;
            c.last_grain = Some(g);
            !std::mem::replace(&mut c.draining, true)
        };
        if start_drain {
            let _ = self.tx.send(Msg::Drain);
        }
    }
}

fn run_worker(inner: &Inner, rx: &Receiver<Msg>) {
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Drain => loop {
                let r = {
                    let mut c = lock(&inner.control);
                    let r = c.request.take();
                    if r.is_none() {
                        c.draining = false;
                    }
                    r
                };
                let Some(r) = r else { break };
                inner.produce(r.grain, r.generation, r.tag);
            },
            Msg::Idle(done) => {
                let _ = done.send(());
            }
        }
    }
}

impl Inner {
    fn produce(&self, g: ScrubGrain, generation: i64, tag: i64) {
        let (timeline, sequences) = {
            let c = lock(&self.control);
            match &c.timeline {
                Some(t) => (Arc::clone(t), Arc::clone(&c.sequences)),
                None => return,
            }
        };
        let mut m = lock(&self.mixer);
        m.render(&g, &timeline, &sequences);
        let n = g.frames();
        if self.voice.publish(&m.out_l[..n], &m.out_r[..n], g.hop, generation, tag) {
            self.produced.fetch_add(1, Relaxed);
        } else {
            self.dropped.fetch_add(1, Relaxed);
        }
    }
}

impl Mixer {
    /// Mixes the grain's source span (timeline mix with clip effects), reads it at `speed` in grain direction and applies
    /// the window into `out_l`/`out_r`.
    fn render(&mut self, g: &ScrubGrain, timeline: &Timeline, sequences: &Sequences) {
        let span = g.source_span().min(self.src_l.len());
        let first = if g.reverse { g.start - span as i64 } else { g.start }; // src[k] = timeline frame first + k
        let block = self.feeder.block_frames;
        let mut k = 0;
        while k < span {
            let f = first + k as i64;
            let n = (span - k).min(block);
            if f < 0 {
                // Before the timeline start: silence.
                let z = n.min((-f) as usize);
                self.src_l[k..k + z].fill(0.0);
                self.src_r[k..k + z].fill(0.0);
                k += z;
                continue;
            }
            // Clip and nest audio effects too, so a scrubbed clip sounds like it plays (chains re-prime at every jump).
            let (l, r) = (&mut self.src_l[k..k + n], &mut self.src_r[k..k + n]);
            self.feeder.mix(timeline, sequences, f, l, r, true);
            k += n;
        }
        let (n, fade) = (g.frames(), g.fade);
        for j in 0..n {
            let x = j as f64 * g.speed;
            let pos = if g.reverse { (span - 1) as f64 - x } else { x };
            let i0 = (pos.floor().max(0.0) as usize).min(span - 1);
            let i1 = (i0 + 1).min(span - 1);
            let w = (pos - i0 as f64) as f32;
            let mut a = self.src_l[i0] + (self.src_l[i1] - self.src_l[i0]) * w;
            let mut b = self.src_r[i0] + (self.src_r[i1] - self.src_r[i0]) * w;
            let win = if j < fade {
                self.ramp[j]
            } else if j >= n - fade {
                self.ramp[n - 1 - j]
            } else {
                1.0
            };
            a *= win;
            b *= win;
            self.out_l[j] = a;
            self.out_r[j] = b;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, Track, TrackKind};
    use sq_core_time::TimeRange;
    use sq_media::media_error::MediaError;
    use sq_media::memory_audio_source::{AudioSource, MemoryAudioSource};

    const SR: i64 = 48_000;
    const FADE_N: usize = 240;

    fn fd30() -> Time {
        Time::new(1, 30)
    }

    /// 440 Hz sine, amplitude 0.5, six seconds, both channels.
    fn sine_source() -> Arc<dyn AudioSource> {
        let n = 6 * SR as usize;
        Arc::new(MemoryAudioSource::mono(
            (0..n).map(|i| (0.5 * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / SR as f64).sin()) as f32).collect(),
        ))
    }

    /// Largest per-sample step of the source itself (the threshold's baseline).
    fn natural_step() -> f32 {
        (0.5 * 2.0 * std::f64::consts::PI * 440.0 / SR as f64) as f32
    }

    /// Crossfades may add |a - b| x max ramp slope (pi / (2 x 240) ~ 0.0065) on top of the natural step.
    fn threshold() -> f32 {
        natural_step() + 0.012
    }

    fn timeline(clip_start: Time, duration: Time, muted: bool, media: Id) -> Timeline {
        let c =
            Clip::new(Id::from_u128(2), "a", media, TrackKind::Audio, TimeRange::new(Time::ZERO, duration), clip_start);
        let mut tr = Track::new(Id::from_u128(3), TrackKind::Audio);
        tr.set_clips(vec![c]);
        tr.is_muted = muted;
        Timeline::new(Id::from_u128(9), "S", SequenceFormat::new(fd30()), vec![tr])
    }

    fn make_scrub(
        settings: ScrubSettings,
        muted: bool,
        clip_start: Time,
        duration: Time,
        inline: bool,
    ) -> (ScrubAudio, ScrubPlayer) {
        let src = sine_source();
        let (s, p) = ScrubAudio::new(Arc::new(move |_| Ok(Arc::clone(&src))), settings, SR, inline);
        s.set_timeline(timeline(clip_start, duration, muted, Id::from_u128(1)), Sequences::new());
        (s, p)
    }

    #[test]
    fn a_scrub_step_sounds_through_the_output_side_voice() {
        use sq_audio_out::output::SideVoice;
        let (s, mut p) = inline_scrub();
        let mut quiet = (vec![0.0f32; 512], vec![0.0f32; 512]);
        assert!(SideVoice::render(&mut p, &mut quiet.0, &mut quiet.1), "no grain yet: silence");
        s.step(Time::new(3, 30), Time::new(4, 30));
        s.wait_until_idle();
        let (mut l, mut r) = (vec![0.0f32; 512], vec![0.0f32; 512]);
        let silent = SideVoice::render(&mut p, &mut l, &mut r);
        assert!(!silent && l.iter().any(|v| v.abs() > 0.1), "the stepped frame plays a grain of the clip's audio");
    }

    fn inline_scrub() -> (ScrubAudio, ScrubPlayer) {
        make_scrub(ScrubSettings::default(), false, Time::ZERO, Time::new(6, 1), true)
    }

    /// Renders `frames` from the player in 512-frame calls; returns the left channel (right is identical).
    fn render(p: &mut ScrubPlayer, frames: usize) -> Vec<f32> {
        let mut out = Vec::new();
        let mut left = frames;
        while left > 0 {
            let n = 512.min(left);
            let (mut l, mut r) = (vec![0.0f32; n], vec![0.0f32; n]);
            p.render(&mut l, &mut r);
            assert_eq!(l, r);
            out.extend(l);
            left -= n;
        }
        out
    }

    fn max_step(x: &[f32]) -> f32 {
        x.windows(2).map(|w| (w[1] - w[0]).abs()).fold(0.0, f32::max)
    }

    fn peak(x: &[f32]) -> f32 {
        x.iter().map(|v| v.abs()).fold(0.0, f32::max)
    }

    fn ms(n: i64) -> i64 {
        n * 1_000_000
    }

    fn t(frame: i64) -> Time {
        Time::new(frame, SR)
    }

    #[test]
    fn grain_length_is_one_frame_but_at_least_40ms() {
        let p = ScrubGrainPlanner::new(ScrubSettings::default(), SR);
        assert_eq!(p.grain_length(1.0, fd30()), 1920); // 33 ms frame -> 40 ms
        assert_eq!(p.grain_length(1.0, Time::new(1, 24)), 2000); // 41.7 ms
        assert_eq!(p.grain_length(1.0, Time::new(1001, 24_000)), 2002); // 23.976: ceil(2002.0)
        assert_eq!(p.grain_length(0.2, Time::new(1, 24)), 2000);
        assert_eq!(p.grain_length(3.0, Time::new(1, 24)), 1920); // fast: shortest grains
        assert_eq!(p.grain_length(1.0, Time::new(1, 10)), 4800);
    }

    #[test]
    fn scrub_grain_follows_the_direction_of_motion() {
        let mut p = ScrubGrainPlanner::new(ScrubSettings::default(), SR);
        p.begin(Time::new(1, 1), 0);
        let f = p.scrub(Time::new(1, 1) + Time::new(1, 60), ms(16), fd30()).unwrap();
        assert!(!f.reverse && f.start == 48_800 && f.hop == 1920 && f.fade == FADE_N && f.speed == 1.0);
        assert!(p.velocity() > 1.0 && p.velocity() < 1.1); // 16.7 ms moved in 16 ms
        let b = p.scrub(Time::new(1, 1), ms(32), fd30()).unwrap();
        assert!(b.reverse && b.start == 48_000); // reads backwards from here
        assert!(p.scrub(Time::new(1, 1), ms(48), fd30()).is_none(), "no movement: no grain");
    }

    #[test]
    fn velocity_resets_after_a_hold_and_fast_scrub_shortens_grains() {
        let mut p = ScrubGrainPlanner::new(ScrubSettings::default(), SR);
        p.begin(Time::ZERO, 0);
        let g = p.scrub(Time::new(1, 10), ms(20), Time::new(1, 24)).unwrap(); // 5x
        assert!(g.hop == 1920 && p.velocity() > 2.0);
        let h = p.scrub(Time::new(1, 10) + Time::new(1, 1000), ms(1000), Time::new(1, 24)).unwrap();
        assert!(h.hop == 2000 && p.velocity().abs() < 0.1, "after a hold: slow again");
    }

    #[test]
    fn varispeed_only_when_enabled() {
        let mut p = ScrubGrainPlanner::new(ScrubSettings::default(), SR);
        p.begin(Time::ZERO, 0);
        assert_eq!(p.scrub(Time::new(1, 10), ms(33), fd30()).map(|g| g.speed), Some(1.0)); // pitch preserved
        let s = ScrubSettings { max_varispeed: 2.0, ..ScrubSettings::default() };
        let mut q = ScrubGrainPlanner::new(s, SR);
        q.begin(Time::ZERO, 0);
        let g = q.scrub(Time::new(1, 10), ms(33), fd30()).unwrap(); // ~3x
        assert!(g.speed == 2.0 && g.source_span() >= 2 * (g.frames() - 1));
    }

    #[test]
    fn step_grain_is_one_frame_in_step_direction() {
        let p = ScrubGrainPlanner::new(ScrubSettings::default(), SR);
        let f = p.step(Time::new(1, 1), Time::new(1, 1) + fd30(), fd30()).unwrap();
        assert!(!f.reverse && f.start == 49_600 && f.hop == 1920);
        let b = p.step(Time::new(1, 1), Time::new(1, 1) - fd30(), fd30()).unwrap();
        assert!(b.reverse && b.start == 48_000, "end of the new frame, read backwards");
        assert!(p.step(Time::ZERO, Time::ZERO, fd30()).is_none());
    }

    /// Forward, backward and jittering drags at mouse-event rate: every grain join is a crossfade, no step above the
    /// threshold.
    #[test]
    fn grain_joins_are_continuous() {
        for mode in ["forward", "backward", "jitter"] {
            let (s, mut player) = inline_scrub();
            let (mut pos, mut host) = (2 * SR, 0i64);
            s.begin(t(pos), host);
            let mut out = Vec::new();
            for k in 0..120 {
                // 120 events, one per 8 ms render slice (~1 s)
                match mode {
                    "forward" => pos += 400,
                    "backward" => pos -= 400,
                    _ => pos += if k % 3 == 0 { -700 } else { 450 },
                }
                host += ms(8);
                s.scrub(t(pos), host);
                out.extend(render(&mut player, 384));
            }
            out.extend(render(&mut player, 4800)); // tail fades out
            assert!(peak(&out) > 0.4, "grains played");
            assert!(max_step(&out) < threshold(), "{mode}: max step {} >= {}", max_step(&out), threshold());
            assert!(s.voice().grains_started() > 10);
            assert!(out[out.len() - 100..].iter().all(|v| *v == 0.0), "silent after the last grain");
        }
    }

    /// The crossfade matters: without it the same drag has steps far above the threshold (sanity check of the measure).
    #[test]
    fn hard_cuts_would_fail_the_threshold() {
        let settings = ScrubSettings { fade_frames: 1, ..ScrubSettings::default() };
        let (s, mut player) = make_scrub(settings, false, Time::ZERO, Time::new(6, 1), true);
        let mut pos = 48_000;
        s.begin(t(pos), 0);
        let mut out = Vec::new();
        for k in 0..60 {
            pos += 737;
            s.scrub(t(pos), ms((k + 1) * 8));
            out.extend(render(&mut player, 384));
        }
        assert!(max_step(&out) > 0.1);
    }

    #[test]
    fn reverse_grain_plays_the_source_backwards() {
        let (s, mut player) = inline_scrub();
        s.begin(t(96_000), 0);
        s.scrub(t(90_000), ms(100));
        let out = render(&mut player, 1920 + FADE_N);
        let src = |i: i64| (0.5 * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / SR as f64).sin()) as f32;
        for j in (300..1900).step_by(97) {
            assert!((out[j] - src(90_000 - 1 - j as i64)).abs() < 1e-5);
        }
    }

    /// Scrubbing much faster than grains can play: requests replace each other (one pending), nothing queues up, and the
    /// grain that plays next is the latest one.
    #[test]
    fn fast_scrub_replaces_pending_grains() {
        let (s, mut player) = inline_scrub();
        let mut pos = 48_000;
        s.begin(t(pos), 0);
        for k in 0..500 {
            pos += 200;
            s.scrub(t(pos), (k + 1) * 100_000);
        }
        assert_eq!(s.dropped_requests(), 0);
        assert_eq!(
            s.voice().free_slots() as usize,
            ScrubVoice::SLOT_COUNT - 1,
            "exactly one pending, nothing else held"
        );
        render(&mut player, 512);
        assert!(s.voice().grains_started() == 1 && s.voice().last_started_tag() == s.last_tag());
        for _ in 0..500 {
            pos += 200;
            s.scrub(t(pos), 1_000 * 100_000);
        }
        let played = render(&mut player, 48_000); // 1 s
        assert!(s.voice().grains_started() == 2 && s.voice().last_started_tag() == s.last_tag());
        assert!(peak(&played) > 0.4 && max_step(&played) < threshold());
        assert_eq!(s.voice().free_slots() as usize, ScrubVoice::SLOT_COUNT);
    }

    #[test]
    fn gap_and_muted_track_are_silent() {
        let (gap, mut gp) = make_scrub(ScrubSettings::default(), false, Time::new(3, 1), Time::new(1, 1), true); // audio only in [3 s, 4 s)
        gap.begin(t(48_000), 0);
        let mut out = Vec::new();
        for k in 0..40 {
            gap.scrub(t(48_000 + (k + 1) * 400), ms((k + 1) * 8));
            out.extend(render(&mut gp, 384));
        }
        assert!(out.iter().all(|v| *v == 0.0));
        let (muted, mut mp) = make_scrub(ScrubSettings::default(), true, Time::ZERO, Time::new(6, 1), true);
        muted.begin(t(48_000), 0);
        out.clear();
        for k in 0..40 {
            muted.scrub(t(48_000 + (k + 1) * 400), ms((k + 1) * 8));
            out.extend(render(&mut mp, 384));
        }
        assert!(out.iter().all(|v| *v == 0.0));
    }

    /// Scrubbing across a clip edge: the grain's gap part is silent, the join into it stays continuous.
    #[test]
    fn clip_edge_inside_a_grain_stays_continuous() {
        let (s, mut player) = make_scrub(ScrubSettings::default(), false, Time::new(1, 1), Time::new(1, 1), true);
        s.begin(t(47_000), 0);
        let mut out = Vec::new();
        for k in 0..20 {
            s.scrub(t(47_000 + (k + 1) * 400), ms((k + 1) * 8));
            out.extend(render(&mut player, 384));
        }
        assert!(peak(&out) > 0.4);
        // The sine starts at phase 0 at the clip start, so the edit itself adds no step either.
        assert!(max_step(&out) < threshold());
    }

    #[test]
    fn stop_fades_out_and_drops_stale_grains() {
        let (s, mut player) = inline_scrub();
        s.begin(t(48_000), 0);
        s.scrub(t(48_400), ms(8));
        let mut out = render(&mut player, 1000); // mid-grain
        s.scrub(t(48_800), ms(16)); // pending
        s.stop();
        out.extend(render(&mut player, 2000));
        assert!(max_step(&out) < threshold());
        assert!(out[out.len() - (2000 - FADE_N)..].iter().all(|v| *v == 0.0), "silent after the 5 ms fade");
        assert!(s.voice().grains_started() == 1 && s.voice().free_slots() as usize == ScrubVoice::SLOT_COUNT);
        // A grain produced for a request made before the stop is dropped by the voice.
        assert!(s.voice().publish(&[0.5; 600], &[0.5; 600], 300, s.voice().generation() - 1, 99));
        assert!(render(&mut player, 512).iter().all(|v| *v == 0.0));
        assert_eq!(s.voice().free_slots() as usize, ScrubVoice::SLOT_COUNT);
    }

    #[test]
    fn step_plays_one_grain_then_silence() {
        let (s, mut player) = inline_scrub();
        s.step(Time::new(1, 1), Time::new(1, 1) + fd30());
        let out = render(&mut player, 4800);
        assert!(peak(&out) > 0.4 && max_step(&out) < threshold());
        assert!(out[1920 + FADE_N..].iter().all(|v| *v == 0.0));
        assert_eq!(s.voice().grains_started(), 1);
    }

    /// Worker-thread mode (the app's): same results once the queue is idle.
    #[test]
    fn async_worker_produces_grains() {
        let (s, mut player) = make_scrub(ScrubSettings::default(), false, Time::ZERO, Time::new(6, 1), false);
        s.begin(t(48_000), 0);
        for k in 0..50 {
            s.scrub(t(48_000 + (k + 1) * 400), ms((k + 1) * 8));
        }
        s.wait_until_idle();
        assert!(s.dropped_requests() == 0 && s.voice().free_slots() as usize == ScrubVoice::SLOT_COUNT - 1);
        let out = render(&mut player, 4800);
        assert!(peak(&out) > 0.4 && s.voice().last_started_tag() == s.last_tag());
    }

    /// P21: a relink swaps the file behind a media id; the scrub mixer must grain from the new file after
    /// `media_changed`, not from the remembered old one (or the remembered open failure of a missing one).
    #[test]
    fn a_relinked_file_is_the_grain_source_after_media_changed() {
        use std::sync::Mutex;
        let current: Arc<Mutex<Option<Arc<dyn AudioSource>>>> = Arc::new(Mutex::new(None));
        let shared = Arc::clone(&current);
        let resolver: Resolver = Arc::new(move |_| shared.lock().unwrap().clone().ok_or(MediaError::Unreadable));
        let (s, mut player) = ScrubAudio::new(resolver, ScrubSettings::default(), SR, true);
        s.set_timeline(timeline(Time::ZERO, Time::new(6, 1), false, Id::from_u128(1)), Sequences::new());
        let step = |s: &ScrubAudio, player: &mut ScrubPlayer| {
            s.step(Time::new(1, 1), Time::new(1, 1) + fd30());
            render(player, 4800)
        };
        assert!(peak(&step(&s, &mut player)) == 0.0, "the missing file is silence");
        *current.lock().unwrap() = Some(sine_source());
        s.media_changed(&[Id::from_u128(1)].into_iter().collect());
        assert!(peak(&step(&s, &mut player)) > 0.4, "the relinked file sounds at the next grain");
        // A second relink to a quieter file replaces the cached source too.
        let quiet: Arc<dyn AudioSource> = Arc::new(MemoryAudioSource::mono(vec![0.1; 6 * SR as usize]));
        *current.lock().unwrap() = Some(quiet);
        s.media_changed(&[Id::from_u128(1)].into_iter().collect());
        let p = peak(&step(&s, &mut player));
        assert!(p > 0.05 && p < 0.2, "the second file replaced the first (peak {p})");
    }

    #[test]
    fn failing_source_is_silence() {
        let (s, mut player) =
            ScrubAudio::new(Arc::new(|_| Err(MediaError::Unreadable)), ScrubSettings::default(), SR, true);
        s.set_timeline(timeline(Time::ZERO, Time::new(6, 1), false, Id::from_u128(1)), Sequences::new());
        s.step(Time::new(1, 1), Time::new(1, 1) + fd30());
        assert!(render(&mut player, 2400).iter().all(|v| *v == 0.0));
        assert!(s.failed_reads() >= 1);
    }
}
