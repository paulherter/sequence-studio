// Swift: PlaybackEngine+ProgramEngine.swift
//! The real Program engine behind the session's [`ProgramEngine`] trait: an adapter over `sq_playback`'s
//! [`ProgramHandle`] (the render thread's mailbox). Audio meters and ducking live next to the audio output, so they come
//! in through [`EngineAudio`].

use std::any::Any;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use sq_core_audio::live_ducking::DialogueSilenceProvider;
use sq_core_color::ColorBypass;
use sq_core_edit::playback::PlaybackRate;
use sq_core_model::{ProjectLiveDucking, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::video_decoding::DecodeScale;
use sq_playback::audio::{AudioMeterSnapshot, LoudnessLevels};
use sq_playback::engine::LookPreview;
use sq_playback::engine::ProgramHandle;
use sq_playback::engine::power_policy::PowerPolicy;

use crate::{MeterReading, PreviewSurface, ProgramEngine, ProxyUse};

/// The audio side of the Program engine (Swift `PlaybackEngine.audio`): meters and the ducking inputs. Implemented next
/// to the audio output; `Send + Sync` because the output threads own the state.
pub trait EngineAudio: Send + Sync {
    /// The latest meter reading with its loudness.
    fn meter_snapshot(&self) -> AudioMeterSnapshot;
    fn reset_loudness_meter(&self);
    fn set_project_live_ducking(&self, setting: Option<ProjectLiveDucking>);
    fn set_dialogue_silences(&self, provider: Option<Arc<dyn DialogueSilenceProvider + Send + Sync>>);
}

/// [`ProgramEngine`] over a running `sq_playback` render thread.
pub struct HandleProgramEngine {
    handle: ProgramHandle,
    audio: Option<Arc<dyn EngineAudio>>,
    quality: DecodeScale,
    last_position: Time,
    shows_captions: bool,
    transparency_grid: bool,
    proxy_use: ProxyUse,
    play_range: Option<TimeRange>,
    loops: bool,
    power_policy: PowerPolicy,
}

impl HandleProgramEngine {
    /// Wraps a started engine; `audio` is `None` for a headless engine (no meters).
    pub fn new(handle: ProgramHandle, audio: Option<Arc<dyn EngineAudio>>) -> HandleProgramEngine {
        HandleProgramEngine {
            handle,
            audio,
            quality: DecodeScale::Full,
            last_position: Time::ZERO,
            shows_captions: true,
            transparency_grid: false,
            proxy_use: ProxyUse::DEFAULT,
            play_range: None,
            loops: false,
            power_policy: PowerPolicy::NORMAL,
        }
    }

    /// The render thread's handle (the monitor draws `latest_shown` from it).
    pub fn handle(&self) -> &ProgramHandle {
        &self.handle
    }
}

impl ProgramEngine for HandleProgramEngine {
    fn set_timeline(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) {
        let all: HashMap<Id, Timeline> = sequences.iter().map(|(k, v)| (*k, v.clone())).collect();
        self.handle.set_timeline(timeline.clone(), all);
    }
    // shortcut: the monitor's window surface is owned by the GPU host, which draws `latest_shown`; nothing to attach.
    fn attach(&mut self, _surface: Option<PreviewSurface>) {}
    fn position(&self) -> Time {
        self.handle.status().position
    }
    fn rate(&self) -> PlaybackRate {
        self.handle.status().rate.unwrap_or(PlaybackRate::ZERO)
    }
    fn failure(&self) -> Option<String> {
        self.handle.status().compositor_failure
    }
    fn play(&mut self, rate: PlaybackRate) {
        self.handle.play(rate);
    }
    fn pause(&mut self) {
        self.handle.pause();
    }
    fn seek(&mut self, t: Time) {
        self.handle.seek(t);
    }
    fn step(&mut self, frames: i64) {
        self.handle.step(i32::try_from(frames).unwrap_or(if frames < 0 { i32::MIN } else { i32::MAX }));
    }
    fn begin_scrub(&mut self) {
        self.handle.begin_scrub();
    }
    fn scrub(&mut self, t: Time) {
        self.handle.scrub(t);
    }
    fn end_scrub(&mut self) {
        self.handle.end_scrub();
    }
    fn quality(&self) -> DecodeScale {
        self.quality
    }
    fn set_quality(&mut self, quality: DecodeScale) {
        self.quality = quality;
        self.handle.set_quality(self.power_policy.viewer_scale(quality));
    }
    fn take_position_change(&mut self) -> Option<Time> {
        let now = self.handle.status().position;
        if now == self.last_position {
            return None;
        }
        self.last_position = now;
        Some(now)
    }
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn shows_transparency_grid(&self) -> bool {
        self.transparency_grid
    }
    fn set_shows_transparency_grid(&mut self, on: bool) {
        self.transparency_grid = on;
        self.handle.set_transparency_grid(on);
    }
    fn shows_captions(&self) -> bool {
        self.shows_captions
    }
    fn set_shows_captions(&mut self, on: bool) {
        self.shows_captions = on;
        self.handle.set_shows_captions(on);
    }
    fn cache_generation(&self) -> i64 {
        i64::try_from(self.handle.status().cache_generation).unwrap_or(i64::MAX)
    }
    fn media_changed(&mut self, ids: &BTreeSet<Id>) {
        self.handle.media_changed(ids.iter().copied().collect::<HashSet<Id>>());
    }
    fn proxy_use(&self) -> ProxyUse {
        self.proxy_use
    }
    // Swift: PlaybackEngine.swift:156 (the render thread reads a ready proxy while scrubbing or playing, never paused)
    fn set_proxy_use(&mut self, proxy_use: ProxyUse) {
        self.proxy_use = proxy_use;
        self.handle.set_proxy_use(sq_playback::engine::proxy_picture::ProxyUse {
            scrubbing: proxy_use.scrubbing,
            playback: proxy_use.playback,
        });
    }
    fn proxies_changed(&mut self, ids: &BTreeSet<Id>) {
        self.handle.proxies_changed(ids.iter().copied().collect::<HashSet<Id>>());
    }
    fn play_range(&self) -> Option<TimeRange> {
        self.play_range
    }
    fn set_play_range(&mut self, range: Option<TimeRange>) {
        self.play_range = range;
        self.handle.set_play_range(range);
    }
    fn loops(&self) -> bool {
        self.loops
    }
    fn set_loops(&mut self, on: bool) {
        self.loops = on;
        self.handle.set_loops(on);
    }
    fn power_policy(&self) -> PowerPolicy {
        self.power_policy
    }
    // Swift: PlaybackEngine.swift:35 (the decode size is the user's quality under the policy's cap; the prefetch halves)
    fn set_power_policy(&mut self, policy: PowerPolicy) {
        if policy == self.power_policy {
            return;
        }
        self.power_policy = policy;
        self.handle.set_quality(policy.viewer_scale(self.quality));
        self.handle.set_prefetch_halved(policy.halves_prefetch);
    }
    fn set_color_bypass(&mut self, bypass: Option<ColorBypass>) {
        self.handle.set_color_bypass(bypass.filter(|b| !b.is_empty()));
    }
    fn set_look_preview(&mut self, preview: Option<LookPreview>) {
        self.handle.set_look_preview(preview);
    }

    // Swift: PlaybackEngine+ProgramEngine.swift:7
    fn cached_spans(&self) -> Vec<TimeRange> {
        self.handle.cached_spans()
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:8
    fn dropped_frames(&self) -> i64 {
        i64::try_from(self.handle.status().skipped_frames).unwrap_or(i64::MAX)
    }
    fn play_counts(&self) -> crate::PlayCounts {
        let s = self.handle.status();
        crate::PlayCounts { shown: s.shown_frames, skipped: s.skipped_frames, late: s.late_frames, run: s.run, clock_running: s.clock_running }
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:9
    // shortcut: `PlayStats` keeps no scrub-latency summary yet, upgrade when it does.
    fn scrub_latency_text(&self) -> Option<String> {
        None
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:13
    fn meter_reading(&self) -> Option<MeterReading> {
        let s = self.audio.as_ref()?.meter_snapshot();
        Some(MeterReading {
            sequence: i64::try_from(s.sequence).unwrap_or(i64::MAX),
            peaks: vec![s.left.peak, s.right.peak],
        })
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:17
    fn loudness_levels(&self) -> Option<LoudnessLevels> {
        Some(self.audio.as_ref()?.meter_snapshot().loudness)
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:18
    fn reset_loudness_meter(&mut self) {
        if let Some(a) = &self.audio {
            a.reset_loudness_meter();
        }
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:19
    fn set_project_live_ducking(&mut self, setting: Option<ProjectLiveDucking>) {
        if let Some(a) = &self.audio {
            a.set_project_live_ducking(setting);
        }
    }
    // Swift: PlaybackEngine+ProgramEngine.swift:20
    fn set_dialogue_silences(&mut self, provider: Option<Arc<dyn DialogueSilenceProvider + Send + Sync>>) {
        if let Some(a) = &self.audio {
            a.set_dialogue_silences(provider);
        }
    }
}
