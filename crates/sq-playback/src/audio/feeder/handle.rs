// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder.swift (control side), AudioFeeder+Preferences.swift
//! The feeder's control surface for other threads: timeline, presets, role buses, de-click, live ducking, stale media.

use super::config::{BusSet, FxConfig, lock};
use crate::audio::track_mix::{Sequences, limiter_ceiling_of, presets_of, roles_of};
use sq_audiofx::de_click::{AudioDeClick, BoolDefaults};
use sq_audiofx::presets::TrackAudioPreset;
use sq_core_audio::live_ducking::{DefaultsStore, DialogueSilenceProvider, DuckTimingExt, LiveDucking};
use sq_core_audio::live_ducking_index::LiveDuckingIndex;
use sq_core_model::{AudioTag, DuckTiming, ProjectLiveDucking, Timeline, TrackKind};
use sq_core_time::Id;
use sq_media::media_error::MediaError;
use sq_media::memory_audio_source::AudioSource;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicI64, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};

/// Opens the audio source of a media (at the mixer rate already).
pub type Resolver = Arc<dyn Fn(Id) -> Result<Arc<dyn AudioSource>, MediaError> + Send + Sync>;
/// Dialogue pauses for live ducking; must answer without blocking.
pub type SharedSilences = Arc<dyn DialogueSilenceProviderSync>;

/// `DialogueSilenceProvider` that can be shared with the feeder thread.
pub trait DialogueSilenceProviderSync: DialogueSilenceProvider + Send + Sync {}
impl<T: DialogueSilenceProvider + Send + Sync> DialogueSilenceProviderSync for T {}

pub(super) struct Control {
    pub(super) timeline: Arc<Timeline>,
    /// Live ducking decisions of `timeline` (built with it in `set_timeline`, off the audio thread): no per-block walk.
    pub(super) duck_index: Arc<LiveDuckingIndex>,
    /// Timeline frame where the next block starts (forward) or ends (reverse).
    pub(super) position: i64,
    pub(super) reverse: bool,
    /// Bumped by seek; blocks mixed under an older generation are dropped.
    pub(super) generation: i64,
    pub(super) buses: BusSet,
    pub(super) sequences: Arc<Sequences>,
    /// Media whose cached source (and failure) the feeder drops at its next block.
    pub(super) stale_media: HashSet<Id>,
    pub(super) stale_all: bool,
    /// Master limiter ceiling (the top sequence's `DeliveryTarget::true_peak_db`); `None` = no limiter.
    pub(super) limiter_ceiling_db: Option<f64>,
}

pub(super) struct Shared {
    pub(super) block_frames: usize,
    pub(super) config: Mutex<FxConfig>,
    pub(super) control: Mutex<Control>,
    pub(super) role_gains_db: Mutex<HashMap<AudioTag, f64>>,
    pub(super) failed_reads: AtomicUsize,
    /// Automatic de-click fade at every clip boundary, in frames (0 = off).
    pub(super) declick: AtomicI64,
    /// Live music ducking amount in 1/100 dB (0 = off) and the timing of the Preferences duck.
    pub(super) duck_centi_db: AtomicI64,
    pub(super) pref_timing: Mutex<DuckTiming>,
    /// The project's own setting: -1 = none (follow Preferences), 0 = off, else the amount in 1/100 dB.
    pub(super) project_centi_db: AtomicI64,
    pub(super) project_timing: Mutex<DuckTiming>,
    pub(super) silences: Mutex<Option<SharedSilences>>,
    pub(super) resolver: Resolver,
    /// Sources opened ahead of the first Play on a worker (`FeederHandle::prewarm`); the feeder takes them instead of
    /// opening a file on the mix thread.
    pub(super) prewarmed: Mutex<HashMap<Id, Arc<dyn AudioSource>>>,
    /// Media already opened ahead since the last `invalidate_sources` / `media_changed` (the feeder keeps what it took), so
    /// an edit that pushes the timeline again opens nothing twice.
    pub(super) prewarm_started: Mutex<HashSet<Id>>,
    /// Media a prewarm worker is opening right now. The mix thread waits for such a file (`prewarm_landed`) instead of
    /// opening it a second time: a big camera file took long enough to open that the first Play dropped out.
    pub(super) prewarm_in_flight: Mutex<HashSet<Id>>,
    /// Signalled when a prewarm worker is done with a file (opened, failed or cancelled).
    pub(super) prewarm_landed: Condvar,
    /// Bumped when the prewarmed set must be dropped (new timeline, changed media): a running prewarm stops and its late
    /// results are discarded.
    pub(super) prewarm_generation: AtomicU64,
    /// Bumped only when opened sources become wrong (`media_changed`, `invalidate_sources`): late results are discarded.
    pub(super) prewarm_epoch: AtomicU64,
}

/// A file a prewarm worker is opening; leaving (also on an early return) wakes a mix thread waiting for it.
struct InFlight<'a>(&'a Shared, Id);

impl<'a> InFlight<'a> {
    fn enter(shared: &'a Shared, id: Id) -> InFlight<'a> {
        lock(&shared.prewarm_in_flight).insert(id);
        InFlight(shared, id)
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        lock(&self.0.prewarm_in_flight).remove(&self.1);
        self.0.prewarm_landed.notify_all();
    }
}

/// Most sources one timeline switch opens ahead (a project with hundreds of clips opens the earliest ones first).
const PREWARM_LIMIT: usize = 24;

impl Shared {
    pub(super) fn new(timeline: Timeline, block_frames: usize, resolver: Resolver) -> Shared {
        let mut cfg = FxConfig::default();
        cfg.track_ids = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Audio).map(|t| t.id).collect();
        cfg.roles = roles_of(&timeline);
        cfg.presets = presets_of(&timeline);
        let buses = cfg.rebuild(block_frames, true);
        let control = Control {
            duck_index: Arc::new(LiveDuckingIndex::new(&timeline)),
            limiter_ceiling_db: limiter_ceiling_of(&timeline),
            timeline: Arc::new(timeline),
            position: 0,
            reverse: false,
            generation: 0,
            buses,
            sequences: Arc::new(HashMap::new()),
            stale_media: HashSet::new(),
            stale_all: false,
        };
        Shared {
            block_frames,
            config: Mutex::new(cfg),
            control: Mutex::new(control),
            role_gains_db: Mutex::new(HashMap::new()),
            failed_reads: AtomicUsize::new(0),
            declick: AtomicI64::new(0),
            duck_centi_db: AtomicI64::new(0),
            pref_timing: Mutex::new(DuckTiming::classic()),
            project_centi_db: AtomicI64::new(-1),
            project_timing: Mutex::new(DuckTiming::classic()),
            silences: Mutex::new(None),
            resolver,
            prewarmed: Mutex::new(HashMap::new()),
            prewarm_started: Mutex::new(HashSet::new()),
            prewarm_in_flight: Mutex::new(HashSet::new()),
            prewarm_landed: Condvar::new(),
            prewarm_generation: AtomicU64::new(0),
            prewarm_epoch: AtomicU64::new(0),
        }
    }

    /// What the mix applies: the project's setting when it has one, else Preferences.
    pub(super) fn effective_live_ducking(&self) -> Option<LiveDucking> {
        let p = self.project_centi_db.load(Ordering::Relaxed);
        if p >= 0 {
            return (p > 0).then(|| LiveDucking::with_timing(p as f64 / 100.0, lock(&self.project_timing).clone()));
        }
        let v = self.duck_centi_db.load(Ordering::Relaxed);
        (v > 0).then(|| LiveDucking::with_timing(v as f64 / 100.0, lock(&self.pref_timing).clone()))
    }
}

/// Control handle of one `AudioFeeder`; cheap to clone, usable from any thread.
#[derive(Clone)]
pub struct FeederHandle {
    shared: Arc<Shared>,
}

impl FeederHandle {
    pub(super) fn new(shared: Arc<Shared>) -> FeederHandle {
        FeederHandle { shared }
    }

    /// Replaces the timeline. `sequences` resolves nested audio clips (id -> timeline); `None` keeps the current set.
    pub fn set_timeline(&self, t: Timeline, sequences: Option<Sequences>) {
        let ids = t.tracks.iter().filter(|x| x.kind == TrackKind::Audio).map(|x| x.id).collect();
        let (roles, presets, ceiling) = (roles_of(&t), presets_of(&t), limiter_ceiling_of(&t));
        let duck_index = Arc::new(LiveDuckingIndex::new(&t));
        // Rebuild and publish under one `config` lock: interleaved callers can never publish an older set last.
        let mut cfg = lock(&self.shared.config);
        cfg.track_ids = ids;
        cfg.roles = roles;
        cfg.presets = presets;
        let set = cfg.rebuild(self.shared.block_frames, false);
        let mut c = lock(&self.shared.control);
        c.timeline = Arc::new(t);
        c.duck_index = duck_index;
        c.buses = set;
        c.limiter_ceiling_db = ceiling;
        if let Some(s) = sequences {
            c.sequences = Arc::new(s);
        }
        let (timeline, sequences) = (Arc::clone(&c.timeline), Arc::clone(&c.sequences));
        drop(c);
        drop(cfg);
        self.prewarm(&timeline, &sequences);
    }

    /// Opens the audio files of the timeline's clips (earliest first, nested sequences included) on a worker, so the first
    /// Play finds them open: probing and seeking a file took 40 to 90 ms each on the mix thread before the first sound.
    /// A newer call or `media_changed` cancels it.
    fn prewarm(&self, timeline: &Timeline, sequences: &Sequences) {
        let generation = self.shared.prewarm_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let mut media: Vec<(sq_core_time::Time, Id)> = Vec::new();
        collect_audio_media(timeline, sequences, 0, sq_core_time::Time::ZERO, &mut media);
        media.sort_by_key(|(at, _)| *at);
        let mut seen = HashSet::new();
        {
            let started = lock(&self.shared.prewarm_started);
            media.retain(|(_, id)| seen.insert(*id) && !started.contains(id));
        }
        media.truncate(PREWARM_LIMIT);
        if media.is_empty() {
            return;
        }
        let shared = Arc::clone(&self.shared);
        let epoch = shared.prewarm_epoch.load(Ordering::SeqCst);
        let _ = std::thread::Builder::new().name("sq-audio-prewarm".into()).spawn(move || {
            for (_, id) in media {
                if shared.prewarm_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                if !lock(&shared.prewarm_started).insert(id) {
                    continue;
                }
                let _in_flight = InFlight::enter(&shared, id);
                let began = std::time::Instant::now();
                let Ok(source) = (shared.resolver)(id) else { continue }; // the mix thread reports a failed open
                let mut parked = lock(&shared.prewarmed);
                if shared.prewarm_epoch.load(Ordering::SeqCst) != epoch {
                    return;
                }
                parked.insert(id, source);
                sq_core_time::milestones::note(&format!(
                    "play: audio source {id} prewarmed in {:.1} ms",
                    began.elapsed().as_secs_f64() * 1e3
                ));
            }
        });
    }

    /// Replaces all per-track presets (tracks without one have no FX). Builds FX objects on the calling thread; the
    /// feeder thread picks the new set up at its next block. Call off the audio render path.
    pub fn set_tracks(&self, presets: HashMap<Id, TrackAudioPreset>) {
        let mut cfg = lock(&self.shared.config);
        cfg.presets = presets;
        let set = cfg.rebuild(self.shared.block_frames, false);
        lock(&self.shared.control).buses = set;
    }

    /// Sets or clears one track's preset. Same threading as `set_tracks`.
    pub fn set_preset(&self, track: Id, preset: Option<TrackAudioPreset>) {
        let mut cfg = lock(&self.shared.config);
        match preset {
            Some(p) => cfg.presets.insert(track, p),
            None => cfg.presets.remove(&track),
        };
        let set = cfg.rebuild(self.shared.block_frames, false);
        lock(&self.shared.control).buses = set;
    }

    /// The preset a track's FX runs: the explicit one, else its role's voiced preset, else none.
    pub fn effective_preset(&self, track: Id) -> Option<TrackAudioPreset> {
        lock(&self.shared.config).effective_preset(track)
    }

    /// New anchor: restarts production at `frame` (timeline frames at the mixer rate). In reverse, `frame` is the
    /// exclusive upper end of the first block, so frame `frame - 1` plays first. Only bumps the generation; the feeder
    /// applies the flush itself. Returns the new generation.
    pub fn seek(&self, frame: i64, reverse: bool) -> i64 {
        let mut c = lock(&self.shared.control);
        c.position = frame;
        c.reverse = reverse;
        c.generation += 1;
        c.generation
    }

    /// Timeline frame the next produced block is anchored at.
    pub fn position(&self) -> i64 {
        lock(&self.shared.control).position
    }

    /// Samples the output lags behind the timeline position (the committed max FX latency). Changes only at a seek.
    pub fn output_latency_samples(&self) -> usize {
        lock(&self.shared.control).buses.latency
    }

    /// Role bus gains in dB (session level, not persisted; missing role = 0 dB). A role at 0 dB is not touched: its tracks
    /// sum straight into the master. Read per block, so a change applies live (ramped).
    pub fn set_role_bus_gains_db(&self, gains: HashMap<AudioTag, f64>) {
        *lock(&self.shared.role_gains_db) = gains;
    }

    pub fn role_bus_gains_db(&self) -> HashMap<AudioTag, f64> {
        lock(&self.shared.role_gains_db).clone()
    }

    /// Segments whose source failed to open or read (they render as silence; playback continues).
    pub fn failed_reads(&self) -> usize {
        self.shared.failed_reads.load(Ordering::Relaxed)
    }

    /// Automatic de-click fade at every clip boundary, in frames (0 = off).
    pub fn declick_frames(&self) -> i64 {
        self.shared.declick.load(Ordering::Relaxed)
    }

    pub fn set_declick_frames(&self, frames: i64) {
        self.shared.declick.store(frames.max(0), Ordering::Relaxed);
    }

    /// Live music ducking from Preferences (`None` = off). Read per block, so a changed setting applies live.
    pub fn live_ducking(&self) -> Option<LiveDucking> {
        let v = self.shared.duck_centi_db.load(Ordering::Relaxed);
        (v > 0).then(|| LiveDucking::with_timing(v as f64 / 100.0, lock(&self.shared.pref_timing).clone()))
    }

    pub fn set_live_ducking(&self, d: Option<LiveDucking>) {
        *lock(&self.shared.pref_timing) = d.as_ref().map_or_else(DuckTiming::classic, |d| d.timing.clone());
        self.shared.duck_centi_db.store(d.map_or(0, |d| ((d.amount_db * 100.0) as i64).max(0)), Ordering::Relaxed);
    }

    /// The project's own setting, which overrides `live_ducking` (`None` = follow Preferences).
    pub fn set_project_live_ducking(&self, p: Option<ProjectLiveDucking>) {
        *lock(&self.shared.project_timing) =
            p.as_ref().and_then(|p| p.timing.clone()).unwrap_or_else(DuckTiming::classic);
        let v = p.map_or(-1, |p| if p.is_on { ((p.amount_db * 100.0) as i64).max(1) } else { 0 });
        self.shared.project_centi_db.store(v, Ordering::Relaxed);
    }

    /// What the mix applies: the project's setting when it has one, else Preferences.
    pub fn effective_live_ducking(&self) -> Option<LiveDucking> {
        self.shared.effective_live_ducking()
    }

    /// Pauses inside dialogue clips release the live duck (`None` or not known yet = the whole clip ducks).
    pub fn set_dialogue_silences(&self, provider: Option<SharedSilences>) {
        *lock(&self.shared.silences) = provider;
    }

    /// Preferences > Audio De-Click and Live Ducking as playback reads them; a host calls this at start and after
    /// Preferences change.
    pub fn apply_audio_preferences(&self, declick: &dyn BoolDefaults, ducking: &dyn DefaultsStore) {
        self.set_declick_frames(AudioDeClick::current_fade_frames(super::SAMPLE_RATE, declick));
        self.set_live_ducking(LiveDucking::current(ducking));
    }

    /// Drops every cached source and remembered open failure (media relinked or proxies switched). The feeder applies it
    /// at the start of its next block.
    pub fn invalidate_sources(&self) {
        self.shared.prewarm_epoch.fetch_add(1, Ordering::SeqCst);
        self.shared.prewarm_generation.fetch_add(1, Ordering::SeqCst);
        lock(&self.shared.prewarmed).clear();
        lock(&self.shared.prewarm_started).clear();
        lock(&self.shared.control).stale_all = true;
    }

    /// The files behind these media changed (relink): their sources are reopened at the next block and a remembered open
    /// failure is forgotten, so the new file plays without a restart.
    pub fn media_changed(&self, ids: &HashSet<Id>) {
        if !ids.is_empty() {
            self.shared.prewarm_epoch.fetch_add(1, Ordering::SeqCst);
            self.shared.prewarm_generation.fetch_add(1, Ordering::SeqCst);
            lock(&self.shared.prewarmed).clear();
            lock(&self.shared.prewarm_started).clear();
            lock(&self.shared.control).stale_media.extend(ids.iter().copied());
        }
    }
}

/// The media of the audio clips of `timeline` with the time each starts at (a nested sequence's clips count at the nest's
/// start); a clip whose media id is a sequence recurses (at most 4 levels, as the mixer nests).
fn collect_audio_media(
    timeline: &Timeline,
    sequences: &Sequences,
    depth: usize,
    base: sq_core_time::Time,
    out: &mut Vec<(sq_core_time::Time, Id)>,
) {
    for track in timeline.tracks.iter().filter(|t| t.kind == TrackKind::Audio) {
        for clip in track.clips() {
            match sequences.get(&clip.media) {
                Some(inner) if depth < 4 => collect_audio_media(inner, sequences, depth + 1, base + clip.start, out),
                Some(_) => {}
                None => out.push((base + clip.start, clip.media)),
            }
        }
    }
}
