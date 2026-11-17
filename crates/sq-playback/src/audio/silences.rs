// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: WaveformSilences.swift
//! N8b: dialogue pauses for live ducking, read from the media's decoded waveform (the app's waveform cache pushes them in
//! with `set_waveform`). Same detection as the baked Auto Duck: the level as heard (`ClipLevels`), -35 dB, at least 0.6 s.
//!
//! Playback asks from the mix thread, so the default instance never computes there: a clip it has not analyzed yet is
//! queued on a utility thread and reported as unknown (`None`: the whole clip ducks) until the result is in. Export needs
//! the same answer on every run, so it uses `for_export`, which shares the waveforms and results but computes inline.

use sq_audiofx::silence_detector::SilenceDetector;
use sq_core_audio::live_ducking::DialogueSilenceProvider;
use sq_core_edit::clip_levels::ClipLevels;
use sq_core_model::Clip;
use sq_core_time::{Id, Time, TimeRange};
use sq_media::waveform_data::WaveformData;
use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A result for one clip value: `fingerprint` hashes what the pauses depend on (edits change it), so a cached entry holds
/// no keyframe arrays alive.
struct Entry {
    media: Id,
    fingerprint: u64,
    fader: f64,
    silences: Vec<TimeRange>,
    serial: u64,
}

#[derive(Default)]
struct State {
    waveforms: HashMap<Id, Arc<WaveformData>>,
    results: HashMap<Id, Entry>,
    queued: HashSet<Id>,
    /// Bumped per `set_waveform`, so a background result of a replaced waveform is not stored.
    generation: HashMap<Id, u64>,
    serial: u64,
}

enum Job {
    Compute { clip: Box<Clip>, data: Arc<WaveformData>, fingerprint: u64, fader: f64, generation: u64 },
    Idle(Sender<()>),
}

struct Store {
    state: Arc<Mutex<State>>,
    jobs: Mutex<Sender<Job>>,
}

/// Dialogue pauses of clips from their waveforms; see the module docs.
pub struct WaveformSilences {
    store: Arc<Store>,
    computes_inline: bool,
}

impl Default for WaveformSilences {
    fn default() -> Self {
        Self::new(false)
    }
}

impl WaveformSilences {
    pub const THRESHOLD_DB: f64 = -35.0;
    /// 0.6 s.
    pub const MINIMUM_LENGTH: Time = Time::new(3, 5);
    /// Most results kept; past this the oldest half is dropped (`prune` removes deleted clips on every timeline change).
    pub const MAX_ENTRIES: usize = 512;

    /// `computes_inline`: compute a missing result on the calling thread (export, tests) instead of in the background.
    pub fn new(computes_inline: bool) -> WaveformSilences {
        let state = Arc::new(Mutex::new(State::default()));
        let (tx, rx) = channel();
        let worker = Arc::clone(&state);
        // The thread ends when the last sender (the store) is gone. If it cannot start, results stay unknown.
        let _ =
            std::thread::Builder::new().name("sq-live-duck-silences".into()).spawn(move || run_worker(&worker, &rx));
        WaveformSilences { store: Arc::new(Store { state, jobs: Mutex::new(tx) }), computes_inline }
    }

    /// Same waveforms and results, computing inline: for export, so it never depends on background timing.
    pub fn for_export(&self) -> WaveformSilences {
        WaveformSilences { store: Arc::clone(&self.store), computes_inline: true }
    }

    /// A waveform arrived (or `None`: the media was relinked / forgotten). Results of that media are dropped.
    pub fn set_waveform(&self, data: Option<Arc<WaveformData>>, media: Id) {
        let mut s = lock(&self.store.state);
        match data {
            Some(d) => s.waveforms.insert(media, d),
            None => s.waveforms.remove(&media),
        };
        *s.generation.entry(media).or_insert(0) += 1;
        s.results.retain(|_, e| e.media != media);
    }

    /// Blocks until the queued work is done (tests).
    pub fn wait_until_idle(&self) {
        let (tx, rx) = channel();
        if lock(&self.store.jobs).send(Job::Idle(tx)).is_ok() {
            let _ = rx.recv();
        }
    }

    /// Drops the results of clips not in `ids` (deleted or replaced); call when the timeline changes.
    pub fn prune(&self, keeping: &HashSet<Id>) {
        lock(&self.store.state).results.retain(|id, _| keeping.contains(id));
    }

    /// Number of cached results (tests).
    pub fn cached_count(&self) -> usize {
        lock(&self.store.state).results.len()
    }

    /// Pauses of `clip` in timeline time as heard (time mapping, Audio Gain, volume line, track fader), from `data`. The
    /// baked Auto Duck and Remove Silences use this too.
    pub fn pauses(
        clip: &Clip,
        data: &WaveformData,
        track_volume_db: f64,
        threshold_db: f64,
        minimum_length: Time,
    ) -> Vec<TimeRange> {
        let (levels, window) = ClipLevels::audible(clip, track_volume_db, |r| {
            data.peaks(r, 1).iter().fold(0.0f32, |m, ch| ch.first().map_or(m, |p| m.max(p.min.abs()).max(p.max.abs())))
        });
        SilenceDetector::silences(&levels, window, threshold_db, minimum_length)
            .into_iter()
            .map(|s| TimeRange::new(clip.start + s.start, s.duration))
            .collect()
    }

    fn default_pauses(clip: &Clip, data: &WaveformData, fader: f64) -> Vec<TimeRange> {
        Self::pauses(clip, data, fader, Self::THRESHOLD_DB, Self::MINIMUM_LENGTH)
    }
}

/// Everything the pauses of a clip depend on, hashed (edits change it).
fn fingerprint(c: &Clip) -> u64 {
    let mut h = DefaultHasher::new();
    c.media.hash(&mut h);
    format!(
        "{:?}|{:?}|{:?}|{:?}|{}|{:?}|{:?}",
        c.start,
        c.source,
        c.speed,
        c.speed_keys,
        c.reversed,
        c.audio_gain_db.to_bits(),
        c.animation.volume
    )
    .hash(&mut h);
    h.finish()
}

/// Stores a result only while the waveform is still the one it was computed from (not relinked meanwhile).
fn remember(state: &Mutex<State>, clip: &Clip, fingerprint: u64, fader: f64, generation: u64, r: &[TimeRange]) {
    let mut s = lock(state);
    if s.generation.get(&clip.media).copied().unwrap_or(0) != generation || !s.waveforms.contains_key(&clip.media) {
        return;
    }
    s.serial = s.serial.wrapping_add(1);
    let serial = s.serial;
    s.results.insert(clip.id, Entry { media: clip.media, fingerprint, fader, silences: r.to_vec(), serial });
    if s.results.len() > WaveformSilences::MAX_ENTRIES {
        // Bounded: drop the oldest half.
        let mut serials: Vec<u64> = s.results.values().map(|e| e.serial).collect();
        serials.sort_unstable();
        let cut = serials[s.results.len() / 2];
        s.results.retain(|_, e| e.serial >= cut);
    }
}

fn run_worker(state: &Mutex<State>, rx: &Receiver<Job>) {
    while let Ok(job) = rx.recv() {
        match job {
            Job::Compute { clip, data, fingerprint, fader, generation } => {
                let r = WaveformSilences::default_pauses(&clip, &data, fader);
                lock(state).queued.remove(&clip.id);
                remember(state, &clip, fingerprint, fader, generation, &r);
            }
            Job::Idle(done) => {
                let _ = done.send(());
            }
        }
    }
}

impl DialogueSilenceProvider for WaveformSilences {
    fn silences(&self, clip: &Clip, track_volume_db: f64) -> Option<Vec<TimeRange>> {
        let fp = fingerprint(clip);
        let (data, generation) = {
            let mut s = lock(&self.store.state);
            if let Some(e) = s.results.get(&clip.id)
                && e.fader == track_volume_db
                && e.fingerprint == fp
            {
                return Some(e.silences.clone());
            }
            let data = Arc::clone(s.waveforms.get(&clip.media)?);
            let generation = s.generation.get(&clip.media).copied().unwrap_or(0);
            if !self.computes_inline && !s.queued.insert(clip.id) {
                return None;
            }
            (data, generation)
        };
        if self.computes_inline {
            let r = Self::default_pauses(clip, &data, track_volume_db);
            remember(&self.store.state, clip, fp, track_volume_db, generation, &r);
            return Some(r);
        }
        let job =
            Job::Compute { clip: Box::new(clip.clone()), data, fingerprint: fp, fader: track_volume_db, generation };
        let _ = lock(&self.store.jobs).send(job);
        None
    }
}

/// 20 s of 10 ms buckets at level 0.5, silent from 5 s for 3 s.
#[cfg(test)]
pub(crate) fn test_waveform() -> WaveformData {
    // 20 s of 10 ms buckets at level 0.5, silent from 5 s for 3 s.
    let mut l0 = Vec::new();
    for i in 0..2000 {
        let silent = (500..800).contains(&i);
        l0.extend(if silent { [0.0, 0.0] } else { [-0.5, 0.5] });
    }
    WaveformData { sample_rate: 1000, channel_count: 1, total_frames: 20_000, base_bucket_size: 10, levels: vec![l0] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Timeline, Track, TrackKind};

    fn dialogue_timeline(d: Id) -> Timeline {
        let len = TimeRange::new(Time::ZERO, Time::new(20, 1));
        let c = Clip::new(Id::from_u128(50), "d", d, TrackKind::Audio, len, Time::ZERO);
        let mut tr = Track::new(Id::from_u128(51), TrackKind::Audio);
        tr.set_clips(vec![c]);
        Timeline::new(Id::from_u128(52), "t", SequenceFormat::new(Time::new(1, 30)), vec![tr])
    }

    fn pause() -> Vec<TimeRange> {
        vec![TimeRange::new(Time::new(5, 1), Time::new(3, 1))]
    }

    #[test]
    fn inline_provider_finds_the_pause() {
        let d = Id::from_u128(1);
        let t = dialogue_timeline(d);
        let s = WaveformSilences::new(true);
        assert_eq!(s.silences(&t.tracks[0].clips()[0], 0.0), None, "no waveform yet");
        s.set_waveform(Some(Arc::new(test_waveform())), d);
        assert_eq!(s.silences(&t.tracks[0].clips()[0], 0.0), Some(pause()));
    }

    #[test]
    fn background_provider_never_blocks_and_delivers_later() {
        let d = Id::from_u128(1);
        let t = dialogue_timeline(d);
        let s = WaveformSilences::new(false);
        s.set_waveform(Some(Arc::new(test_waveform())), d);
        assert_eq!(s.silences(&t.tracks[0].clips()[0], 0.0), None, "first ask: queued, whole clip ducks");
        s.wait_until_idle();
        assert_eq!(s.silences(&t.tracks[0].clips()[0], 0.0), Some(pause()));
    }

    #[test]
    fn an_edited_clip_is_recomputed() {
        let d = Id::from_u128(1);
        let mut t = dialogue_timeline(d);
        let s = WaveformSilences::new(true);
        s.set_waveform(Some(Arc::new(test_waveform())), d);
        let mut c = t.tracks[0].clips()[0].clone();
        s.silences(&c, 0.0);
        c.start = Time::new(1, 1);
        t.tracks[0].set_clips(vec![c]);
        assert_eq!(
            s.silences(&t.tracks[0].clips()[0], 0.0),
            Some(vec![TimeRange::new(Time::new(6, 1), Time::new(3, 1))])
        );
    }

    #[test]
    fn forgetting_the_waveform_falls_back_to_the_whole_clip() {
        let d = Id::from_u128(1);
        let t = dialogue_timeline(d);
        let s = WaveformSilences::new(true);
        s.set_waveform(Some(Arc::new(test_waveform())), d);
        s.silences(&t.tracks[0].clips()[0], 0.0);
        s.set_waveform(None, d);
        assert_eq!(s.silences(&t.tracks[0].clips()[0], 0.0), None);
    }

    #[test]
    fn export_view_shares_the_waveforms() {
        let d = Id::from_u128(1);
        let t = dialogue_timeline(d);
        let s = WaveformSilences::new(false);
        s.set_waveform(Some(Arc::new(test_waveform())), d);
        assert_eq!(s.for_export().silences(&t.tracks[0].clips()[0], 0.0), Some(pause()));
    }
}
