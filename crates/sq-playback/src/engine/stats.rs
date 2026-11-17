// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Windows/SQWinApp WinPlayStats.swift
//! Per-stage playback timings for the play test: each stage as total milliseconds, a count and a max since the last
//! `reset`. Decode work runs on lane threads, so the numbers are summed under a lock. One instance per engine (the Swift
//! singleton becomes an `Arc<PlayStats>` the engine hands to its decode jobs).

use sq_core_time::Time;
use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Instant;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Stage {
    Decode,
    Download,
    Reduce,
    Upload,
    Texture,
    Grade,
    Commit,
    CaptionPass,
    PresentPass,
    VideoLayers,
    Key,
    Title,
    Layers,
    Record,
    Compose,
    /// The render thread waited for the GPU to finish an earlier frame (back-pressure).
    GpuWait,
    /// A frame was dropped because the GPU was still busy with two earlier ones.
    GpuBusy,
    Position,
    Plan,
    Runloop,
    Tick,
    Ui,
    Present,
    Arrive,
    Finish,
    Session,
}

impl Stage {
    pub fn name(self) -> &'static str {
        match self {
            Stage::Decode => "decode",
            Stage::Download => "download",
            Stage::Reduce => "reduce",
            Stage::Upload => "upload",
            Stage::Texture => "texture",
            Stage::Grade => "grade",
            Stage::Commit => "commit",
            Stage::CaptionPass => "captionPass",
            Stage::PresentPass => "presentPass",
            Stage::VideoLayers => "videoLayers",
            Stage::Key => "key",
            Stage::Title => "title",
            Stage::Layers => "layers",
            Stage::Record => "record",
            Stage::Compose => "compose",
            Stage::GpuWait => "gpuWait",
            Stage::GpuBusy => "gpuBusy",
            Stage::Position => "position",
            Stage::Plan => "plan",
            Stage::Runloop => "runloop",
            Stage::Tick => "tick",
            Stage::Ui => "ui",
            Stage::Present => "present",
            Stage::Arrive => "arrive",
            Stage::Finish => "finish",
            Stage::Session => "session",
        }
    }
}

#[derive(Default)]
struct State {
    ms: BTreeMap<Stage, f64>,
    count: BTreeMap<Stage, usize>,
    max: BTreeMap<Stage, f64>,
    layers: usize,
    layer_frames: usize,
    layers_max: usize,
    culled: usize,
    waits: usize,
    /// Largest |master clock - shown position| over the frames composited while playing, in ms (`maxAVDrift`).
    max_av_drift_ms: f64,
    decoders: BTreeMap<String, usize>,
    decode_by: BTreeMap<String, (f64, usize)>,
}

#[derive(Default)]
pub struct PlayStats {
    state: Mutex<State>,
}

impl PlayStats {
    pub fn new() -> PlayStats {
        PlayStats::default()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Clears the numbers (the opened-decoder list stays).
    pub fn reset(&self) {
        let mut s = self.lock();
        let decoders = std::mem::take(&mut s.decoders);
        *s = State { decoders, ..State::default() };
    }

    pub fn add(&self, stage: Stage, ms: f64, count: usize) {
        let mut s = self.lock();
        *s.ms.entry(stage).or_default() += ms;
        *s.count.entry(stage).or_default() += count;
        let per = if count > 0 { ms / count as f64 } else { ms };
        let m = s.max.entry(stage).or_default();
        *m = m.max(per);
    }

    /// Times `body` as one `stage` sample.
    pub fn time<T>(&self, stage: Stage, body: impl FnOnce() -> T) -> T {
        let t0 = Instant::now();
        let r = body();
        self.add(stage, t0.elapsed().as_secs_f64() * 1e3, 1);
        r
    }

    /// One composited frame with `layers` media pictures drawn and `culled` left out (covered).
    pub fn frame(&self, layers: usize, culled: usize) {
        let mut s = self.lock();
        s.layers += layers;
        s.layer_frames += 1;
        s.layers_max = s.layers_max.max(layers);
        s.culled += culled;
    }

    /// A tick while playing whose sequence frame was not ready (a decode still running).
    pub fn waited(&self) {
        self.lock().waits += 1;
    }

    /// A decode (one picture) of the decoder `label`.
    pub fn decoded(&self, label: &str, ms: f64) {
        let mut s = self.lock();
        let e = s.decode_by.entry(label.to_string()).or_default();
        e.0 += ms;
        e.1 += 1;
    }

    pub fn decoder_opened(&self, name: &str) {
        *self.lock().decoders.entry(name.to_string()).or_default() += 1;
    }

    pub fn count(&self, stage: Stage) -> usize {
        self.lock().count.get(&stage).copied().unwrap_or(0)
    }

    /// One composited frame while playing: the master clock (the audio's) against the frame's position.
    pub fn av_drift(&self, clock: Time, position: Time) {
        let gap = clock - position;
        let ms = (gap.value() as f64 / gap.timescale().max(1) as f64 * 1e3).abs();
        let mut s = self.lock();
        s.max_av_drift_ms = s.max_av_drift_ms.max(ms);
    }

    /// The largest A/V drift seen since the last reset, in ms.
    pub fn max_av_drift_ms(&self) -> f64 {
        self.lock().max_av_drift_ms
    }

    pub fn waits(&self) -> usize {
        self.lock().waits
    }

    /// "stage: mean ms (max ms, n)" lines for the play test.
    pub fn report(&self) -> Vec<String> {
        let s = self.lock();
        let mut out: Vec<String> = s
            .count
            .iter()
            .filter(|(_, n)| **n > 0)
            .map(|(st, n)| {
                format!(
                    "{} {:.2} ms mean, {:.2} max, {}",
                    st.name(),
                    s.ms.get(st).copied().unwrap_or(0.0) / *n as f64,
                    s.max.get(st).copied().unwrap_or(0.0),
                    n
                )
            })
            .collect();
        let mean = if s.layer_frames > 0 { s.layers as f64 / s.layer_frames as f64 } else { 0.0 };
        out.push(format!(
            "media layers {mean:.1} per frame (max {}), {} covered left out, {} window frames waited",
            s.layers_max, s.culled, s.waits
        ));
        out.push(format!("max A/V drift {:.1} ms", s.max_av_drift_ms));
        if !s.decoders.is_empty() {
            let list: Vec<String> = s.decoders.iter().map(|(k, v)| format!("{v}x {k}")).collect();
            out.push(format!("decoders {}", list.join(", ")));
        }
        for (k, (ms, n)) in &s.decode_by {
            out.push(format!("decode by {k}: {:.1} ms mean, {n} pictures", ms / *n as f64));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_sum_and_report() {
        let s = PlayStats::new();
        s.add(Stage::Decode, 10.0, 2);
        s.add(Stage::Decode, 2.0, 1);
        s.frame(3, 1);
        s.frame(1, 0);
        s.decoder_opened("1920x1080 h264");
        s.reset();
        assert_eq!(s.count(Stage::Decode), 0);
        s.add(Stage::Compose, 4.0, 1);
        s.time(Stage::Key, || ());
        let r = s.report();
        assert!(r.iter().any(|l| l.starts_with("compose 4.00 ms mean")), "{r:?}");
        assert!(r.iter().any(|l| l == "decoders 1x 1920x1080 h264"), "{r:?}");
        s.av_drift(Time::new(5, 100), Time::new(2, 100));
        s.av_drift(Time::new(1, 100), Time::new(2, 100));
        assert!((s.max_av_drift_ms() - 30.0).abs() < 1e-6, "the larger gap stays, in either direction");
        assert!(s.report().iter().any(|l| l == "max A/V drift 30.0 ms"));
        s.reset();
        assert_eq!(s.max_av_drift_ms(), 0.0);
    }
}
