//! The Sequence Studio application: opens a window around the headless `App` and draws it with the wgpu renderer.
//! Design: docs/rust/session-ui-design.md section 4 (tasks P1-P3).

// The release exe has no console tab; `attach_parent_console` gives CLI runs their output back in a terminal.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod a11y;
mod applog;
#[cfg(test)]
mod break_ui;
// Windows decides drag, resize and double-click in its frame messages and the Mac keeps its lights; the logic is shared.
#[cfg_attr(any(windows, target_os = "macos"), allow(dead_code))]
mod caption;
#[cfg(not(target_os = "macos"))]
mod caption_root;
mod cli;
mod crash;
mod drag_pacing;
#[cfg(test)]
mod drag_tests;
mod error_window;
mod export;
mod export_cli;
mod export_scale;
mod fault_inject;
mod files;
#[cfg(test)]
mod first_picture_tests;
#[cfg(unix)]
mod first_run;
mod float_windows;
mod headless;
#[cfg(test)]
mod host_forwarding;
#[cfg(test)]
mod id_tests;
mod image_slots;
mod input;
mod language;
mod latency_log;
mod live_resize;
#[cfg(test)]
mod locate_tests;
mod meter_tap;
#[cfg(test)]
mod open_path_tests;
mod paths;
mod perf;
mod perf_project;
mod play_bench;
mod playback;
mod png;
mod preflight;
mod present_check;
mod present_watch;
mod probe;
mod proxy;
mod proxy_host;
#[cfg(test)]
mod real_window_tests;
mod resize_log;
#[cfg(test)]
mod scrub_color_tests;
#[cfg(test)]
mod shutter_proof_tests;
mod start_failure;
mod start_marker;
mod start_trace;
mod surface;
mod system_watch;
mod use_pass;
mod window_fit;
#[cfg(test)]
mod window_id_tests;

use files::{DesktopFiles, connect_clipboard};
use sq_app_hosts::{MonitorPicture, SOURCE_PICTURE_SLOT};
use sq_app_shell::{App, AppDeps, AppMessage, AppServices, Headless};
use sq_core_time::Timestamp;
use sq_draw::{DrawList, DrawTheme, GlyphAtlas, InputEvent, InputKey};
use sq_editor_session::{EditorSession, ProjectPanelDeps, RefOnlyMediaResolver, SessionDeps, SessionMediaResolving};
use sq_runtime::{Clock, SystemClock, WorkerPool};
use start_failure::{StartCode, StartFailure};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use surface::Surface;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::keyboard::ModifiersState;
use winit::window::{Window, WindowId};

/// Probes (and copies) of one import running at once.
const IMPORT_PROBES: usize = 4;

/// What wakes the loop: a background service that posted to the app's inbox, or the screen-reader adapter.
enum Wake {
    Inbox,
    /// A project file for the running window (`None`: bring the window forward).
    Open(Option<PathBuf>),
    Access(accesskit_winit::Event),
}

impl From<accesskit_winit::Event> for Wake {
    fn from(e: accesskit_winit::Event) -> Wake {
        Wake::Access(e)
    }
}

/// Frame pacing while something animates or plays when the monitor does not tell its refresh rate.
const FRAME: Duration = Duration::from_micros(16_667);

/// One refresh of the display the window is on (120 Hz ProMotion: 8.3 ms), [`FRAME`] when unknown.
fn display_frame(window: &Window) -> Duration {
    window
        .current_monitor()
        .and_then(|m| m.refresh_rate_millihertz())
        .filter(|&mhz| (20_000..=500_000).contains(&mhz))
        .map_or(FRAME, |mhz| Duration::from_nanos(1_000_000_000_000 / u64::from(mhz)))
}

/// The next frame deadline on the display grid that started at `last`: one `frame` after it, or when the loop fell
/// behind, the next grid point after `now` (late ticks are dropped, the phase is kept, no burst of catch-up frames).
fn next_tick(last: Instant, now: Instant, frame: Duration) -> Instant {
    let due = last + frame;
    if due > now {
        return due;
    }
    let behind = now.duration_since(last).as_nanos() / frame.as_nanos().max(1);
    last + frame * (behind as u32 + 1)
}

/// When the loop wakes for the next draw: on the frame grid (`tick`) for the first `MAX_RETRIES` failed attempts, then
/// every `SLOW_RETRY`. It never stops: the draw that missed its drawable may be the one with the first picture.
fn retry_deadline(retries: u8, tick: Instant, now: Instant) -> Instant {
    if retries <= MAX_RETRIES { tick } else { now + SLOW_RETRY }
}

#[cfg(test)]
mod retry_tests {
    use super::*;

    #[test]
    fn a_window_without_a_drawable_is_retried_slowly_but_never_given_up() {
        let (tick, now) = (Instant::now() + Duration::from_millis(8), Instant::now());
        assert_eq!(retry_deadline(0, tick, now), tick, "a fresh failure retries on the next frame");
        assert_eq!(retry_deadline(MAX_RETRIES, tick, now), tick);
        assert_eq!(retry_deadline(MAX_RETRIES + 1, tick, now), now + SLOW_RETRY, "later failures retry slowly");
        assert_eq!(retry_deadline(u8::MAX, tick, now), now + SLOW_RETRY, "and keep doing so");
    }
}

/// Where the bundled fonts live: `SQ_FONTS`, then the package layouts (`sq_text::portable_font_match::discover_fonts_root`), then the source tree.
fn fonts_root() -> PathBuf {
    sq_text::portable_font_match::fonts_root().unwrap_or_else(|| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts")
    })
}

/// A new untitled project in a session without platform services; its state lives under `support`.
#[cfg(test)]
pub(crate) fn untitled_session(support: &Path) -> (EditorSession, MonitorPicture) {
    untitled_session_with(support, playback::WakeSlot::default())
}

fn untitled_session_with(support: &Path, wake: playback::WakeSlot) -> (EditorSession, MonitorPicture) {
    // Random ids: the timeline panel and the hosts mint ids of their own, and a project reopened later must not meet the
    // ids its session hands out (two clips with one id cannot be selected, drawn or edited).
    let mut ids = sq_app_hosts::speech::RandomIds;
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(support.to_path_buf()).with_wall_clock();
    deps.ids = Box::new(ids);
    let media = Arc::new(RefOnlyMediaResolver::new());
    let picture = MonitorPicture::default();
    deps.engine = playback::engine(Arc::clone(&media) as Arc<dyn SessionMediaResolving>, picture.clone(), wake);
    deps.media = media;
    (EditorSession::new(project, deps), picture)
}

/// The session for `project` (an empty one when `None` or when the file cannot be opened; the error is printed).
pub(crate) fn session_for(
    project: Option<&Path>,
    support: &Path,
    wake: playback::WakeSlot,
) -> (EditorSession, MonitorPicture) {
    let (session, picture, _) = session_for_checked(project, support, wake);
    (session, picture)
}

/// [`session_for`] that also says why the project could not be opened (`SQS-404`), so the window can tell the user.
pub(crate) fn session_for_checked(
    project: Option<&Path>,
    support: &Path,
    wake: playback::WakeSlot,
) -> (EditorSession, MonitorPicture, Option<StartFailure>) {
    let slot = Arc::clone(&wake);
    let (mut session, picture) = untitled_session_with(support, wake);
    sq_app_hosts::apply_session_settings(support, &mut session);
    // The proxy service: its workers wake the window loop through the same slot the engines use.
    session.set_auto_proxy(Some(Box::new(proxy_host::ProxyHost::new(
        support,
        Arc::new(move || {
            if let Some(f) = slot.get() {
                f();
            }
        }),
    ))));
    if project.is_some() {
        sq_core_time::milestones::begin("project open begins (command line)");
    }
    let mut failure = None;
    if fault_inject::active(fault_inject::Fault::Project) {
        failure = Some(fault_inject::failure(fault_inject::Fault::Project));
    } else if let Some(path) = project
        && let Err(e) = session.open(path)
    {
        eprintln!("cannot open {}: {e}", path.display());
        failure = Some(StartFailure::new(StartCode::ProjectOpen, "opening the project", e.to_string()).with_path(path));
    }
    (session, picture, failure)
}

/// Puts the editing window (menu bar, panels) into `app` and launches it: an empty untitled session shows the start window.
/// Panel state (dock layout, recent projects, presets) lives in `support`.
pub(crate) fn add_root(
    app: &Headless,
    clock: Arc<SystemClock>,
    theme: DrawTheme,
    support: &Path,
    picture: MonitorPicture,
    page: sq_editor_session::WorkspacePage,
) -> MonitorPicture {
    add_root_with(app, clock, theme, support, picture, page, |root| Box::new(root)).unwrap_or_else(|e| {
        eprintln!("{e}");
        MonitorPicture::default()
    })
}

/// [`add_root`] with the root put into `wrap` first (the Windows window draws its caption around it).
fn add_root_with(
    app: &Headless,
    clock: Arc<SystemClock>,
    theme: DrawTheme,
    support: &Path,
    picture: MonitorPicture,
    page: sq_editor_session::WorkspacePage,
    wrap: impl FnOnce(sq_app_hosts::AppRoot) -> Box<dyn sq_app_shell::AppHost>,
) -> Result<MonitorPicture, StartFailure> {
    // The Source monitor plays on an engine of its own; its frames go to the renderer's image slot.
    let source_picture = picture.sibling();
    let Some(media) = app.with(|a| Arc::clone(a.session().media())) else { return Ok(source_picture) };
    let source_wake = playback::WakeSlot::default();
    playback::connect_wake(&source_wake, app);
    let source_engine = playback::engine(media, source_picture.clone(), source_wake);
    match sq_app_hosts::standard_root_with_source(support, clock, theme, picture, source_engine, source_picture.clone())
    {
        Some(root) => {
            // Conform to Constant Frame Rate probes the new file like an import does.
            let mut root = root.with_conform(Arc::new(|path| {
                use sq_editor_session::ImportBackend;
                probe::FfmpegProbe::default().probe(path).map_err(|e| format!("{e:?}"))
            }));
            // A finished poster decode posts a no-op to the app's inbox: that wakes the loop and marks the frame dirty.
            if let Some(tx) = app.with(|a| a.sender()) {
                let wake = tx.clone();
                root.set_wake(Arc::new(move || wake.send(AppMessage::Post(Box::new(|_| {})))));
                // The local Edit API (off until Preferences > Advanced turns it on) commits through the inbox.
                root = root.with_edit_api(tx, support);
            }
            root.dock.set_page(page);
            root.shell.enable_export(export::setup());
            #[cfg(target_os = "macos")]
            {
                root.shell.shell().menu_bar.use_system_bar();
                root.shell.shell().window_lights = true;
            }
            // shortcut: SQ_SHOT_SYSTEM_BAR=1 makes a PC shot look like the Mac window (the Mac's menu bar is the system's), for pixel parity.
            #[cfg(not(target_os = "macos"))]
            if std::env::var_os("SQ_SHOT_SYSTEM_BAR").is_some() {
                root.shell.shell().menu_bar.use_system_bar();
                root.shell.shell().window_lights = true;
            }
            // Linux draws its own caption buttons like Windows, so Export keeps 146 pt from the edge (spec §14); a shot has
            // no window and shows the spacing without the buttons (the real window wraps the root in `CaptionRoot`).
            #[cfg(not(any(windows, target_os = "macos")))]
            if std::env::var_os("SQ_SHOT_SYSTEM_BAR").is_none() {
                root.set_title_right_margin(caption::export_margin(sq_os::Platform::Linux));
            }
            // One bar on Linux and Windows, as in their real windows (the Windows caption root sets it in `layout`): the
            // start screen's search sits in the app bar, with no extra "Sequence Studio" title row under it.
            #[cfg(not(target_os = "macos"))]
            if shot_search_in_bar(std::env::var_os("SQ_SHOT_SYSTEM_BAR").is_some()) {
                root.shell.shell().start_search_in_bar = true;
            }
            app.with(|a| {
                a.add_host(wrap(root));
                a.launch();
            });
        }
        None => {
            let why = format!("the panels could not start: {} is not usable", support.display());
            return Err(StartFailure::new(StartCode::SupportFolder, "building the panels", why).with_path(support));
        }
    }
    Ok(source_picture)
}

/// Whether a shot (or window) outside the Mac draws the start screen's search in the app bar. Only the Mac-look pose
/// (`SQ_SHOT_SYSTEM_BAR`) keeps the own title row under the system bar.
#[cfg(not(target_os = "macos"))]
fn shot_search_in_bar(system_bar_pose: bool) -> bool {
    !system_bar_pose
}

#[cfg(all(test, not(target_os = "macos")))]
mod shot_bar_tests {
    #[test]
    fn a_shot_draws_the_bar_the_real_window_draws_on_every_platform() {
        assert!(super::shot_search_in_bar(false), "no extra title row in the default shot");
        assert!(!super::shot_search_in_bar(true), "the Mac-look pose keeps its own title row");
    }
}

/// Draw attempts in a row, one per display frame, before a window the system has no drawable for is retried slowly.
const MAX_RETRIES: u8 = 20;
/// The pause between attempts after `MAX_RETRIES`: a window that was slow to get a drawable (a cold start, the first
/// frames of a busy GPU) still shows its picture without any input, and a stuck one does not spin.
const SLOW_RETRY: Duration = Duration::from_millis(250);

/// Everything that exists once the window does.
struct Shell {
    window: Arc<Window>,
    access: accesskit_winit::Adapter,
    surface: Surface,
    picture: MonitorPicture,
    source_picture: MonitorPicture,
    slots: image_slots::ImageSlots,
    app: Headless,
    clock: Arc<SystemClock>,
    pointer: input::Pointer,
    /// Whether a press in the title row starts the window drag (Mac).
    #[cfg(target_os = "macos")]
    title_drag: input::TitleDragGate,
    /// Linux: the window has no system title bar, so the drawn one moves, maximizes and resizes it.
    #[cfg(not(any(windows, target_os = "macos")))]
    controls: caption::WindowControls,
    mods: ModifiersState,
    /// Which Alt keys are down: AltGr versus a Ctrl+Alt chord, and a lone Alt tap (the menu bar).
    alt: input::AltKeys,
    /// The frame drawn by the last turn, shown by the next `RedrawRequested`.
    pending: Option<DrawList>,
    /// Where the open text editor's caret was told to the input method (device px), `None`: input method off.
    ime_area: Option<(i32, i32, u32, u32)>,
    cursor: sq_draw::ui_cx::DrawCursor,
    /// The drawn tool cursors made so far, for `cursor_scale`.
    cursors: std::collections::HashMap<sq_draw::ui_cx::DrawCursor, winit::window::CustomCursor>,
    cursor_scale: f64,
    /// The status line last written to the log.
    status_logged: String,
    perf: perf::FramePerf,
    /// The monitor picture generation the renderer holds.
    uploaded_generation: i64,
    /// The last present found no drawable: the next loop turn draws again.
    retry_draw: bool,
    resize_log: resize_log::ResizeLog,
    /// Pointer events and frames of a drag, for `SQ_LATENCY_LOG` (`latency_log.rs`).
    latency_log: latency_log::LatencyLog,
    /// Whether a drag is on and when the last frame left (`drag_pacing.rs`).
    pacing: drag_pacing::DragPacing,
    /// The newest window size no frame has applied yet (`live_resize.rs`).
    live_resize: live_resize::LiveResize,
    /// What the last `app.turn` took (laying the panels out).
    layout_took: Duration,
    /// Consecutive draws the system was not ready for; after `MAX_RETRIES` the retries slow down to `SLOW_RETRY`.
    retries: u8,
    rate: applog::FrameRate,
    /// One refresh of the window's display and the last frame deadline: animation and playback redraw on that grid.
    display_frame: Duration,
    tick: Instant,
    #[cfg(target_os = "macos")]
    menu: sq_platform_mac::MenuBar,
    /// `App::menu_builds` at the last push to the native menu bar: the bar is pushed only when the shell rebuilt its menus.
    #[cfg(target_os = "macos")]
    menu_builds_pushed: u64,
    indicators: sq_platform::ExportIndicators,
    notifier: Box<dyn sq_platform::notify::Notifier>,
    /// The OS windows of the floating panels (`float_windows.rs`) and the screen their frames are measured on.
    floats: Vec<float_windows::FloatWin>,
    float_screen: Option<float_windows::Screen>,
    /// The first frame reached the screen: from then on a start has worked (the start marker is gone, a panic is a crash).
    first_frame_shown: bool,
    /// A present failed before the first frame: the window never showed the app (`SQS-204`); the handler reads it.
    start_failure: Option<StartFailure>,
    /// Failed presents in a row before the first frame, and when the window opened (`present_watch.rs`).
    present_watch: present_watch::PresentWatch,
    opened: Instant,
}

/// Size and position of the first window on the primary screen (`window_fit`).
fn first_window_rect(el: &ActiveEventLoop) -> ((f64, f64), (i32, i32)) {
    const WANTED: (f64, f64) = (1440.0, 900.0);
    let monitor = el.primary_monitor().or_else(|| el.available_monitors().next());
    let scale = monitor.as_ref().map_or(1.0, |m| m.scale_factor());
    #[cfg(windows)]
    let area =
        sq_platform_win::primary_work_area().map(|(x, y, width, height)| window_fit::WorkArea { x, y, width, height });
    #[cfg(not(windows))]
    let area = monitor.as_ref().map(|m| {
        let (p, s) = (m.position(), m.size());
        window_fit::WorkArea { x: p.x, y: p.y, width: s.width, height: s.height }
    });
    match area {
        Some(area) => window_fit::fit_first_window(WANTED, scale, area),
        None => (WANTED, (0, 0)),
    }
}

impl Shell {
    /// Opens the main window and everything in it. The notices are problems that were worked around (the project could
    /// not be opened); the window is up and the user is told about them. A failure here is a start failure.
    fn open(
        el: &ActiveEventLoop,
        proxy: &EventLoopProxy<Wake>,
        project: Option<&Path>,
    ) -> Result<(Shell, Vec<StartFailure>), StartFailure> {
        if fault_inject::active(fault_inject::Fault::Panic) {
            panic!("{}", fault_inject::PANIC_MESSAGE);
        }
        // Never larger than the primary screen's work area, centered in it (a 1280 x 800 screen showed a 1440 x 900 window).
        let ((width, height), (x, y)) = first_window_rect(el);
        let mut attrs = Window::default_attributes()
            .with_title("Sequence Studio")
            .with_inner_size(LogicalSize::new(width, height))
            .with_position(winit::dpi::PhysicalPosition::new(x, y))
            // The screen-reader adapter must exist before the window is shown.
            .with_visible(false);
        // The real app icon for the title bar and the taskbar (the exe carries it too, see build.rs).
        let (icon_pixels, icon_side) = sq_draw_shell::ShellAppIcon::rgba();
        if let Ok(icon) = winit::window::Icon::from_rgba(icon_pixels.to_vec(), icon_side, icon_side) {
            attrs = attrs.with_window_icon(Some(icon));
        }
        attrs = window_fit::with_min_size(attrs);
        // Windows and Linux draw their own caption (caption_root.rs; Linux: client-side decorations, `caption::WindowControls`). The Mac has
        // no title bar either: the drawn title row runs under the window buttons, which float at its left.
        attrs = attrs.with_decorations(cfg!(target_os = "macos"));
        // Linux: the app id is the desktop entry's id, so the dock and taskbar show the entry's icon and group the windows.
        attrs = sq_platform::app_window::with_app_id(attrs);
        #[cfg(target_os = "macos")]
        {
            use winit::platform::macos::WindowAttributesExtMacOS;
            attrs = attrs.with_titlebar_transparent(true).with_fullsize_content_view(true).with_title_hidden(true);
        }
        let window = Arc::new(
            el.create_window(attrs)
                .map_err(|e| StartFailure::new(StartCode::WindowCreate, "creating the window", e.to_string()))?,
        );
        // Mac: only empty title-row space may drag or zoom the window (`drag_if_title_row`), never a click on a control.
        #[cfg(target_os = "macos")]
        {
            use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
            if let Ok(handle) = window.window_handle()
                && let RawWindowHandle::AppKit(h) = handle.as_raw()
            {
                sq_platform_mac::keep_clicks_out_of_the_titlebar_drag(h.ns_view);
            }
        }
        start_trace::mark("window created");
        // The window stays hidden while the GPU, the project, the fonts and the UI are built (below): Windows puts
        // "(Not Responding)" on a visible window whose message loop does not pump for about 5 s, and a cold start
        // (driver shader cache, first project open) can take longer. It is shown once everything is ready.
        let access = accesskit_winit::Adapter::with_event_loop_proxy(el, &window, proxy.clone());
        let mut surface = Surface::new(&window)?;
        start_trace::mark("GPU surface ready");

        let clock = Arc::new(SystemClock::new());
        let support = paths::app_support_dir();
        let engine_wake = playback::WakeSlot::default();
        // Before the session: its playback thread draws captions at once and needs the fonts.
        sq_text::portable_font_match::set_fonts_root(&fonts_root());
        let (session, picture, project_failure) = session_for_checked(project, &support, Arc::clone(&engine_wake));
        start_trace::mark("project session ready");
        surface.use_choices(picture.view_choices());
        surface::apply_display_view_env(picture.view_choices());

        #[cfg(target_os = "macos")]
        let menu_proxy = proxy.clone();
        let proxy = proxy.clone();
        let task_proxy = proxy.clone();
        let wake_clock: Arc<dyn Clock> = Arc::clone(&clock) as Arc<dyn Clock>;
        let theme = DrawTheme { scale: window.scale_factor() as f32, ..DrawTheme::default() };
        let atlas = GlyphAtlas::ui(&fonts_root());
        if atlas.is_none() {
            // The preflight checks the fonts first; this is the same check for a start that skipped it.
            let why = format!("Inter was not found in {}", fonts_root().display());
            return Err(StartFailure::new(StartCode::FontsMissing, "loading the fonts", why).with_path(&fonts_root()));
        }
        atlas.iter().for_each(|a| a.set_point_scale(theme.scale));
        start_trace::mark("font atlas ready");
        let mut import = ProjectPanelDeps::headless();
        import.backend = Arc::new(probe::FfmpegProbe::default());
        import.pool = Arc::new(WorkerPool::threads(IMPORT_PROBES));
        import.probe_limit = IMPORT_PROBES;
        import.calendar = Rc::new(sq_editor_session::LocalCalendar);
        import.mono = Arc::clone(&clock) as Arc<dyn Clock>;
        import.clock = Rc::new(|| {
            let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
            Timestamp::from_unix_seconds(secs)
        });
        let deps = AppDeps {
            services: AppServices {
                files: Box::new(DesktopFiles),
                panel_files: Box::new(DesktopFiles),
                monitor: None,
                sampler: None,
                magic: None,
            },
            clock: wake_clock,
            atlas,
            theme,
            wake: Box::new(move || {
                let _ = proxy.send_event(Wake::Inbox);
            }),
            import,
        };
        let size = window.inner_size();
        let app = Headless::new(session, deps, i64::from(size.width), i64::from(size.height));
        // A task woken off the loop (a file dialog's answer) must turn the idle loop, not wait for the next input.
        app.executor().set_wake_hook(Arc::new(move || {
            let _ = task_proxy.send_event(Wake::Inbox);
        }));
        playback::connect_wake(&engine_wake, &app);
        app.with(|a| connect_clipboard(a.ui_mut()));
        #[cfg(not(target_os = "macos"))]
        let caption_state = caption::Shared::default();
        #[cfg(not(target_os = "macos"))]
        let wrap = |root| {
            Box::new(caption_root::CaptionRoot::new(root, &window, Arc::clone(&caption_state)))
                as Box<dyn sq_app_shell::AppHost>
        };
        #[cfg(target_os = "macos")]
        let wrap = |root| Box::new(root) as Box<dyn sq_app_shell::AppHost>;
        let source_picture = add_root_with(
            &app,
            Arc::clone(&clock),
            theme,
            &support,
            picture.clone(),
            sq_editor_session::WorkspacePage::Edit,
            wrap,
        )?;

        start_trace::mark("UI built");
        #[cfg(target_os = "macos")]
        let menu = sq_platform_mac::MenuBar::install(move || {
            let _ = menu_proxy.send_event(Wake::Inbox);
        });
        let frame = display_frame(&window);
        crash::connect(&app, &support);
        app.watch_project_folder();
        let indicators = sq_platform::ExportIndicators::new(&window);
        let notifier = sq_platform::notify::system_notifier(&window);
        window.set_visible(true);
        start_trace::mark("window shown");
        let shell = Shell {
            window,
            access,
            surface,
            picture,
            source_picture,
            slots: image_slots::ImageSlots::default(),
            app,
            clock,
            pointer: input::Pointer::awaiting_position(),
            #[cfg(target_os = "macos")]
            title_drag: input::TitleDragGate::default(),
            #[cfg(not(any(windows, target_os = "macos")))]
            controls: caption::WindowControls::new(caption_state),
            mods: ModifiersState::empty(),
            alt: input::AltKeys::default(),
            pending: None,
            ime_area: None,
            cursor: sq_draw::ui_cx::DrawCursor::Arrow,
            cursors: std::collections::HashMap::new(),
            cursor_scale: 0.0,
            status_logged: String::new(),
            perf: perf::FramePerf::new(),
            uploaded_generation: -1,
            retry_draw: false,
            resize_log: resize_log::ResizeLog::default(),
            latency_log: latency_log::LatencyLog::default(),
            pacing: drag_pacing::DragPacing::default(),
            live_resize: live_resize::LiveResize::default(),
            layout_took: Duration::ZERO,
            retries: 0,
            rate: applog::FrameRate::new(),
            display_frame: frame,
            tick: Instant::now(),
            #[cfg(target_os = "macos")]
            menu,
            #[cfg(target_os = "macos")]
            menu_builds_pushed: u64::MAX,
            indicators,
            notifier,
            floats: Vec::new(),
            float_screen: None,
            first_frame_shown: false,
            start_failure: None,
            present_watch: present_watch::PresentWatch::default(),
            opened: Instant::now(),
        };
        Ok((shell, project_failure.into_iter().collect()))
    }

    /// The primary screen in the shell's terms.
    // shortcut: one screen (the primary one) and the main window's scale for every floating window; upgrade with a
    // per-display list in `floating.screens` when a second display matters.
    fn primary_screen(&self, el: &ActiveEventLoop) -> Option<float_windows::Screen> {
        let m = el.primary_monitor().or_else(|| self.window.current_monitor())?;
        let scale = m.scale_factor();
        let size = m.size();
        Some(float_windows::Screen {
            origin: (m.position().x, m.position().y),
            size: (f64::from(size.width) / scale, f64::from(size.height) / scale),
            scale,
        })
    }

    /// Opens, moves and closes the OS windows to match `ShellDock::floating` (Move to Floating Window, Dock, Close, a
    /// zoom, a restored layout).
    fn sync_floats(&mut self, el: &ActiveEventLoop) {
        let Some(screen) = self.primary_screen(el) else {
            // No screen to measure on: no window can open, so the panels go back to the dock instead of staying hidden.
            self.app.with(|a| a.dock_mut().map(sq_draw_shell::ShellDock::dock_all_floating));
            return;
        };
        self.float_screen = Some(screen);
        let (wins, raised) = self
            .app
            .with(|a| {
                a.dock_mut().map(|d| {
                    if d.floating.main_screen_frame != Some(screen.frame()) {
                        d.floating.main_screen_frame = Some(screen.frame());
                        d.floating.screens = vec![screen.frame()];
                        d.fit_floating_to_screens();
                    }
                    (d.floating.windows().to_vec(), d.floating.take_raised())
                })
            })
            .flatten()
            .unwrap_or_default();
        // Maximize Panel on a floating panel brings its window forward (Swift `floating.raise`).
        for p in raised {
            if let Some(f) = self.floats.iter().find(|f| f.panel == p) {
                f.window.focus_window();
            }
        }
        let before = self.floats.iter().map(|f| f.panel).collect::<Vec<_>>();
        self.floats.retain(|f| wins.iter().any(|w| w.panel == f.panel));
        for w in &wins {
            if let Some(f) = self.floats.iter_mut().find(|f| f.panel == w.panel) {
                f.rect = w.rect;
                if w.frame != f.applied {
                    let (pos, _) = screen.os_rect(w.frame);
                    f.window.set_outer_position(winit::dpi::PhysicalPosition::new(pos.0, pos.1));
                    // An applied size may come back without a `Resized` event: the surface follows it here too.
                    if let Some(now) =
                        f.window.request_inner_size(winit::dpi::LogicalSize::new(w.frame.width, w.frame.height))
                    {
                        f.surface.resize(now.width, now.height);
                    }
                    f.applied = w.frame;
                }
                continue;
            }
            match self.open_float(el, w, &screen) {
                Ok(f) => {
                    applog::info(&format!("floating window opened for {:?}", w.panel));
                    self.floats.push(f);
                }
                Err(e) => {
                    // The panel goes back to the dock instead of vanishing.
                    applog::error(&format!("floating window for {:?} failed: {e}", w.panel));
                    let panel = w.panel;
                    self.app.with(|a| a.dock_mut().map(|d| d.dock_back(panel)));
                }
            }
        }
        if before != self.floats.iter().map(|f| f.panel).collect::<Vec<_>>() {
            self.window.request_redraw();
        }
    }

    fn open_float(
        &mut self,
        el: &ActiveEventLoop,
        w: &sq_draw_shell::FloatingWindow,
        screen: &float_windows::Screen,
    ) -> Result<float_windows::FloatWin, String> {
        let (pos, _) = screen.os_rect(w.frame);
        let min = w.panel.min_size();
        #[cfg_attr(not(windows), allow(unused_mut))]
        let mut attrs = Window::default_attributes()
            .with_title(w.title.clone())
            // Logical: Wayland knows the window's scale only after it exists, a physical size would come out `scale` times too big.
            .with_inner_size(winit::dpi::LogicalSize::new(w.frame.width, w.frame.height))
            .with_position(winit::dpi::PhysicalPosition::new(pos.0, pos.1))
            .with_min_inner_size(winit::dpi::LogicalSize::new(min.0, min.1 + sq_draw_shell::ShellFloating::TITLE_BAR))
            // The drawn title row (Dock and Close buttons) is the window's caption.
            .with_decorations(false);
        #[cfg(windows)]
        {
            use winit::platform::windows::WindowAttributesExtWindows;
            attrs = attrs.with_skip_taskbar(true);
        }
        // Owned by the main window: the float stays above it when the main window is clicked (the Swift utility panel).
        attrs = sq_platform::owned_window::owned_by(attrs, &self.window);
        // The same app id as the main window, so the desktop groups the floats under the app's one icon.
        attrs = sq_platform::app_window::with_app_id(attrs);
        let window = Arc::new(el.create_window(attrs).map_err(|e| format!("window: {e}"))?);
        let mut surface = Surface::new(&window).map_err(|e| e.to_string())?;
        surface.use_choices(self.picture.view_choices());
        for (slot, image) in self.slots.all() {
            surface.set_image(slot, image);
        }
        Ok(float_windows::FloatWin {
            panel: w.panel,
            window,
            surface,
            pointer: input::Pointer::awaiting_position(),
            uploaded_generation: -1,
            rect: w.rect,
            applied: w.frame,
        })
    }

    /// Whether `id` is one of the floating windows.
    fn owns_float(&self, id: WindowId) -> bool {
        self.floats.iter().any(|f| f.window.id() == id)
    }

    /// The user moved or resized a floating window: the shell stores the frame (and lays the panel out again).
    fn float_moved(&mut self, i: usize) {
        let Some(screen) = self.float_screen else { return };
        let f = &mut self.floats[i];
        // Wayland never tells a window's position: the size alone still counts (`Screen::frame_after`).
        let pos = f.window.outer_position().ok().map(|p| (p.x, p.y));
        let size = f.window.inner_size();
        let frame = screen.frame_after(pos, (size.width, size.height), f.window.scale_factor(), f.applied);
        if frame == f.applied {
            return;
        }
        f.applied = frame;
        let panel = f.panel;
        self.app.with(|a| a.dock_mut().map(|d| d.set_floating_frame(frame, panel)));
        self.window.request_redraw();
    }

    /// The pointer events of one button change in floating window `i`, each placed on the canvas by the pointer.
    fn float_buttons(&mut self, i: usize, events: Vec<InputEvent>, scale: f64) {
        for e in events {
            // Ask what lies under a press before the shell answers it (a Dock button removes the window).
            let hit = match e {
                InputEvent::MouseDown { x, y, .. } => self
                    .app
                    .with(|a| {
                        a.dock_mut().and_then(|d| {
                            d.floating
                                .hit(sq_uikit::controls_grid::CGPoint::new(f64::from(x) / scale, f64::from(y) / scale))
                        })
                    })
                    .flatten(),
                _ => None,
            };
            self.app.input(&e);
            self.window.request_redraw();
            let drag = match hit {
                Some(sq_draw_shell::FloatingHit::Title(_)) => self.floats[i].window.drag_window().is_ok(),
                Some(sq_draw_shell::FloatingHit::Grip(_)) => {
                    let dir = winit::window::ResizeDirection::SouthEast;
                    self.floats[i].window.drag_resize_window(dir).is_ok()
                }
                _ => false,
            };
            if drag && let Some(up) = self.floats[i].pointer.cancel() {
                // The system owns the mouse until the drag ends and never reports the release.
                self.send(&up);
            }
        }
    }

    /// One event of a floating window: the mouse position is moved by the window's rectangle on the canvas, everything else
    /// is the main window's code.
    fn float_event(&mut self, id: WindowId, event: WindowEvent) {
        let Some(i) = self.floats.iter().position(|f| f.window.id() == id) else { return };
        let scale = self.window.scale_factor();
        let (rect, window_scale) = (self.floats[i].rect, self.floats[i].window.scale_factor());
        let mods = input::modifiers(self.mods);
        match event {
            // The swapchain follows the window (as the main window's `resized`), else the panel draws stretched or freezes.
            WindowEvent::Resized(size) => {
                self.floats[i].surface.resize(size.width, size.height);
                self.float_moved(i);
            }
            WindowEvent::Moved(_) => self.float_moved(i),
            WindowEvent::CloseRequested => {
                let panel = self.floats[i].panel;
                self.app.with(|a| a.dock_mut().map(|d| d.close_floating(panel)));
                self.window.request_redraw();
            }
            WindowEvent::RedrawRequested | WindowEvent::Occluded(false) => self.window.request_redraw(),
            WindowEvent::ModifiersChanged(m) => self.mods = m.state(),
            WindowEvent::KeyboardInput { event, .. } => self.key_event(event),
            WindowEvent::CursorMoved { position, .. } => {
                let (x, y) = float_windows::canvas_point(rect, scale, window_scale, (position.x, position.y));
                let e = self.floats[i].pointer.moved(x, y, mods);
                self.send(&e);
                // Presses that came before this first position land here now.
                for (_, _, events) in self.floats[i].pointer.take_queued() {
                    self.float_buttons(i, events, scale);
                }
            }
            WindowEvent::CursorLeft { .. } => {
                if let Some(e) = self.floats[i].pointer.left() {
                    self.send(&e);
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let events = self.floats[i].pointer.button(state, button, mods);
                self.float_buttons(i, events, scale);
            }
            WindowEvent::MouseWheel { delta, phase, .. } => {
                let now = self.clock.now().as_secs_f64();
                let g = self.floats[i].pointer.wheel(delta, phase, mods, scale as f32, now);
                self.send_gesture(g);
            }
            _ => {}
        }
    }

    fn send(&self, e: &InputEvent) {
        self.app.input(e);
        self.window.request_redraw();
    }

    /// Mac: a press in the drawn title row that nothing took moves the window (there is no system title bar); the
    /// double-click on empty space does what the system setting says (zoom, minimize or nothing).
    fn drag_if_title_row(&mut self, e: &InputEvent, taken: bool) {
        #[cfg(target_os = "macos")]
        if let InputEvent::MouseDown { x, y, .. } = *e {
            use caption::TitleAction;
            let now = self.clock.now().as_secs_f64();
            match self.title_drag.press(x, y, self.window.scale_factor() as f32, taken, now) {
                TitleAction::Drag if self.window.drag_window().is_ok() => {
                    // The system owns the mouse until the drag ends and never reports the release.
                    if let Some(up) = self.pointer.cancel() {
                        self.send(&up);
                    }
                }
                TitleAction::ToggleMaximize => {
                    let setting = sq_platform_mac::title_bar_double_click_setting();
                    match input::DoubleClickAction::from_setting(setting.as_deref()) {
                        input::DoubleClickAction::Zoom => self.window.set_maximized(!self.window.is_maximized()),
                        input::DoubleClickAction::Minimize => self.window.set_minimized(true),
                        input::DoubleClickAction::Nothing => {}
                    }
                }
                TitleAction::Drag | TitleAction::Nothing => {}
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (e, taken);
    }

    /// Linux: a press on the window's edge or corner starts the system resize and stays out of the app. True when it did.
    #[cfg(not(any(windows, target_os = "macos")))]
    fn edge_resize(&mut self, e: &InputEvent) -> bool {
        if let InputEvent::MouseDown { x, y, modifiers } = *e
            && !modifiers.contains(sq_draw::InputModifiers::SECONDARY)
            && let Some(direction) = self.controls.edge_press(x, y)
            && self.window.drag_resize_window(direction).is_ok()
        {
            // The system owns the mouse until the resize ends and never reports the release.
            let _ = self.pointer.cancel();
            return true;
        }
        false
    }

    /// Linux: what a press does to the window once the app has answered it. A primary press on empty bar space moves the
    /// window, the second one maximizes or restores it, a secondary press opens the window manager's window menu, and a
    /// click on the Close button (any event: it fires on the release) asks the app to close.
    #[cfg(not(any(windows, target_os = "macos")))]
    fn caption_press(&mut self, e: &InputEvent, taken: bool) {
        use caption::TitleAction;
        if let InputEvent::MouseDown { x, y, modifiers } = *e {
            let scale = self.window.scale_factor();
            if modifiers.contains(sq_draw::InputModifiers::SECONDARY) {
                if self.controls.is_empty_bar(x, y) {
                    let at = winit::dpi::LogicalPosition::new(f64::from(x) / scale, f64::from(y) / scale);
                    self.window.show_window_menu(at);
                }
            } else {
                match self.controls.title_press(x, y, scale as f32, taken, self.clock.now().as_secs_f64()) {
                    TitleAction::Drag if self.window.drag_window().is_ok() => {
                        // The system owns the mouse until the drag ends and never reports the release.
                        if let Some(up) = self.pointer.cancel() {
                            self.send(&up);
                        }
                    }
                    TitleAction::ToggleMaximize => self.window.set_maximized(!self.window.is_maximized()),
                    TitleAction::Drag | TitleAction::Nothing => {}
                }
            }
        }
        if self.controls.take_close() {
            self.app.with(|a| a.close_requested());
            self.window.request_redraw();
        }
    }

    /// A scroll, pinch or double tap: the gesture rides along with the event for the panels that read it.
    fn send_gesture(&self, (e, g): (InputEvent, sq_draw::scroll::ScrollGesture)) {
        self.app.with(|a| {
            let taken = a.handle_with_gesture(&e, g);
            applog::debug(&format!("scroll {e:?} gesture {g:?} taken {taken}"));
        });
        self.window.request_redraw();
    }

    /// Puts the pointer shape the app asks for on the window: a system cursor, or for the tool shapes (trim, razor,
    /// rotate, ...) a custom cursor drawn from `sq_draw::cursor_glyph` once per shape and scale.
    fn apply_cursor(&mut self, el: &ActiveEventLoop) {
        // Linux: at the window's edge the resize cursor wins over the app's; leaving it brings the app's cursor back.
        #[cfg(not(any(windows, target_os = "macos")))]
        {
            match self.controls.cursor_change() {
                Some(Some(icon)) => self.window.set_cursor(winit::window::Cursor::Icon(icon)),
                Some(None) => self.cursor_scale = 0.0,
                None => {}
            }
            if self.controls.shows_edge_cursor() {
                return;
            }
        }
        let Some(shape) = self.app.with(|a| a.pointer_shape()) else { return };
        let scale = self.window.scale_factor();
        if shape == self.cursor && scale == self.cursor_scale {
            return;
        }
        if scale != self.cursor_scale {
            self.cursors.clear();
            self.cursor_scale = scale;
        }
        self.cursor = shape;
        if shape.has_drawn_glyph() {
            if !self.cursors.contains_key(&shape)
                && let Some(img) = sq_draw::cursor_glyph::render(shape, input::cursor_render_scale(scale as f32))
                && let (img_side, img_hot) = (img.side, img.hot)
                && let Ok(src) = winit::window::CustomCursor::from_rgba(
                    img.rgba,
                    img.side as u16,
                    img.side as u16,
                    img.hot as u16,
                    img.hot as u16,
                )
            {
                // winit's macOS cursor is an NSImage of width x height POINTS with a pixel-for-pixel bitmap: log what it gets.
                applog::info(&format!(
                    "custom cursor {shape:?}: {side}x{side} px image, hotspot {hot} pt, window scale {scale} (Mac shows {side} pt)",
                    side = img_side,
                    hot = img_hot,
                ));
                self.cursors.insert(shape, el.create_custom_cursor(src));
            }
            if let Some(c) = self.cursors.get(&shape) {
                self.window.set_cursor(winit::window::Cursor::Custom(c.clone()));
                return;
            }
        }
        self.window.set_cursor(input::cursor_icon(shape));
    }

    /// Names the phase and the host or task behind a turn that held the UI thread for long (`SQ_START_TRACE`, `SQ_LATENCY_LOG`).
    fn log_if_slow(&self, took: Duration) {
        let times = self.app.last_turn();
        self.app.with(|a| start_trace::slow_turn(took, times, if times.drew { a.frame_profile() } else { &[] }));
    }

    /// One loop turn: inbox, tasks, a frame if the app wants one, the cursor. Returns when to wake next.
    fn turn(&mut self) -> ControlFlow {
        let turn_began = Instant::now();
        self.rate.report();
        if self.perf.autoplay(self.picture.get().is_some()) {
            self.app.with(|a| a.session_mut().play_pause());
        }
        #[cfg(target_os = "macos")]
        self.menu.run_picked();
        self.follow_drag();
        let may_draw = self.pacing.may_draw(Instant::now(), self.display_frame);
        let laid_out = Instant::now();
        let (_, list) = self.app.turn_with(may_draw);
        self.layout_took = laid_out.elapsed();
        self.log_if_slow(self.layout_took);
        self.follow_caret();
        if let Some(status) = self.app.with(|a| a.status_text().to_string())
            && status != self.status_logged
        {
            if !status.is_empty() {
                applog::info(&format!("status: {status}"));
            }
            self.status_logged = status;
        }
        let indicators = &mut self.indicators;
        #[cfg(target_os = "macos")]
        let (menu, pushed) = (&mut self.menu, &mut self.menu_builds_pushed);
        self.app.with(|a| {
            #[cfg(target_os = "macos")]
            if a.menu_builds() != *pushed {
                *pushed = a.menu_builds();
                menu.update(a.menus());
            }
            indicators.set(a.export_progress());
        });
        // An export ended: a notification when the app is in the background (click = show the file).
        if let Some((done, failed)) = self.app.with(App::take_exports_finished).flatten()
            && let Some(note) =
                sq_platform::notify::export_finished(&done, &failed, sq_platform::notify::app_is_active(&self.window))
        {
            self.notifier.post(&note);
        }
        if let Some(list) = list {
            // Draw now: winit/macOS runs the redraws before `about_to_wait`, so a request made here would sit until the
            // next input event (the monitor stayed black after opening a project until the mouse moved).
            self.pending = Some(list);
            if self.live_resize.holds_frame(Instant::now()) {
                // A resize frame waits for `RedrawRequested`, which the system paces; drawing here would commit a frame per step.
                self.window.request_redraw();
            } else {
                self.redraw();
                self.push_access_tree();
            }
        }
        if let Some(on) = self.app.with(App::take_full_screen).flatten() {
            self.window.set_fullscreen(on.then_some(winit::window::Fullscreen::Borderless(None)));
        }
        if let Some(op) = self.app.with(App::take_window_op).flatten() {
            match op {
                sq_draw_shell::WindowOp::Minimize => self.window.set_minimized(true),
                sq_draw_shell::WindowOp::ToggleMaximize => self.window.set_maximized(!self.window.is_maximized()),
            }
        }
        if cfg!(windows) && self.pointer.win_scroll_active() {
            // A touchpad gesture has no end message: wait for it to go quiet.
            let (now, scale) = (self.clock.now().as_secs_f64(), self.window.scale_factor() as f32);
            if let Some(g) = self.pointer.win_idle(input::modifiers(self.mods), scale, now) {
                self.send_gesture(g);
            }
            return ControlFlow::WaitUntil(Instant::now() + self.display_frame);
        }
        let animating = self.app.with(|a| a.needs_redraw()).unwrap_or(false);
        if animating && !may_draw {
            // A drag: the frame waits for its refresh and then draws the newest pointer position.
            return ControlFlow::WaitUntil(self.pacing.due(self.display_frame).unwrap_or_else(Instant::now));
        }
        if animating || std::mem::take(&mut self.retry_draw) {
            self.app.with(App::set_needs_redraw);
            self.tick = next_tick(self.tick, Instant::now(), self.display_frame);
            // The engine's display lead and frame phase lock read these ticks (winit has no present timestamps).
            playback::display_timing().tick(turn_began, self.display_frame, turn_began.elapsed());
            return ControlFlow::WaitUntil(retry_deadline(self.retries, self.tick, Instant::now()));
        }
        match self.app.executor().next_deadline() {
            Some(at) => {
                let now = self.clock.now();
                ControlFlow::WaitUntil(Instant::now() + at.saturating_sub(now))
            }
            None => ControlFlow::Wait,
        }
    }

    /// A held pointer that has moved starts the drag path of the surface and the release ends it; a click never switches and
    /// playback never takes it (its frames stay on the display's beat).
    fn follow_drag(&mut self) {
        let held = self.pointer.is_down().then(|| self.pointer.position());
        let playing = self.app.with(|a| a.session().is_playing()).unwrap_or(false);
        if let Some(on) = self.pacing.update(held, playing) {
            let took = self.surface.set_interactive(on);
            if latency_log::on() {
                eprintln!("latency-surface drag={} reconfigure={:.1}", u8::from(on), took.as_secs_f64() * 1e3);
            }
            self.window.request_redraw();
        }
    }

    fn redraw(&mut self) {
        self.follow_drag();
        if !self.pacing.may_draw(Instant::now(), self.display_frame) && self.live_resize.is_idle() {
            // Too soon after the last frame of a drag: the loop turn draws at the refresh (`turn`).
            self.app.with(App::set_needs_redraw);
            return;
        }
        // The system asked for a frame before the loop turn made one (winit may deliver the request ahead of
        // `about_to_wait`, and on macOS a request made there can wait for the next event): draw on demand, so a drag
        // never shows the previous state.
        if let Some((width, height)) = self.live_resize.take() {
            // The newest size of a resize, applied once for this frame: the surface follows it and the panels lay out for it.
            self.surface.resize(width, height);
            self.app.resize(i64::from(width), i64::from(height));
            self.pending = None;
        }
        if self.pending.is_none() {
            self.app.with(App::set_needs_redraw);
            let laid_out = Instant::now();
            self.pending = self.app.turn().1;
            self.layout_took = laid_out.elapsed();
            self.log_if_slow(self.layout_took);
        }
        let Some(list) = self.pending.take() else { return };
        sq_core_time::milestones::mark("first layout done (display list built)");
        let window = Arc::clone(&self.window);
        let surface = &mut self.surface;
        let began = Instant::now();
        // Upload only a new picture: the renderer keeps the texture, and a 30 fps clip is redrawn at 60 Hz or more.
        let generation = self.picture.generation();
        if generation != self.uploaded_generation {
            self.uploaded_generation = generation;
            surface.set_picture(&self.picture);
            sq_core_time::milestones::mark(if self.picture.size().is_some() {
                "monitor picture given to the renderer"
            } else {
                "monitor cleared in the renderer (no video picture yet)"
            });
        }
        let uploaded = began.elapsed();
        for f in &mut self.floats {
            if f.uploaded_generation != generation {
                f.uploaded_generation = generation;
                f.surface.set_picture(&self.picture);
            }
        }
        surface.set_source_picture(&self.source_picture);
        for f in &mut self.floats {
            f.surface.set_source_picture(&self.source_picture);
        }
        if let Some(img) = self.source_picture.get() {
            surface.set_image(SOURCE_PICTURE_SLOT, &img);
            for f in &mut self.floats {
                f.surface.set_image(SOURCE_PICTURE_SLOT, &img);
            }
        }
        // Posters, source thumbnails and scope pictures the panels made during this frame.
        if let Some(uploads) = self.app.with(App::take_image_uploads) {
            self.slots.apply(uploads);
        }
        for (slot, image) in self.slots.take_dirty() {
            surface.set_image(slot, image);
            for f in &mut self.floats {
                f.surface.set_image(slot, image);
            }
            sq_core_time::milestones::mark(&format!("image slot {slot:?} uploaded (poster/thumbnail/scope)"));
        }
        let slots_done = began.elapsed();
        // Floating panels lie right of the window on the same canvas: each window shows its rectangle, the main window the
        // part it covers (a list wider than the window would be squeezed into it).
        let scale = window.scale_factor() as f32;
        for f in &mut self.floats {
            let (x, y, w, h) = float_windows::canvas_region(f.rect, f64::from(scale));
            let region = sq_draw::Rect::new(x, y, w, h);
            let part = list.region(region);
            let shown = self.app.with(|a| f.surface.present(&f.window, &part, a.atlas()));
            if let Some(Err(e)) = shown {
                eprintln!("floating window draw failed: {e}");
            }
        }
        let inner = window.inner_size();
        let list = if list.width() > inner.width as f32 + 0.5 || list.height() > inner.height as f32 + 0.5 {
            list.region(sq_draw::Rect::new(0.0, 0.0, inner.width as f32, inner.height as f32))
        } else {
            list
        };
        let drawn = self.app.with(|a| surface.present(&window, &list, a.atlas()));
        self.pacing.drew(Instant::now());
        if resize_log::on() {
            self.resize_log.frame(self.layout_took, surface.timing(), matches!(drawn, Some(Ok(true))));
        }
        if latency_log::on() {
            let down = self.pointer.is_down();
            let shape = format!("{:?}", self.app.with(|a| a.pointer_shape()));
            self.latency_log.frame(self.layout_took, surface.timing(), down, matches!(drawn, Some(Ok(true))), &shape);
        }
        // The eyedropper samples the app's own last frame: render it once on the CPU when sampling starts (no screen capture).
        let slots = &self.slots;
        let picture = &self.picture;
        self.app.with(|a| {
            if a.wants_window_frame() {
                let (w, h) = (list.width().ceil() as usize, list.height().ceil() as usize);
                let video = picture.get();
                let sources = sq_draw::Sources { atlas: a.atlas(), video: video.as_deref(), images: slots.images() };
                let clear = sq_draw::Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
                let frame = sq_draw::SoftwareRenderer::render_8bit(&list, w, h, clear, &sources);
                a.set_window_frame(frame);
            }
        });
        if !matches!(drawn, Some(Ok(true))) {
            applog::debug(&format!("redraw {} without a presented frame ({:?})", self.retries, drawn));
        }
        if began.elapsed() > Duration::from_millis(40) {
            applog::debug(&format!(
                "slow redraw: picture {:.0} ms, slots {:.0} ms, present {:.0} ms ({:?})",
                uploaded.as_secs_f64() * 1e3,
                (slots_done - uploaded).as_secs_f64() * 1e3,
                (began.elapsed() - slots_done).as_secs_f64() * 1e3,
                drawn.as_ref().map(|d| d.as_ref().map(|b| *b).map_err(|e| e.clone()))
            ));
        }
        match drawn {
            Some(Err(e)) => {
                eprintln!("draw failed: {e}");
                if !self.first_frame_shown {
                    // An unbroken run of failures that lasts: the window never shows the app. Draw again soon to find
                    // out; the first draws of a cold start can fail before the surface is configured and heal.
                    let verdict = self.present_watch.failed(self.opened.elapsed(), surface.was_configured_at_present());
                    self.retry_draw = !verdict;
                    if verdict && self.start_failure.is_none() {
                        self.start_failure =
                            Some(StartFailure::new(StartCode::GpuPresent, "drawing the first frame", e.clone()));
                    }
                }
            }
            // No drawable yet (window not shown, occluded, resizing): the surface's own request is lost in
            // `about_to_wait`, so the loop wakes itself.
            // Occluded: `WindowEvent::Occluded(false)` redraws; polling a hidden window burned a whole core.
            Some(Ok(false)) if surface.is_occluded() => {
                self.retries = 0;
                self.present_watch.answered();
            }
            Some(Ok(false)) => {
                self.retries = self.retries.saturating_add(1);
                self.retry_draw = true;
                self.present_watch.answered();
            }
            Some(Ok(true)) => {
                self.retries = 0;
                self.present_watch.answered();
                if !self.first_frame_shown {
                    self.first_frame_shown = true;
                    start_marker::clear(&paths::app_support_dir());
                    start_trace::first_frame();
                    sq_media_ffmpeg::encode::warm_up();
                }
                sq_core_time::milestones::mark("first frame presented");
                // The generation also moves for a cleared monitor: the picture itself says whether there is a video picture.
                if self.picture.size().is_some() {
                    sq_core_time::milestones::mark("first presented with a video picture");
                }
                self.rate.drawn();
            }
            _ => {}
        }
        let head = self
            .app
            .with(|a| {
                let t = a.session().playhead();
                t.value() as f64 / t.timescale() as f64
            })
            .unwrap_or(0.0);
        self.perf.frame(uploaded, began.elapsed(), self.picture.generation(), head);
    }

    fn resized(&mut self, width: u32, height: u32) {
        if resize_log::on() {
            self.resize_log.event();
        }
        self.live_resize.event((width, height), Instant::now());
        self.window.request_redraw();
    }

    /// Sends the accessibility tree of the current frame while a screen reader listens.
    fn push_access_tree(&mut self) {
        let app = &self.app;
        self.access.update_if_active(|| {
            let nodes = app.with(|a| a.accessibility(true).take()).unwrap_or_default();
            a11y::tree_update("Sequence Studio", nodes)
        });
    }

    fn window_event(&mut self, event: WindowEvent) {
        self.access.process_event(&self.window, &event);
        match event {
            WindowEvent::Resized(s) => {
                if let Some((w, h)) = window_fit::clamp_to_min((s.width, s.height), self.window.scale_factor()) {
                    let _ = self.window.request_inner_size(winit::dpi::PhysicalSize::new(w, h));
                }
                self.display_frame = display_frame(&self.window);
                self.resized(s.width, s.height)
            }
            WindowEvent::Occluded(false) => {
                self.retries = 0;
                self.window.request_redraw();
            }
            WindowEvent::Moved(_) => {
                self.display_frame = display_frame(&self.window);
                self.surface.probe_display(&self.window);
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                self.surface.probe_display(&self.window);
                let scale = scale_factor as f32;
                applog::info(&format!("scale factor changed: {scale}"));
                self.app.with(|a| a.set_display_scale(scale));
                self.window.request_redraw();
            }
            WindowEvent::RedrawRequested => {
                self.redraw();
                self.push_access_tree();
            }
            WindowEvent::ModifiersChanged(m) => self.mods = m.state(),
            // A drag that loses the window (focus change, pointer left while a button is down) must not stay held.
            WindowEvent::Focused(false) => {
                self.alt.reset();
                self.app.with(|a| a.focus_lost());
                if let Some(e) = self.pointer.cancel() {
                    self.send(&e);
                }
            }
            WindowEvent::Focused(true) => {
                self.app.with(|a| a.focus_gained());
                self.window.request_redraw();
            }
            WindowEvent::DroppedFile(path) => {
                self.app.with(|a| a.drop_files(vec![path]));
                self.window.request_redraw();
            }
            WindowEvent::CursorMoved { position, .. } => {
                if latency_log::on() {
                    self.latency_log.pointer(Instant::now());
                }
                let e = self.pointer.moved(position.x, position.y, input::modifiers(self.mods));
                #[cfg(not(any(windows, target_os = "macos")))]
                self.controls.hover(position.x as f32, position.y as f32, self.pointer.is_down());
                let scale = self.window.scale_factor();
                let taken = self.app.input(&e);
                self.window.request_redraw();
                // A press that came before this first position lands here now, not at (0, 0).
                for (state, button, events) in self.pointer.take_queued() {
                    self.pointer_events(state, button, events);
                }
                applog::debug(&format!(
                    "cursor moved: {:.1},{:.1} pt (device {:.0},{:.0}), scale {scale}, taken {taken}",
                    position.x / scale,
                    position.y / scale,
                    position.x,
                    position.y
                ));
            }
            // No sticky hover: a pointer that left the window clears it (winit 0.30 names no pointer kind; a Mac has no touch).
            WindowEvent::CursorLeft { .. } => {
                #[cfg(not(any(windows, target_os = "macos")))]
                self.controls.left();
                if let Some(e) = self.pointer.left() {
                    self.app.input(&e);
                    self.window.request_redraw();
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                self.alt.other();
                let events = self.pointer.button(state, button, input::modifiers(self.mods));
                self.pointer_events(state, button, events);
            }
            WindowEvent::MouseWheel { delta, phase, .. } => {
                self.alt.other(); // Alt + wheel zooms the timeline, it is no tap
                let now = self.clock.now().as_secs_f64();
                let scale = self.window.scale_factor() as f32;
                let mods = input::modifiers(self.mods);
                let g = if cfg!(windows) {
                    self.pointer.win_wheel(delta, mods, scale, now)
                } else {
                    self.pointer.wheel(delta, phase, mods, scale, now)
                };
                self.send_gesture(g);
            }
            WindowEvent::PinchGesture { delta, phase, .. } => {
                let g = self.pointer.pinch(delta, phase, input::modifiers(self.mods));
                self.send_gesture(g);
            }
            WindowEvent::DoubleTapGesture { .. } => {
                let g = self.pointer.smart_magnify(input::modifiers(self.mods));
                self.send_gesture(g);
            }
            WindowEvent::Ime(ime) => self.ime_event(&ime),
            WindowEvent::KeyboardInput { event, .. } => {
                applog::debug(&input::describe_key_event(&event, self.mods));
                self.key_event(event);
            }
            _ => {}
        }
    }

    /// What a button change of the main window's pointer does: the app takes it, then the window (edge resize, title drag).
    fn pointer_events(
        &mut self,
        state: winit::event::ElementState,
        button: winit::event::MouseButton,
        events: Vec<InputEvent>,
    ) {
        for e in events {
            #[cfg(not(any(windows, target_os = "macos")))]
            if self.edge_resize(&e) {
                continue;
            }
            let taken = self.app.input(&e);
            self.window.request_redraw();
            let scale = self.window.scale_factor();
            let open_rows = self.app.with(|a| a.open_menu_items().len()).unwrap_or(0);
            applog::info(&format!(
                "mouse {state:?} {button:?}: {:?} (scale {scale}, taken by a host {taken}, open menu rows {open_rows})",
                e
            ));
            self.drag_if_title_row(&e, taken);
            #[cfg(not(any(windows, target_os = "macos")))]
            self.caption_press(&e, taken);
        }
    }

    /// An input method event: the composition is drawn inline at the caret, the finished text goes to the focused field.
    fn ime_event(&mut self, ime: &winit::event::Ime) {
        let modifiers = input::modifiers(self.mods);
        match input::ime_action(ime) {
            input::ImeAction::Composition(text) => {
                self.app.with(|a| a.ui_mut().requests.composition = text);
            }
            input::ImeAction::Commit(text) => {
                self.app.with(|a| {
                    a.ui_mut().requests.composition.clear();
                    a.ui_mut().typed_text = Some(text);
                    // A key of no binding carries the text: only the focused text field takes it.
                    a.handle(&InputEvent::KeyDown { key: InputKey::Character('\0'), modifiers });
                    a.ui_mut().typed_text = None;
                });
            }
            input::ImeAction::Nothing => {}
        }
        self.window.request_redraw();
    }

    /// The input method runs only while a text editor is open, and its candidate window sits at that editor's caret.
    fn follow_caret(&mut self) {
        let caret = self.app.with(|a| a.ui_mut().requests.caret).flatten();
        let area = caret.map(|r| (r.x as i32, r.y as i32, (r.w as u32).max(1), (r.h as u32).max(1)));
        if area == self.ime_area {
            return;
        }
        if area.is_some() != self.ime_area.is_some() {
            self.window.set_ime_allowed(area.is_some());
            if area.is_none() {
                self.app.with(|a| a.ui_mut().requests.composition.clear());
            }
        }
        if let Some((x, y, w, h)) = area {
            self.window
                .set_ime_cursor_area(winit::dpi::PhysicalPosition::new(x, y), winit::dpi::PhysicalSize::new(w, h));
        }
        self.ime_area = area;
    }

    fn key_event(&mut self, event: winit::event::KeyEvent) {
        let pressed = event.state.is_pressed();
        if let Some(alt) = input::alt_key_of(&event.logical_key) {
            // An Alt tapped alone focuses the menu bar (Windows, Linux; the Mac has the system menu bar).
            if self.alt.alt_changed(alt, pressed) && sq_os::Platform::current() != sq_os::Platform::Mac {
                self.app.with(|a| a.alt_tapped());
                self.window.request_redraw();
            }
            return;
        }
        self.alt.other();
        let held = input::modifiers(self.mods);
        let Some((key, shift)) = input::event_key(&event, held) else { return };
        if pressed {
            let (key, typed, mods) = input::press_shape(
                sq_os::Platform::current(),
                key,
                event.text.as_deref(),
                input::with_shift(held, shift),
                self.alt.altgr_down(),
            );
            if !event.repeat && input::closes_window(sq_os::Platform::current(), key, mods) {
                self.app.with(|a| a.close_requested());
                self.window.request_redraw();
                return;
            }
            self.app.with(|a| {
                a.ui_mut().key_repeat = event.repeat;
                a.ui_mut().typed_text = typed;
                a.handle(&InputEvent::KeyDown { key, modifiers: mods });
                a.ui_mut().typed_text = None;
                a.ui_mut().key_repeat = false;
            });
        } else {
            self.app.with(|a| a.key_up(key));
        }
        self.window.request_redraw();
    }
}

/// The winit handler: the shell appears with the first `resumed`. A start that fails shows its error window instead
/// (`error_window.rs`), in this same loop: winit allows one event loop per process.
struct Handler {
    proxy: EventLoopProxy<Wake>,
    project: Option<PathBuf>,
    shell: Option<Shell>,
    /// Where the system's open-file requests go (the Mac's Apple Event), taken once the app has finished launching.
    open_requests: Option<std::sync::mpsc::Sender<Option<PathBuf>>>,
    /// Why the start failed, once the user has seen it; the run then ends with a failure so scripts see it.
    failed: Option<String>,
    /// Failures the user has not seen yet: the fatal one of the preflight first, then the notices.
    pending: std::collections::VecDeque<StartFailure>,
    /// The error window that is open and the failure it shows.
    error: Option<(error_window::ErrorWindow, StartFailure)>,
    /// `Try Again` was pressed: `run` starts the app again once this process let go of the single-instance claim.
    relaunch: bool,
    /// Linux: the first-run question (add to the app menu, update the entry) that is open before the Start window.
    #[cfg(unix)]
    first_run: Option<first_run::FirstRun>,
    /// The first-run question was asked (or skipped) once.
    #[cfg(unix)]
    asked: bool,
}

/// The panic the hook saw last, as a start failure.
fn panic_failure() -> StartFailure {
    let (message, place) = crash::last_panic().unwrap_or_else(|| ("unknown panic".into(), "unknown".into()));
    StartFailure::from_panic(&message, &place)
}

impl Handler {
    /// The next step of the start: a failure that waits is shown first, else the main window opens.
    fn advance(&mut self, el: &ActiveEventLoop) {
        if self.error.is_some() || self.has_first_run() {
            return;
        }
        if let Some(failure) = self.pending.pop_front() {
            self.show(el, failure);
        } else if self.shell.is_none() {
            if self.ask_first_run(el) {
                return;
            }
            self.open_shell(el);
        }
    }

    #[cfg(unix)]
    fn has_first_run(&self) -> bool {
        self.first_run.is_some()
    }

    #[cfg(not(unix))]
    fn has_first_run(&self) -> bool {
        false
    }

    /// Linux: opens the first-run question once, before the Start window. True while it is open.
    #[cfg(unix)]
    fn ask_first_run(&mut self, el: &ActiveEventLoop) -> bool {
        if std::mem::replace(&mut self.asked, true) {
            return false;
        }
        self.first_run = first_run::FirstRun::open(el, &fonts_root());
        self.first_run.is_some()
    }

    #[cfg(not(unix))]
    fn ask_first_run(&mut self, _el: &ActiveEventLoop) -> bool {
        false
    }

    /// The first-run window ended: the answer is kept, then the start goes on.
    #[cfg(unix)]
    fn finish_first_run(&mut self, el: &ActiveEventLoop, exit: sq_installer::machine::Exit) {
        if let Some(run) = self.first_run.take() {
            run.finish(exit);
        }
        self.advance(el);
    }

    /// Opens the main window; a failure or a panic in it is a start failure, shown in the error window.
    fn open_shell(&mut self, el: &ActiveEventLoop) {
        // A media file as the argument is imported into the untitled project, never read as a project.
        let media_arg = self.project.clone().filter(|p| {
            sq_core_edit::project_open_routing::open_route(p)
                == sq_core_edit::project_open_routing::ProjectOpenRoute::MediaImport
        });
        let project = self.project.as_deref().filter(|_| media_arg.is_none());
        let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| Shell::open(el, &self.proxy, project)));
        match opened {
            Ok(Ok((shell, notices))) => {
                if let Some(media) = media_arg {
                    shell.app.with(|a| a.drop_files(vec![media]));
                }
                shell.window.request_redraw();
                self.shell = Some(shell);
                self.pending.extend(notices);
                self.advance(el);
            }
            Ok(Err(failure)) => self.show(el, failure),
            Err(_) => self.show(el, panic_failure()),
        }
    }

    /// A failure of the window while it was starting: the half-made window goes, the error window shows why.
    fn fatal(&mut self, el: &ActiveEventLoop, failure: StartFailure) {
        if let Some(shell) = self.shell.take() {
            shell.window.set_visible(false);
            // A shell that failed may fail again while it is dropped.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || drop(shell)));
        }
        self.pending.clear();
        self.show(el, failure);
    }

    /// Writes `failure` to the log and shows it. When not even the error window can open, a native box names the code
    /// and the log (and a fatal failure ends the run).
    fn show(&mut self, el: &ActiveEventLoop, failure: StartFailure) {
        let screen = failure.record();
        if failure.is_fatal() {
            start_marker::clear(&paths::app_support_dir());
        }
        match error_window::ErrorWindow::open(el, screen.clone(), &fonts_root()) {
            Ok(window) => {
                window.focus();
                self.error = Some((window, failure));
            }
            Err(why) => {
                applog::error(&format!("the error window could not open: {why}"));
                error_window::native_message(&failure, screen.log.as_deref());
                if failure.is_fatal() {
                    self.failed = Some(failure.to_string());
                    el.exit();
                    exit_soon(failure.to_string());
                } else {
                    self.advance(el);
                }
            }
        }
    }

    /// The user left the error window.
    fn finish(&mut self, el: &ActiveEventLoop, outcome: error_window::Outcome) {
        let Some((_window, failure)) = self.error.take() else { return };
        match outcome {
            error_window::Outcome::Continue => self.advance(el),
            error_window::Outcome::TryAgain => {
                self.relaunch = true;
                el.exit();
            }
            error_window::Outcome::Close => {
                if failure.is_fatal() {
                    self.failed = Some(failure.to_string());
                }
                el.exit();
            }
        }
    }
}

impl ApplicationHandler<Wake> for Handler {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        let _block = start_trace::block("resumed");
        // After the app finished launching: AppKit installs its own open-document handler before this, ours replaces it.
        if let Some(tx) = self.open_requests.take() {
            sq_platform::install_open_handler(tx);
        }
        if self.shell.is_some() || self.error.is_some() || self.has_first_run() {
            return;
        }
        self.advance(el);
    }

    fn user_event(&mut self, _el: &ActiveEventLoop, wake: Wake) {
        let _block = start_trace::block("user_event");
        if let (Wake::Open(path), Some(shell)) = (&wake, &mut self.shell) {
            shell.window.focus_window();
            if shell.window.is_minimized() == Some(true) {
                shell.window.set_minimized(false);
            }
            if let Some(path) = path {
                shell.app.with(|a| a.emit_flow(sq_draw_shell::ShellFlow::OpenProject(path.clone())));
            }
            shell.window.request_redraw();
        }
        if let (Wake::Access(event), Some(shell)) = (wake, &mut self.shell) {
            match event.window_event {
                accesskit_winit::WindowEvent::InitialTreeRequested => shell.push_access_tree(),
                accesskit_winit::WindowEvent::ActionRequested(request) => {
                    if let Some((id, action)) = a11y::action_of(&request) {
                        shell.app.with(|a| a.accessibility_action(id, action));
                    }
                    shell.window.request_redraw();
                }
                accesskit_winit::WindowEvent::AccessibilityDeactivated => {}
            }
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        let _block = start_trace::block("about_to_wait");
        #[cfg(unix)]
        if let Some(run) = self.first_run.as_mut() {
            match run.wait() {
                (Some(exit), _) => self.finish_first_run(el, exit),
                (None, Some(wake)) => el.set_control_flow(ControlFlow::WaitUntil(wake)),
                (None, None) => el.set_control_flow(ControlFlow::Wait),
            }
            return;
        }
        let Some(shell) = &mut self.shell else { return };
        let step = |shell: &mut Shell| {
            el.set_control_flow(shell.turn());
            shell.apply_cursor(el);
            shell.sync_floats(el);
            shell.app.with(|a| a.quit_requested()).unwrap_or(false)
        };
        // Until the first frame is on screen a panic is a start failure, not a crash of a running app.
        let quit = if shell.first_frame_shown {
            step(shell)
        } else {
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| step(shell))) {
                Ok(quit) => quit,
                Err(_) => {
                    self.fatal(el, panic_failure());
                    return;
                }
            }
        };
        if quit {
            el.exit();
        }
        if let Some(failure) = self.shell.as_mut().and_then(|s| s.start_failure.take()) {
            self.fatal(el, failure);
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        let _block = start_trace::block("window_event");
        #[cfg(unix)]
        if let Some(run) = self.first_run.as_mut()
            && run.id() == id
        {
            if let Some(exit) = run.event(event) {
                self.finish_first_run(el, exit);
            }
            return;
        }
        if let Some((window, _)) = &mut self.error
            && window.id() == id
        {
            if let Some(outcome) = window.event(event) {
                self.finish(el, outcome);
            }
            return;
        }
        if let Some(shell) = &mut self.shell
            && shell.owns_float(id)
        {
            shell.float_event(id, event);
        } else if matches!(event, WindowEvent::CloseRequested) {
            // The title bar's close button, Alt+F4 and the window manager's close take the Save Changes question
            // (Save / Don't Save / Cancel); the loop ends after the answer (`about_to_wait`) and the crash marker goes
            // with the session close. Without a window shell there is nothing to ask.
            match &mut self.shell {
                Some(shell) => {
                    shell.app.with(|a| a.close_requested());
                    shell.window.request_redraw();
                }
                None => el.exit(),
            }
        } else if let Some(shell) = &mut self.shell {
            if shell.first_frame_shown {
                shell.window_event(event);
            } else if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| shell.window_event(event))).is_err() {
                self.fatal(el, panic_failure());
            }
        }
    }
}

/// Reduce motion: the system setting, or `SQ_REDUCE_MOTION=1` (every animation duration becomes 0).
fn reduce_motion_wanted() -> bool {
    if let Some(v) = std::env::var_os("SQ_REDUCE_MOTION") {
        return v != "0";
    }
    #[cfg(target_os = "macos")]
    return sq_platform_mac::reduce_motion();
    #[cfg(windows)]
    return sq_platform_win::reduce_motion();
    #[cfg(not(any(target_os = "macos", windows)))]
    return sq_platform::linux_settings::reduce_motion();
}

/// The keyboard layout the user types with now, asked of the running system (shortcut keys follow it). Every backend
/// answers from a cache: labels ask on every frame.
fn install_keyboard_provider() {
    #[cfg(target_os = "macos")]
    sq_os::keyboard::set_provider(|| {
        let mut positions: Vec<(u16, char)> = sq_uikit::key_character_resolver::PhysicalKeys::codes()
            .iter()
            .filter_map(|(code, key)| match key {
                sq_uikit::key_binding::Key::Char(c) => Some((*code, *c)),
                _ => None,
            })
            .collect();
        positions.sort_unstable();
        sq_platform_mac::active_keyboard(&positions).map(std::sync::Arc::new)
    });
    #[cfg(windows)]
    sq_os::keyboard::set_provider(|| {
        sq_platform_win::cached_active_keyboard(|| {
            let mut positions: Vec<char> = sq_uikit::key_character_resolver::PhysicalKeys::codes()
                .values()
                .filter_map(|key| match key {
                    sq_uikit::key_binding::Key::Char(c) => Some(*c),
                    _ => None,
                })
                .collect();
            positions.sort_unstable();
            positions
        })
    });
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        // The desktop is asked once (it runs gsettings, kreadconfig6, setxkbmap): a layout switch shows after a restart.
        static LAYOUT: std::sync::OnceLock<Option<std::sync::Arc<sq_os::keyboard::ActiveKeyboard>>> =
            std::sync::OnceLock::new();
        fn layout() -> Option<std::sync::Arc<sq_os::keyboard::ActiveKeyboard>> {
            LAYOUT.get_or_init(|| sq_platform::linux_settings::active_keyboard().map(std::sync::Arc::new)).clone()
        }
        sq_os::keyboard::set_provider(layout);
        std::thread::spawn(layout);
    }
}

fn run() -> Result<(), String> {
    start_trace::begin();
    #[cfg(windows)]
    sq_platform_win::attach_parent_console();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cli::Cli { mode, project } = cli::parse(&args)?;
    if !crash::install(&paths::app_support_dir()) {
        let why = format!("the log goes to {} instead", applog::fallback_dir().display());
        StartFailure::new(StartCode::LogFolder, "opening the log folder", why).record();
    }
    sq_export::core::preflight::ExportPreflight::install_host_probes(
        sq_platform::free_bytes,
        sq_platform::physical_memory,
    );
    language::install(&paths::app_support_dir());
    sq_draw_shell::set_log_sink(|is_error, line| if is_error { applog::error(line) } else { applog::info(line) });
    sq_core_time::milestones::set_sink(applog::debug);
    sq_core_time::milestones::set_info_sink(applog::info);
    // Shots and other headless runs draw one frame: no fades, so a dialog is whole in it.
    install_keyboard_provider();
    // Apple Color Emoji sequences (family, flag, keycap) need CoreText; shots and headless runs share this setup.
    #[cfg(target_os = "macos")]
    sq_platform_mac::install_emoji_sequence_shaper();
    // The font menus list the installed families: scan the font folders now, off the UI thread.
    std::thread::spawn(|| drop(sq_text::system_fonts::families()));
    // The export sheet names this computer's video encoder and what it cannot do: ask it once, off the UI thread. A window
    // run asks after its first frame (the probes load GPU drivers and encode test video, which slows the start); shots
    // and headless runs ask now.
    if !matches!(mode, cli::Mode::Window) {
        sq_media_ffmpeg::encode::warm_up();
    }
    sq_draw::motion::set_reduce_motion(reduce_motion_wanted());
    sq_draw::motion::set_snap(!matches!(mode, cli::Mode::Window));
    if !matches!(mode, cli::Mode::Window) {
        // Shots and headless runs never read the user's preferences (watched folders of the Swift app); SQ_REAL_PREFS=1
        // asks for them on purpose.
        if std::env::var_os("SQ_REAL_PREFS").is_none_or(|v| v.is_empty()) {
            sq_app_hosts::isolate_preferences();
        }
        sq_text::portable_font_match::set_fonts_root(&fonts_root());
        return headless::run(&mode, project.as_deref(), &fonts_root());
    }
    let support = paths::app_support_dir();
    let mut pending = std::collections::VecDeque::new();
    // The GPU device takes seconds on a cold driver: open it beside the preflight and the window, not after them.
    std::thread::spawn(|| {
        let _ = surface::shared_gpu();
    });
    let began = Instant::now();
    let preflight = preflight::run(&support, &fonts_root());
    applog::info(&format!("preflight: {:.0} ms", began.elapsed().as_secs_f64() * 1e3));
    start_trace::mark("preflight done");
    pending.extend(preflight.fatal);
    pending.extend(preflight.notices);
    if fault_inject::active(fault_inject::Fault::Display) {
        return no_window(fault_inject::failure(fault_inject::Fault::Display));
    }
    let el = match EventLoop::<Wake>::with_user_event().build() {
        Ok(el) => el,
        Err(e) => {
            // Linux: neither Wayland nor X11 answered; the other systems: the loop itself did not start.
            let code =
                if cfg!(all(unix, not(target_os = "macos"))) { StartCode::NoDisplay } else { StartCode::EventLoop };
            return no_window(StartFailure::new(code, "connecting to the window system", e.to_string()));
        }
    };
    // One window: a second launch (double click on a project, Open With, the command line) hands its file to the running
    // app and exits (Swift: the running app receives the open-file request).
    let (open_tx, open_rx) = std::sync::mpsc::channel();
    let apple_events = open_tx.clone();
    let primary = match sq_platform::instance::claim(&support, project.as_deref(), open_tx) {
        Ok(sq_platform::instance::Claim::Forwarded) => return Ok(()),
        Ok(primary) => Some(primary),
        Err(e) => {
            applog::error(&format!("single instance: {e}"));
            None
        }
    };
    // This process owns the app now: an earlier start that never reached its first frame is told to the user.
    pending.extend(start_marker::begin(&support));
    let _watchers = system_watch::install();
    let proxy = el.create_proxy();
    let relay = proxy.clone();
    std::thread::spawn(move || {
        while let Ok(path) = open_rx.recv() {
            if relay.send_event(Wake::Open(path)).is_err() {
                return;
            }
        }
    });
    let mut handler = Handler {
        proxy,
        project,
        shell: None,
        open_requests: Some(apple_events),
        failed: None,
        pending,
        error: None,
        relaunch: false,
        #[cfg(unix)]
        first_run: None,
        #[cfg(unix)]
        asked: false,
    };
    if let Err(e) = el.run_app(&mut handler) {
        // The loop itself broke: nothing can be shown any more, but the log and the exit code say what happened.
        let failure = StartFailure::new(StartCode::Other, "running the window system", e.to_string());
        failure.record();
        return Err(failure.to_string());
    }
    // Drop the window before the GPU: the surface must not outlive the device (G4 finding).
    let failed = handler.failed.take();
    let relaunch = handler.relaunch;
    drop(handler);
    drop(primary);
    if relaunch {
        start_again();
    }
    window_outcome(failed)
}

/// Ends the process a moment after the loop was told to exit, for a start that has no window to leave through: a window
/// system that could not even make the error window may not finish its loop either. The message is what `main` would print.
fn exit_soon(message: String) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(3));
        eprintln!("{message}");
        std::process::exit(1);
    });
}

/// `Try Again`: starts the app again with the same arguments (the old process has let go of the single-instance claim).
fn start_again() {
    let Ok(exe) = std::env::current_exe() else { return };
    // A harness run that pressed Try Again by itself must not press it again in the new process (no endless restarts).
    let started =
        std::process::Command::new(exe).args(std::env::args_os().skip(1)).env_remove("SQ_FAULT_INJECT_PRESS").spawn();
    if let Err(e) = started {
        applog::error(&format!("try again: the app could not be started: {e}"));
    }
}

/// A start that fails before any window system exists: the failure goes to the log, to a native box when one can open,
/// and to stderr through the returned error (exit code 1).
fn no_window(failure: StartFailure) -> Result<(), String> {
    let screen = failure.record();
    error_window::native_message(&failure, screen.log.as_deref());
    Err(failure.to_string())
}

/// The end of a window run: a window that could not open is a failure (exit code 1), not a quiet exit.
fn window_outcome(failed: Option<String>) -> Result<(), String> {
    failed.map_or(Ok(()), |e| Err(format!("cannot open the window: {e}")))
}

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tick_tests {
    use super::*;

    #[test]
    fn a_window_that_cannot_open_ends_the_run_with_a_failure() {
        assert_eq!(window_outcome(None), Ok(()));
        let err = window_outcome(Some("this display cannot present GPU frames".to_string()));
        assert_eq!(err, Err("cannot open the window: this display cannot present GPU frames".to_string()));
    }

    /// Windows puts "(Not Responding)" on a visible window whose loop does not pump for about 5 s: the shell is shown
    /// only after the GPU, the project, the fonts and the UI are built (`Shell::open`).
    #[test]
    fn the_window_is_shown_after_the_heavy_start_steps() {
        let src = include_str!("main.rs").split("mod tick_tests").next().expect("source");
        let at = |needle: &str| src.find(needle).unwrap_or_else(|| panic!("`{needle}` is gone from Shell::open"));
        let shown = at("window.set_visible(true);");
        for step in ["Surface::new(&window)", "session_for_checked(", "GlyphAtlas::ui(", "add_root_with("] {
            assert!(at(step) < shown, "{step} runs while the window is still hidden");
        }
    }

    #[test]
    fn ticks_keep_the_display_grid_and_drop_late_ones() {
        let (t0, f) = (Instant::now(), Duration::from_millis(10));
        assert_eq!(next_tick(t0, t0 + Duration::from_millis(3), f), t0 + f, "on time: one frame on");
        assert_eq!(next_tick(t0, t0 + Duration::from_millis(25), f), t0 + 3 * f, "late: next grid point, no burst");
        assert_eq!(next_tick(t0, t0 + f, f), t0 + 2 * f, "exactly on a tick: the following one");
    }
}
