// Swift: ProgramEngine.swift, SessionServices.swift, AnalysisFlows.swift (AnalysisBackend),
// AnalysisFlows+ColorMatch.swift (ProgramFrameSampling)
//! The services the session talks to, as small traits (Swift seam 5). The real implementations live outside this
//! module: the Program engine adapter over `sq_playback::ProgramHandle` and the resolver over `sq_media::MediaOpener`
//! (ES8), the proxy service (ES8), the platform analysis backend (ES6). Swift `@MainActor` protocols are plain traits
//! with `&mut self`; protocols whose objects cross threads (`Sendable`) take `&self` and are `Send + Sync`.

use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use sq_analysis::reframe::SubjectDetecting;
use sq_analysis::stabilization_analyzing::StabilizationAnalyzing;
use sq_core_audio::live_ducking::DialogueSilenceProvider;
use sq_core_color::ColorBypass;
use sq_core_edit::playback::PlaybackRate;
use sq_core_model::{ColorSpaceID, MediaInfo, MediaRef, ProjectLiveDucking, RenderCacheSpan, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::video_decoding::DecodeScale;
use sq_playback::audio::LoudnessLevels;
use sq_playback::engine::LookPreview;
use sq_playback::engine::power_policy::PowerPolicy;

/// The drawing surface a Program engine renders into (Swift `PreviewSurface`, `AnyObject` off the Mac): the binary
/// hands in its window surface; the session only passes it through.
// Swift: ProgramEngine.swift:13
pub type PreviewSurface = Box<dyn Any>;

/// When the monitor decodes a media's proxy instead of the original (Swift `SQPlayback.ProxyUse`). Paused frames are
/// always the original's exact frame; export never sees proxies.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ProxyUse {
    /// While a scrub gesture runs (`begin_scrub`...`end_scrub`).
    pub scrubbing: bool,
    /// While playing (weak machines, or the `sq.proxy.playback` setting).
    pub playback: bool,
}

impl ProxyUse {
    pub const OFF: ProxyUse = ProxyUse { scrubbing: false, playback: false };
    /// Engine default: proxies for scrubbing once the resolver has one.
    pub const DEFAULT: ProxyUse = ProxyUse { scrubbing: true, playback: false };
}

/// The latest meter reading of an engine: the sequence it belongs to and the peaks per channel.
#[derive(Clone, Debug, PartialEq)]
pub struct MeterReading {
    pub sequence: i64,
    pub peaks: Vec<f32>,
}

/// The Program monitor's playback engine as the session drives it (Swift `ProgramEngine`). Optional members have the
/// defaults of the Swift protocol extension. Mac-only members (`viewerZoom`, textures, frame capture, Look preview)
/// are not part of the portable trait. Swift's `onPositionChange` hook is [`ProgramEngine::take_position_change`]:
/// the app reads it once per frame (and the session after its own calls) and hands it to the session.
// Swift: ProgramEngine.swift:23
pub trait ProgramEngine {
    fn set_timeline(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>);
    fn attach(&mut self, surface: Option<PreviewSurface>);
    fn position(&self) -> Time;
    fn rate(&self) -> PlaybackRate;
    /// Why no picture can be drawn (the compositor could not be created), or `None`. The monitor shows it as a card.
    fn failure(&self) -> Option<String> {
        None
    }
    fn play(&mut self, rate: PlaybackRate);
    fn pause(&mut self);
    fn seek(&mut self, t: Time);
    fn step(&mut self, frames: i64);
    fn begin_scrub(&mut self);
    fn scrub(&mut self, t: Time);
    fn end_scrub(&mut self);
    fn quality(&self) -> DecodeScale;
    fn set_quality(&mut self, quality: DecodeScale);
    /// The position the engine moved to since the last call (Swift `onPositionChange`), if any.
    fn take_position_change(&mut self) -> Option<Time>;
    /// For downcasts in tests and adapters (`StubProgramEngine`).
    fn as_any(&self) -> &dyn Any;

    /// Whether the engine still runs; an auxiliary engine whose monitor closed answers false (Swift `weak` nil).
    fn is_alive(&self) -> bool {
        true
    }
    fn play_range(&self) -> Option<TimeRange> {
        None
    }
    fn set_play_range(&mut self, _range: Option<TimeRange>) {}
    fn loops(&self) -> bool {
        false
    }
    fn set_loops(&mut self, _loops: bool) {}
    fn redraw(&mut self) {}
    fn meter_reading(&self) -> Option<MeterReading> {
        None
    }
    fn loudness_levels(&self) -> Option<LoudnessLevels> {
        None
    }
    fn reset_loudness_meter(&mut self) {}
    /// The listening level and Dim for the speakers (never the meter). Swift: `MonitorGainStage`.
    fn set_monitor_gain(&mut self, _setting: sq_audiofx::monitor_gain::MonitorSetting) {}
    /// Solo / Mute of the output channels (speakers only). Swift: `ChannelMonitorStage`.
    fn set_channel_monitor(&mut self, _monitor: sq_audiofx::channel_monitor::ChannelMonitor) {}
    /// The Solo / Mute last handed to the engine (`None` before any; for tests and the meter).
    fn channel_monitor(&self) -> Option<sq_audiofx::channel_monitor::ChannelMonitor> {
        None
    }
    fn audio_scrubbing(&self) -> bool {
        false
    }
    fn set_audio_scrubbing(&mut self, _on: bool) {}
    fn cached_spans(&self) -> Vec<TimeRange> {
        Vec::new()
    }
    fn cache_generation(&self) -> i64 {
        0
    }
    fn scrub_latency_text(&self) -> Option<String> {
        None
    }
    fn dropped_frames(&self) -> i64 {
        0
    }
    /// Frame positions shown, skipped and late since the last play (the Auto quality governor reads them).
    fn play_counts(&self) -> crate::PlayCounts {
        crate::PlayCounts::default()
    }
    fn shows_transparency_grid(&self) -> bool {
        false
    }
    fn set_shows_transparency_grid(&mut self, _on: bool) {}
    fn shows_captions(&self) -> bool {
        true
    }
    fn set_shows_captions(&mut self, _on: bool) {}
    fn media_changed(&mut self, _ids: &BTreeSet<Id>) {}
    /// Preferences > Playback > Frame Cache: the bytes the Program monitor's frame cache may hold.
    fn set_frame_cache_bytes(&mut self, _bytes: usize) {}
    fn proxy_use(&self) -> ProxyUse {
        ProxyUse::OFF
    }
    fn set_proxy_use(&mut self, _use: ProxyUse) {}
    fn proxies_changed(&mut self, _ids: &BTreeSet<Id>) {}
    fn set_project_live_ducking(&mut self, _setting: Option<ProjectLiveDucking>) {}
    fn set_dialogue_silences(&mut self, _provider: Option<Arc<dyn DialogueSilenceProvider + Send + Sync>>) {}
    fn power_policy(&self) -> PowerPolicy {
        PowerPolicy::NORMAL
    }
    fn set_power_policy(&mut self, _policy: PowerPolicy) {}
    fn set_color_bypass(&mut self, _bypass: Option<ColorBypass>) {}
    /// Draws the monitor's text as the Look hover `preview` says until it is `None` (display only; Swift `setLookPreview`).
    fn set_look_preview(&mut self, _preview: Option<LookPreview>) {}
}

/// A call the stub engine recorded (Swift `StubProgramEngine.Call`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineCall {
    SetTimeline,
    Attach(bool),
    Play(PlaybackRate),
    Pause,
    Seek(Time),
    Step(i64),
    BeginScrub,
    Scrub(Time),
    EndScrub,
}

/// Engine without picture or sound for tests and headless runs: records every call and moves its position like a
/// real engine would (Swift `StubProgramEngine`).
// Swift: ProgramEngine.swift:139
pub struct StubProgramEngine {
    pub timeline: Option<Timeline>,
    pub timelines: Vec<Timeline>,
    pub sequences: BTreeMap<Id, Timeline>,
    pub calls: Vec<EngineCall>,
    pub changed_media: Vec<BTreeSet<Id>>,
    /// The last frame cache size handed to the engine.
    pub frame_cache_bytes: Option<usize>,
    pub redraw_count: i64,
    /// How often the loudness meter was reset.
    pub loudness_resets: i64,
    /// The last listening setting and channel Solo / Mute handed to the engine.
    pub monitor_gain: Option<sq_audiofx::monitor_gain::MonitorSetting>,
    pub channel_monitor: Option<sq_audiofx::channel_monitor::ChannelMonitor>,
    pub proxy_use: Option<ProxyUse>,
    /// View > Audio Scrubbing and Show Captions in Program Monitor, as a real engine keeps them.
    pub audio_scrubbing: bool,
    pub shows_captions: bool,
    pub proxy_changes: Vec<BTreeSet<Id>>,
    pub project_duckings: Vec<Option<ProjectLiveDucking>>,
    pub color_bypass: Option<ColorBypass>,
    pub look_preview: Option<LookPreview>,
    pub position: Time,
    pub rate: PlaybackRate,
    pub quality: Option<DecodeScale>,
    pub power_policy: PowerPolicy,
    /// What the session handed over (Swift `playRange`, `loops`).
    pub play_range: Option<TimeRange>,
    pub loops: bool,
    /// Test hook: how far ahead of `position` a pause parks while playing.
    // Swift: ProgramEngine.swift:209
    pub pause_parks_ahead: Option<Time>,
    moved_to: Option<Time>,
}

impl StubProgramEngine {
    pub fn new() -> StubProgramEngine {
        StubProgramEngine {
            timeline: None,
            timelines: Vec::new(),
            sequences: BTreeMap::new(),
            calls: Vec::new(),
            changed_media: Vec::new(),
            frame_cache_bytes: None,
            redraw_count: 0,
            loudness_resets: 0,
            monitor_gain: None,
            channel_monitor: None,
            proxy_use: None,
            audio_scrubbing: false,
            shows_captions: true,
            proxy_changes: Vec::new(),
            project_duckings: Vec::new(),
            color_bypass: None,
            look_preview: None,
            position: Time::ZERO,
            rate: PlaybackRate::ZERO,
            quality: None,
            power_policy: PowerPolicy::NORMAL,
            play_range: None,
            loops: false,
            pause_parks_ahead: None,
            moved_to: None,
        }
    }

    fn frame_duration(&self) -> Time {
        self.timeline.as_ref().map_or(Time::new(1, 30), Timeline::frame_duration)
    }

    /// Test hook: pretends playback advanced by `dt`.
    // Swift: ProgramEngine.swift:231
    pub fn simulate_playback(&mut self, dt: Time) {
        self.move_to(self.position + dt);
    }

    fn move_to(&mut self, t: Time) {
        let snapped = t.max(Time::ZERO).snapped(self.frame_duration());
        self.position = snapped;
        self.moved_to = Some(snapped);
    }
}

impl Default for StubProgramEngine {
    fn default() -> StubProgramEngine {
        StubProgramEngine::new()
    }
}

impl ProgramEngine for StubProgramEngine {
    fn audio_scrubbing(&self) -> bool {
        self.audio_scrubbing
    }
    fn set_audio_scrubbing(&mut self, on: bool) {
        self.audio_scrubbing = on;
    }
    fn shows_captions(&self) -> bool {
        self.shows_captions
    }
    fn set_shows_captions(&mut self, on: bool) {
        self.shows_captions = on;
    }
    fn set_timeline(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) {
        self.timeline = Some(timeline.clone());
        self.sequences = sequences.clone();
        self.timelines.push(timeline.clone());
        self.calls.push(EngineCall::SetTimeline);
    }
    fn attach(&mut self, surface: Option<PreviewSurface>) {
        self.calls.push(EngineCall::Attach(surface.is_some()));
    }
    fn position(&self) -> Time {
        self.position
    }
    fn rate(&self) -> PlaybackRate {
        self.rate
    }
    fn play(&mut self, rate: PlaybackRate) {
        self.rate = rate;
        self.calls.push(EngineCall::Play(rate));
    }
    fn pause(&mut self) {
        let was_playing = !self.rate.is_paused();
        self.rate = PlaybackRate::ZERO;
        self.calls.push(EngineCall::Pause);
        if was_playing && let Some(ahead) = self.pause_parks_ahead {
            self.move_to(self.position + ahead);
        }
    }
    fn seek(&mut self, t: Time) {
        self.calls.push(EngineCall::Seek(t));
        self.move_to(t);
    }
    fn step(&mut self, frames: i64) {
        self.calls.push(EngineCall::Step(frames));
        self.move_to(self.position + self.frame_duration() * frames);
    }
    fn begin_scrub(&mut self) {
        self.calls.push(EngineCall::BeginScrub);
    }
    fn scrub(&mut self, t: Time) {
        self.calls.push(EngineCall::Scrub(t));
        self.move_to(t);
    }
    fn end_scrub(&mut self) {
        self.calls.push(EngineCall::EndScrub);
    }
    fn quality(&self) -> DecodeScale {
        self.quality.unwrap_or(DecodeScale::Full)
    }
    fn set_quality(&mut self, quality: DecodeScale) {
        self.quality = Some(quality);
    }
    fn power_policy(&self) -> PowerPolicy {
        self.power_policy
    }
    fn set_power_policy(&mut self, policy: PowerPolicy) {
        self.power_policy = policy;
    }
    fn play_range(&self) -> Option<TimeRange> {
        self.play_range
    }
    fn set_play_range(&mut self, range: Option<TimeRange>) {
        self.play_range = range;
    }
    fn loops(&self) -> bool {
        self.loops
    }
    fn set_loops(&mut self, loops: bool) {
        self.loops = loops;
    }
    fn take_position_change(&mut self) -> Option<Time> {
        self.moved_to.take()
    }
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn redraw(&mut self) {
        self.redraw_count += 1;
    }
    fn reset_loudness_meter(&mut self) {
        self.loudness_resets += 1;
    }
    fn set_monitor_gain(&mut self, setting: sq_audiofx::monitor_gain::MonitorSetting) {
        self.monitor_gain = Some(setting);
    }
    fn set_channel_monitor(&mut self, monitor: sq_audiofx::channel_monitor::ChannelMonitor) {
        self.channel_monitor = Some(monitor);
    }
    fn channel_monitor(&self) -> Option<sq_audiofx::channel_monitor::ChannelMonitor> {
        self.channel_monitor
    }
    fn media_changed(&mut self, ids: &BTreeSet<Id>) {
        self.changed_media.push(ids.clone());
    }
    fn set_frame_cache_bytes(&mut self, bytes: usize) {
        self.frame_cache_bytes = Some(bytes);
    }
    fn proxy_use(&self) -> ProxyUse {
        self.proxy_use.unwrap_or(ProxyUse::DEFAULT)
    }
    fn set_proxy_use(&mut self, proxy_use: ProxyUse) {
        self.proxy_use = Some(proxy_use);
    }
    fn proxies_changed(&mut self, ids: &BTreeSet<Id>) {
        self.proxy_changes.push(ids.clone());
    }
    fn set_project_live_ducking(&mut self, setting: Option<ProjectLiveDucking>) {
        self.project_duckings.push(setting);
    }
    fn set_color_bypass(&mut self, bypass: Option<ColorBypass>) {
        self.color_bypass = bypass.filter(|b| !b.is_empty());
    }
    fn set_look_preview(&mut self, preview: Option<LookPreview>) {
        self.look_preview = preview;
    }
}

/// The session's media resolver (Swift `SessionMediaResolving`): media infos and readiness for the open project.
/// Shared with the engine threads, so `&self` and `Send + Sync`; the demux side (Swift `MediaResolver`) lives in
/// `sq_media::MediaOpener`. Swift's async `prepare` runs on the worker pool: it blocks and returns the prepared ids.
// Swift: SessionServices.swift:10
pub trait SessionMediaResolving: Send + Sync {
    fn set_project_folder(&self, folder: Option<PathBuf>);
    fn info(&self, id: Id) -> Option<MediaInfo>;
    fn update(&self, media: &[MediaRef], sample_rate: Option<i64>);
    fn invalidate(&self, ids: &BTreeSet<Id>);
    /// Prepares the media (probe, index); blocking, called from a worker. Returns the ids that became ready.
    fn prepare(&self, ids: &[Id]) -> BTreeSet<Id>;
    /// The file of a media (Swift `fileURL(for:)`).
    fn file_path(&self, id: Id) -> Option<PathBuf>;
}

/// The preview render cache as the session feeds it (Swift `SessionRenderCaching`). Swift's `onSpansChanged` and
/// `seedFrames` hooks become inbox messages of the render cache service (ES8).
// Swift: SessionServices.swift:21
pub trait SessionRenderCaching {
    fn spans(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) -> Vec<RenderCacheSpan>;
    fn media_changed(&mut self);
    /// Thermal pressure, Low Power Mode or memory pressure: no new render job starts (`PowerPolicy::pauses_background_jobs`).
    fn set_held(&mut self, _held: bool) {}
}

/// Background proxies for the monitors (Swift `SessionProxyServing`).
// Swift: SessionServices.swift:30
pub trait SessionProxyServing {
    fn project_id(&self) -> Option<Id>;
    fn sync(&mut self, media: &[MediaRef], project_id: Option<Id>, active_timeline: Option<&Timeline>);
    /// What the monitors must be told since the last call (Swift held weak references to the engines and told them
    /// itself): the session applies it to the Program engine and every alive auxiliary engine.
    fn take_effects(&mut self) -> Vec<crate::ProxyEffect>;
    /// `PowerPolicy::pauses_background_jobs`: no new proxy transcode starts while held. The default does nothing.
    fn set_held(&mut self, _held: bool) {}
    /// Takes what the workers finished and hands them new work (the app calls it every frame). The default does nothing.
    fn pump(&mut self) {}
    /// The unfinished transcodes, for the export queue's background list. The default has none.
    fn background_jobs(&self) -> Vec<BackgroundProxyJob> {
        Vec::new()
    }
    /// Cancel of a background job's row (`BackgroundProxyJob::id`).
    fn cancel_job(&mut self, _id: &str) {}
    /// Preferences > Media > Delete Cache: removes every proxy no monitor uses; the bytes freed. The default frees none.
    fn clear_cache(&mut self) -> i64 {
        0
    }
}

/// One running or waiting proxy transcode as the queue popover lists it (Swift `BackgroundJob`).
#[derive(Clone, Debug, PartialEq)]
pub struct BackgroundProxyJob {
    pub id: String,
    pub title: String,
    pub progress: Option<f64>,
}

/// Resolver that knows only the media refs (Swift `RefOnlyMediaResolver`, the portable default): infos and paths
/// come from the project, nothing is prepared.
// Swift: SessionServices.swift:49
#[derive(Default)]
pub struct RefOnlyMediaResolver {
    state: Mutex<RefOnlyState>,
}

#[derive(Default)]
struct RefOnlyState {
    refs: BTreeMap<Id, MediaRef>,
    folder: Option<PathBuf>,
}

impl RefOnlyMediaResolver {
    pub fn new() -> RefOnlyMediaResolver {
        RefOnlyMediaResolver::default()
    }

    /// The stored path of a media.
    // Swift: SessionServices.swift:64
    pub fn path(&self, id: Id) -> Option<String> {
        self.with(|s| s.refs.get(&id).map(|r| r.path.clone()))
    }

    /// The project folder last set.
    pub fn project_folder(&self) -> Option<PathBuf> {
        self.with(|s| s.folder.clone())
    }

    fn with<R>(&self, f: impl FnOnce(&mut RefOnlyState) -> R) -> R {
        // A panic while holding the lock leaves plain data behind: keep using it (Swift's NSLock has no poisoning).
        let mut guard = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }
}

impl SessionMediaResolving for RefOnlyMediaResolver {
    fn set_project_folder(&self, folder: Option<PathBuf>) {
        self.with(|s| s.folder = folder);
    }
    fn info(&self, id: Id) -> Option<MediaInfo> {
        self.with(|s| s.refs.get(&id).and_then(|r| r.info.clone()))
    }
    fn update(&self, media: &[MediaRef], _sample_rate: Option<i64>) {
        self.with(|s| s.refs = media.iter().map(|r| (r.id, r.clone())).collect());
    }
    fn invalidate(&self, _ids: &BTreeSet<Id>) {}
    fn prepare(&self, _ids: &[Id]) -> BTreeSet<Id> {
        BTreeSet::new()
    }
    fn file_path(&self, id: Id) -> Option<PathBuf> {
        self.path(id).map(PathBuf::from)
    }
}

/// Platform analysis for the session's flows (Swift `AnalysisBackend`): scene detection, subject detection for
/// Reframe, stabilization. Defaults: nothing offered. Runs on workers, so `Send + Sync`; Swift's async
/// `sceneChanges` blocks here and reports progress through `progress`.
// Swift: AnalysisFlows.swift:9
pub trait AnalysisBackend: Send + Sync {
    /// Scene cut times in `range` of the file, `None` when this backend cannot detect them. Errors are messages.
    fn scene_changes(
        &self,
        _path: &Path,
        _range: TimeRange,
        _progress: &(dyn Fn(f64) + Send + Sync),
    ) -> Result<Option<Vec<Time>>, String> {
        Ok(None)
    }
    fn offers_reframe(&self) -> bool {
        false
    }
    fn offers_stabilize(&self) -> bool {
        false
    }
    fn subject_detector(&self, _media: &MediaRef) -> Option<Box<dyn SubjectDetecting<Error = String> + Send>> {
        None
    }
    fn stabilization_analyzer(&self, _media: &MediaRef) -> Option<Box<dyn StabilizationAnalyzing + Send>> {
        None
    }
}

/// Reads the shown Program picture back as working-linear Rec. 709 samples, rows top down (Swift
/// `ProgramFrameSampling`). The answer comes later than the call: the sampler posts it to the app inbox, which hands
/// it to whoever asked under `key` (a newer request with the same key replaces the older one).
// Swift: AnalysisFlows+ColorMatch.swift:7
pub trait ProgramFrameSampling {
    /// About `width` pixels wide by the picture's aspect; the answer is `None` when there is no picture.
    fn sample_linear(&mut self, width: i64, key: &str);
    /// Mean linear RGB of a (2 * radius + 1) squared patch around `position` (0...1, y down) of the shown picture. The
    /// answer (one `[f32; 3]` as a one-element sample list) arrives under `key`.
    fn sample_patch(&mut self, position: [f64; 2], radius: i64, key: &str);
}

/// What a color detector found in a file (Swift's `(space:, embeddedLUTName:)` tuple).
#[derive(Clone, Debug, PartialEq)]
pub struct DetectedColor {
    pub space: ColorSpaceID,
    pub embedded_lut_name: Option<String>,
}
