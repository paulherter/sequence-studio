//! The session's Program engine for the app: [`sq_playback`]'s render thread behind the session's `ProgramEngine` trait.
//! Frames are composited on the GPU by the engine, read back once per new frame into a [`MonitorPicture`], and the audio
//! mix goes to the default output device, whose clock then drives the picture.

use sq_app_hosts::MonitorPicture;
use sq_audio_out::clock::{AudioClock, HostClock, PlaybackClock, SwitchingClock};
use sq_audio_out::output::{AudioOut, OutputConfig, OutputEvent};
use sq_core_edit::playback::PlaybackRate;
use sq_core_model::{SequenceFormat, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::RgbaImage;
use sq_editor_session::{PreviewSurface, ProgramEngine, SessionMediaResolving};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use sq_media::embedded_lut::EmbeddedMeta;
use sq_media::media_error::MediaError;
use sq_media::media_opener::MediaOpener;
use sq_media::video_decoding::DecodeScale;
use sq_media_ffmpeg::decode::FFmpegAudioSource;
use sq_playback::audio::{AudioFeeder, FeederHandle, Resolver, ScrubAudio, ScrubSettings};
use sq_playback::engine::core::ProgramEngine as RenderEngine;
use sq_playback::engine::handle::{EngineDeps, ProgramHandle, Shown};
use sq_playback::engine::media_source::DefaultOpener;
use sq_playback::engine::types::MediaRef;
use sq_playback::engine::{CaptionPreview, LayerRasters};
use sq_render::color::clip_pipeline::CachingLutProvider;
use sq_render::compositor::LayerColorResolver;
use std::any::Any;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::{Arc, OnceLock};

/// The mixer rate; sources are decoded to it.
const SAMPLE_RATE: i32 = 48_000;
/// Samples per mix block of the playback feeder.
const BLOCK_FRAMES: usize = 1024;

/// A running engine plus the picture it fills.
pub struct SessionEngine {
    handle: ProgramHandle,
    gpu: Option<Arc<Gpu>>,
    media: Arc<dyn SessionMediaResolving>,
    picture: MonitorPicture,
    feeder: FeederHandle,
    /// Keeps the output stream open; `None` when no device could be opened (the host clock drives playback then).
    _audio: Option<AudioOut>,
    /// What the meter panel reads (`None` without an output) and the thread measuring into it.
    meter: Option<Arc<sq_playback::audio::AudioMeterStore>>,
    _meter_thread: Option<sq_playback::audio::MeterThread>,
    /// Listening level, Dim, Solo and Mute for the output (`None` without an output).
    monitor: Arc<crate::meter_tap::MonitorControl>,
    shown_generation: u64,
    reported: Time,
    rate: PlaybackRate,
    /// The play range and loop the session set; the render thread owns the behavior.
    play_range: Option<TimeRange>,
    loops: bool,
    quality: DecodeScale,
    power_policy: sq_playback::engine::power_policy::PowerPolicy,
    sent_media: Vec<MediaRef>,
    /// Maps composites into display-ready textures on the GPU (`None` without a GPU: CPU pictures).
    display: Option<DisplayPath>,
    /// `SQ_PERF`: when the engine's counters were last printed.
    perf_logged: Option<std::time::Instant>,
    /// View > Show Captions in Program Monitor (the render thread owns the behavior; on by default like the core).
    shows_captions: bool,
    /// View > Audio Scrubbing: short grains of the timeline's sound at the playhead while scrubbing and stepping. The
    /// grain voice is created on first use and summed into the output next to the play ring.
    audio_scrubbing: bool,
    scrub: Option<ScrubAudio>,
    scrub_resolver: Resolver,
    /// The timeline the grains are mixed from (what `set_timeline` last got).
    scrub_timeline: Option<(Timeline, sq_playback::audio::Sequences)>,
}

/// What the play benchmark reads from a session's engine: its counters since the last Play and the per-stage report
/// (decode, upload, compose ...). `None` when the session runs another engine.
pub(crate) fn bench_numbers(engine: &dyn ProgramEngine) -> Option<(sq_playback::engine::handle::Status, Vec<String>)> {
    let e = engine.as_any().downcast_ref::<SessionEngine>()?;
    Some((e.handle.status(), e.handle.query(|e| e.stats().report()).unwrap_or_default()))
}

/// The playhead position of the newest composite the engine of a session put on screen (the play benchmark's frame clock).
pub(crate) fn bench_shown(engine: &dyn ProgramEngine) -> Option<Time> {
    let e = engine.as_any().downcast_ref::<SessionEngine>()?;
    Some(e.handle.latest_shown()?.position)
}

/// Why a clip's sound is silent. A file that is gone is offline, like other missing media, not "unreadable".
fn silent_sound_message(path: &std::path::Path, e: &MediaError) -> String {
    if path.exists() {
        format!("Cannot play the sound of {}: {e}. It is silent.", path.display())
    } else {
        format!("Cannot play the sound of {}: the file is offline (missing). It is silent.", path.display())
    }
}

/// Host time for the scrub velocity estimate: nanoseconds since the first call.
fn scrub_nanos() -> i64 {
    static START: OnceLock<std::time::Instant> = OnceLock::new();
    i64::try_from(START.get_or_init(std::time::Instant::now).elapsed().as_nanos()).unwrap_or(i64::MAX)
}

/// What the engine calls when a new composite is ready. The engine starts before the app exists, so the slot is filled
/// later (see [`connect_wake`]); until then a new composite waits for the next UI tick.
/// The window loop's frame ticks, one per process (both monitors' engines read them).
pub fn display_timing() -> Arc<sq_playback::engine::DisplayTiming> {
    static TIMING: OnceLock<Arc<sq_playback::engine::DisplayTiming>> = OnceLock::new();
    Arc::clone(TIMING.get_or_init(Arc::default))
}

pub type WakeSlot = Arc<OnceLock<Arc<dyn Fn() + Send + Sync>>>;

/// Lets the engines holding `slot` wake `app`'s window loop (a no-op post marks the frame dirty). A composite the engine
/// published before the slot was filled found nobody to wake, so the loop is woken once now.
pub fn connect_wake(slot: &WakeSlot, app: &sq_app_shell::Headless) {
    if let Some(tx) = app.with(|a| a.sender())
        && slot
            .set(Arc::new({
                let tx = tx.clone();
                move || tx.send(sq_app_shell::AppMessage::Post(Box::new(|_| {})))
            }))
            .is_ok()
    {
        tx.send(sq_app_shell::AppMessage::Post(Box::new(|_| {})));
    }
}

/// The status line for an output event (`None`: log only).
fn audio_event_line(event: &OutputEvent) -> Option<String> {
    match event {
        OutputEvent::StreamInvalidated => Some("Audio output changed. Reconnecting.".into()),
        OutputEvent::DeviceLost => Some("Audio output lost. Waiting for a device.".into()),
        OutputEvent::Rebuilt { .. } => Some("Audio output is back.".into()),
        OutputEvent::DeviceChanged => {
            crate::applog::error("audio output: device changed");
            None
        }
        OutputEvent::Underrun(n) => {
            crate::applog::debug(&format!("audio output: {n} underruns"));
            None
        }
    }
}

/// Writes an audio failure to the app log and shows it in the status bar.
fn report_audio(line: &str, wake: &WakeSlot) {
    crate::applog::error(line);
    eprintln!("{line}");
    sq_app_hosts::audio_notice::post(line);
    if let Some(f) = wake.get() {
        f();
    }
}

/// Starts the engine for a session whose media paths come from `media`; the frames appear in `picture` and `wake` is
/// called for each one.
pub fn engine(
    media: Arc<dyn SessionMediaResolving>,
    picture: MonitorPicture,
    wake: WakeSlot,
) -> Box<dyn ProgramEngine> {
    // The window's device: the window samples the composite directly (see `pump_picture`).
    let gpu = crate::surface::shared_gpu().map(|(_, g)| Arc::clone(g));

    let resolver_media = Arc::clone(&media);
    let resolver_wake = std::sync::Arc::clone(&wake);
    let reported = std::sync::Mutex::new(std::collections::HashSet::new());
    let resolver: Resolver = Arc::new(move |id| {
        let path = resolver_media.file_path(id).ok_or(MediaError::Unreadable)?;
        // The item's Audio Channels: a multi-track file plays the channels the map names (Swift `MultiTrackAudio`).
        let map = resolver_media.info(id).and_then(|i| i.audio).and_then(|a| a.channel_map);
        FFmpegAudioSource::open_mapped(&path, SAMPLE_RATE, map.as_ref()).map(Arc::from).inspect_err(|e| {
            // A clip whose sound cannot be opened plays silent: say which file and why, once per file.
            // AVERROR_STREAM_NOT_FOUND is a file without sound: silent by nature, nothing to warn about.
            let no_sound = matches!(e, MediaError::DecodeFailed(-1_381_258_232));
            if !no_sound && reported.lock().is_ok_and(|mut r| r.insert(id)) {
                report_audio(&silent_sound_message(&path, e), &resolver_wake);
            }
        })
    });
    let empty = Timeline::new(Id::from_u128(0), "", SequenceFormat::new(Time::new(1001, 30000)), Vec::new());
    let scrub_resolver = Arc::clone(&resolver);
    let feeder = AudioFeeder::new(empty, BLOCK_FRAMES, resolver);
    let feeder_handle = feeder.handle();
    // The live duck releases through dialogue pauses (the waveform reads feed this store; unknown clips duck whole).
    feeder_handle.set_dialogue_silences(Some(Arc::clone(sq_app_hosts::export_audio::app_silences()) as _));
    let (events, event_rx) = std::sync::mpsc::channel();
    let (metered, meter, meter_thread, monitor) = crate::meter_tap::MeteringRenderer::new(Box::new(feeder));
    let notify = std::sync::Arc::clone(&wake);
    // `SQ_AUDIO_NULL`: a deliberate null sink for offscreen runs, no notice.
    let audio = if sq_audio_out::output::null_sink_requested() {
        None
    } else {
        AudioOut::open(OutputConfig::default(), Box::new(metered), events)
            .map_err(|e| report_audio(&format!("No audio output: {e}. Playback is silent."), &notify))
            .ok()
    };
    if audio.is_some() {
        std::thread::Builder::new()
            .name("sq-audio-events".into())
            .spawn(move || {
                while let Ok(event) = event_rx.recv() {
                    if let Some(line) = audio_event_line(&event) {
                        report_audio(&line, &notify);
                    }
                }
            })
            .ok();
    }
    let (meter, meter_thread) = if audio.is_some() { (Some(meter), Some(meter_thread)) } else { (None, None) };
    let host: Arc<dyn PlaybackClock> = Arc::new(HostClock::new());
    let audio_clock: Option<Arc<AudioClock>> = audio.as_ref().map(|a| a.clock().playback_clock());
    let switching = Arc::new(SwitchingClock::new(host, audio_clock));
    // The output drives the clock from the start: without this the engine ran on the host clock and never started the
    // mixer, so the output stayed silent and the meter flat (found on the Windows PC, 2026-11-09).
    switching.use_audio(audio.is_some());
    let clock: Arc<dyn PlaybackClock> = switching;

    let fields_media = Arc::clone(&media);
    let opener: Arc<dyn MediaOpener> =
        Arc::new(DefaultOpener::new(gpu.clone()).with_deinterlace(Arc::new(move |id| {
            fields_media.info(id).and_then(|i| i.video).and_then(|v| v.deinterlace_field_order())
        })));
    let mut deps = EngineDeps::new(crate::proxy::monitor_opener(opener), clock);
    deps.gpu = gpu.clone();
    deps.display = Some(display_timing());
    deps.on_shown = Some(Arc::new(move || {
        if let Some(f) = wake.get() {
            f();
        }
    }));
    // Titles, shapes and captions are drawn on the CPU, clip grades come from the layer color resolver; without these
    // the monitor would show the bare video layers.
    // Lottie clips are drawn by the pure Rust tiny-skia rasterizer on the render thread; the finished composite wakes the
    // window through `on_shown` above, also while playback is paused.
    let lottie = sq_lottie::lottie_skia::LottieRendererSkia::renderer();
    deps.rasters = Some(Arc::new(LayerRasters::with_lottie(lottie)));
    deps.planner = Some(Arc::new(CaptionPreview));
    // Gyroflow Stabilizers: the shared engine's warp maps; a clip not analyzed yet shows unwarped and the engine redraws.
    deps.gyro = Some(sq_app_hosts::gyroflow_host::hook(false));
    let lookup_media = Arc::clone(&media);
    // The camera LUT stored inside a clip's file (Sony: the look the camera records with S-Log3).
    let lut_media = Arc::clone(&media);
    let embedded = Box::new(move |id| {
        let path = lut_media.file_path(id)?;
        EmbeddedMeta::lut_in_clip(&path).ok().flatten().map(|l| l.data)
    });
    let luts = CachingLutProvider::new(None, embedded, None);
    deps.color =
        Some(Arc::new(LayerColorResolver::new(Some(Arc::new(luts)), Arc::new(move |id| lookup_media.info(id)))));
    let display = gpu.as_ref().and_then(|g| DisplayPath::new(Arc::clone(g)));
    Box::new(SessionEngine {
        display,
        handle: RenderEngine::spawn(deps),
        gpu,
        media,
        picture,
        feeder: feeder_handle,
        _audio: audio,
        meter,
        _meter_thread: meter_thread,
        monitor,
        shown_generation: 0,
        reported: Time::ZERO,
        rate: PlaybackRate::ZERO,
        play_range: None,
        loops: false,
        quality: DecodeScale::Full,
        power_policy: sq_playback::engine::power_policy::PowerPolicy::NORMAL,
        sent_media: Vec::new(),
        perf_logged: std::env::var_os("SQ_PERF").map(|_| std::time::Instant::now()),
        shows_captions: true,
        audio_scrubbing: false,
        scrub: None,
        scrub_resolver,
        scrub_timeline: None,
    })
}

/// Every media a timeline (and the sequences nested in it) plays, with the file the session knows for it.
fn media_refs<'a>(media: &dyn SessionMediaResolving, timelines: impl Iterator<Item = &'a Timeline>) -> Vec<MediaRef> {
    let ids: BTreeSet<Id> = timelines.flat_map(|t| &t.tracks).flat_map(|tr| tr.clips()).map(|c| c.media).collect();
    ids.into_iter()
        .filter_map(|id| media.file_path(id).map(|p| MediaRef { id, path: p.to_string_lossy().into_owned() }))
        .collect()
}

/// True when the render thread published at most one composite more while a picture was read back (the ring holds
/// `OUTPUT_RING` textures; one more may be in flight), so the texture read was not overwritten.
fn read_is_safe(read: u64, newest: Option<u64>) -> bool {
    newest.is_none_or(|n| n.saturating_sub(read) <= (sq_render::program::OUTPUT_RING as u64).saturating_sub(3))
}

/// The composite of `shown` read back to the CPU (`None` without a composite).
fn read_picture(gpu: &Arc<Gpu>, shown: &Shown) -> Option<RgbaImage> {
    let frame = shown.frame.as_ref()?;
    let (width, height) = (frame.size.0 as usize, frame.size.1 as usize);
    let pixels = gpu.read_texture(frame.planes.first()?).ok()?;
    (pixels.len() == width * height * 4).then_some(RgbaImage { width, height, pixels })
}

/// The linear half-float composite (`Rgba16Float`, tight rows) as the Export Frame writers want it.
fn read_linear(gpu: &Arc<Gpu>, texture: &GpuTexture) -> Option<sq_app_hosts::LinearImage> {
    let bytes = gpu.read_texture(texture).ok()?;
    let (width, height) = (texture.width() as usize, texture.height() as usize);
    (bytes.len() == width * height * 8).then_some(sq_app_hosts::LinearImage { width, height, bytes })
}

/// The GPU way of a composite to the window: a queued copy of the composite (for readers that want pixels) and the
/// display gamma pass into the texture the window samples. Nothing waits for the GPU.
pub struct DisplayPath {
    gpu: Arc<Gpu>,
    gamma: sq_draw::display_gamma::GpuDisplayGamma,
    /// The last composite, raw (read back only on demand) and display-ready.
    textures: Option<(GpuTexture, GpuTexture)>,
}

impl DisplayPath {
    pub const PATH: &'static str = "GPU copy + GPU display gamma, sampled by the window (no readback)";

    pub fn new(gpu: Arc<Gpu>) -> Option<DisplayPath> {
        let gamma = sq_draw::display_gamma::GpuDisplayGamma::new(Arc::clone(&gpu))
            .map_err(|e| eprintln!("display gamma pass: {e}"))
            .ok()?;
        Some(DisplayPath { gpu, gamma, textures: None })
    }

    /// Queues `shown` into the display texture and publishes it in `picture`; `Some(None)` = no composite (the
    /// caller clears the picture), `None` = published.
    fn take(&mut self, shown: &Shown, picture: &MonitorPicture) -> Option<Option<RgbaImage>> {
        let Some(source) = shown.frame.as_ref().and_then(|f| f.planes.first()) else { return Some(None) };
        if source.texture().format() != PixelFormat::Rgba8Unorm.wgpu() {
            return Some(read_picture(&self.gpu, shown));
        }
        let (w, h) = (source.width(), source.height());
        if self.textures.as_ref().is_none_or(|(raw, _)| (raw.width(), raw.height()) != (w, h)) {
            self.textures = Some((
                self.gpu.texture(w, h, PixelFormat::Rgba8Unorm),
                self.gpu.texture(w, h, PixelFormat::Rgba8Unorm),
            ));
        }
        let (raw, display) = self.textures.clone()?;
        let mut cmds = self.gpu.commands();
        cmds.copy(source, &raw);
        self.gpu.submit(cmds);
        let gamma = picture.view_choices().gamma().gamma();
        if let Err(e) = self.gamma.apply(source, &display, gamma) {
            eprintln!("display gamma pass: {e}");
            return Some(read_picture(&self.gpu, shown));
        }
        let gpu = Arc::clone(&self.gpu);
        let reader = Arc::new(move || {
            let pixels = gpu.read_texture(&raw).ok()?;
            let (width, height) = (raw.width() as usize, raw.height() as usize);
            (pixels.len() == width * height * 4).then_some(RgbaImage { width, height, pixels })
        });
        let shared = Arc::new(crate::surface::DisplayPicture {
            gpu: Arc::clone(&self.gpu),
            texture: display,
            linear: shown.linear.clone(),
        });
        picture.set_gpu((w as usize, h as usize), shared, reader);
        None
    }
}

/// The window's picture pump: moves the engine's newest composite into `picture` when its generation is new and returns
/// the composite taken (`None`: nothing new). The app and the present check (`present_check.rs`) share it.
pub(crate) fn pump(
    handle: &ProgramHandle,
    mut display: Option<&mut DisplayPath>,
    gpu: Option<&Arc<Gpu>>,
    picture: &MonitorPicture,
    shown_generation: &mut u64,
) -> Option<Arc<Shown>> {
    // A read the render thread lapped is read again from the newest composite (its wake may already be spent).
    for _ in 0..3 {
        let shown = handle.latest_shown()?;
        if shown.generation == *shown_generation {
            return None;
        }
        let taken = match display.as_deref_mut() {
            Some(display) => display.take(&shown, picture),
            None => Some(gpu.and_then(|gpu| read_picture(gpu, &shown))),
        };
        // The compositor rotates its output textures: when the render thread got a whole ring ahead during the
        // read (or the queued copy), the texture may hold a newer, half-drawn composite.
        if read_is_safe(shown.generation, handle.latest_shown().map(|s| s.generation)) {
            *shown_generation = shown.generation;
            if let Some(image) = taken {
                picture.set(image);
            }
            let reader = shown.linear.clone().zip(display.as_deref().map(|d| &d.gpu).or(gpu)).map(|(t, g)| {
                let g = Arc::clone(g);
                Arc::new(move || read_linear(&g, &t)) as sq_app_hosts::LinearReader
            });
            picture.set_linear(reader);
            probe_applied(&shown);
            return Some(shown);
        }
    }
    None
}

/// What the window does with a new composite before it can draw it, for the engine benchmark: the app's display path,
/// then the window renderer taking the picture; waits until the GPU finished so the cost is measured.
pub struct MonitorUpload {
    gpu: Arc<Gpu>,
    path: Option<DisplayPath>,
    picture: MonitorPicture,
    renderer: sq_draw::WgpuRenderer,
}

impl MonitorUpload {
    pub const PATH: &'static str = DisplayPath::PATH;

    pub fn new(gpu: Arc<Gpu>) -> Result<MonitorUpload, String> {
        let renderer =
            sq_draw::WgpuRenderer::new(Arc::clone(&gpu), PixelFormat::Bgra8Unorm).map_err(|e| e.to_string())?;
        let path = DisplayPath::new(Arc::clone(&gpu));
        Ok(MonitorUpload { gpu, path, picture: MonitorPicture::default(), renderer })
    }

    /// Moves `shown` into the window renderer's video texture and waits until the GPU took it.
    pub fn take(&mut self, shown: &Shown) {
        if let Some(path) = &mut self.path
            && path.take(shown, &self.picture).is_none()
            && let Some(p) = self.picture.gpu().and_then(|g| g.downcast::<crate::surface::DisplayPicture>().ok())
        {
            self.renderer.set_video_texture(Some(&p.texture));
        }
        let _ = self.gpu.wait();
    }
}

impl SessionEngine {
    fn send_media(&mut self, refs: Vec<MediaRef>) {
        if refs != self.sent_media {
            self.handle.set_media(refs.clone());
            self.sent_media = refs;
        }
    }

    /// Moves the engine's newest composite into the monitor picture when it is a new one.
    fn pump_picture(&mut self) {
        let handed =
            pump(&self.handle, self.display.as_mut(), self.gpu.as_ref(), &self.picture, &mut self.shown_generation);
        // A composite without a picture clears the monitor (an empty timeline, a clip still opening); only a real video picture
        // counts as the first one, or every first-picture check measures the black placeholder.
        if let Some(shown) = handed {
            let real = shown.frame.is_some();
            sq_core_time::milestones::mark(if real {
                "first picture handed to the monitor"
            } else {
                "monitor cleared (no video picture yet)"
            });
        }
    }

    /// Output counters and clock state, for the audio tests.
    #[cfg(test)]
    fn audio_report(&self) -> String {
        self._audio.as_ref().map_or("no audio".into(), |a| format!("{:?} stalled {}", a.stats(), a.clock().stalled()))
    }

    /// Waits until the render thread took the call so `position` and `rate` answer for it.
    fn settle(&self) {
        self.handle.sync();
    }
}

impl ProgramEngine for SessionEngine {
    fn set_timeline(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) {
        let refs = media_refs(self.media.as_ref(), std::iter::once(timeline).chain(sequences.values()));
        self.send_media(refs);
        let all: HashMap<Id, Timeline> = sequences.iter().map(|(k, v)| (*k, v.clone())).collect();
        if let Some(scrub) = &self.scrub {
            scrub.set_timeline(timeline.clone(), all.clone());
        }
        // shortcut: one more copy of the timeline is kept so the switch can start grains at any time; upgrade by sharing it with the feeder.
        self.scrub_timeline = Some((timeline.clone(), all.clone()));
        self.feeder.set_timeline(timeline.clone(), Some(all.clone()));
        self.handle.set_timeline(timeline.clone(), all);
    }

    fn attach(&mut self, _surface: Option<PreviewSurface>) {}

    fn set_color_bypass(&mut self, bypass: Option<sq_core_color::ColorBypass>) {
        self.handle.set_color_bypass(bypass.filter(|b| !b.is_empty()));
    }

    fn set_look_preview(&mut self, preview: Option<sq_playback::engine::LookPreview>) {
        self.handle.set_look_preview(preview);
    }

    fn shows_captions(&self) -> bool {
        self.shows_captions
    }

    fn audio_scrubbing(&self) -> bool {
        self.audio_scrubbing
    }

    fn set_audio_scrubbing(&mut self, on: bool) {
        self.audio_scrubbing = on;
        if !on {
            if let Some(scrub) = &self.scrub {
                scrub.stop();
            }
            return;
        }
        // The voice rides on the output's callback; without an output there is nothing to hear.
        if self.scrub.is_none()
            && let Some(audio) = &self._audio
        {
            let (scrub, player) = ScrubAudio::new(
                Arc::clone(&self.scrub_resolver),
                ScrubSettings::default(),
                i64::from(SAMPLE_RATE),
                false,
            );
            audio.set_side_voice(Some(Box::new(player)));
            self.scrub = Some(scrub);
        }
        if let (Some(scrub), Some((timeline, sequences))) = (&self.scrub, self.scrub_timeline.clone()) {
            scrub.set_timeline(timeline, sequences);
        }
    }

    fn set_shows_captions(&mut self, on: bool) {
        self.shows_captions = on;
        self.handle.set_shows_captions(on);
    }

    fn set_proxy_use(&mut self, proxy_use: sq_editor_session::ProxyUse) {
        self.handle.set_proxy_use(sq_playback::engine::proxy_picture::ProxyUse {
            scrubbing: proxy_use.scrubbing,
            playback: proxy_use.playback,
        });
    }

    fn proxies_changed(&mut self, ids: &std::collections::BTreeSet<Id>) {
        self.handle.proxies_changed(ids.iter().copied().collect());
    }

    fn position(&self) -> Time {
        self.handle.status().position
    }

    fn rate(&self) -> PlaybackRate {
        self.handle.status().rate.unwrap_or(self.rate)
    }

    fn failure(&self) -> Option<String> {
        self.handle.status().compositor_failure
    }

    fn play(&mut self, rate: PlaybackRate) {
        if let Some(scrub) = &self.scrub {
            scrub.stop();
        }
        self.rate = rate;
        self.handle.play(rate);
        self.settle();
    }

    fn pause(&mut self) {
        self.rate = PlaybackRate::ZERO;
        self.handle.pause();
        self.settle();
    }

    fn seek(&mut self, t: Time) {
        self.handle.seek(t);
        self.settle();
    }

    fn meter_reading(&self) -> Option<sq_editor_session::MeterReading> {
        let s = self.meter.as_ref()?.snapshot();
        Some(sq_editor_session::MeterReading {
            sequence: i64::try_from(s.sequence).unwrap_or(i64::MAX),
            peaks: vec![s.left.peak, s.right.peak],
        })
    }

    fn loudness_levels(&self) -> Option<sq_playback::audio::LoudnessLevels> {
        Some(self.meter.as_ref()?.snapshot().loudness)
    }

    fn reset_loudness_meter(&mut self) {
        if let Some(m) = &self.meter {
            m.reset_loudness();
        }
    }

    fn set_monitor_gain(&mut self, setting: sq_audiofx::monitor_gain::MonitorSetting) {
        self.monitor.set_gain(&setting);
    }

    fn set_channel_monitor(&mut self, monitor: sq_audiofx::channel_monitor::ChannelMonitor) {
        self.monitor.set_channels(monitor);
    }

    /// A paused picture is shown again (View Gamma changed): seek to where it stands.
    fn redraw(&mut self) {
        if self.rate() == PlaybackRate::ZERO {
            let t = self.position();
            self.seek(t);
        }
    }

    fn step(&mut self, frames: i64) {
        let from = self.audio_scrubbing.then(|| self.position());
        self.handle.step(i32::try_from(frames).unwrap_or(0));
        self.settle();
        if let (Some(from), Some(scrub)) = (from, &self.scrub) {
            scrub.step(from, self.position());
        }
    }

    fn begin_scrub(&mut self) {
        if let (true, Some(scrub)) = (self.audio_scrubbing, &self.scrub) {
            scrub.begin(self.position(), scrub_nanos());
        }
        self.handle.begin_scrub();
    }

    fn scrub(&mut self, t: Time) {
        if let (true, Some(scrub)) = (self.audio_scrubbing, &self.scrub) {
            scrub.scrub(t, scrub_nanos());
        }
        self.handle.scrub(t);
    }

    fn end_scrub(&mut self) {
        if let Some(scrub) = &self.scrub {
            scrub.stop();
        }
        self.handle.end_scrub();
    }

    fn quality(&self) -> DecodeScale {
        self.quality
    }

    fn set_quality(&mut self, quality: DecodeScale) {
        self.quality = quality;
        self.handle.set_quality(self.power_policy.viewer_scale(quality));
    }

    fn power_policy(&self) -> sq_playback::engine::power_policy::PowerPolicy {
        self.power_policy
    }

    // Swift: PlaybackEngine.swift:35 (decode size capped by the policy, the prefetch look-ahead halved)
    fn set_power_policy(&mut self, policy: sq_playback::engine::power_policy::PowerPolicy) {
        if policy == self.power_policy {
            return;
        }
        self.power_policy = policy;
        self.handle.set_quality(policy.viewer_scale(self.quality));
        self.handle.set_prefetch_halved(policy.halves_prefetch);
    }

    /// The app's frame pump calls this once per frame: the place to bring the newest picture over.
    fn take_position_change(&mut self) -> Option<Time> {
        self.pump_picture();
        if self.perf_logged.is_some_and(|t| t.elapsed().as_secs() >= 1) && !self.rate.is_paused() {
            self.perf_logged = Some(std::time::Instant::now());
            eprintln!("engine: {:?}", self.handle.status());
            eprintln!("engine: {:?}", self.handle.query(|e| e.stats().report()));
        }
        let now = self.handle.status().position;
        (now != std::mem::replace(&mut self.reported, now)).then_some(now)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn media_changed(&mut self, ids: &BTreeSet<Id>) {
        let ids: HashSet<Id> = ids.iter().copied().collect();
        // A relink changes no clip, so the session does not push the timeline again: send the new files now, before
        // the engine reopens, or it reopens the old (missing) path and stays black until the project is reopened.
        if let Some((timeline, sequences)) = &self.scrub_timeline {
            let refs = media_refs(self.media.as_ref(), std::iter::once(timeline).chain(sequences.values()));
            self.send_media(refs);
        }
        self.feeder.media_changed(&ids);
        // The scrub mixer has its own feeder: without this it keeps grain-reading the old (or missing) file.
        if let Some(scrub) = &self.scrub {
            scrub.media_changed(&ids);
        }
        self.handle.media_changed(ids);
    }

    fn set_frame_cache_bytes(&mut self, bytes: usize) {
        self.handle.set_frame_cache_bytes(bytes);
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
}

#[cfg(test)]
mod tests {
    use sq_media::media_error::MediaError;

    #[test]
    fn a_missing_file_is_offline_not_unreadable() {
        let gone = std::path::Path::new("/definitely/not/here/Audio 1_5.wav");
        let msg = super::silent_sound_message(gone, &MediaError::Unreadable);
        assert!(msg.contains("offline") && !msg.contains("unreadable"), "{msg}");
    }

    use super::read_is_safe;

    /// The engine starts before the window exists: a composite it published while the wake slot was still empty reaches no
    /// one, so filling the slot wakes the loop once and the first turn takes the picture.
    #[test]
    fn connecting_the_wake_after_the_engine_published_wakes_the_loop_once() {
        use super::{WakeSlot, connect_wake};
        use sq_app_shell::{AppDeps, Headless};
        use sq_runtime::{Clock, SystemClock};
        use std::sync::Arc;
        use std::sync::atomic::{AtomicUsize, Ordering};
        let clock = Arc::new(SystemClock::new());
        let wakes = Arc::new(AtomicUsize::new(0));
        let mut deps = AppDeps::headless(Arc::clone(&clock) as Arc<dyn Clock>);
        let counted = Arc::clone(&wakes);
        deps.wake = Box::new(move || {
            counted.fetch_add(1, Ordering::SeqCst);
        });
        let (session, _) =
            crate::untitled_session(&std::env::temp_dir().join(format!("sq-wake-{}", std::process::id())));
        let app = Headless::new(session, deps, 800, 600);
        let slot = WakeSlot::default();
        // An engine that published now would call `slot.get()` and find nothing.
        assert!(slot.get().is_none());
        connect_wake(&slot, &app);
        assert_eq!(wakes.load(Ordering::SeqCst), 1, "connecting did not wake the loop");
        slot.get().expect("the slot is filled")();
        assert_eq!(wakes.load(Ordering::SeqCst), 2, "a later engine wake still reaches the loop");
        connect_wake(&slot, &app);
        assert_eq!(
            wakes.load(Ordering::SeqCst),
            2,
            "a second connect must not wake again (the slot is already filled)"
        );
    }

    #[test]
    fn a_read_is_dropped_when_the_render_thread_lapped_the_ring() {
        assert!(read_is_safe(5, Some(5)));
        assert!(read_is_safe(5, Some(6)));
        assert!(!read_is_safe(5, Some(7)));
        assert!(read_is_safe(5, None));
    }
}

#[cfg(test)]
mod audio_event_tests {
    use super::*;
    use sq_core_model::{Clip, Track, TrackKind};
    use std::path::PathBuf;

    /// Serves one file for every media id.
    struct OneFile(PathBuf);
    impl SessionMediaResolving for OneFile {
        fn set_project_folder(&self, _: Option<PathBuf>) {}
        fn info(&self, _: Id) -> Option<sq_core_model::MediaInfo> {
            None
        }
        fn update(&self, _: &[sq_core_model::MediaRef], _: Option<i64>) {}
        fn invalidate(&self, _: &BTreeSet<Id>) {}
        fn prepare(&self, ids: &[Id]) -> BTreeSet<Id> {
            ids.iter().copied().collect()
        }
        fn file_path(&self, _: Id) -> Option<PathBuf> {
            Some(self.0.clone())
        }
    }

    /// A 16-bit mono 48 kHz WAV of `secs` seconds of 440 Hz.
    fn tone_wav(path: &std::path::Path, secs: u32) {
        let n = 48_000 * secs;
        let mut b = Vec::new();
        b.extend(b"RIFF");
        b.extend((36 + n * 2).to_le_bytes());
        b.extend(b"WAVEfmt ");
        b.extend(16u32.to_le_bytes());
        b.extend(1u16.to_le_bytes());
        b.extend(1u16.to_le_bytes());
        b.extend(48_000u32.to_le_bytes());
        b.extend(96_000u32.to_le_bytes());
        b.extend(2u16.to_le_bytes());
        b.extend(16u16.to_le_bytes());
        b.extend(b"data");
        b.extend((n * 2).to_le_bytes());
        for i in 0..n {
            let v = (f64::from(i) * 2.0 * std::f64::consts::PI * 440.0 / 48_000.0).sin() * 0.5;
            b.extend(((v * 32767.0) as i16).to_le_bytes());
        }
        std::fs::write(path, b).expect("write the tone");
    }

    #[test]
    fn lost_and_back_show_in_the_status_bar_underruns_do_not() {
        assert!(audio_event_line(&OutputEvent::DeviceLost).is_some());
        assert!(audio_event_line(&OutputEvent::Rebuilt { latency: std::time::Duration::ZERO }).is_some());
        assert!(audio_event_line(&OutputEvent::Underrun(3)).is_none());
    }

    /// Plays a 440 Hz clip for 1.5 s through the app's engine: the position follows the wall clock (not 17 frames, not
    /// 50 s) and the meter shows the tone. Skips without an audio device or FFmpeg.
    /// Serves a file path that a relink can change.
    struct MovingFile(std::sync::Mutex<PathBuf>);
    impl SessionMediaResolving for MovingFile {
        fn set_project_folder(&self, _: Option<PathBuf>) {}
        fn info(&self, _: Id) -> Option<sq_core_model::MediaInfo> {
            None
        }
        fn update(&self, _: &[sq_core_model::MediaRef], _: Option<i64>) {}
        fn invalidate(&self, _: &BTreeSet<Id>) {}
        fn prepare(&self, ids: &[Id]) -> BTreeSet<Id> {
            ids.iter().copied().collect()
        }
        fn file_path(&self, _: Id) -> Option<PathBuf> {
            self.0.lock().ok().map(|p| p.clone())
        }
    }

    #[test]
    fn a_relink_sends_the_new_file_to_the_engine_without_a_timeline_push() {
        let media = Arc::new(MovingFile(std::sync::Mutex::new(PathBuf::from("/gone/a.mp4"))));
        let mut engine = engine(
            Arc::clone(&media) as Arc<dyn SessionMediaResolving>,
            MonitorPicture::default(),
            WakeSlot::default(),
        );
        let mut ids = sq_core_time::SequentialIds::default();
        let mut track = Track::new(Id::from_u128(2), TrackKind::Video);
        let m = Id::from_u128(3);
        let clip = Clip::new(
            Id::from_u128(4),
            "a",
            m,
            TrackKind::Video,
            sq_core_time::TimeRange::new(sq_core_time::Time::ZERO, sq_core_time::Time::seconds(2)),
            sq_core_time::Time::ZERO,
        );
        assert!(track.insert(clip, &mut ids).is_ok());
        let timeline = Timeline::new(
            Id::from_u128(1),
            "T",
            sq_core_model::SequenceFormat::new(sq_core_time::Time::new(1, 25)),
            vec![track],
        );
        engine.set_timeline(&timeline, &BTreeMap::new());
        if let Ok(mut p) = media.0.lock() {
            *p = PathBuf::from("/found/a.mp4");
        }
        engine.media_changed(&[m].into_iter().collect());
        let sent = engine.as_any().downcast_ref::<SessionEngine>().map(|e| e.sent_media.clone()).unwrap_or_default();
        assert_eq!(sent.first().map(|r| r.path.as_str()), Some("/found/a.mp4"));
    }

    #[test]
    fn the_view_switches_reach_the_engine() {
        let mut engine = engine(Arc::new(OneFile(PathBuf::new())), MonitorPicture::default(), WakeSlot::default());
        assert!(engine.shows_captions(), "captions show by default");
        engine.set_shows_captions(false);
        assert!(!engine.shows_captions());
        assert!(!engine.audio_scrubbing());
        engine.set_audio_scrubbing(true);
        assert!(engine.audio_scrubbing(), "the engine takes the Audio Scrubbing switch");
    }

    #[test]
    fn a_playing_tone_moves_the_position_with_the_wall_clock_and_the_meter() {
        if !sq_media_ffmpeg::shim::AVAILABLE {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-tone-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let wav = dir.join("tone.wav");
        tone_wav(&wav, 6);
        let mut engine = engine(Arc::new(OneFile(wav)), MonitorPicture::default(), WakeSlot::default());
        let media = Id::from_u128(5);
        let mut track = Track::new(Id::from_u128(9), TrackKind::Audio);
        let source = TimeRange::new(Time::ZERO, Time::seconds(6));
        track.set_clips(vec![Clip::new(Id::from_u128(10), "tone", media, TrackKind::Audio, source, Time::ZERO)]);
        let timeline = Timeline::new(Id::from_u128(1), "t", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        engine.set_timeline(&timeline, &BTreeMap::new());
        engine.play(PlaybackRate::FORWARD);
        let started = std::time::Instant::now();
        let mut loudest = 0.0f32;
        while started.elapsed() < std::time::Duration::from_millis(1500) {
            std::thread::sleep(std::time::Duration::from_millis(20));
            if let Some(m) = engine.meter_reading() {
                loudest = m.peaks.iter().copied().fold(loudest, f32::max);
            }
        }
        let wall = started.elapsed().as_secs_f64();
        let report = engine.as_any().downcast_ref::<SessionEngine>().map(SessionEngine::audio_report);
        let position = engine.position();
        let seconds = position.value() as f64 / position.timescale() as f64;
        let has_meter = engine.meter_reading().is_some();
        engine.pause();
        let _ = std::fs::remove_dir_all(&dir);
        assert!((seconds - wall).abs() < 0.4, "the position is {seconds} s after {wall} s of play");
        if has_meter {
            assert!(loudest > 0.05, "the meter stayed at {loudest} while the tone played ({report:?})");
        }
    }

    /// Writes a project with a 6 s tone clip (A1) to `SQ_TONE_PROJECT` for the real-window check; run with `--ignored`.
    #[test]
    #[ignore = "writes a project file for a manual check"]
    fn write_the_tone_project() {
        use sq_core_model::{MediaFingerprint, MediaRef, Project};
        let (Some(file), Some(wav)) = (std::env::var_os("SQ_TONE_PROJECT"), std::env::var_os("SQ_TONE_WAV")) else {
            return;
        };
        let media = Id::from_u128(100);
        let reference = MediaRef::new(media, "tone", &wav.to_string_lossy(), MediaFingerprint::new(1));
        let mut track = Track::new(Id::from_u128(900), TrackKind::Audio);
        let source = TimeRange::new(Time::ZERO, Time::seconds(6));
        track.set_clips(vec![Clip::new(Id::from_u128(10), "tone", media, TrackKind::Audio, source, Time::ZERO)]);
        let timeline = Timeline::new(Id::from_u128(1), "t", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        let project = Project::new(Id::from_u128(2), "p", vec![reference], vec![timeline]);
        let dir = std::path::PathBuf::from(&file).parent().map(std::path::Path::to_path_buf).unwrap_or_default();
        let mut session = sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir));
        session.save_as(std::path::Path::new(&file)).expect("save the tone project");
    }
}

/// `SQ_PLAY_PROBE=1`: the window took the composite (stages `applied` and `glass`). shortcut: the picture is handed to the
/// window here, not read back from the presented drawable (Swift headless probe does the same); upgrade when the surface reports
/// real present times. Every 10th finished jump the summary goes to the log.
fn probe_applied(shown: &Shown) {
    if !sq_playback::probe::enabled() || !shown.exact {
        return;
    }
    let probe = sq_playback::probe::PlayProbe::shared();
    if probe.awaiting_apply() {
        let now = sq_playback::probe::now();
        probe.note(sq_playback::probe::Stage::Applied, None, now);
        let before = probe.completed_count();
        probe.glass(now);
        let after = probe.completed_count();
        if after > before && after.is_multiple_of(10) {
            probe.log_report();
        }
    }
}
