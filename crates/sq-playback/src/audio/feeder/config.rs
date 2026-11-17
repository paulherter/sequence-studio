// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder.swift (TrackBus, BusSet, FXConfig)
//! Per-track buses: optional FX, delay compensation to the maximum FX latency, kept across rebuilds so unchanged tracks
//! keep their state.

use crate::audio::track_mix::effective_preset;
use sq_audiofx::gain::VolumeAutomation;
use sq_audiofx::presets::TrackAudioPreset;
use sq_audiofx::realtime_audio_fx::{RealtimeAudioFX, RealtimeControls};
use sq_core_model::AudioTag;
use sq_core_time::Id;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

pub(super) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The realtime FX of one track; `controls` re-parameterises it from any thread, the feeder thread runs `fx`.
pub(super) struct FxCell {
    fx: Mutex<RealtimeAudioFX>,
    controls: Arc<RealtimeControls>,
    pub(super) latency: usize,
}

struct BusState {
    dl: Vec<f32>,
    dr: Vec<f32>,
    dpos: usize,
    applied_reverse: Option<bool>,
}

/// One audio track: optional FX and compensation delay. Touched by the feeder thread only (the mix buffer lives in the
/// feeder).
pub(super) struct TrackBus {
    fx: Option<Arc<FxCell>>,
    pub(super) extra_delay: usize,
    state: Mutex<BusState>,
}

impl TrackBus {
    fn new(fx: Option<Arc<FxCell>>, extra_delay: usize) -> TrackBus {
        let n = extra_delay.max(1);
        TrackBus {
            fx,
            extra_delay,
            state: Mutex::new(BusState { dl: vec![0.0; n], dr: vec![0.0; n], dpos: 0, applied_reverse: None }),
        }
    }

    pub(super) fn reset(&self) {
        if let Some(fx) = &self.fx {
            fx.controls.reset();
        }
        let mut s = lock(&self.state);
        s.dl.fill(0.0);
        s.dr.fill(0.0);
        s.dpos = 0;
    }

    /// In place, in play order.
    pub(super) fn process(&self, l: &mut [f32], r: &mut [f32], reverse: bool, start_sample: i64) {
        let count = l.len().min(r.len());
        let mut s = lock(&self.state);
        if let Some(fx) = &self.fx {
            if s.applied_reverse != Some(reverse) {
                fx.controls.set_bypass(reverse);
                s.applied_reverse = Some(reverse);
            }
            lock(&fx.fx).process(&mut [&mut l[..count], &mut r[..count]], count, start_sample);
        }
        let d = self.extra_delay;
        if d == 0 {
            return;
        }
        for i in 0..count {
            let p = s.dpos;
            let (a, b) = (s.dl[p], s.dr[p]);
            s.dl[p] = l[i];
            s.dr[p] = r[i];
            l[i] = a;
            r[i] = b;
            s.dpos += 1;
            if s.dpos == d {
                s.dpos = 0;
            }
        }
    }
}

/// The buses of the audio tracks, in track order, with the committed latency.
#[derive(Clone, Default)]
pub(super) struct BusSet {
    pub(super) list: Vec<Arc<TrackBus>>,
    pub(super) index: HashMap<Id, usize>,
    pub(super) latency: usize,
}

struct FxEntry {
    cell: Arc<FxCell>,
    denoiser: bool,
}

/// Caller-side bookkeeping (under the `config` lock): presets, and the FX/bus objects kept across rebuilds.
#[derive(Default)]
pub(super) struct FxConfig {
    pub(super) presets: HashMap<Id, TrackAudioPreset>,
    /// Track roles of the current timeline: a track without an explicit preset gets its role's voiced preset.
    pub(super) roles: HashMap<Id, AudioTag>,
    pub(super) track_ids: Vec<Id>,
    fxs: HashMap<Id, FxEntry>,
    buses: HashMap<Id, Arc<TrackBus>>,
    /// Latency the running feeder compensates to. Changes only with `commit` (at a seek), never mid-play.
    committed_latency: usize,
}

impl FxConfig {
    pub(super) fn effective_preset(&self, id: Id) -> Option<TrackAudioPreset> {
        effective_preset(&self.presets, &self.roles, id)
    }

    pub(super) fn rebuild(&mut self, block_frames: usize, commit: bool) -> BusSet {
        let mut new_fx: HashMap<Id, FxEntry> = HashMap::new();
        for &id in &self.track_ids {
            let Some(preset) = self.effective_preset(id) else { continue };
            let old = self.fxs.remove(&id);
            let dn = preset.noise_reduction > 0.0 || old.as_ref().is_some_and(|o| o.denoiser);
            if let Some(old) = old
                && old.denoiser == dn
            {
                old.cell.controls.set_preset(&preset);
                new_fx.insert(id, old);
                continue;
            }
            // Unity volume: clip/track volume is applied by the feeder, never twice.
            if let Ok(mut fx) = RealtimeAudioFX::new(&preset, VolumeAutomation::default(), 2, block_frames, dn) {
                fx.set_meter_track(id);
                let controls = fx.controls();
                let latency = fx.latency_samples;
                new_fx.insert(
                    id,
                    FxEntry { cell: Arc::new(FxCell { fx: Mutex::new(fx), controls, latency }), denoiser: dn },
                );
            }
        }
        self.fxs = new_fx;
        if commit {
            self.committed_latency =
                self.track_ids.iter().map(|id| self.fxs.get(id).map_or(0, |e| e.cell.latency)).max().unwrap_or(0);
        }
        let m = self.committed_latency;
        let mut set = BusSet { latency: m, ..BusSet::default() };
        let mut new_buses = HashMap::new();
        for &id in &self.track_ids {
            // An FX whose latency exceeds the committed one waits (track plays dry) until the next seek commits it.
            let e = self.fxs.get(&id).filter(|e| e.cell.latency <= m);
            let extra = m - e.map_or(0, |e| e.cell.latency);
            let cell = e.map(|e| Arc::clone(&e.cell));
            let bus = match self.buses.get(&id) {
                Some(old) if old.extra_delay == extra && same_fx(&old.fx, &cell) => Arc::clone(old),
                _ => Arc::new(TrackBus::new(cell, extra)),
            };
            new_buses.insert(id, Arc::clone(&bus));
            set.index.insert(id, set.list.len());
            set.list.push(bus);
        }
        self.buses = new_buses;
        set
    }
}

fn same_fx(a: &Option<Arc<FxCell>>, b: &Option<Arc<FxCell>>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => Arc::ptr_eq(x, y),
        _ => false,
    }
}
