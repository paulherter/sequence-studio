//! The windowless test modes: one frame of the app, drawn or dumped, then exit.

use crate::cli::{Mode, Pose};
use crate::image_slots::ImageSlots;
use crate::png;
use sq_app_hosts::MonitorPicture;
use sq_app_shell::{ATLAS_SLOT, AppDeps, Headless};
use sq_core_time::Time;
use sq_draw::{Color, DrawTheme, GlyphAtlas, InputModifiers, SoftwareRenderer, Sources};
use sq_editor_session::WorkspacePage;
use sq_runtime::{Clock, SystemClock};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use winit::dpi::PhysicalPosition;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, TouchPhase};

pub(crate) fn build(
    width: u32,
    height: u32,
    scale: f32,
    project: Option<&Path>,
    fonts: &Path,
) -> (Headless, MonitorPicture) {
    build_in(&std::env::temp_dir().join("sequence-studio"), width, height, scale, project, fonts)
}

/// [`build`] with the settings, workspaces and recents read from `support`.
pub(crate) fn build_in(
    support: &Path,
    width: u32,
    height: u32,
    scale: f32,
    project: Option<&Path>,
    fonts: &Path,
) -> (Headless, MonitorPicture) {
    build_on(support, width, height, scale, project, fonts, sq_editor_session::WorkspacePage::Edit, false)
}

#[allow(clippy::too_many_arguments)] // shortcut: test-only builder, a settings struct when a ninth argument comes
pub(crate) fn build_on(
    support: &Path,
    width: u32,
    height: u32,
    scale: f32,
    project: Option<&Path>,
    fonts: &Path,
    page: sq_editor_session::WorkspacePage,
    tour: bool,
) -> (Headless, MonitorPicture) {
    let atlas = GlyphAtlas::ui(fonts);
    if atlas.is_none() {
        eprintln!("Inter not found in {}: text will not draw", fonts.display());
    }
    atlas.iter().for_each(|a| a.set_point_scale(scale));
    let clock = Arc::new(SystemClock::new());
    let mut deps = AppDeps::headless(Arc::clone(&clock) as Arc<dyn Clock>);
    deps.atlas = atlas;
    deps.theme = DrawTheme { scale, ..DrawTheme::default() };
    // The window's own import wiring, so an `import:` step probes a real file like a drop on the window does.
    deps.import.backend = Arc::new(crate::probe::FfmpegProbe::in_support(support));
    deps.import.pool = Arc::new(sq_runtime::WorkerPool::threads(crate::IMPORT_PROBES));
    deps.import.probe_limit = crate::IMPORT_PROBES;
    let theme = deps.theme;
    // A shot or export never writes into the user's projects folder (template cards and Create make real folders). The
    // shell suggests the stored folder (`ShellHost::new_project_start_folder`), so this one setting is all it takes;
    // `RealFolders` checks it held.
    sq_app_hosts::use_projects_folder(support, &support.join("Projects"));
    if !tour {
        sq_app_hosts::mark_welcome_seen(support);
    }
    // shortcut: SQ_SHOT_LIBRARY=<folder> is a shot-only switch that puts a folder of test media into the Library.
    if let Some(folder) = std::env::var_os("SQ_SHOT_LIBRARY") {
        sq_app_hosts::watch_library_folder(support, Path::new(&folder));
    }
    // shortcut: SQ_SHOT_THEME=light is a shot-only switch (not a CLI flag); the app reads its Appearance from Preferences.
    if std::env::var("SQ_SHOT_THEME").as_deref() == Ok("light") {
        let light = sq_uikit::appearance_palette::AppearanceSettings::new(
            sq_uikit::appearance_palette::AppearanceMode::Light,
            0,
            50,
        );
        sq_app_hosts::store_appearance(support, &light);
    } // no tour dialog over the first click
    let wake = crate::playback::WakeSlot::default();
    let (session, picture) = crate::session_for(project, support, Arc::clone(&wake));
    let app = Headless::new(session, deps, i64::from(width), i64::from(height));
    crate::playback::connect_wake(&wake, &app);
    crate::add_root(&app, clock, theme, support, picture.clone(), page);
    (app, picture)
}

/// The one guard of every offscreen mode (`--ui-shot` with clicks, keys, poses and steps, `--use-pass`, the dumps and
/// benches): the real default Projects folder a run must never write into. `build_on` points the app at a Projects
/// folder of its own; this notes what the real folder held before the run and fails the run, loudly, when it holds
/// anything else afterwards (a `click` + `key:enter` through New Project once made a folder under `~/Movies`).
pub(crate) struct RealFolders {
    root: PathBuf,
    before: Option<BTreeSet<OsString>>,
}

impl RealFolders {
    /// Watches the real default Projects folder.
    pub(crate) fn watch() -> Self {
        Self::watching(sq_editor_session::StorageLocations::default().projects_root())
    }

    fn watching(root: PathBuf) -> Self {
        let before = Self::listing(&root);
        RealFolders { root, before }
    }

    /// The names inside `root`; `None` while the folder does not exist.
    fn listing(root: &Path) -> Option<BTreeSet<OsString>> {
        std::fs::read_dir(root).ok().map(|entries| entries.flatten().map(|e| e.file_name()).collect())
    }

    /// `Err` naming what the run added to the real folder (the folder itself when it did not exist before).
    pub(crate) fn verify(&self) -> Result<(), String> {
        let after = Self::listing(&self.root);
        if after == self.before {
            return Ok(());
        }
        let before = self.before.clone().unwrap_or_default();
        let added: Vec<String> =
            after.unwrap_or_default().difference(&before).map(|n| n.to_string_lossy().into_owned()).collect();
        Err(format!("offscreen run changed the real folder {} (new: {added:?})", self.root.display()))
    }
}

/// One text line per node: `role<TAB>label`, in draw order.
pub fn a11y_lines(nodes: &[(accesskit::NodeId, accesskit::Node)]) -> String {
    nodes.iter().map(|(_, n)| format!("{:?}\t{}\n", n.role(), n.label().unwrap_or(""))).collect()
}

/// A project with media shows its first frame and its poster frames only after the workers decoded them: turn the loop
/// (drawing frames, so the panels collect their pictures) until the first frame is there and no poster arrived for a
/// while (a 3 GB clip takes about a second per poster, and the timeline tiles come after the first one).
fn wait_for_picture(app: &Headless, picture: &MonitorPicture, slots: &mut ImageSlots, w: i64, h: i64) {
    const QUIET: Duration = Duration::from_millis(2500);
    let has_media = app.with(|a| !a.session().project().media.is_empty()).unwrap_or(false);
    // A playhead in a gap (a first clip that starts after zero) leaves the monitor black on purpose and nothing opens: do not
    // wait 20 s for a picture that cannot come, and say so, so a black shot is not read as a failed open.
    let picture_expected = app.with(|a| video_at_playhead(a.session())).unwrap_or(true);
    if has_media && !picture_expected {
        eprintln!("shot: no video clip under the playhead, the monitor is black on purpose");
    }
    let end = Instant::now() + Duration::from_secs(20);
    let mut last_poster = Instant::now();
    while has_media && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(20));
        app.turn();
        app.with(|a| {
            a.frame(w, h);
            let uploads = a.take_image_uploads();
            if uploads.iter().any(|u| u.slot == ATLAS_SLOT) {
                last_poster = Instant::now();
            }
            slots.apply(uploads);
        });
        let posters = slots.images().get(ATLAS_SLOT).is_some_and(Option::is_some);
        if (picture.get().is_some() || !picture_expected) && posters && last_poster.elapsed() > QUIET {
            break;
        }
    }
}

/// True when an enabled clip of a video track covers the session's playhead (a nested sequence and a generator count).
fn video_at_playhead(session: &sq_editor_session::EditorSession) -> bool {
    let Some(timeline) = session.active_timeline() else { return false };
    let at = session.playhead();
    timeline
        .tracks
        .iter()
        .filter(|t| t.kind == sq_core_model::TrackKind::Video)
        .flat_map(|t| t.clips())
        .any(|c| c.is_enabled && c.timeline().contains(at))
}

/// Moves the playhead to `playhead_ms` and turns the loop until the monitor picture for it is composed: a new picture
/// arrived and no further one followed for a moment (a stand-in is replaced by the exact frame a little later).
fn wait_for_playhead(
    app: &Headless,
    picture: &MonitorPicture,
    slots: &mut ImageSlots,
    playhead_ms: i64,
    w: i64,
    h: i64,
) {
    let before = picture.generation();
    app.with(|a| a.session_mut().seek(Time::new(playhead_ms, 1000)));
    let end = Instant::now() + Duration::from_secs(10);
    let (mut last, mut changed) = (before, Instant::now());
    while Instant::now() < end {
        std::thread::sleep(Duration::from_millis(20));
        app.turn();
        app.with(|a| {
            a.frame(w, h);
            slots.apply(a.take_image_uploads());
        });
        if picture.generation() != last {
            last = picture.generation();
            changed = Instant::now();
        }
        if last != before && changed.elapsed() > Duration::from_millis(300) {
            break;
        }
    }
}

/// Selects the clip at index `which` (track order) or the first clip named `which` on the active timeline.
pub(crate) fn select_clip(session: &mut sq_editor_session::EditorSession, which: &str) {
    let Some(timeline) = session.active_timeline() else { return };
    let clips = timeline.tracks.iter().flat_map(|t| t.clips());
    let id = match which.parse::<usize>() {
        Ok(i) => clips.clone().nth(i).map(|c| c.id),
        Err(_) => clips.clone().find(|c| c.name == which).map(|c| c.id),
    };
    match id {
        // `select`, as a click does: it also ends Selection Follows Playhead (Swift SharedUIShot: `session.select`).
        Some(id) => session.select_with_partners(std::iter::once(id).collect()),
        None => eprintln!("--select: no clip {which}"),
    }
}

/// The poses a shot runs: the ones asked for, or `focus-timeline` for the plain Editor shot, which is posed like the
/// design frames (the Timeline has the focus frame). Any click, key, menu, tour or the Color page is not plain.
pub(crate) fn shot_poses(pose: &Pose) -> Vec<String> {
    let plain = pose.poses.is_empty()
        && !pose.color_page
        && pose.clicks.is_empty()
        && pose.right_clicks.is_empty()
        && pose.keys.is_empty()
        && pose.steps.is_empty()
        && pose.lone_modifiers.is_empty()
        && pose.menu.is_none()
        && !pose.menu_grid
        && !pose.tour;
    if plain { vec![String::from("focus-timeline")] } else { pose.poses.clone() }
}

/// `--menu <title>`: opens that menu-bar menu; `--menu all` opens none and writes every menu as `<stem>-<slug>.txt`
/// (Swift `shared-menu-bar-<slug>.txt`).
fn write_bar_outlines(app: &Headless, pose: &Pose, title: &str) {
    if title != "all" {
        if !app.with(|a| a.open_bar_menu(title)).unwrap_or(false) {
            eprintln!("--menu: no menu {title}");
        }
        return;
    }
    let Some(png) = &pose.outline_beside else { return };
    let menus: Vec<(String, String)> = app
        .with(|a| {
            a.menus().iter().map(|m| (m.title.clone(), sq_uikit::menu_outline::menu_outline(&m.items, 0))).collect()
        })
        .unwrap_or_default();
    let stem = png.file_stem().and_then(|s| s.to_str()).unwrap_or("shot");
    for (title, text) in menus {
        let slug: String = title.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
        let slug = slug.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
        let _ = std::fs::write(png.with_file_name(format!("{stem}-{slug}.txt")), text);
    }
}

/// `--menu-grid`: a right press at every point of a 32 x 20 grid; each distinct menu (by its text) is written once.
fn menu_grid(app: &Headless, pose: &Pose, size: (u32, u32), scale: f32) {
    let Some(png) = &pose.outline_beside else { return };
    let stem = png.file_stem().and_then(|s| s.to_str()).unwrap_or("shot");
    let mut seen = std::collections::HashSet::new();
    let escape = sq_draw::InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: Default::default() };
    for gy in 0..20 {
        for gx in 0..32 {
            let (x, y) =
                (size.0 as f32 * (gx as f32 + 0.5) / 32.0, 50.0 + (size.1 as f32 - 80.0) * (gy as f32 + 0.5) / 20.0);
            app.input(&sq_draw::InputEvent::MouseDown {
                x: x * scale,
                y: y * scale,
                modifiers: sq_draw::InputModifiers::SECONDARY,
            });
            app.turn();
            let items = app.with(|a| a.open_menu_items()).unwrap_or_default();
            if !items.is_empty() {
                let text = sq_uikit::menu_outline::menu_outline(&items, 0);
                if seen.insert(text.clone()) {
                    // As the Swift sweep (`shared-menu-<panel>-<n>-<first row>.txt`): the first row's slug is in the name,
                    // `scripts/menu-pair.py` pairs the two sets by it; the probe point stays for the Rust side.
                    let first =
                        text.lines().next().unwrap_or("").split("  [").next().unwrap_or("").trim().to_lowercase();
                    let slug = first
                        .split(|c: char| !c.is_alphanumeric())
                        .filter(|w| !w.is_empty())
                        .collect::<Vec<_>>()
                        .join("-");
                    let name = format!("{stem}-{}-{slug}-{}x{}.txt", seen.len(), x as i32, y as i32);
                    let _ = std::fs::write(png.with_file_name(name), text);
                }
            }
            app.input(&escape);
            app.turn();
        }
    }
}

/// One frame of the app at `width` x `height` points: the picture and the image slots it was drawn with.
/// Keeps the app drawing for `ms`: async loads (posters, thumbnails, probes) arrive and their images reach `slots`.
fn pump(app: &Headless, slots: &mut ImageSlots, ms: u64, (w, h): (i64, i64)) {
    let end = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < end {
        std::thread::sleep(Duration::from_millis(20));
        app.turn();
        app.with(|a| {
            a.frame(w, h);
            slots.apply(a.take_image_uploads());
        });
    }
}

/// The points one wheel line moves a trackpad swipe of a `wheel:` step with `pad`.
const NOTCH_PIXELS: f32 = 40.0;

/// The time between two moves of a `drag:` step, about one frame at 60 Hz.
const DRAG_STEP_MS: u64 = 16;

/// How long an `import:` step waits for the dropped file to show up in the project.
const IMPORT_WAIT: Duration = Duration::from_secs(10);

/// The title of the dialog that is open, if any. A dialog is modal as in the window: it takes every key and no shortcut
/// (Save, Export) runs behind it until it is answered, so a script that does not know one is up proves the wrong thing.
fn open_dialog(app: &Headless, (w, h): (i64, i64)) -> Option<String> {
    app.with(|a| {
        a.frame(w, h);
        let nodes = a.accessibility(true).take();
        nodes
            .iter()
            .find(|(_, n)| n.role() == accesskit::Role::Dialog)
            .map(|(_, n)| n.label().unwrap_or("").to_string())
    })
    .flatten()
}

/// One `--step` on the layout the step before it produced; points are in points, `scale` makes them pixels.
fn run_step(
    app: &Headless,
    step: &crate::cli::Step,
    scale: f32,
    size: (i64, i64),
    slots: &mut ImageSlots,
) -> Result<(), String> {
    use sq_draw::InputEvent;
    app.with(|a| a.frame(size.0, size.1));
    match step {
        crate::cli::Step::Click(x, y) => {
            let (x, y) = (x * scale, y * scale);
            app.input(&InputEvent::MouseDown { x, y, modifiers: Default::default() });
            app.input(&InputEvent::MouseUp { x, y });
        }
        crate::cli::Step::Hover(x, y) => {
            app.input(&InputEvent::MouseMoved { x: x * scale, y: y * scale });
            app.with(|a| a.frame(size.0, size.1));
        }
        crate::cli::Step::Key(key, modifiers) => {
            // Loud, not a silent no-op: a menu shortcut never runs behind an open question (cmd+s after a drop that asked
            // "Copy, Move or Leave" saved nothing).
            if let (true, Some(title)) = (key.is_menu_chord(*modifiers), open_dialog(app, size)) {
                eprintln!(
                    "--step key: the dialog \"{title}\" is open and takes the shortcut; answer it first (key:enter picks its default button)"
                );
            }
            app.input(&InputEvent::KeyDown { key: *key, modifiers: *modifiers });
        }
        crate::cli::Step::Type(text) => {
            for ch in text.chars() {
                // As the window's text input does: the key carries the text only the focused field takes.
                app.with(|a| a.ui_mut().typed_text = Some(ch.to_string()));
                app.input(&InputEvent::KeyDown {
                    key: sq_draw::InputKey::Character(ch),
                    modifiers: Default::default(),
                });
                app.with(|a| a.ui_mut().typed_text = None);
            }
        }
        crate::cli::Step::Select(which) => app.with(|a| select_clip(a.session_mut(), which)).unwrap_or_default(),
        crate::cli::Step::Wait(ms) => pump(app, slots, *ms, size),
        crate::cli::Step::Drag { from, to, ms } => {
            // The window's own pointer turns moves and the button into events, so a drag here takes the road a real one does.
            let mut pointer = sq_draw::pointer::Pointer::default();
            let none = InputModifiers::NONE;
            let device = |(x, y): (f32, f32)| (f64::from(x * scale), f64::from(y * scale));
            let (x1, y1) = device(*from);
            let (x2, y2) = device(*to);
            app.input(&pointer.moved(x1, y1, none));
            for e in pointer.button(ElementState::Pressed, MouseButton::Left, none) {
                app.input(&e);
            }
            pump(app, slots, DRAG_STEP_MS, size);
            let steps = (*ms / DRAG_STEP_MS).max(1);
            for i in 1..=steps {
                let t = i as f64 / steps as f64;
                app.input(&pointer.moved(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, none));
                pump(app, slots, DRAG_STEP_MS, size);
            }
            for e in pointer.button(ElementState::Released, MouseButton::Left, none) {
                app.input(&e);
            }
            pump(app, slots, DRAG_STEP_MS, size);
        }
        crate::cli::Step::Wheel { at, dy, dx, pad } => {
            let mut pointer = sq_draw::pointer::Pointer::default();
            let none = InputModifiers::NONE;
            app.input(&pointer.moved(f64::from(at.0 * scale), f64::from(at.1 * scale), none));
            // The step reads like a scroll position (negative = up); winit's delta says where the content goes (down = up).
            let (lines_x, lines_y) = (-dx, -dy);
            let mut send = |delta, phase| {
                let g = pointer.wheel(delta, phase, none, scale, 0.0);
                app.with(|a| a.handle_with_gesture(&g.0, g.1));
            };
            if *pad {
                // A trackpad: the fingers move and lift, so a pull past the end springs back and needs only frames.
                let pixels = |lines: f32| f64::from(lines * NOTCH_PIXELS * scale);
                let swipe = PhysicalPosition::new(pixels(lines_x), pixels(lines_y));
                send(MouseScrollDelta::PixelDelta(swipe), TouchPhase::Started);
                send(MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, 0.0)), TouchPhase::Ended);
            } else {
                send(MouseScrollDelta::LineDelta(lines_x, lines_y), TouchPhase::Moved);
            }
            pump(app, slots, DRAG_STEP_MS, size);
        }
        crate::cli::Step::Flick { at, dy, frames, until_ms, move_to, win } => {
            // The same event lists the tests replay, through the window's own Pointer and handler, with the real clock so the
            // momentum gap, the velocity window and the idle end behave as in the window. `win` is the Windows route:
            // phase-less wheel messages (`Pointer::win_wheel`) and `win_idle` once per turn, the calls main.rs makes.
            let mut pointer = sq_draw::pointer::Pointer::default();
            let none = InputModifiers::NONE;
            let device = |(x, y): (f32, f32)| (f64::from(x * scale), f64::from(y * scale));
            let (px, py) = device(*at);
            app.input(&pointer.moved(px, py, none));
            let lines = f64::from(-dy);
            let total = f64::from(-dy * NOTCH_PIXELS * scale);
            // (time, phase, pixels or lines) of every message, and where the momentum tail begins.
            let (events, tail): (Vec<(f64, TouchPhase, f64)>, usize) = if *win {
                let e = sq_draw::pointer::win_flick_events(lines, *frames);
                (
                    e.into_iter().map(|(t, l)| (t, TouchPhase::Moved, l)).collect(),
                    sq_draw::pointer::win_flick_tail_start(*frames),
                )
            } else {
                let e = sq_draw::pointer::flick_events(total, *frames);
                (
                    e.into_iter().map(|e| (e.at, e.phase, e.pixels)).collect(),
                    sq_draw::pointer::flick_tail_start(*frames),
                )
            };
            let start = Instant::now();
            let idle = |app: &Headless, pointer: &mut sq_draw::pointer::Pointer| {
                if *win && let Some(g) = pointer.win_idle(none, scale, start.elapsed().as_secs_f64()) {
                    app.with(|a| a.handle_with_gesture(&g.0, g.1));
                }
            };
            for (i, (t, phase, amount)) in events.into_iter().enumerate() {
                let due = start + Duration::from_secs_f64(t);
                if until_ms.is_some_and(|ms| t * 1000.0 > ms as f64) {
                    break;
                }
                while Instant::now() < due {
                    pump(app, slots, DRAG_STEP_MS.min((due - Instant::now()).as_millis() as u64 + 1), size);
                    idle(app, &mut pointer);
                }
                if let Some(m) = move_to.filter(|m| tail + m.tail_frame == i) {
                    // As the window's cursor-moved handler does: the Pointer turns the move into an event.
                    let (x, y) = device(m.to);
                    app.input(&pointer.moved(x, y, none));
                }
                let g = if *win {
                    let delta = MouseScrollDelta::LineDelta(0.0, amount as f32);
                    pointer.win_wheel(delta, none, scale, start.elapsed().as_secs_f64())
                } else {
                    let delta = MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, amount));
                    pointer.wheel(delta, phase, none, scale, start.elapsed().as_secs_f64())
                };
                app.with(|a| a.handle_with_gesture(&g.0, g.1));
            }
            if let Some(ms) = until_ms {
                let end = start + Duration::from_millis(*ms);
                while Instant::now() < end {
                    pump(app, slots, 10, size);
                    idle(app, &mut pointer);
                }
            }
        }
        crate::cli::Step::Import(file) => {
            // Loud, not a silent shot of the wrong screen: a path that is not there fails the run.
            if !file.exists() {
                return Err(format!("--step import:{}: no such file", file.display()));
            }
            let media = |app: &Headless| app.with(|a| a.session().project().media.len()).unwrap_or_default();
            let before = media(app);
            app.with(|a| a.drop_files(vec![file.clone()]));
            let end = Instant::now() + IMPORT_WAIT;
            while media(app) == before && Instant::now() < end {
                pump(app, slots, 20, size);
            }
            if media(app) == before {
                eprintln!("--step import:{}: nothing arrived in the project within {:?}", file.display(), IMPORT_WAIT);
            } else {
                // The question about files outside the project folder comes right after the clip lands.
                pump(app, slots, 100, size);
                if let Some(title) = open_dialog(app, size) {
                    eprintln!(
                        "--step import:{}: the dialog \"{title}\" is open (key:enter picks its default button)",
                        file.display()
                    );
                }
            }
        }
    }
    app.turn();
    Ok(())
}

fn shoot(
    width: u32,
    height: u32,
    scale: f32,
    playhead_ms: i64,
    pose: &Pose,
    project: Option<&Path>,
    fonts: &Path,
) -> Result<(sq_draw::RgbaImage, ImageSlots), String> {
    let (w, h) = ((width as f32 * scale) as usize, (height as f32 * scale) as usize);
    // A support folder of its own: a leftover autosave of an earlier run would put the "Recover" dialog over the shot.
    let support = std::env::temp_dir().join(format!("sequence-studio-shot-{}", std::process::id()));
    let page = if pose.color_page { WorkspacePage::Color } else { WorkspacePage::Edit };
    let (app, picture) = build_on(&support, w as u32, h as u32, scale, project, fonts, page, pose.tour);
    if let Some(which) = &pose.select {
        app.with(|a| select_clip(a.session_mut(), which));
    }
    if !pose.clicks.is_empty() {
        // Layout happens while drawing: the hosts have no frames before the first one.
        app.with(|a| a.frame(w as i64, h as i64));
    }
    for &(x, y) in &pose.clicks {
        // Each click lands on the layout the one before it produced (Simple -> Pro -> "Start from Simple grade").
        app.with(|a| a.frame(w as i64, h as i64));
        let (x, y) = (x * scale, y * scale);
        let down = sq_draw::InputEvent::MouseDown { x, y, modifiers: Default::default() };
        app.input(&down);
        app.input(&sq_draw::InputEvent::MouseUp { x, y });
        app.turn();
    }
    // A sequence tab switch (a click above) clears the selection: select again once the clicks are done (the Swift shot
    // harness selects after it opened the tabs).
    if let (Some(which), false) = (&pose.select, pose.clicks.is_empty()) {
        app.with(|a| select_clip(a.session_mut(), which));
    }
    for &(x, y) in &pose.right_clicks {
        app.with(|a| a.frame(w as i64, h as i64));
        // The press only: the menu stays open (Swift `SharedUIShot.menuSweep` probes the same way).
        let down = sq_draw::InputEvent::MouseDown {
            x: x * scale,
            y: y * scale,
            modifiers: sq_draw::InputModifiers::SECONDARY,
        };
        app.input(&down);
        app.turn();
    }
    // The playhead goes first, so Step, Go to and edit-point keys start from where it was asked to be; `--focus` picks the panel
    // a panel-scoped chord belongs to.
    let mut slots = ImageSlots::default();
    if playhead_ms > 0 && !pose.keys.is_empty() {
        app.with(|a| a.frame(w as i64, h as i64));
        wait_for_playhead(&app, &picture, &mut slots, playhead_ms, w as i64, h as i64);
    }
    if let Some(panel) = pose.focus {
        app.with(|a| a.frame(w as i64, h as i64));
        app.with(|a| a.dock_mut().map(|d| d.set_focused(Some(panel))));
        app.turn();
    }
    for &(key, modifiers) in &pose.keys {
        app.with(|a| a.frame(w as i64, h as i64));
        app.input(&sq_draw::InputEvent::KeyDown { key, modifiers });
        app.turn();
    }
    for m in &pose.lone_modifiers {
        app.with(|a| a.frame(w as i64, h as i64));
        // Press and release of a modifier alone: only Alt has a meaning (the menu bar's key, as the window reports it).
        if *m == crate::cli::LoneModifier::Alt {
            app.with(|a| a.alt_tapped());
        }
        app.turn();
    }
    if pose.menu_grid {
        app.with(|a| a.frame(w as i64, h as i64));
        menu_grid(&app, pose, (width, height), scale);
    }
    for name in &shot_poses(pose) {
        app.with(|a| a.frame(w as i64, h as i64));
        // `sampling:x,y` (points): the eyedropper is armed, gets the frame drawn so far and the pointer moves to x,y.
        if let Some(at) = name.strip_prefix("sampling:") {
            let at: Vec<f32> = at.split(',').filter_map(|v| v.parse().ok()).collect();
            if let (true, [x, y]) = (app.with(|a| a.shot_pose("sampling")).unwrap_or(false), at.as_slice()) {
                app.turn();
                // shortcut: the shot's sampled frame has no posters or thumbnails (the uploads are kept for the final render).
                let frame = app.with(|a| {
                    let list = a.frame(w as i64, h as i64);
                    let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
                    let sources = Sources { atlas: a.atlas(), video: None, images: &[] };
                    SoftwareRenderer::render_8bit(&list, w, h, clear, &sources)
                });
                if let Some(frame) = frame {
                    app.with(|a| a.set_window_frame(frame));
                }
                app.input(&sq_draw::InputEvent::MouseMoved { x: x * scale, y: y * scale });
                app.turn();
            }
            continue;
        }
        if !app.with(|a| a.shot_pose(name)).unwrap_or(false) {
            // Loud, not a silent shot of the wrong screen (P38): the run fails and no picture is written.
            return Err(format!("--pose: unknown or failed pose {name}"));
        }
        app.turn();
        // A pose can change which panels show (Steps appears with a Pro grade): lay them out once more.
        app.with(|a| a.frame(w as i64, h as i64));
        app.turn();
        app.with(|a| a.frame(w as i64, h as i64));
    }
    for step in &pose.steps {
        run_step(&app, step, scale, (w as i64, h as i64), &mut slots)?;
    }
    if let Some(title) = &pose.menu {
        app.with(|a| a.frame(w as i64, h as i64));
        write_bar_outlines(&app, pose, title);
    }
    if pose.poses.iter().any(|p| p.starts_with("start-")) {
        // The start cards' posters decode on the worker pool: draw until they have arrived (at least 2 s, then a quiet 500 ms after the last one).
        let (begin, mut quiet) = (Instant::now(), Instant::now());
        while begin.elapsed() < Duration::from_secs(6)
            && (begin.elapsed() < Duration::from_secs(2) || quiet.elapsed() < Duration::from_millis(500))
        {
            let got = app.with(|a| {
                a.frame(w as i64, h as i64);
                let uploads = a.take_image_uploads();
                let any = !uploads.is_empty();
                slots.apply(uploads);
                any
            });
            if got == Some(true) {
                quiet = Instant::now();
            }
            std::thread::sleep(Duration::from_millis(30));
        }
    }
    wait_for_picture(&app, &picture, &mut slots, w as i64, h as i64);
    // With keys the playhead was set before them: seeking again would undo what Home or a Step key did.
    if playhead_ms > 0 && pose.keys.is_empty() {
        wait_for_playhead(&app, &picture, &mut slots, playhead_ms, w as i64, h as i64);
    }
    // One turn first: a selection made above shows its panels (the Color page's "Applies to this clip" row) only after a turn,
    // and every control sat 30 px off until a click.
    app.turn();
    // shortcut: SQ_SHOT_WAIT_MS=<ms> is a shot-only switch: the app keeps drawing for that long before the picture is taken, so a
    // playing Library preview has moved on.
    if let Some(ms) = std::env::var("SQ_SHOT_WAIT_MS").ok().and_then(|v| v.parse::<u64>().ok()) {
        pump(&app, &mut slots, ms, (w as i64, h as i64));
    }
    let image = app
        .with(|a| {
            let list = a.frame(w as i64, h as i64);
            slots.apply(a.take_image_uploads());
            let frame = picture.get();
            let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
            let sources = Sources { atlas: a.atlas(), video: frame.as_deref(), images: slots.images() };
            // The GPU rounds every blend to 8 bits; the shot does too unless SQ_SHOT_FLOAT is set (the float oracle).
            if std::env::var_os("SQ_SHOT_FLOAT").is_some() {
                SoftwareRenderer::render(&list, w, h, clear, &sources)
            } else {
                SoftwareRenderer::render_8bit(&list, w, h, clear, &sources)
            }
        })
        .ok_or("app busy")?;
    // A menu that is open (right-click, `--menu <title>`) is written as text beside the PNG, as the Swift sweep does.
    if let Some(png) = &pose.outline_beside {
        let items = app.with(|a| a.open_menu_items()).unwrap_or_default();
        if !items.is_empty() {
            let _ = std::fs::write(png.with_extension("txt"), sq_uikit::menu_outline::menu_outline(&items, 0));
        }
    }
    drop(app);
    let _ = std::fs::remove_dir_all(&support);
    Ok((image, slots))
}

/// p50, p95 and max of `v` in milliseconds (`n/a` when empty).
fn spread(v: &mut [f64]) -> String {
    if v.is_empty() {
        return "n/a".into();
    }
    v.sort_by(f64::total_cmp);
    let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
    format!("p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms", at(0.5), at(0.95), at(1.0))
}

/// Plays `project` at 1x for `SQ_BENCH_SECS` seconds (default 4) the way the window loop does (turn, draw list, new
/// picture) and reports what the viewer sees: the time to the first picture and from Play to the first new one, frames
/// shown against expected and dropped (the engine's counters), the gaps between distinct monitor pictures, the UI frame
/// cost and the engine's per-stage times. The software renderer is not timed: only the app's own work is.
/// Numbers and how to run it on every system: docs/rust/PERF-NOTES.md, "Many layers (perf-layers)".
fn play_bench(width: u32, height: u32, project: Option<&Path>, fonts: &Path) -> String {
    let secs =
        std::env::var("SQ_BENCH_SECS").ok().and_then(|v| v.parse::<f64>().ok()).filter(|s| *s >= 1.0).unwrap_or(4.0);
    let (w, h) = (i64::from(width), i64::from(height));
    let opened = Instant::now();
    let (app, picture) = build(width, height, 2.0, project, fonts);
    let mut slots = ImageSlots::default();
    let first_by = opened + Duration::from_secs(30);
    // The generation also moves for a cleared monitor: wait for a picture with pixels.
    while picture.size().is_none() && Instant::now() < first_by {
        app.turn();
        app.with(|a| a.frame(w, h));
        std::thread::sleep(Duration::from_millis(2));
    }
    let first_picture = opened.elapsed().as_secs_f64() * 1e3;
    wait_for_picture(&app, &picture, &mut slots, w, h);
    let (fps, length) = app
        .with(|a| {
            let t = a.session().active_timeline();
            let frame = t.map(|t| t.format.frame_duration).unwrap_or(Time::new(1, 30));
            let length = t.map(|t| t.duration()).unwrap_or(Time::ZERO);
            (
                frame.timescale() as f64 / frame.value().max(1) as f64,
                length.value() as f64 / length.timescale().max(1) as f64,
            )
        })
        .unwrap_or((30.0, 0.0));

    let (mut frames, mut seen, mut ui_ms) = (0u32, 0u32, 0.0);
    let (mut last, mut gaps, mut to_first) = (picture.generation(), Vec::new(), None);
    // The frame position on screen before Play, so only a new position counts as a frame.
    let mut position = app.with(|a| crate::playback::bench_shown(a.session().engine())).flatten();
    let mut long_gaps = Vec::new(); // (timeline second, gap in ms) of gaps over 50 ms
    let mut slow_ui = Vec::new(); // (seconds since Play, ms) of UI frames over 25 ms
    app.with(|a| a.session_mut().play_pause());
    let began = Instant::now();
    let (mut next_ui, mut changed) = (began, began);
    // Resident memory once a second (the Linux and Mac runs; on Windows read the working set beside it): a queue or a pool that
    // grows without bound shows as a line that keeps climbing past the frame cache's budget.
    let mut rss: Vec<f64> = crate::play_bench::rss_mb().into_iter().collect();
    let mut next_rss = began + Duration::from_secs(1);
    sq_gpu::gpu::timing::reset();
    while began.elapsed().as_secs_f64() < secs {
        if Instant::now() >= next_rss {
            next_rss += Duration::from_secs(1);
            rss.extend(crate::play_bench::rss_mb());
        }
        // The window loop at 60 Hz: one UI frame per tick; between ticks the loop only watches the composites, so the
        // gap between two new frame positions is measured to about a millisecond.
        if Instant::now() >= next_ui {
            let t = Instant::now();
            app.turn();
            app.with(|a| a.set_needs_redraw());
            app.with(|a| a.frame(w, h));
            let took = t.elapsed().as_secs_f64() * 1e3;
            ui_ms += took;
            if took > 25.0 {
                slow_ui.push((began.elapsed().as_secs_f64(), took));
            }
            frames += 1;
            next_ui = (next_ui + Duration::from_micros(16_667)).max(Instant::now());
            if picture.generation() != last {
                last = picture.generation();
                seen += 1;
            }
        }
        let now = app.with(|a| crate::playback::bench_shown(a.session().engine())).flatten();
        if let Some(at_position) = now
            && Some(at_position) != position
        {
            position = Some(at_position);
            let at = Instant::now();
            if to_first.is_none() {
                to_first = Some(at.duration_since(began).as_secs_f64() * 1e3);
            } else {
                let gap = at.duration_since(changed).as_secs_f64() * 1e3;
                if gap > 50.0 {
                    long_gaps.push((at_position.value() as f64 / at_position.timescale().max(1) as f64, gap));
                }
                gaps.push(gap);
            }
            changed = at;
        }
        std::thread::sleep(Duration::from_micros(500));
    }
    let played = began.elapsed().as_secs_f64();
    // Read before anything else touches the engine: a Play at the end of the sequence starts over and resets the counters.
    let engine = app.with(|a| crate::playback::bench_numbers(a.session().engine())).flatten();
    let expected = if length > 0.0 { played.min(length) } else { played } * fps;
    gaps.sort_by(f64::total_cmp);
    let (over50, over100) = (gaps.iter().filter(|g| **g > 50.0).count(), gaps.iter().filter(|g| **g > 100.0).count());
    // Late frames are what the viewer sees: positions that never showed (dropped) plus positions that showed a stand-in.
    let (shown, dropped, stale, max_lag) =
        engine.as_ref().map_or((0, 0, 0, 0), |(s, _)| (s.shown_frames, s.skipped_frames, s.late_frames, s.max_lag));
    let late = dropped + stale;
    // Where it happens (the first stand-in frames in seconds on the timeline, and the gaps over 50 ms): what a hitch is looked up by.
    let first_late: Vec<String> = engine
        .as_ref()
        .map(|(s, _)| s.first_late.iter().map(|f| format!("{:.2}s", *f as f64 / fps)).collect())
        .unwrap_or_default();
    let gpu_busy: u64 = engine
        .as_ref()
        .and_then(|(_, stages)| stages.iter().find(|l| l.starts_with("gpuBusy ")))
        .and_then(|l| l.rsplit(", ").next()?.parse().ok())
        .unwrap_or(0);
    let (rss_first, rss_last) = (rss.first().copied().unwrap_or(0.0), rss.last().copied().unwrap_or(0.0));
    let rss_max = rss.iter().copied().fold(0.0, f64::max);
    let long: Vec<String> = long_gaps.iter().map(|(at, ms)| format!("{at:.2}s {ms:.0}ms")).collect();
    let slow: Vec<String> = slow_ui.iter().map(|(at, ms)| format!("{at:.2}s {ms:.0}ms")).collect();
    let mut out = format!(
        "project: {}\nfirst picture {first_picture:.0} ms after open, Play to the first new picture {:.0} ms\n",
        project.map_or("none".into(), |p| p.display().to_string()),
        to_first.unwrap_or(f64::NAN)
    );
    if let Some((status, stages)) = &engine {
        out += &format!(
            "play {played:.1} s at 1x: {shown} frames shown of {expected:.0} expected ({fps:.0} fps), {dropped} dropped, {stale} with a stand-in, final lag {}\n",
            status.shown_lag
        );
        out += &format!("engine: {}\n", stages.join("; "));
    }
    out += &format!(
        "frame gaps {}; over 50 ms {over50}, over 100 ms {over100} (new frame positions on screen: {}; monitor pictures taken by the UI {seen}, {:.1}/s)\nlate frames {late} (dropped {dropped} + a layer still a stand-in when the next frame came {stale}), stalest layer up to {max_lag} frames behind\nfirst stand-in frames at [{}]; gaps over 50 ms at [{}]; UI frames over 25 ms at [{}]\n",
        spread(&mut gaps),
        gaps.len() + usize::from(to_first.is_some()),
        f64::from(seen) / played,
        first_late.join(", "),
        long.join(", "),
        slow.join(", "),
    );
    out += &format!(
        "GPU back-pressure: {gpu_busy} frames dropped because the GPU still ran two earlier ones; process memory {rss_first:.0} MB at Play, {rss_max:.0} MB at most, {rss_last:.0} MB at the end\n"
    );
    let (reused, allocated) = sq_frame::buffer_pool::BufferPool::shared().counts();
    out += &format!("picture buffers: {reused} reused from the pool, {allocated} allocated fresh\n");
    // Per-pass GPU time (SQ_GPU_TIMING=1, adapters with timestamp queries): which effect's shader costs how much.
    let passes = sq_gpu::gpu::timing::report();
    if !passes.is_empty() {
        out += "GPU time per pass (SQ_GPU_TIMING=1):\n";
        for t in passes.iter().take(24) {
            out += &format!(
                "  {:<56} {:>8.1} ms total, {:>6.3} ms mean, {:>6.2} ms max, {} passes\n",
                t.label,
                t.total_ms,
                t.total_ms / t.passes.max(1) as f64,
                t.max_ms,
                t.passes
            );
        }
    }
    out += &format!(
        "ui frames {:.1}/s, ui frame avg {:.1} ms\n",
        f64::from(frames) / played,
        ui_ms / f64::from(frames.max(1))
    );
    // One line a script can take the median of (`scripts/perf-layers.sh`).
    let at = |q: f64| if gaps.is_empty() { f64::NAN } else { gaps[((gaps.len() - 1) as f64 * q).round() as usize] };
    out += &format!(
        "RESULT shown={shown} expected={expected:.0} dropped={dropped} late={late} gap_p50={:.1} gap_p95={:.1} gap_max={:.1} over50={over50} over100={over100} stale={stale} maxlag={max_lag} first_ms={first_picture:.0} play_first_ms={:.0} gpubusy={gpu_busy} rss_start={rss_first:.0} rss_max={rss_max:.0} rss_end={rss_last:.0}\n",
        at(0.5),
        at(0.95),
        at(1.0),
        to_first.unwrap_or(f64::NAN)
    );
    out
}

/// First Play after the open, then after a switch to the sequence 0x10A and back to 0x0A (`Id::from_u128`): the time from
/// the Play call to the first new picture. The engine's phase notes (`play:` lines) go to stderr with the run's clock.
fn play_start(project: Option<&Path>, fonts: &Path) -> String {
    let t0 = Instant::now();
    // The engine's `play:` notes reach the app log (run with SQ_LOG=debug).
    let (app, picture) = build(640, 360, 1.0, project, fonts);
    let turn = |ms: u64| {
        let end = Instant::now() + Duration::from_millis(ms);
        while Instant::now() < end {
            app.turn();
            app.with(|a| {
                a.set_needs_redraw();
                a.frame(640, 360);
            });
            std::thread::sleep(Duration::from_millis(1));
        }
    };
    let end = Instant::now() + Duration::from_secs(20);
    // The generation also moves for a cleared monitor (nothing under the playhead): only a picture with pixels counts.
    while picture.size().is_none() && Instant::now() < end {
        turn(5);
    }
    let mut out = if picture.size().is_some() {
        format!("first picture at {:.0} ms after start\n", t0.elapsed().as_secs_f64() * 1e3)
    } else {
        "no video picture within 20 s after start (a gap under the playhead, or the clip does not open)\n".to_string()
    };
    turn(1500);
    let steps: [(Option<u128>, &str); 3] = [
        (None, "first play"),
        (Some(0x10A), "first play after switch to B"),
        (Some(0x0A), "first play after switch to A"),
    ];
    for (switch, label) in steps {
        if let Some(id) = switch {
            app.with(|a| a.session_mut().set_active_timeline(sq_core_time::Id::from_u128(id)));
        }
        turn(2000);
        let before = picture.generation();
        let began = Instant::now();
        sq_core_time::milestones::note(&format!("play: [{label}] Space"));
        app.with(|a| a.session_mut().play_pause());
        let mut ms = None;
        while began.elapsed() < Duration::from_secs(3) {
            app.turn();
            app.with(|a| {
                a.set_needs_redraw();
                a.frame(640, 360);
            });
            if ms.is_none() && picture.generation() != before {
                ms = Some(began.elapsed().as_secs_f64() * 1e3);
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        out +=
            &format!("{label}: first new picture {} ms after Play\n", ms.map_or("never".into(), |m| format!("{m:.0}")));
        app.with(|a| a.session_mut().play_pause());
    }
    out
}

/// The soak loop: three seconds of play, a scrub burst, then edits (marker, edit at the playhead) each undone, over and
/// over for `SQ_SOAK_SECS` seconds (default 1200). Writes one line per 30 s: frames, distinct pictures, operations.
fn soak(width: u32, height: u32, project: Option<&Path>, fonts: &Path, out: &Path) -> Result<(), String> {
    use std::io::Write;
    let secs: u64 = std::env::var("SQ_SOAK_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(1200);
    let (w, h) = (i64::from(width), i64::from(height));
    let (app, picture) = build(width, height, 1.0, project, fonts);
    let mut slots = ImageSlots::default();
    wait_for_picture(&app, &picture, &mut slots, w, h);
    let mut log = std::fs::File::create(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let (start, mut next_line) = (Instant::now(), Duration::from_secs(30));
    let (mut frames, mut seen, mut last, mut ops, mut round, mut seed) =
        (0u64, 0u64, picture.generation(), 0u64, 0u64, 7u64);
    let mut frame = |app: &Headless, seen: &mut u64, last: &mut i64, frames: &mut u64| {
        app.turn();
        app.with(|a| {
            a.set_needs_redraw();
            a.frame(w, h);
            let uploads = a.take_image_uploads();
            slots.apply(uploads);
        });
        *frames += 1;
        if picture.generation() != *last {
            *last = picture.generation();
            *seen += 1;
        }
        std::thread::sleep(Duration::from_millis(8));
    };
    while start.elapsed() < Duration::from_secs(secs) {
        round += 1;
        let phase_end = Instant::now() + Duration::from_secs(3);
        app.with(|a| a.session_mut().seek(Time::ZERO));
        app.with(|a| a.session_mut().play_pause());
        while Instant::now() < phase_end {
            frame(&app, &mut seen, &mut last, &mut frames);
        }
        app.with(|a| a.session_mut().play_pause());
        for _ in 0..60 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let ms = ((seed >> 33) % 20_000) as i64;
            app.with(|a| a.session_mut().seek(Time::new(ms, 1000)));
            ops += 1;
            for _ in 0..3 {
                frame(&app, &mut seen, &mut last, &mut frames);
            }
        }
        for _ in 0..20 {
            app.with(|a| {
                a.session_mut().add_marker_at_playhead();
                a.session_mut().add_edit_at_playhead(true);
                a.session_mut().undo();
                a.session_mut().undo();
                a.session_mut().redo();
                a.session_mut().undo();
            });
            ops += 6;
            frame(&app, &mut seen, &mut last, &mut frames);
        }
        if start.elapsed() >= next_line {
            next_line += Duration::from_secs(30);
            let line = format!(
                "t={}s round={round} ui_frames={frames} pictures={seen} ops={ops}\n",
                start.elapsed().as_secs()
            );
            let _ = log.write_all(line.as_bytes());
            let _ = log.flush();
        }
    }
    let end =
        format!("done t={}s round={round} ui_frames={frames} pictures={seen} ops={ops}\n", start.elapsed().as_secs());
    log.write_all(end.as_bytes()).map_err(|e| e.to_string())
}

/// Runs a test mode and writes its file.
pub fn run(mode: &Mode, project: Option<&Path>, fonts: &Path) -> Result<(), String> {
    let offscreen = matches!(
        mode,
        Mode::UiShot { .. }
            | Mode::UsePass { .. }
            | Mode::A11yDump { .. }
            | Mode::Soak { .. }
            | Mode::PlayBench { .. }
            | Mode::PlayStart { .. }
    );
    if !offscreen {
        return run_mode(mode, project, fonts);
    }
    let guard = RealFolders::watch();
    let ran = run_mode(mode, project, fonts);
    // The guard speaks first: a run that wrote into a real folder fails whatever its picture shows.
    guard.verify().and(ran)
}

fn run_mode(mode: &Mode, project: Option<&Path>, fonts: &Path) -> Result<(), String> {
    sq_app_hosts::desktop_entry::allow_offers(false);
    // Offscreen modes click through the UI by script: a Support, GitHub, Discord or Reveal click must not open a window.
    sq_app_hosts::disable_external_open();
    match mode {
        Mode::Window => Ok(()),
        Mode::UiShot { out, width, height, scale, playhead_ms, pose } => {
            let pose = Pose { outline_beside: Some(out.clone()), ..pose.clone() };
            let (image, _) = shoot(*width, *height, *scale, *playhead_ms, &pose, project, fonts)?;
            std::fs::write(out, png::encode(&image)).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::UsePass { out, width, height, pitch, states, known } => {
            crate::use_pass::run(out, (*width, *height), *pitch, states, known.as_deref(), project, fonts)
        }
        Mode::PlayBench { out, width, height } => {
            let text = play_bench(*width, *height, project, fonts);
            std::fs::write(out, text).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::PlayStart { out } => {
            let text = play_start(project, fonts);
            std::fs::write(out, text).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::Soak { out, width, height } => soak(*width, *height, project, fonts, out),
        Mode::EngineBench { out } => {
            let text = crate::play_bench::run(project.ok_or("--engine-bench needs a clip")?)?;
            print!("{text}");
            std::fs::write(out, text).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::PerfProject { out, media } => {
            let written = crate::perf_project::write_all(out, media)?;
            let text: String = written.iter().map(|p| format!("{}\n", p.display())).collect();
            print!("{text}");
            Ok(())
        }
        Mode::StartErrorShot { out, scale, light } => {
            let fault = crate::fault_inject::current().unwrap_or(crate::fault_inject::Fault::Gpu);
            let screen = crate::fault_inject::failure(fault).record();
            let atlas = sq_draw::GlyphAtlas::inter(fonts).ok_or_else(|| format!("no fonts in {}", fonts.display()))?;
            let theme = crate::error_window::theme(*light, *scale);
            let size = (
                (sq_draw_shell::ERROR_SCREEN_W * f64::from(*scale)).round() as usize,
                (sq_draw_shell::ERROR_SCREEN_H * f64::from(*scale)).round() as usize,
            );
            let mut view = sq_draw_shell::ErrorView::new(screen);
            let image = crate::error_window::render(&mut view, Some(&atlas), &theme, size, 0.0);
            std::fs::write(out, png::encode(&image)).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::PresentCheck { out } => {
            let clip = project.ok_or("--present-check needs a clip")?;
            let report = crate::present_check::run(clip, &crate::present_check::Plan::standard())?;
            print!("{}", report.text);
            std::fs::write(out, report.text).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::MaskEval { out, click, disk } => {
            let clip = project.ok_or("--mask-eval needs a clip")?;
            let disk = disk.as_deref().map(sq_app_hosts::Disk::parse).transpose()?;
            let text = sq_app_hosts::mask_eval(clip, sq_core_time::Vec2::new(click.0, click.1), disk, None)?;
            print!("{text}");
            std::fs::write(out, text).map_err(|e| format!("{}: {e}", out.display()))
        }
        Mode::Export(args) => {
            // The preference is read once here, at the start of the CLI export, and carried in the args.
            let mut args = args.clone();
            args.use_proxies = sq_app_hosts::stored_settings(&crate::paths::app_support_dir()).use_proxies_for_export;
            crate::export_cli::run(project.ok_or("--export needs a project")?, &args)
        }
        Mode::DesktopEntry(command) => {
            use crate::cli::DesktopEntryCommand as Command;
            let env = sq_platform::desktop_integration::DesktopEnv::current();
            let choice = match command {
                Command::Add => Some(sq_draw_shell::AppMenuRequest::Add),
                Command::Remove => Some(sq_draw_shell::AppMenuRequest::Remove { trash_file: false }),
                Command::Status => None,
            };
            let state = match choice {
                Some(c) => sq_app_hosts::desktop_entry::apply(env.as_ref(), c)?,
                None => sq_platform::desktop_integration::state(env.as_ref()),
            };
            println!("{state:?}");
            Ok(())
        }
        Mode::ListPresets => {
            crate::export_cli::list_presets().iter().for_each(|n| println!("{n}"));
            Ok(())
        }
        Mode::A11yDump { out, width, height } => {
            let (app, _) = build(*width, *height, 1.0, project, fonts);
            let text = app
                .with(|a| {
                    a.frame(i64::from(*width), i64::from(*height));
                    let mut tree = a.accessibility(true);
                    a11y_lines(&crate::a11y::tree_update("Sequence Studio", tree.take()).nodes)
                })
                .ok_or("app busy")?;
            std::fs::write(out, text).map_err(|e| format!("{}: {e}", out.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use accesskit::{Node, NodeId, Role};

    #[test]
    fn lines_list_role_and_label() {
        let mut n = Node::new(Role::Button);
        n.set_label("Play");
        assert_eq!(a11y_lines(&[(NodeId(1), n)]), "Button\tPlay\n");
    }

    /// H2: a shot builds its app on a projects folder of its own, so a template card or Create never writes under the
    /// user's `~/Movies/Sequence Studio`.
    #[test]
    fn a_shot_writes_new_projects_into_its_own_folder_only() {
        let support = std::env::temp_dir().join(format!("sq-shot-projects-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&support);
        let _ = build_in(&support, 64, 48, 1.0, None, Path::new("/nonexistent"));
        let prefs = std::fs::read_to_string(support.join("prefs.json")).expect("prefs.json");
        let projects = support.join("Projects");
        assert!(prefs.contains(&*projects.to_string_lossy().replace('\\', "\\\\")), "{prefs}");
        let _ = std::fs::remove_dir_all(&support);
    }

    /// Windows acceptance item 16: the start window draws the app's own menu bar on Windows and Linux (contract
    /// alpha-base 16), in a shot as in the real window. A Linux reference shot taken with `SQ_SHOT_SYSTEM_BAR=1` (the
    /// Mac-look pose) has none: that is the pose, not the platform, so a parity run must use the same setting on both.
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn the_start_window_draws_the_menu_bar_on_windows_and_linux() {
        if std::env::var_os("SQ_SHOT_SYSTEM_BAR").is_some() {
            return; // the Mac-look pose is asked for: no drawn bar by design
        }
        let support = std::env::temp_dir().join(format!("sq-shot-start-bar-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&support);
        let (app, _) = build_in(&support, 1100, 744, 1.0, None, &crate::fonts_root());
        app.turn();
        sq_draw::text_log::start();
        app.with(|a| a.frame(1100, 744));
        let runs = sq_draw::text_log::finish();
        let _ = std::fs::remove_dir_all(&support);
        let titles: Vec<&str> =
            ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window", "Help"].into_iter().collect();
        for t in &titles {
            assert!(
                runs.iter().any(|r| r.asked == *t && r.drawn.is_some() && r.rect.1 < 40.0),
                "the start window's top row draws the {t} menu title"
            );
        }
    }

    /// P38: an unknown pose name fails the shot (it showed the Recent screen before).
    #[test]
    fn an_unknown_pose_name_fails_the_shot_loudly() {
        let out = std::env::temp_dir().join(format!("sq-shot-bad-pose-{}.png", std::process::id()));
        let pose = Pose { poses: vec!["start-whatsnew".into()], ..Default::default() };
        let mode = Mode::UiShot { out: out.clone(), width: 64, height: 48, scale: 1.0, playhead_ms: 0, pose };
        let err = run(&mode, None, Path::new("/nonexistent")).expect_err("unknown pose");
        assert!(err.contains("start-whatsnew"), "{err}");
        assert!(!out.exists(), "no picture of the wrong screen");
    }

    #[test]
    fn ui_shot_writes_a_png_of_the_requested_size() {
        let out = std::env::temp_dir().join(format!("sq-shot-{}.png", std::process::id()));
        let mode = Mode::UiShot {
            out: out.clone(),
            width: 64,
            height: 48,
            scale: 1.0,
            playhead_ms: 0,
            pose: Default::default(),
        };
        assert_eq!(run(&mode, None, Path::new("/nonexistent")), Ok(()));
        let bytes = std::fs::read(&out).unwrap_or_default();
        let _ = std::fs::remove_file(&out);
        let img = sq_core_time::portable_png::decode(&bytes);
        assert_eq!(img.map(|i| (i.width, i.height)), Some((64, 48)));
    }

    #[test]
    fn a_saved_project_opens_and_the_shot_shows_the_panels() {
        let dir = std::env::temp_dir().join(format!("sq-slice-{}", std::process::id()));
        let project = dir.join("small.sqproj");
        let (mut session, _) = crate::untitled_session(&dir);
        session.save_as(&project).expect("save the test project");
        let out = dir.join("shot.png");
        let mode = Mode::UiShot {
            out: out.clone(),
            width: 320,
            height: 200,
            scale: 1.0,
            playhead_ms: 0,
            pose: Default::default(),
        };
        assert_eq!(run(&mode, Some(&project), Path::new("/nonexistent")), Ok(()));
        let bytes = std::fs::read(&out).unwrap_or_default();
        // The same size without a project shows the start window, which must differ from the editing window.
        let start = dir.join("start.png");
        let mode = Mode::UiShot {
            out: start.clone(),
            width: 320,
            height: 200,
            scale: 1.0,
            playhead_ms: 0,
            pose: Default::default(),
        };
        assert_eq!(run(&mode, None, Path::new("/nonexistent")), Ok(()));
        assert_ne!(std::fs::read(&start).unwrap_or_default(), bytes, "a project hides the start window");
        let _ = std::fs::remove_dir_all(&dir);
        let img = sq_core_time::portable_png::decode(&bytes).expect("a png");
        // Panels, tab strips and the menu bar draw more than one color; the empty window was one flat fill.
        let first = img.rgba.get(..4).map(<[u8]>::to_vec);
        assert!(img.rgba.chunks(4).any(|p| Some(p) != first.as_deref()), "the shot is not a flat fill");
    }

    #[test]
    fn the_default_layout_shot_draws_the_text_panel_and_the_meters() {
        let dir = std::env::temp_dir().join(format!("sq-text-panel-{}", std::process::id()));
        let (mut session, _) = crate::untitled_session(&dir);
        let project = dir.join("p.sqproj");
        session.save_as(&project).expect("save the test project");
        let out = dir.join("shot.png");
        let mode = Mode::UiShot {
            out: out.clone(),
            width: 1440,
            height: 900,
            scale: 1.0,
            playhead_ms: 0,
            pose: Default::default(),
        };
        assert_eq!(run(&mode, Some(&project), Path::new("/nonexistent")), Ok(()));
        let img = sq_core_time::portable_png::decode(&std::fs::read(&out).unwrap_or_default()).expect("a png");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!((img.width, img.height), (1440, 900));
    }

    #[test]
    fn imported_media_shows_a_row_in_the_project_panel() {
        use sq_core_model::{MediaFingerprint, MediaRef};
        let dir = std::env::temp_dir().join(format!("sq-project-panel-{}", std::process::id()));
        let shot = |name: &str, media: Vec<MediaRef>| {
            let (session, _) = crate::untitled_session(&dir);
            let mut project = session.project().clone();
            project.media = media.into();
            let file = dir.join(format!("{name}.sqproj"));
            let mut session =
                sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
            session.save_as(&file).expect("save the test project");
            let out = dir.join(format!("{name}.png"));
            let mode = Mode::UiShot {
                out: out.clone(),
                width: 1280,
                height: 800,
                scale: 1.0,
                playhead_ms: 0,
                pose: Default::default(),
            };
            assert_eq!(run(&mode, Some(&file), Path::new("/nonexistent")), Ok(()));
            std::fs::read(&out).unwrap_or_default()
        };
        let mut clip =
            MediaRef::new(sq_core_time::Id::from_u128(100), "clip", "/tmp/clip.mp4", MediaFingerprint::new(1));
        clip.duration = Some(sq_core_time::Time::seconds(1));
        let with = shot("with", vec![clip]);
        let without = shot("without", Vec::new());
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!with.is_empty() && with != without, "the Project panel shows no row for the media");
    }

    /// A 1 s test clip from the `ffmpeg` command line, or `None` (the test then skips).
    fn make_clip(dir: &Path) -> Option<std::path::PathBuf> {
        if !sq_media_ffmpeg::shim::AVAILABLE {
            return None;
        }
        let path = dir.join("clip.mp4");
        let bundled = std::env::var_os("SQ_FFMPEG").map(|r| std::path::PathBuf::from(r).join("bin").join("ffmpeg"));
        let ffmpeg =
            bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffmpeg".into());
        let made = std::process::Command::new(ffmpeg)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=1"])
            // mpeg4 is built into every FFmpeg; the LGPL build of the PC has no libx264.
            .args(["-c:v", "mpeg4", "-pix_fmt", "yuv420p"])
            .arg(&path)
            .status()
            .ok()?;
        (made.success() && path.exists()).then_some(path)
    }

    #[test]
    fn a_poster_frame_reaches_the_atlas_slot_and_the_shot() {
        use sq_core_model::{MediaFingerprint, MediaRef};
        let dir = std::env::temp_dir().join(format!("sq-poster-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(clip_path) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let (session, _) = crate::untitled_session(&dir);
        let mut project = session.project().clone();
        let mut clip = MediaRef::new(
            sq_core_time::Id::from_u128(100),
            "clip",
            &clip_path.to_string_lossy(),
            MediaFingerprint::new(1),
        );
        clip.duration = Some(sq_core_time::Time::seconds(1));
        project.media = vec![clip].into();
        let file = dir.join("p.sqproj");
        let mut session =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        session.save_as(&file).expect("save the test project");
        let (image, slots) =
            shoot(1280, 800, 1.0, 0, &Pose::default(), Some(&file), Path::new("/nonexistent")).expect("a shot");
        let _ = std::fs::remove_dir_all(&dir);
        let atlas = slots.images()[sq_app_shell::ATLAS_SLOT].as_ref().expect("the poster was uploaded");
        // testsrc2 is full of saturated colors; the rest of the atlas is transparent.
        let colorful = atlas.pixels.chunks(4).filter(|p| p[3] == 255 && p[0].abs_diff(p[2]) > 60).count();
        assert!(colorful > 2000, "the poster is flat in the atlas ({colorful} colorful pixels)");
        assert_eq!((image.width, image.height), (1280, 800));
    }

    #[test]
    fn the_plain_editor_shot_takes_the_focus_timeline_pose() {
        let plain = Pose::default();
        assert_eq!(shot_poses(&plain), ["focus-timeline"]);
        // every other kind of shot keeps exactly the poses it asked for
        let asked = Pose { poses: vec!["mask".into()], ..Pose::default() };
        assert_eq!(shot_poses(&asked), ["mask"]);
        assert!(shot_poses(&Pose { color_page: true, ..Pose::default() }).is_empty());
        assert!(shot_poses(&Pose { clicks: vec![(1.0, 2.0)], ..Pose::default() }).is_empty());
        assert!(shot_poses(&Pose { menu: Some("Edit".into()), ..Pose::default() }).is_empty());
        assert!(shot_poses(&Pose { tour: true, ..Pose::default() }).is_empty());
    }

    #[test]
    fn the_focus_timeline_pose_is_known_to_the_app_and_focuses_the_timeline() {
        let dir = std::env::temp_dir().join(format!("sq-focus-pose-{}", std::process::id()));
        let (session, _) = crate::untitled_session(&dir);
        let file = dir.join("p.sqproj");
        let mut session = session;
        session.save_as(&file).expect("save the test project");
        let (app, _, _) = scaled_app(&dir, &file, 1.0);
        assert_eq!(
            app.with(|a| a.shot_pose("focus-timeline")),
            Some(true),
            "an unknown pose would leave the shot unfocused"
        );
        assert_ne!(app.with(|a| a.shot_pose("no-such-pose")), Some(true));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_shot_waits_for_the_posters_of_every_media_item() {
        use sq_core_model::{MediaFingerprint, MediaRef};
        let dir = std::env::temp_dir().join(format!("sq-posters-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(clip_path) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let (session, _) = crate::untitled_session(&dir);
        let colorful = |count: u128| {
            let mut project = session.project().clone();
            project.media = (0..count)
                .map(|n| {
                    let copy = dir.join(format!("copy{n}.mp4"));
                    std::fs::copy(&clip_path, &copy).expect("copy the clip");
                    let mut m = MediaRef::new(
                        sq_core_time::Id::from_u128(200 + n),
                        "clip",
                        &copy.to_string_lossy(),
                        MediaFingerprint::new(1),
                    );
                    m.duration = Some(sq_core_time::Time::seconds(1));
                    m
                })
                .collect::<Vec<_>>()
                .into();
            let file = dir.join(format!("p{count}.sqproj"));
            let mut s =
                sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
            s.save_as(&file).expect("save the test project");
            let (_, slots) =
                shoot(1280, 800, 1.0, 0, &Default::default(), Some(&file), Path::new("/nonexistent")).expect("a shot");
            let atlas = slots.images()[sq_app_shell::ATLAS_SLOT].as_ref().expect("a poster was uploaded");
            atlas.pixels.chunks(4).filter(|p| p[3] == 255 && p[0].abs_diff(p[2]) > 60).count()
        };
        let (one, three) = (colorful(1), colorful(3));
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            three * 10 > one * 25,
            "the shot stopped at the first poster ({one} pixels for one item, {three} for three)"
        );
    }

    #[test]
    fn the_project_grid_shows_the_poster_in_icon_view_and_none_in_the_list() {
        use sq_core_model::{MediaFingerprint, MediaRef};
        let dir = std::env::temp_dir().join(format!("sq-grid-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(clip_path) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let (session, _) = crate::untitled_session(&dir);
        let mut project = session.project().clone();
        let id = sq_core_time::Id::from_u128(100);
        let mut clip = MediaRef::new(id, "clip", &clip_path.to_string_lossy(), MediaFingerprint::new(1));
        clip.duration = Some(sq_core_time::Time::seconds(1));
        project.media = vec![clip].into();
        let file = dir.join("p.sqproj");
        let mut session =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        session.save_as(&file).expect("save the test project");
        for mode in ["list", "icons"] {
            let support = dir.join(mode);
            std::fs::create_dir_all(&support).expect("support folder");
            let prefs = format!(r#"{{"strings":{{"ProjectPanel.viewMode":"{mode}"}}}}"#);
            std::fs::write(support.join("prefs.json"), prefs).expect("prefs");
            let (app, picture) = build_in(&support, 1280, 800, 1.0, Some(&file), Path::new("/nonexistent"));
            let mut slots = ImageSlots::default();
            wait_for_picture(&app, &picture, &mut slots, 1280, 800);
            let render = |slots: &ImageSlots| {
                app.with(|a| {
                    let list = a.frame(1280, 800);
                    let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
                    let sources = Sources { atlas: a.atlas(), video: None, images: slots.images() };
                    SoftwareRenderer::render(&list, 1280, 800, clear, &sources)
                })
                .expect("a shot")
            };
            let with = render(&slots);
            let bare = render(&ImageSlots::default());
            // Only the posters differ between the two; testsrc2 is full of saturated colors.
            let poster_pixels = with
                .pixels
                .chunks(4)
                .zip(bare.pixels.chunks(4))
                .filter(|(a, b)| a != b && a[0].abs_diff(a[2]) > 60)
                .count();
            // The list rows draw no picture (the Mac `ProjectListView` has none either); the icon tiles show the poster.
            if mode == "icons" {
                assert!(poster_pixels > 100, "icon view: no poster pixels in the grid ({poster_pixels})");
            } else {
                assert_eq!(poster_pixels, 0, "list view: rows draw no poster");
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_project_with_a_clip_shows_its_picture_in_the_monitor() {
        use sq_core_model::{Clip, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind};
        use sq_core_time::{Id, Time, TimeRange};
        let dir = std::env::temp_dir().join(format!("sq-monitor-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(clip_path) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let media = Id::from_u128(100);
        let reference = MediaRef::new(media, "clip", &clip_path.to_string_lossy(), MediaFingerprint::new(1));
        let mut track = Track::new(Id::from_u128(900), TrackKind::Video);
        let source = TimeRange::new(Time::ZERO, Time::seconds(1));
        track.set_clips(vec![Clip::new(Id::from_u128(10), "c", media, TrackKind::Video, source, Time::ZERO)]);
        let mut format = SequenceFormat::new(Time::new(1, 25));
        (format.width, format.height) = (320, 180);
        let timeline = Timeline::new(Id::from_u128(1), "t", format, vec![track]);
        let project = Project::new(Id::from_u128(2), "p", vec![reference], vec![timeline]);
        let file = dir.join("clip.sqproj");
        let mut session =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        session.save_as(&file).expect("save the test project");

        let out = dir.join("shot.png");
        let mode = Mode::UiShot {
            out: out.clone(),
            width: 1280,
            height: 800,
            scale: 1.0,
            playhead_ms: 0,
            pose: Default::default(),
        };
        assert_eq!(run(&mode, Some(&file), Path::new("/nonexistent")), Ok(()));
        let img = sq_core_time::portable_png::decode(&std::fs::read(&out).unwrap_or_default()).expect("a png");
        let _ = std::fs::remove_dir_all(&dir);
        // testsrc2 is full of saturated colors; the panels around the monitor are gray.
        let colorful = img.rgba.chunks(4).filter(|p| p[0].abs_diff(p[1]) > 60 || p[1].abs_diff(p[2]) > 60).count();
        assert!(colorful > 2000, "the monitor shows no picture ({colorful} colorful pixels)");
    }

    #[test]
    fn a_step_on_the_opacity_slider_edits_the_project_and_undoes() {
        use accesskit::Role;
        use sq_app_shell::A11yAction;
        use sq_core_model::ShapeKind;
        use sq_core_time::Time;
        use sq_draw::A11y;
        let dir = std::env::temp_dir().join(format!("sq-a11y-{}", std::process::id()));
        let (mut session, _) = crate::untitled_session(&dir);
        let project = dir.join("p.sqproj");
        session.save_as(&project).expect("save the test project");
        let (app, _) = build(1440, 900, 1.0, Some(&project), Path::new("/nonexistent"));
        let slider = |a: &mut sq_app_shell::App| {
            a.frame(1440, 900);
            let nodes = a.accessibility(true).take();
            let id = A11y::node_id("inspector", Role::Slider, "opacity");
            nodes.into_iter().find(|(n, _)| *n == id).map(|(n, node)| (n, node.numeric_value()))
        };
        let (id, before, clip) = app
            .with(|a| {
                let clip = a.session_mut().add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5));
                let clip = clip.expect("shape clip");
                a.session_mut().set_selection([clip].into(), Default::default());
                let (id, value) = slider(a).expect("the dump lists an Opacity slider");
                (id, value, clip)
            })
            .expect("app");
        assert_eq!(before, Some(100.0));
        let after = app
            .with(|a| {
                assert!(a.accessibility_action(id, A11yAction::Decrement));
                slider(a).and_then(|s| s.1)
            })
            .expect("app");
        assert_eq!(after, Some(99.5));
        app.with(|a| a.session_mut().undo());
        let restored = app.with(|a| slider(a).and_then(|s| s.1)).flatten();
        assert_eq!(restored, Some(100.0), "undo of the action restores clip {clip:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn monitor_controls_effects_rows_and_library_are_nodes_and_clicks_reach_them() {
        use accesskit::Role;
        use sq_app_shell::A11yAction;
        let dir = std::env::temp_dir().join(format!("sq-a11y-panels-{}", std::process::id()));
        let (mut session, _) = crate::untitled_session(&dir);
        let project = dir.join("p.sqproj");
        session.save_as(&project).expect("save the test project");
        let (app, _) = build(1440, 900, 1.0, Some(&project), Path::new("/nonexistent"));
        let nodes = app
            .with(|a| {
                // The default layout tucks Effects behind the Library tab, and the root pushes no nodes for a hidden panel.
                if let Some(dock) = a.dock_mut() {
                    dock.show(sq_uikit::panel_id::PanelID::Effects);
                }
                a.frame(1440, 900);
                a.accessibility(true).take()
            })
            .expect("app");
        let by_label = |label: &str| nodes.iter().find(|(_, n)| n.label() == Some(label)).map(|(id, _)| *id);
        let zoom = by_label("Zoom: Fit, or 10 to 800 %").expect("the monitor zoom popup is a node");
        assert!(by_label("Play").is_some(), "the monitor transport has a Play button");
        assert!(nodes.iter().any(|(_, n)| n.role() == Role::ListItem && n.is_expanded().is_some()), "Effects folders");
        assert!(
            app.with(|a| a.accessibility_action(zoom, A11yAction::Click)).unwrap_or(false),
            "the click reaches the monitor"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A saved project with one clip on Video 1, opened in a headless app at `scale` on a 1440x900 point window.
    fn scaled_app(dir: &Path, file: &Path, scale: f32) -> (Headless, i64, i64) {
        let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let (w, h) = ((1440.0 * scale) as i64, (900.0 * scale) as i64);
        let (app, _) = build_in(&dir.join("support"), w as u32, h as u32, scale, Some(file), &fonts);
        app.with(|a| a.frame(w, h));
        (app, w, h)
    }

    /// Clicks the point `(x, y)` the way the window does: device pixels, then one loop turn.
    fn click_point(app: &Headless, scale: f32, (x, y): (f32, f32)) {
        let (px, py) = (x * scale, y * scale);
        app.input(&sq_draw::InputEvent::MouseMoved { x: px, y: py });
        app.input(&sq_draw::InputEvent::MouseDown { x: px, y: py, modifiers: Default::default() });
        app.input(&sq_draw::InputEvent::MouseUp { x: px, y: py });
        app.turn();
    }

    /// A Retina report: events arrive in device pixels while layouts are in points, so the same click point must
    /// do the same thing at every display scale: a Project row, a timeline clip and
    /// the monitor's Play button.
    #[test]
    fn clicks_land_on_the_same_controls_at_every_display_scale() {
        use sq_core_model::{Clip, MediaFingerprint, MediaRef, TrackKind};
        let dir = std::env::temp_dir().join(format!("sq-scale-clicks-{}", std::process::id()));
        let (session, _) = crate::untitled_session(&dir);
        let mut project = session.project().clone();
        let mut media =
            MediaRef::new(sq_core_time::Id::from_u128(100), "clip", "/tmp/clip.mp4", MediaFingerprint::new(1));
        media.duration = Some(sq_core_time::Time::seconds(4));
        project.media = vec![media].into();
        let file = dir.join("p.sqproj");
        let mut saved =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        saved.perform("Setup", None, |p| {
            let mut ids = sq_core_time::SequentialIds::default();
            let clip = Clip::new(
                sq_core_time::Id::from_u128(7),
                "clip",
                sq_core_time::Id::from_u128(100),
                TrackKind::Video,
                sq_core_time::TimeRange::new(sq_core_time::Time::ZERO, sq_core_time::Time::seconds(4)),
                sq_core_time::Time::ZERO,
            );
            assert!(p.timelines[0].tracks[0].insert(clip, &mut ids).is_ok());
        });
        saved.save_as(&file).expect("save the test project");
        let project_row_selected = |app: &Headless| {
            let nodes = app.with(|a| a.accessibility(true).take()).unwrap_or_default();
            nodes.iter().any(|(_, n)| n.label() == Some("clip") && n.is_selected() == Some(true))
        };
        for scale in [1.0_f32, 1.5, 2.0] {
            let (app, _, _) = scaled_app(&dir, &file, scale);
            // The Project strip is 30 pt tall now: the first row sits below it, so scan down the list instead of a fixed y.
            let mut y = 500.0_f32;
            while y < 720.0 && !project_row_selected(&app) {
                click_point(&app, scale, (1150.0, y));
                y += 4.0;
            }
            assert!(project_row_selected(&app), "Project row at scale {scale}");

            click_point(&app, scale, (300.0, 669.0));
            let selected = app.with(|a| a.session().selection().is_empty()).unwrap_or(true);
            assert!(!selected, "a timeline clip is selected at scale {scale}");

            click_point(&app, scale, (858.0, 452.0));
            assert!(app.with(|a| a.session().is_playing()).unwrap_or(false), "Play starts at scale {scale}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A Project row dragged to the timeline inserts the media under the pointer, at every display scale and in both
    /// views (the real Windows window logged `item None` for the press).
    #[test]
    fn dragging_a_project_row_to_the_timeline_places_the_clip() {
        use sq_core_model::{MediaFingerprint, MediaRef};
        let dir = std::env::temp_dir().join(format!("sq-row-drag-{}", std::process::id()));
        let (session, _) = crate::untitled_session(&dir);
        let mut project = session.project().clone();
        let mut media =
            MediaRef::new(sq_core_time::Id::from_u128(100), "clip", "/tmp/clip.mp4", MediaFingerprint::new(1));
        media.duration = Some(sq_core_time::Time::seconds(4));
        project.media = vec![media].into();
        let file = dir.join("p.sqproj");
        let mut saved =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        saved.save_as(&file).expect("save the test project");
        let clips = |app: &Headless| {
            app.with(|a| {
                a.session().active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum::<usize>())
            })
            .unwrap_or(0)
        };
        for scale in [1.0_f32, 1.5, 2.0] {
            let (app, _, _) = scaled_app(&dir, &file, scale);
            let mut y = 500.0_f32;
            let selected = |app: &Headless| {
                let nodes = app.with(|a| a.accessibility(true).take()).unwrap_or_default();
                nodes.iter().any(|(_, n)| n.label() == Some("clip") && n.is_selected() == Some(true))
            };
            while y < 720.0 && !selected(&app) {
                click_point(&app, scale, (1150.0, y));
                y += 4.0;
            }
            assert!(selected(&app), "row found at scale {scale}");
            let row_y = y - 4.0;
            let before = clips(&app);
            let (px, py) = (1150.0 * scale, row_y * scale);
            app.input(&sq_draw::InputEvent::MouseMoved { x: px, y: py });
            app.input(&sq_draw::InputEvent::MouseDown { x: px, y: py, modifiers: Default::default() });
            for step in 1..=10 {
                let t = step as f32 / 10.0;
                let (x, y) = (px + (400.0 * scale - px) * t, py + (669.0 * scale - py) * t);
                app.input(&sq_draw::InputEvent::dragged(x, y));
                app.turn();
            }
            app.input(&sq_draw::InputEvent::MouseUp { x: 400.0 * scale, y: 669.0 * scale });
            app.turn();
            assert_eq!(clips(&app), before + 1, "the drop inserted a clip at scale {scale}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn step(text: &str) -> crate::cli::Step {
        crate::cli::parse_step(text).expect("a step")
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp folder");
        dir
    }

    #[test]
    fn the_real_folder_guard_names_what_a_run_added() {
        let root = scratch("real-folder");
        let guard = RealFolders::watching(root.clone());
        assert_eq!(guard.verify(), Ok(()));
        std::fs::create_dir(root.join("Untitled Project")).expect("a leaked folder");
        let verdict = guard.verify().expect_err("a new entry in the real folder fails the run");
        assert!(verdict.contains("Untitled Project"), "{verdict}");
        let missing = RealFolders::watching(root.join("not-there-yet"));
        assert_eq!(missing.verify(), Ok(()));
        std::fs::create_dir_all(root.join("not-there-yet")).expect("the folder appears");
        assert!(missing.verify().is_err(), "a real folder that only exists after the run fails it too");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The report: `--step click:784,523 --step key:enter` (New Project, Create) made a folder under `~/Movies/Sequence
    /// Studio`. The sheet suggested the built-in default instead of the stored Projects folder. Driven through the real
    /// dialog (Cmd+Opt+N, Enter), the project lands in the shot's own folder and the real default folder holds nothing new.
    #[test]
    fn the_new_project_dialog_creates_into_the_shots_own_folder_only() {
        let real = RealFolders::watch();
        let dir = scratch("shot-dialog");
        let support = dir.join("support");
        let (app, _) = build_in(&support, 1280, 800, 1.0, None, Path::new("/nonexistent"));
        let mut slots = ImageSlots::default();
        for text in ["key:cmd+opt+n", "wait:300", "key:enter", "wait:300"] {
            run_step(&app, &step(text), 1.0, (1280, 800), &mut slots).expect("the step runs");
        }
        let made: Vec<String> = std::fs::read_dir(support.join("Projects"))
            .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        assert!(
            made.iter().any(|n| n.starts_with("Untitled Project")),
            "the project is not in the shot's folder: {made:?}"
        );
        assert_eq!(real.verify(), Ok(()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_hover_step_moves_the_pointer_and_a_wait_step_lets_time_pass() {
        let dir = scratch("shot-hover");
        let (app, _) = build_in(&dir.join("support"), 960, 600, 1.0, None, Path::new("/nonexistent"));
        let mut slots = ImageSlots::default();
        let render = |app: &Headless| {
            app.with(|a| {
                let list = a.frame(960, 600);
                let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
                let sources = Sources { atlas: a.atlas(), video: None, images: &[] };
                SoftwareRenderer::render_8bit(&list, 960, 600, clear, &sources).pixels
            })
        };
        run_step(&app, &step("hover:2,2"), 1.0, (960, 600), &mut slots).expect("hover");
        let rest = render(&app);
        // A hover fill answers the pointer at once: somewhere on the start window a point differs from the corner.
        let changed = (1..12).flat_map(|gx| (1..8).map(move |gy| (gx * 80, gy * 75))).any(|(x, y)| {
            run_step(&app, &step(&format!("hover:{x},{y}")), 1.0, (960, 600), &mut slots).expect("hover");
            render(&app) != rest
        });
        assert!(changed, "no control on the start window answered a hover step");
        let begin = Instant::now();
        run_step(&app, &step("wait:150"), 1.0, (960, 600), &mut slots).expect("wait");
        assert!(begin.elapsed() >= Duration::from_millis(150));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A saved project of `media` items named `m00`, `m01`, ... and one 20 s clip (id 7) of the first at the timeline's start.
    fn saved_project(dir: &Path, media: usize) -> PathBuf {
        use sq_core_model::{Clip, MediaFingerprint, MediaRef, TrackKind};
        let (session, _) = crate::untitled_session(dir);
        let mut project = session.project().clone();
        let items: Vec<MediaRef> = (0..media)
            .map(|i| {
                let id = sq_core_time::Id::from_u128(100 + i as u128);
                let mut m = MediaRef::new(id, &format!("m{i:02}"), "/tmp/clip.mp4", MediaFingerprint::new(1));
                m.duration = Some(Time::seconds(20));
                m
            })
            .collect();
        project.media = items.into();
        let file = dir.join("p.sqproj");
        let mut saved =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.to_path_buf()));
        saved.perform("Setup", None, |p| {
            let mut ids = sq_core_time::SequentialIds::default();
            let clip = Clip::new(
                sq_core_time::Id::from_u128(7),
                "clip",
                sq_core_time::Id::from_u128(100),
                TrackKind::Video,
                sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(20)),
                Time::ZERO,
            );
            assert!(p.timelines[0].tracks[0].insert(clip, &mut ids).is_ok());
        });
        saved.save_as(&file).expect("save the test project");
        file
    }

    /// A `drag:` step on a timeline clip moves it by the frames the pointer travelled: twice the distance moves it twice as
    /// far, and dragging back lands where it began (the same events as a real window, `sq_draw::pointer::Pointer`).
    #[test]
    fn a_drag_step_moves_a_timeline_clip_by_the_frames_it_travelled() {
        let dir = scratch("shot-drag");
        let file = saved_project(&dir, 1);
        let size = (1440, 900);
        let moved_by = |text: &str| {
            let (app, ..) = scaled_app(&dir, &file, 1.0);
            let mut slots = ImageSlots::default();
            let start = |app: &Headless| {
                app.with(|a| {
                    let t = a.session().active_timeline()?;
                    let clip =
                        t.tracks.iter().flat_map(|k| k.clips()).find(|c| c.id == sq_core_time::Id::from_u128(7))?;
                    Some(clip.start.frame_index(t.frame_duration()))
                })
                .flatten()
            };
            let before = start(&app).expect("the clip is on the timeline");
            for text in text.split(' ') {
                run_step(&app, &step(text), 1.0, size, &mut slots).expect("the drag runs");
            }
            start(&app).expect("the clip is still there") - before
        };
        let near = moved_by("drag:300,669,380,669");
        let far = moved_by("drag:300,669,460,669");
        assert!(near > 0, "80 pt to the right moved the clip: {near} frames");
        assert!((far - 2 * near).abs() <= 1, "160 pt moves it twice as far as 80 pt: {near} and {far} frames");
        let back = moved_by("drag:300,669,380,669 drag:380,669,300,669");
        assert_eq!(back, 0, "dragging back lands where the clip began");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The drawn Project panel (its lower right part, where the list is) of the app as it is now. The accessibility tree has
    /// no bounds, so the list's offset is read from what it draws: the same pixels mean the same offset.
    fn list_pixels(app: &Headless, (w, h): (usize, usize)) -> Vec<u8> {
        let (x0, y0) = (1040_usize, 470_usize);
        let image = app.with(|a| {
            let list = a.frame(w as i64, h as i64);
            let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
            let sources = Sources { atlas: a.atlas(), video: None, images: &[] };
            SoftwareRenderer::render_8bit(&list, w, h, clear, &sources).pixels
        });
        let image = image.unwrap_or_default();
        let per = image.len() / (w * h).max(1);
        (y0..h)
            .flat_map(|y| image.get((y * w + x0) * per..(y * w + w) * per).unwrap_or_default().iter().copied())
            .collect()
    }

    /// A `wheel:` step on the Project list: a wheel up at the top stays at the top, a wheel notch down scrolls, and a
    /// trackpad swipe past the top (`pad`) shows the rubber band and then, with only frames and no more input, springs back
    /// to offset 0 (a bug on the Effects panel).
    #[test]
    fn a_wheel_step_scrolls_a_list_and_a_pull_at_the_top_springs_back() {
        let dir = scratch("shot-wheel");
        let file = saved_project(&dir, 40);
        let (app, w, h) = scaled_app(&dir, &file, 1.0);
        let size = (w as usize, h as usize);
        let mut slots = ImageSlots::default();
        let mut run = |text: &str| run_step(&app, &step(text), 1.0, (w, h), &mut slots).expect("the step runs");
        run("hover:1150,600");
        let rest = list_pixels(&app, size);
        run("wheel:1150,600,-2,0,pad");
        assert_ne!(list_pixels(&app, size), rest, "a swipe past the top pulls the list down");
        run("wait:3000");
        assert_eq!(list_pixels(&app, size), rest, "the list springs back to offset 0");
        run("wheel:1150,600,-5");
        run("wait:3000");
        assert_eq!(list_pixels(&app, size), rest, "a wheel up at the top stays at the top");
        run("wheel:1150,600,4");
        run("wait:600");
        assert_ne!(list_pixels(&app, size), rest, "a wheel down scrolls the list");
        run("wheel:1150,600,-20");
        run("wait:3000");
        // A real pointer reports where it rests after the list stopped; the row under it takes the hover then.
        run("hover:1150,600");
        let back = list_pixels(&app, size);
        let differing = back.iter().zip(&rest).filter(|(a, b)| a != b).count();
        assert_eq!(differing, 0, "a wheel up brings the list back to the top: {differing} bytes differ");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The Mac check's row 2d (save kept no clips, the status stayed "Edited"): a drop outside the project folder asks "Copy,
    /// Move or Leave" and that dialog is modal, so Cmd+S ran behind it and saved nothing. Answered like a user does (Enter
    /// picks the default), the shortcut saves both clips, the session is clean and a reopened project has them.
    #[test]
    fn new_project_import_twice_answer_save_reopen_keeps_both_clips() {
        let dir = scratch("shot-import-save");
        let Some(made) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let (first, second) = (dir.join("a.mp4"), dir.join("b.mp4"));
        std::fs::copy(&made, &first).expect("copy a");
        std::fs::copy(&made, &second).expect("copy b");
        let support = dir.join("support");
        let (app, _) = build_in(&support, 1280, 800, 1.0, None, Path::new("/nonexistent"));
        let mut slots = ImageSlots::default();
        let size = (1280, 800);
        for text in ["key:cmd+opt+n", "wait:300", "key:enter", "wait:300"] {
            run_step(&app, &step(text), 1.0, size, &mut slots).expect("the step runs");
        }
        let url = app.with(|a| a.session().file_url().map(Path::to_path_buf)).flatten().expect("Create makes a file");
        for file in [first, second] {
            run_step(&app, &crate::cli::Step::Import(file), 1.0, size, &mut slots).expect("the import runs");
        }
        let media = |app: &Headless| app.with(|a| a.session().project().media.len()).unwrap_or_default();
        assert_eq!(media(&app), 2, "both clips reached the session");
        assert!(app.with(|a| a.session().is_dirty()).unwrap_or(false), "the imports made the project dirty");
        // The question is up and swallows the shortcut: nothing is saved yet.
        let title = open_dialog(&app, size).expect("a drop from outside the project asks what to do with the files");
        assert!(title.contains("outside the project folder"), "{title}");
        run_step(&app, &step("key:cmd+s"), 1.0, size, &mut slots).expect("the step runs");
        assert!(app.with(|a| a.session().is_dirty()).unwrap_or(false), "Cmd+S ran behind the open question");
        // Answer every question (one per drop), let the copies land, then save.
        for _ in 0..4 {
            if open_dialog(&app, size).is_none() {
                break;
            }
            run_step(&app, &step("key:enter"), 1.0, size, &mut slots).expect("the step runs");
            run_step(&app, &step("wait:300"), 1.0, size, &mut slots).expect("the step runs");
        }
        assert_eq!(open_dialog(&app, size), None, "every question was answered");
        for text in ["key:cmd+s", "wait:300"] {
            run_step(&app, &step(text), 1.0, size, &mut slots).expect("the step runs");
        }
        assert!(!app.with(|a| a.session().is_dirty()).unwrap_or(true), "Cmd+S saved the project");
        let on_disk = std::fs::read_to_string(sq_core_file::document_file(&url)).expect("the project file");
        let saved: serde_json::Value = serde_json::from_str(&on_disk).expect("project json");
        let written = saved.pointer("/project/media").and_then(|m| m.as_array()).map_or(0, Vec::len);
        assert_eq!(written, 2, "the file on disk holds both clips");
        let (reopened, _) = build_in(&dir.join("support2"), 1280, 800, 1.0, Some(&url), Path::new("/nonexistent"));
        assert_eq!(media(&reopened), 2, "a reopened project has both clips");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// FINAL-LIN-4 row 4: a project opened from its own folder (or loose) and a drop from outside. Asked and answered with
    /// Enter, the copy must land in `Files/Imported`; a loose project file (its folder is not named like it, as after
    /// renaming the folder) has no `Files/` of its own, so it never asks and keeps the file in place, even with "ask" saved.
    fn opened_project_outside_import(
        project_file: &str,
        files_beside: bool,
        expects_question: bool,
    ) -> Option<OpenedImport> {
        let dir = scratch(&format!("shot-opened-{}-{files_beside}", project_file.replace('/', "-")));
        let Some(made) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return None;
        };
        let clip = dir.join("elsewhere").join("c1.mp4");
        std::fs::create_dir_all(clip.parent().expect("parent")).expect("dir");
        std::fs::rename(&made, &clip).expect("move the clip");
        let (session, _) = crate::untitled_session(&dir);
        let mut session = sq_editor_session::EditorSession::new(
            session.project().clone(),
            sq_editor_session::SessionDeps::headless(dir.clone()),
        );
        let file = dir.join(project_file);
        // The setting the check's project carried (made in a project folder, then the folder was renamed): saved as "ask".
        session.perform("Change Media Setting", None, |p| {
            p.media_policy = Some(sq_core_model::MediaPolicy {
                outside: Some(sq_core_model::OutsideMediaMode::Ask),
                ..Default::default()
            });
        });
        session.save_as(&file).expect("save the test project");
        if files_beside {
            // The check's layout: `Film/Untitled Project.sqproj` with a `Files` folder beside it.
            std::fs::create_dir_all(file.with_file_name("Files").join("Imported")).expect("Files folder");
        }
        let (app, _) = build_in(&dir.join("support"), 1280, 800, 1.0, Some(&file), Path::new("/nonexistent"));
        let mut slots = ImageSlots::default();
        let size = (1280, 800);
        // The launch-time work of the open (Recent, the relink look, a notice) settles before the drop, and none of it
        // leaves a dialog up that would take the Enter meant for the question.
        pump(&app, &mut slots, 200, size);
        assert_eq!(open_dialog(&app, size), None, "a project opened with every clip online opens no dialog of its own");
        run_step(&app, &crate::cli::Step::Import(clip), 1.0, size, &mut slots).expect("the import runs");
        // The suite shares the machine: the question and the copy on the worker land turns later, so wait for each by its
        // effect (a fixed 300 ms pause after Enter left Files/Imported empty when the machine was busy).
        if expects_question {
            pump_until(&app, &mut slots, size, |a| open_dialog(a, size).is_some());
        }
        let asked = open_dialog(&app, size);
        let names = |folder: PathBuf| -> Vec<String> {
            let mut v: Vec<String> = std::fs::read_dir(folder)
                .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
                .unwrap_or_default();
            v.sort();
            v
        };
        let media_paths = |app: &Headless| -> Vec<String> {
            app.with(|a| a.session().project().media.iter().map(|m| m.path.clone()).collect()).unwrap_or_default()
        };
        let mut still_open = None;
        if asked.is_some() {
            run_step(&app, &step("key:enter"), 1.0, size, &mut slots).expect("the step runs");
            // Copy lands when the question is closed and the clip points at the copy.
            pump_until(&app, &mut slots, size, |a| {
                let paths = media_paths(a);
                // Not vacuous: before the copy lands the media list can still be empty, and `all` of nothing is true.
                open_dialog(a, size).is_none()
                    && !paths.is_empty()
                    && paths.iter().all(|p| p.contains("Files/Imported"))
            });
            still_open = open_dialog(&app, size);
        }
        let imported = names(file.with_file_name("Files").join("Imported"));
        let paths = media_paths(&app);
        let status = app.with(|a| a.status_text().to_string()).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&dir);
        Some(OpenedImport { asked, imported, paths, status, still_open })
    }

    /// Turns the loop until `done` holds or ten seconds ran out.
    fn pump_until(app: &Headless, slots: &mut ImageSlots, size: (i64, i64), done: impl Fn(&Headless) -> bool) {
        let end = Instant::now() + Duration::from_secs(10);
        while !done(app) && Instant::now() < end {
            pump(app, slots, 20, size);
        }
    }

    /// What an outside drop into an opened project did: the question (if any), `Files/Imported`, the clip paths, the status
    /// line, and the question still open after Enter (`None` when Enter answered it).
    struct OpenedImport {
        asked: Option<String>,
        imported: Vec<String>,
        paths: Vec<String>,
        status: String,
        still_open: Option<String>,
    }

    #[test]
    fn enter_on_the_question_copies_into_a_project_opened_from_its_folder() {
        let Some(r) = opened_project_outside_import("Film/Film.sqproj", false, true) else { return };
        assert!(r.asked.is_some(), "an outside file asks in a project folder");
        assert_eq!(r.still_open, None, "Enter answered the question");
        assert_eq!(r.imported, ["c1.mp4"], "Enter is Copy: the file lands in Files/Imported");
        assert!(r.paths.iter().all(|p| p.contains("Files/Imported")), "the clip points at the copy: {:?}", r.paths);
    }

    #[test]
    fn a_loose_project_opened_from_a_path_does_not_ask_about_outside_files() {
        for (file, files_beside) in [("Film.sqproj", false), ("Film/Untitled Project.sqproj", true)] {
            let Some(r) = opened_project_outside_import(file, files_beside, false) else { return };
            assert_eq!(r.asked, None, "{file}: a loose project keeps outside files in place without a question");
            assert!(r.imported.is_empty(), "{file}");
            assert!(r.status.starts_with("Kept 1 file where it is"), "{file}: the status line says why: {}", r.status);
            assert!(r.paths.iter().all(|p| !p.contains("Files/Imported")), "{file}: {:?}", r.paths);
        }
    }

    /// `import:<path>` is the window's file drop (`App::drop_files`), so the Project panel lists the clip.
    #[test]
    fn an_import_step_puts_the_file_in_the_project_panel() {
        let dir = scratch("shot-import");
        let Some(made) = make_clip(&dir) else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let clip = dir.join("zebra-import.mp4");
        std::fs::rename(&made, &clip).expect("rename the clip");
        let (session, _) = crate::untitled_session(&dir);
        let file = dir.join("p.sqproj");
        let mut session = sq_editor_session::EditorSession::new(
            session.project().clone(),
            sq_editor_session::SessionDeps::headless(dir.clone()),
        );
        session.save_as(&file).expect("save the test project");
        let (app, _) = build_in(&dir.join("support"), 1280, 800, 1.0, Some(&file), Path::new("/nonexistent"));
        let mut slots = ImageSlots::default();
        assert_eq!(app.with(|a| a.session().project().media.len()), Some(0));
        let import = crate::cli::Step::Import(clip);
        run_step(&app, &import, 1.0, (1280, 800), &mut slots).expect("the import runs");
        assert_eq!(app.with(|a| a.session().project().media.len()), Some(1));
        let text = app
            .with(|a| {
                a.frame(1280, 800);
                a11y_lines(&crate::a11y::tree_update("Sequence Studio", a.accessibility(true).take()).nodes)
            })
            .unwrap_or_default();
        assert!(text.contains("zebra-import"), "the Project panel lists no row for the file:\n{text}");
        let missing = crate::cli::Step::Import(dir.join("missing.mp4"));
        assert!(run_step(&app, &missing, 1.0, (1280, 800), &mut slots).is_err(), "a missing file fails loudly");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
