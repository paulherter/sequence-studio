//! The GPU, the surface of the window and the renderer that draws the app's `DrawList` onto it.

use crate::fault_inject::{self, Fault};
use crate::resize_log::{self, PresentTiming};
use crate::start_failure::{StartCode, StartFailure};
use sq_app_hosts::SOURCE_PICTURE_SLOT;
use sq_app_shell::ATLAS_SLOT;
use sq_draw::display_gamma::{MAC_VIDEO_GAMMA, video_to_srgb_lut};
use sq_draw::hdr_present::{Encoding, HdrPresent, VideoQuad};
use sq_draw::wgpu_renderer::VideoOverride;
use sq_draw::{Color, DrawList, GlyphAtlas, WgpuRenderer};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use sq_platform::display::{HeadroomProbe, SystemProbe};
use sq_render::effects::display_view::{DisplayView, SurfaceMode, describe, surface_mode};
use sq_render::effects::view_choices::ViewChoices;
use std::sync::Arc;
use winit::window::Window;

/// What the window shows behind the panels before the first one draws.
const CLEAR: Color = Color { r: 0.08, g: 0.08, b: 0.09, a: 1.0 };

type Shared = Result<(wgpu::Instance, Arc<Gpu>), GpuError>;

fn shared() -> &'static Shared {
    static SHARED: std::sync::OnceLock<Shared> = std::sync::OnceLock::new();
    SHARED.get_or_init(|| {
        let backends = sq_gpu::gpu::backend();
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        pollster::block_on(Gpu::with_instance(&instance, None)).map(|gpu| {
            harden(&gpu);
            // Known pipelines build in the background while the project opens and the first frame decodes.
            let _ = gpu.prewarm();
            (instance, gpu)
        })
    })
}

/// The one device of the app: the Program engine composites on it and the window samples the composite directly, so a
/// frame never leaves the GPU on its way to the screen. `None` when no adapter opened (the reason is in the log and in
/// the error `Surface::new` returns).
pub fn shared_gpu() -> Option<&'static (wgpu::Instance, Arc<Gpu>)> {
    match shared() {
        Ok(pair) => Some(pair),
        Err(e) => {
            sq_os::errln!("no GPU: {e}");
            None
        }
    }
}

/// Free intermediate textures the device keeps are capped by the machine's RAM as well as the adapter class: RAM / 32,
/// 128 MB to 1 GB (`MemoryBudget`); an integrated GPU's own, lower default stays.
pub(crate) fn limit_pool(gpu: &Gpu) {
    let ram = sq_platform::physical_memory().unwrap_or(16 << 30);
    let budget = sq_playback::engine::memory_budget::MemoryBudget::current(|k| std::env::var(k).ok(), ram);
    gpu.limit_pool_bytes(budget.intermediate_pool_bytes() as u64);
}

/// A GPU error the app can live with must not take the app down: wgpu's default handler panics, and a panic inside a
/// window callback (a zoom animation resizes the window from a nested AppKit loop that cannot unwind) aborts the process.
/// Errors are logged; the next frame retries (`present` reconfigures the surface when it has no drawable).
fn harden(gpu: &Gpu) {
    limit_pool(gpu);
    gpu.device().on_uncaptured_error(Arc::new(|e| crate::applog::error(&format!("gpu error: {e}"))));
    gpu.device().set_device_lost_callback(|reason, message| {
        crate::applog::error(&format!("gpu device lost ({reason:?}): {message}"));
    });
}

/// A Program picture that stays on the GPU: display-ready code values (display gamma applied) on `gpu`.
pub struct DisplayPicture {
    pub gpu: Arc<Gpu>,
    pub texture: GpuTexture,
    /// The same composite as linear half floats (the engine's working canvas), for the extended-range surface.
    pub linear: Option<GpuTexture>,
}

/// `SQ_DISPLAY_VIEW=sdr|p3|hdr1000|raw` starts the session on that View > Display choice (tests, bug reports).
pub fn apply_display_view_env(choices: &ViewChoices) {
    let view = match std::env::var("SQ_DISPLAY_VIEW").as_deref() {
        Ok("p3") => DisplayView::DisplayP3,
        Ok("hdr1000") => DisplayView::Hdr1000,
        Ok("raw") => DisplayView::UnToneMapped,
        Ok("sdr") => DisplayView::Sdr,
        _ => return,
    };
    choices.set_display(view);
}

/// Configures `surface` for `mode`; on macOS also tags its layer: sRGB for the 8-bit surface (wgpu leaves it untagged, which
/// the window server shows unmanaged as raw Display P3 values) and Display P3 for the P3 view. The float surface keeps the
/// extended linear tag and the EDR flag wgpu sets for `ExtendedSrgbLinear` (checked by `log_layer`). Windows and Linux show
/// the surface as sRGB without OS color management.
fn configure(surface: &wgpu::Surface<'static>, gpu: &Gpu, config: &wgpu::SurfaceConfiguration, mode: SurfaceMode) {
    surface.configure(gpu.device(), config);
    #[cfg(target_os = "macos")]
    match mode {
        SurfaceMode::Sdr8 => sq_platform_mac::tag_surface_srgb(surface),
        SurfaceMode::DisplayP3 => sq_platform_mac::tag_surface_display_p3(surface),
        SurfaceMode::ExtendedLinear => {}
    }
    #[cfg(not(target_os = "macos"))]
    let _ = mode;
}

/// The screen's (current, potential) EDR component values (macOS), for the log.
#[cfg(target_os = "macos")]
fn edr_of(window: &Window) -> Option<(f64, f64)> {
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().ok()?.as_raw() {
        RawWindowHandle::AppKit(h) => sq_platform_mac::edr_values(h.ns_view.as_ptr().cast()),
        _ => None,
    }
}

/// Logs what the window's layer is set to after a mode change (macOS: pixel format, color space, EDR flag).
fn log_layer(surface: &wgpu::Surface<'static>, mode: SurfaceMode) {
    #[cfg(target_os = "macos")]
    if let Some(report) = sq_platform_mac::layer_report(surface) {
        crate::applog::info(&format!("surface {mode:?}: {report}"));
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (surface, mode);
}

/// Whether this surface can present `Rgba16Float` as `ExtendedSrgbLinear` on the adapter (Metal EDR, DX12 scRGB).
/// A surface that offers no format of ours (a compositor without a GPU path, such as a headless one) cannot present:
/// wgpu would panic at the first frame ("Surface is not configured for presentation"), so the window refuses it up front
/// with a readable error. Not a timing problem: the window's first configure is acknowledged long before the first frame.
/// Weston's headless backend with the default (pixman) renderer has no `zwp_linux_dmabuf_v1`, so the Vulkan driver lists no
/// surface format at all; `--renderer=gl` offers it (measured on weston 15, 2026-11-16).
fn can_present(offered: &[wgpu::TextureFormat], wanted: wgpu::TextureFormat) -> Result<(), String> {
    if offered.contains(&wanted) {
        return Ok(());
    }
    Err(format!(
        "this display cannot present GPU frames (the window surface offers {} formats, none is {wanted:?}); \
         run in a session with a GPU-backed compositor (a nested weston needs --renderer=gl)",
        offered.len()
    ))
}

fn float_surface_supported(caps: &wgpu::SurfaceCapabilities) -> bool {
    caps.color_spaces(PixelFormat::Rgba16Float.wgpu()).contains(wgpu::SurfaceColorSpaces::EXTENDED_SRGB_LINEAR)
}

/// The mode that is configured: the wanted float mode only when the surface can do it, else the SDR surface.
/// The P3 view needs a layer tag, which only the macOS surface has (Windows and Linux stay on the SDR surface).
fn usable_mode(want: SurfaceMode, float_ok: bool) -> SurfaceMode {
    match want {
        SurfaceMode::ExtendedLinear if !float_ok => SurfaceMode::Sdr8,
        SurfaceMode::DisplayP3 if !cfg!(target_os = "macos") => SurfaceMode::Sdr8,
        _ => want,
    }
}

/// The extended-range path's offscreen UI targets and pass (made when the float surface is first used).
struct HdrState {
    pass: HdrPresent,
    /// The UI with a black / white picture, `Bgra8Unorm` like the SDR surface.
    ui: Option<(GpuTexture, GpuTexture)>,
}

/// The window's drawing target.
pub struct Surface {
    /// The drawable accepts a copy (`COPY_DST`): the UI is kept in a layer and redrawn only where it changed.
    can_copy: bool,
    /// Presented UI frames by what they redrew: nothing, some regions, everything (`SQ_RETAIN_LOG`).
    damage_counts: [u64; 3],
    gpu: Arc<Gpu>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    /// The last configure did not panic and no present found the surface unconfigured.
    configured: bool,
    /// The surface was configured when the last `present` began, after the reconfigure that `present` makes when it was
    /// not (`present_watch.rs` reads it: a failure with a configured surface is a real one).
    ready_at_present: bool,
    occluded: bool,
    renderer: WgpuRenderer,
    /// What the display of the window reports (`None` = SDR or unknown); read again when the window moves.
    headroom: Option<f32>,
    mode: SurfaceMode,
    /// `float_surface_supported`, asked once from the adapter before any float configure.
    float_ok: bool,
    /// The view whose float mode was refused (logged once per view, not every frame).
    refused: Option<DisplayView>,
    /// The app's View > Display and View Gamma choices, read on every frame ([`Surface::use_choices`]).
    choices: ViewChoices,
    hdr: Option<HdrState>,
    /// The linear picture of the Program monitor (set by `set_picture` while it is a shared GPU picture).
    hdr_picture: Option<GpuTexture>,
    /// The same for the Source monitor (`set_source_picture`).
    hdr_source: Option<GpuTexture>,
    /// Where the last `present` spent its time (`SQ_RESIZE_LOG`).
    timing: PresentTiming,
    /// Whether the system presents in Mailbox mode (the newest frame replaces a queued one).
    mailbox: bool,
    /// `SQ_PRESENT_IMMEDIATE=1` and the system has Immediate: playback presents without display sync (A/B for the drawable stalls
    /// under load; wgpu-hal Metal maps Immediate to `displaySyncEnabled = false`). The pacer paces the frames then.
    immediate_playback: bool,
    /// The drag path is on ([`Surface::set_interactive`]).
    interactive: bool,
    /// The timeline plays ([`Surface::set_playing`]).
    playing: bool,
}

/// Images the playback path queues ahead (wgpu `desired_maximum_frame_latency`; on the Mac the layer gets one drawable more).
/// 1 on the Mac missed vsyncs (run7: glass interval p95 16.7 ms), so every system queues 2 images while playing.
/// `SQ_PLAY_LATENCY=<1..3>` overrides it for a comparison run.
const QUEUED_LATENCY_DEFAULT: u32 = 2;

fn queued_latency() -> u32 {
    std::env::var("SQ_PLAY_LATENCY")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .map_or(QUEUED_LATENCY_DEFAULT, |n| n.clamp(1, 3))
}

impl Surface {
    /// Opens the window's surface on the shared device (the G4 setup); a device of its own when that cannot present.
    /// A failure says which step failed (`SQS-2xx`): no adapter, a missing feature, a surface that cannot present, or a
    /// pipeline that did not build.
    pub fn new(window: &Arc<Window>) -> Result<Surface, StartFailure> {
        if fault_inject::active(Fault::Gpu) {
            return Err(fault_inject::failure(Fault::Gpu));
        }
        let (surface, gpu) = match shared_gpu()
            .and_then(|(instance, gpu)| Some((instance.create_surface(Arc::clone(window)).ok()?, Arc::clone(gpu))))
        {
            Some(pair) => pair,
            None => {
                // No shared device: a device of the window's own (the monitor picture then comes as CPU pixels).
                let backends = sq_gpu::gpu::backend();
                let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
                    backends,
                    ..wgpu::InstanceDescriptor::new_without_display_handle()
                });
                let surface = instance.create_surface(Arc::clone(window)).map_err(|e| {
                    StartFailure::new(StartCode::GpuPresent, "creating the window surface", e.to_string())
                })?;
                let gpu = pollster::block_on(Gpu::with_instance(&instance, Some(&surface)))
                    .map_err(|e| StartFailure::from_gpu(&e))?;
                harden(&gpu);
                (surface, gpu)
            }
        };
        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: PixelFormat::Bgra8Unorm.wgpu(),
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: queued_latency(),
            alpha_mode: wgpu::CompositeAlphaMode::Auto,
            color_space: wgpu::SurfaceColorSpace::Auto,
            view_formats: vec![],
        };
        let caps = surface.get_capabilities(gpu.adapter());
        can_present(&caps.formats, config.format)
            .map_err(|e| StartFailure::new(StartCode::GpuPresent, "checking the window surface", e))?;
        let float_ok = float_surface_supported(&caps);
        // The retained UI layer is copied into the drawable: the surface must allow it (else every frame is drawn in full).
        let can_copy = caps.usages.contains(wgpu::TextureUsages::COPY_DST);
        let mut config = config;
        if can_copy {
            config.usage |= wgpu::TextureUsages::COPY_DST;
        }
        crate::applog::info(&format!("float display surface supported: {float_ok}"));
        configure(&surface, &gpu, &config, SurfaceMode::Sdr8);
        let renderer = WgpuRenderer::new(Arc::clone(&gpu), PixelFormat::Bgra8Unorm)
            .map_err(|e| StartFailure::new(StartCode::GpuShaders, "building the drawing pipelines", e.to_string()))?;
        let mailbox = caps.present_modes.contains(&wgpu::PresentMode::Mailbox);
        let immediate_playback = std::env::var("SQ_PRESENT_IMMEDIATE").is_ok_and(|v| v == "1")
            && caps.present_modes.contains(&wgpu::PresentMode::Immediate);
        let mut s = Surface {
            can_copy,
            damage_counts: [0; 3],
            mailbox,
            immediate_playback,
            interactive: false,
            playing: false,
            gpu,
            surface,
            config,
            configured: true,
            ready_at_present: true,
            occluded: false,
            renderer,
            headroom: None,
            mode: SurfaceMode::Sdr8,
            float_ok,
            refused: None,
            choices: ViewChoices::default(),
            hdr: None,
            hdr_picture: None,
            hdr_source: None,
            timing: PresentTiming::default(),
        };
        if resize_log::on() {
            sq_os::errln!(
                "surface: present modes {:?}, using {:?}, frame latency {}",
                caps.present_modes,
                s.config.present_mode,
                s.config.desired_maximum_frame_latency
            );
        }
        s.probe_display(window);
        Ok(s)
    }

    /// Switches between the playback path and the drag path (`drag_pacing.rs`). The drag path presents in Mailbox mode where the
    /// system has it (the frame shows at the next refresh, nothing queues ahead of it), otherwise through a swap chain that
    /// queues one image; the playback path is Fifo with two queued images, which keeps the frames on the display's beat.
    /// Returns what the reconfigure cost.
    pub fn set_interactive(&mut self, on: bool) -> std::time::Duration {
        self.interactive = on;
        self.apply_present_mode()
    }

    /// Tells the surface whether the timeline plays. Only matters with `SQ_PRESENT_IMMEDIATE=1`: Immediate while playing,
    /// Fifo for the idle UI and the drag path (no tearing on a still picture). Returns what the reconfigure cost.
    pub fn set_playing(&mut self, playing: bool) -> std::time::Duration {
        if self.playing == playing {
            return std::time::Duration::ZERO;
        }
        self.playing = playing;
        if self.immediate_playback { self.apply_present_mode() } else { std::time::Duration::ZERO }
    }

    fn apply_present_mode(&mut self) -> std::time::Duration {
        let began = std::time::Instant::now();
        let (mode, latency) = match self.interactive {
            true if self.mailbox => (wgpu::PresentMode::Mailbox, 1),
            true => (wgpu::PresentMode::Fifo, 1),
            false if self.immediate_playback && self.playing => (wgpu::PresentMode::Immediate, queued_latency()),
            false => (wgpu::PresentMode::Fifo, queued_latency()),
        };
        if (self.config.present_mode, self.config.desired_maximum_frame_latency) != (mode, latency) {
            self.config.present_mode = mode;
            self.config.desired_maximum_frame_latency = latency;
            self.reconfigure();
        }
        began.elapsed()
    }

    /// Follows the app's View choices (the monitor picture's handle) instead of the default ones.
    pub fn use_choices(&mut self, choices: &ViewChoices) {
        self.choices = choices.clone();
    }

    /// Asks the system what the window's display can show and logs it. Call at start and whenever the window may have
    /// moved to another display (`Moved`, `ScaleFactorChanged`); `SQ_HDR_HEADROOM=<x>` overrides the answer (tests, bug reports).
    pub fn probe_display(&mut self, window: &Window) {
        let forced = std::env::var("SQ_HDR_HEADROOM").ok().and_then(|v| v.parse::<f32>().ok());
        let probed = forced.or_else(|| SystemProbe.headroom(window));
        if probed != self.headroom {
            self.headroom = probed;
            crate::applog::info(&format!("display headroom probe: {probed:?} (override {forced:?})"));
            #[cfg(target_os = "macos")]
            if let Some((current, potential)) = edr_of(window) {
                crate::applog::info(&format!("screen EDR component value: current {current}, potential {potential}"));
            }
        }
    }

    /// Follows the View > Display choice and the probed headroom: reconfigures the surface when the chosen mode changes.
    fn follow_mode(&mut self) {
        let view = self.choices.display();
        let asked = surface_mode(view, self.headroom);
        let want = usable_mode(asked, self.float_ok);
        if want != asked {
            if self.refused != Some(view) {
                self.refused = Some(view);
                crate::applog::info(&format!(
                    "view {} needs a float surface this display or adapter cannot present; staying on the SDR surface",
                    view.title()
                ));
            }
        } else {
            self.refused = None;
        }
        if want == self.mode {
            return;
        }
        self.config.format = match want {
            SurfaceMode::Sdr8 | SurfaceMode::DisplayP3 => PixelFormat::Bgra8Unorm.wgpu(),
            SurfaceMode::ExtendedLinear => PixelFormat::Rgba16Float.wgpu(),
        };
        self.config.color_space = match want {
            SurfaceMode::Sdr8 | SurfaceMode::DisplayP3 => wgpu::SurfaceColorSpace::Auto,
            SurfaceMode::ExtendedLinear => wgpu::SurfaceColorSpace::ExtendedSrgbLinear,
        };
        self.mode = want;
        crate::applog::info(&describe(view, self.headroom, false));
        self.reconfigure();
        log_layer(&self.surface, want);
        if want != SurfaceMode::Sdr8 && self.hdr.is_none() {
            self.hdr = Some(HdrState { pass: HdrPresent::new(Arc::clone(&self.gpu)), ui: None });
        }
    }

    /// Follows the window's new size in device pixels.
    /// The surface is configured by the next `present`, once, however many sizes came before it: a swap chain per drag step
    /// costs 1 to 80 ms each and fills the compositor's queue (`live_resize.rs`).
    pub fn resize(&mut self, width: u32, height: u32) {
        let size = (width.max(1), height.max(1));
        if self.configured && size == (self.config.width, self.config.height) {
            return;
        }
        (self.config.width, self.config.height) = size;
        self.configured = false;
    }

    /// Configures the surface again with the current config; a panic inside is caught and leaves it unconfigured until
    /// the next try (every `present` makes one while it is).
    fn reconfigure(&mut self) {
        let (surface, gpu, config, mode) = (&self.surface, &self.gpu, &self.config, self.mode);
        let done = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| configure(surface, gpu, config, mode)));
        if done.is_err() {
            crate::applog::error("surface reconfigure panicked; the next frame retries");
        }
        self.configured = done.is_ok();
    }

    /// Whether the surface was configured when the last `present` began (after the reconfigure `present` makes when it
    /// was not): a present that fails then is a real failure, one that fails on an unconfigured surface may heal.
    pub fn was_configured_at_present(&self) -> bool {
        self.ready_at_present
    }

    /// The Program monitor's picture: a display-ready texture on this surface's device is drawn as it is (no upload),
    /// CPU pixels go through the display gamma table and are uploaded.
    pub fn set_picture(&mut self, picture: &sq_app_hosts::MonitorPicture) {
        let shared = picture.gpu().and_then(|g| g.downcast::<DisplayPicture>().ok());
        self.hdr_picture = None;
        match shared {
            Some(p) if Arc::ptr_eq(&p.gpu, &self.gpu) => {
                self.hdr_picture = p.linear.clone();
                self.renderer.set_video_texture(Some(&p.texture));
            }
            _ => self.set_video(picture.get().as_deref()),
        }
    }

    /// The Source monitor's picture: its linear half-float composite when it is a GPU picture of this device, so the
    /// extended-range and Display P3 views present it like the Program picture. The CPU image still goes in through `set_image`.
    pub fn set_source_picture(&mut self, picture: &sq_app_hosts::MonitorPicture) {
        self.hdr_source = picture
            .gpu()
            .and_then(|g| g.downcast::<DisplayPicture>().ok())
            .filter(|p| Arc::ptr_eq(&p.gpu, &self.gpu))
            .and_then(|p| p.linear.clone());
    }

    /// The picture of the Program monitor's video quad.
    pub fn set_video(&mut self, picture: Option<&sq_draw::RgbaImage>) {
        let lut = video_to_srgb_lut(self.choices.gamma().gamma());
        self.renderer.set_video(picture.map(|p| p.mapped(&lut)).as_ref());
    }

    /// Uploads `picture` into the renderer's image slot `slot` (the Source monitor's picture).
    pub fn set_image(&mut self, slot: usize, picture: &sq_draw::RgbaImage) {
        // Slots holding video pictures (thumbnail atlas, Source picture) are re-encoded like the Program picture.
        if slot == ATLAS_SLOT || slot == SOURCE_PICTURE_SLOT {
            self.renderer.set_image(slot, &picture.mapped(&video_to_srgb_lut(MAC_VIDEO_GAMMA)));
        } else {
            self.renderer.set_image(slot, picture);
        }
    }

    /// The last `present` found the window occluded: nothing to retry until the system says it is visible again.
    pub fn is_occluded(&self) -> bool {
        self.occluded
    }

    /// Where the last `present` spent its time (`SQ_RESIZE_LOG`).
    pub fn timing(&self) -> PresentTiming {
        self.timing
    }

    /// Draws `list` and presents it; false when the system was not ready for a frame (the caller draws again soon).
    pub fn present(&mut self, window: &Window, list: &DrawList, atlas: Option<&GlyphAtlas>) -> Result<bool, String> {
        self.follow_mode();
        let _present_span = sq_os::trace::span("ui", "ui present");
        let began = std::time::Instant::now();
        // The first draws of a cold start can come before the surface is configured: configure it now, so the frame
        // below (or the next one) works instead of failing.
        if !self.configured {
            self.reconfigure();
        }
        let configured_in = began.elapsed();
        self.ready_at_present = self.configured;
        // wgpu panics (not an error value) when the surface was never configured; a lost configuration skips the frame.
        let waiting = crate::loop_trace::enter(crate::loop_trace::Phase::Acquire);
        let acquired = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.surface.get_current_texture()));
        drop(waiting);
        let _drawing = crate::loop_trace::enter(crate::loop_trace::Phase::Draw);
        self.timing = PresentTiming {
            configure: configured_in,
            acquire: began.elapsed() - configured_in,
            ..PresentTiming::default()
        };
        let Ok(acquired) = acquired else {
            crate::applog::error("surface cannot present; frame skipped");
            self.configured = false;
            return Err("the window surface cannot present".into());
        };
        let frame = match acquired {
            wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            // Behind another window or minimized: wait for `WindowEvent::Occluded(false)`, never poll.
            wgpu::CurrentSurfaceTexture::Occluded => {
                sq_core_time::milestones::mark("surface: occluded, no drawable");
                self.occluded = true;
                return Ok(false);
            }
            other => {
                sq_core_time::milestones::mark(&format!("surface: no drawable ({})", crate::applog::variant(&other)));
                configure(&self.surface, &self.gpu, &self.config, self.mode);
                return Ok(false);
            }
        };
        self.occluded = false;
        let drawing = std::time::Instant::now();
        if self.mode != SurfaceMode::Sdr8 {
            self.draw_extended(list, atlas, &frame.texture)?;
        } else {
            let target = GpuTexture::from_texture(frame.texture.clone());
            if self.can_copy {
                let redrawn = self.renderer.draw_retained(list, &target, CLEAR, atlas).map_err(|e| e.to_string())?;
                let slot = match &redrawn {
                    sq_draw::damage::Damage::None => 0,
                    sq_draw::damage::Damage::Regions(_) => 1,
                    sq_draw::damage::Damage::Full => 2,
                };
                self.damage_counts[slot] += 1;
                let n: u64 = self.damage_counts.iter().sum();
                if n.is_multiple_of(240) && std::env::var_os("SQ_RETAIN_LOG").is_some() {
                    sq_os::errln!(
                        "ui layer frames: none {} regions {} full {}",
                        self.damage_counts[0],
                        self.damage_counts[1],
                        self.damage_counts[2]
                    );
                }
            } else {
                self.renderer.draw(list, &target, CLEAR, atlas, 1.0).map_err(|e| e.to_string())?;
            }
        }
        self.timing.draw = drawing.elapsed();
        let presenting = std::time::Instant::now();
        window.pre_present_notify();
        self.gpu.queue().present(frame);
        self.timing.present = presenting.elapsed();
        Ok(true)
    }

    /// The present pass (float surface and Display P3): the UI twice into 8-bit targets (black and white picture), then the
    /// pass (see `hdr_present`). The Program and the Source monitor picture both go through it when they are GPU pictures.
    /// Without any linear picture (CPU pixels, no composite yet) the UI is drawn once as it is and the pass only converts it.
    fn draw_extended(
        &mut self,
        list: &DrawList,
        atlas: Option<&GlyphAtlas>,
        target: &wgpu::Texture,
    ) -> Result<(), String> {
        let (w, h) = (self.config.width, self.config.height);
        let program = self.hdr_picture.clone().zip(VideoQuad::of(list));
        let source = self.hdr_source.clone().zip(VideoQuad::of_image(list, SOURCE_PICTURE_SLOT));
        let Some(hdr) = self.hdr.as_mut() else { return Ok(()) };
        if hdr.ui.as_ref().is_none_or(|(b, _)| (b.width(), b.height()) != (w, h)) {
            hdr.ui = Some((
                self.gpu.texture(w, h, PixelFormat::Bgra8Unorm),
                self.gpu.texture(w, h, PixelFormat::Bgra8Unorm),
            ));
        }
        let Some((black, white)) = hdr.ui.as_ref() else { return Ok(()) };
        let video = if program.is_some() { VideoOverride::Black } else { VideoOverride::Keep };
        let image = source.is_some().then_some((SOURCE_PICTURE_SLOT, VideoOverride::Black));
        self.renderer.draw_with_image(list, black, CLEAR, atlas, 1.0, video, image).map_err(|e| e.to_string())?;
        if program.is_some() || source.is_some() {
            let video = if program.is_some() { VideoOverride::White } else { VideoOverride::Keep };
            let image = source.is_some().then_some((SOURCE_PICTURE_SLOT, VideoOverride::White));
            self.renderer.draw_with_image(list, white, CLEAR, atlas, 1.0, video, image).map_err(|e| e.to_string())?;
        }
        let encoding = match (self.mode, self.choices.display()) {
            (SurfaceMode::DisplayP3, _) => Encoding::DisplayP3,
            (_, DisplayView::Hdr1000) => Encoding::ScrgbRollOff,
            _ => Encoding::Scrgb,
        };
        let pictures: Vec<(&GpuTexture, VideoQuad)> =
            [program.as_ref(), source.as_ref()].into_iter().flatten().map(|(t, q)| (t, *q)).collect();
        hdr.pass.draw(black, white, &pictures, encoding, target);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{can_present, float_surface_supported, usable_mode};

    #[test]
    fn a_surface_without_our_format_is_refused_with_a_readable_error() {
        let wanted = wgpu::TextureFormat::Bgra8Unorm;
        assert!(can_present(&[wgpu::TextureFormat::Rgba8Unorm, wanted], wanted).is_ok());
        let err = can_present(&[], wanted).unwrap_err();
        assert!(err.contains("cannot present") && err.contains("0 formats") && err.contains("--renderer=gl"), "{err}");
    }
    use sq_draw::hdr_present::encode_picture;
    use sq_render::color::vec::Vec3;
    use sq_render::effects::display_view::DisplayView;
    use sq_render::effects::display_view::SurfaceMode;

    /// The WGSL/CPU path in sq-draw and the engine's `DisplayView` agree on what the extended views write.
    #[test]
    fn the_float_surface_encoding_matches_display_view() {
        for (view, roll) in [(DisplayView::Hdr1000, true), (DisplayView::UnToneMapped, false)] {
            for c in [
                [0.0, 0.0, 0.0],
                [0.5, 0.25, 0.1],
                [1.0, 1.0, 1.0],
                [8.0, 4.0, 2.0],
                [30.0, 5.0, 0.0],
                [-1.0, 2.0, 0.5],
            ] {
                let want = view.encode_scrgb(Vec3::new(c[0], c[1], c[2]));
                let got = encode_picture(roll, c).map(|v| v * sq_draw::hdr_present::SCRGB_SCALE);
                assert!(
                    (want.x - got[0]).abs() < 1e-4 && (want.y - got[1]).abs() < 1e-4 && (want.z - got[2]).abs() < 1e-4,
                    "{view:?} {c:?}: {want:?} vs {got:?}"
                );
            }
        }
    }

    fn caps(spaces: &[(wgpu::TextureFormat, wgpu::SurfaceColorSpaces)]) -> wgpu::SurfaceCapabilities {
        wgpu::SurfaceCapabilities {
            formats: vec![],
            format_capabilities: spaces
                .iter()
                .map(|(format, color_spaces)| wgpu::SurfaceFormatCapabilities {
                    format: *format,
                    color_spaces: *color_spaces,
                })
                .collect(),
            present_modes: vec![],
            alpha_modes: vec![],
            usages: wgpu::TextureUsages::RENDER_ATTACHMENT,
        }
    }

    #[test]
    fn a_surface_without_extended_linear_falls_back_to_sdr() {
        use wgpu::{SurfaceColorSpaces as S, TextureFormat as F};
        let sdr_only = caps(&[(F::Bgra8Unorm, S::SRGB)]);
        let wrong_space = caps(&[(F::Rgba16Float, S::SRGB)]);
        let hdr = caps(&[(F::Bgra8Unorm, S::SRGB), (F::Rgba16Float, S::SRGB | S::EXTENDED_SRGB_LINEAR)]);
        assert!(!float_surface_supported(&sdr_only));
        assert!(!float_surface_supported(&wrong_space));
        assert!(!float_surface_supported(&caps(&[])));
        assert!(float_surface_supported(&hdr));
        assert_eq!(usable_mode(SurfaceMode::ExtendedLinear, false), SurfaceMode::Sdr8);
        assert_eq!(usable_mode(SurfaceMode::ExtendedLinear, true), SurfaceMode::ExtendedLinear);
        assert_eq!(usable_mode(SurfaceMode::Sdr8, false), SurfaceMode::Sdr8);
        // The P3 view needs the macOS layer tag; elsewhere it stays on the SDR surface.
        let p3 = usable_mode(SurfaceMode::DisplayP3, false);
        assert_eq!(p3, if cfg!(target_os = "macos") { SurfaceMode::DisplayP3 } else { SurfaceMode::Sdr8 });
    }

    /// The P3 pass writes the same light as the Swift `DisplayView.displayP3` encoding: its Rec.709-transfer codes decode to
    /// the light this pass's sRGB-transfer codes decode to (the layer tag differs only by the transfer curve).
    #[test]
    fn the_display_p3_encoding_matches_display_view() {
        use sq_draw::hdr_present::{REC709_TO_P3, encode_display_p3};
        use sq_render::color::gamut::Gamut;
        let bt709_decode = |v: f32| if v < 0.081 { v / 4.5 } else { ((v + 0.099) / 1.099).powf(1.0 / 0.45) };
        let srgb_decode = |c: f32| if c <= 0.040_45 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) };
        // The shader's matrix is the engine's Rec.709 -> P3 matrix.
        let m = Gamut::rec709().matrix(Gamut::display_p3());
        for (i, basis) in
            [Vec3::new(1.0, 0.0, 0.0), Vec3::new(0.0, 1.0, 0.0), Vec3::new(0.0, 0.0, 1.0)].into_iter().enumerate()
        {
            let col = m.mul_vec(basis);
            let want = [col.x, col.y, col.z];
            for r in 0..3 {
                assert!(
                    (REC709_TO_P3[r][i] - want[r]).abs() < 5e-4,
                    "matrix [{r}][{i}]: {} vs {}",
                    REC709_TO_P3[r][i],
                    want[r]
                );
            }
        }
        for c in
            [[0.0, 0.0, 0.0], [0.5, 0.25, 0.1], [1.0, 1.0, 1.0], [0.0, 1.0, 0.0], [4.0, 2.0, 0.5], [-1.0, 0.5, 0.2]]
        {
            let want = DisplayView::DisplayP3.encode(Vec3::new(c[0], c[1], c[2]));
            let got = encode_display_p3(c);
            for (w, g) in [want.x, want.y, want.z].into_iter().zip(got) {
                assert!((bt709_decode(w) - srgb_decode(g)).abs() < 2e-3, "{c:?}: {w} vs {g}");
            }
        }
    }

    /// Writes a one-clip project for a manual window check: `SQ_HDR_CLIP=<media> SQ_HDR_OUT=<dir> cargo test -p sequence-studio
    /// write_hdr_check_project -- --ignored` (not run in the suite).
    #[test]
    #[ignore = "writes a project for a manual check"]
    fn write_hdr_check_project() {
        use sq_core_model::{Clip, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind};
        use sq_core_time::{Id, Time, TimeRange};
        let (Ok(clip), Ok(out)) = (std::env::var("SQ_HDR_CLIP"), std::env::var("SQ_HDR_OUT")) else { return };
        let dir = std::path::PathBuf::from(out);
        std::fs::create_dir_all(&dir).expect("folder");
        let media = Id::from_u128(100);
        let reference = MediaRef::new(media, "hdr.mov", &clip, MediaFingerprint::new(1));
        let mut track = Track::new(Id::from_u128(10), TrackKind::Video);
        let source = TimeRange::new(Time::ZERO, Time::seconds(3));
        track.set_clips(vec![Clip::new(Id::from_u128(11), "hdr", media, TrackKind::Video, source, Time::ZERO)]);
        let mut format = SequenceFormat::new(Time::new(1, 24));
        (format.width, format.height) = (1280, 720);
        let timeline = Timeline::new(Id::from_u128(1), "HDR check", format, vec![track]);
        let project = Project::new(Id::from_u128(2), "HDR check", vec![reference], vec![timeline]);
        let mut session =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        session.save_as(&dir.join("hdr.sqproj")).expect("save");
    }
}
