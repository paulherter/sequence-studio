//! The click sweep of the use pass (check U1 of docs/contracts/use-pass.md): `--use-pass <dir>` runs the offscreen app through
//! its main screens and clicks every control it can find. A control whose click changes nothing beyond the panel's focus
//! frame is written to `<dir>/u1-controls.tsv`, with a crop of its screen in `<dir>/crops/`.
//!
//! How the controls are found (the harness has no list of them): (1) a pointer sweep reads the tooltip and the cursor the
//! panels offer at every point; touching points with the same tooltip are one control. (2) Every button-sized rounded fill of
//! the settled frame that has a glyph on it and reacts to the pointer (the frame with the pointer on it differs there) is a
//! control too. A link that leaves the app is never clicked by its name, and a click that still tries to open something
//! outside counts as external, not as dead.

use crate::cli::{parse_focus, parse_key};
use crate::headless::{build_on, select_clip};
use crate::png;
use sq_app_shell::Headless;
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Color, DrawList, DrawQuad, InputEvent, InputKey, QuadKind, RgbaImage, SoftwareRenderer, Sources};
use sq_editor_session::WorkspacePage;
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::label_lint::visible_problem;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The most time one screen may take; a screen that runs over is written as cut short.
const BUDGET: Duration = Duration::from_secs(240);
/// The most reacting button-sized shapes one screen tries beyond the ones that have a tooltip.
const MAX_SHAPES: usize = 700;
/// Where the pointer waits while a frame is taken without it: outside the window.
const AWAY: (f32, f32) = (-50.0, -50.0);
/// Controls that leave the app (a mail draft, a browser, a file manager); never clicked by name. Matched on the tooltip.
const EXTERNAL: &[&str] =
    &["support", "feedback", "github", "discord", "reveal", "open original", "report", "website", "check for updates"];

/// One screen of the app the sweep opens: what to open and what to press before it is looked at.
struct StateSpec {
    name: &'static str,
    /// Opens the generated sample project; the Start screen otherwise.
    project: bool,
    color_page: bool,
    /// Selects the first clip, so the Controls panel has something to show.
    select: bool,
    /// The panel with the keyboard focus (`--focus` names).
    focus: Option<&'static str>,
    /// Keys pressed after the focus (`--key` specs): the Settings and Export chords.
    keys: &'static [&'static str],
    /// `--pose` names, in order.
    poses: &'static [&'static str],
}

impl StateSpec {
    const NONE: StateSpec =
        StateSpec { name: "", project: false, color_page: false, select: false, focus: None, keys: &[], poses: &[] };
}

/// Every main screen and the dialogs that open from it. The Edit page shows all its panels at once and the sweep gives each
/// click's panel the focus first, so one screen covers every focused panel (a sweep with each panel focused in turn found the
/// same controls every time); the tabs and sections that change what a panel shows are separate screens.
const STATES: &[StateSpec] = &[
    StateSpec { name: "start-home", poses: &["start-home"], ..StateSpec::NONE },
    StateSpec { name: "start-recent", poses: &["start-recent"], ..StateSpec::NONE },
    StateSpec { name: "start-templates", poses: &["start-templates"], ..StateSpec::NONE },
    StateSpec { name: "start-learn", poses: &["start-learn"], ..StateSpec::NONE },
    StateSpec { name: "start-new", poses: &["start-new"], ..StateSpec::NONE },
    StateSpec { name: "new-project", poses: &["new-project"], ..StateSpec::NONE },
    StateSpec { name: "editor", project: true, select: true, focus: Some("timeline"), ..StateSpec::NONE },
    StateSpec { name: "editor-effects", project: true, select: true, poses: &["effects"], ..StateSpec::NONE },
    StateSpec { name: "controls-max", project: true, select: true, poses: &["max-ec"], ..StateSpec::NONE },
    StateSpec { name: "captions", project: true, select: true, poses: &["captions-list"], ..StateSpec::NONE },
    StateSpec { name: "transcript", project: true, select: true, poses: &["captions-transcript"], ..StateSpec::NONE },
    StateSpec { name: "graphics", project: true, select: true, poses: &["graphics"], ..StateSpec::NONE },
    // The text layer selected: the Text block with its Look row (a dead "+" there went unseen while only a shape was).
    StateSpec { name: "graphics-text", project: true, select: true, poses: &["graphics-text"], ..StateSpec::NONE },
    StateSpec { name: "mask", project: true, select: true, poses: &["mask"], ..StateSpec::NONE },
    StateSpec { name: "transition", project: true, select: true, poses: &["transition"], ..StateSpec::NONE },
    StateSpec { name: "audio-fx", project: true, select: true, poses: &["audio-fx"], ..StateSpec::NONE },
    StateSpec { name: "color", project: true, select: true, color_page: true, ..StateSpec::NONE },
    StateSpec {
        name: "color-pro",
        project: true,
        select: true,
        color_page: true,
        poses: &["color-pro"],
        ..StateSpec::NONE
    },
    StateSpec { name: "settings", project: true, select: true, keys: &["cmd+,"], ..StateSpec::NONE },
    // Export is Cmd+M (Ctrl+M on Windows and Linux, `docs/manual/11-shortcuts.md`); Cmd+Shift+E opens nothing, so this
    // screen once repeated the editor.
    StateSpec { name: "export", project: true, select: true, keys: &["cmd+m"], ..StateSpec::NONE },
    StateSpec { name: "import-report", project: true, poses: &["import-report"], ..StateSpec::NONE },
    StateSpec { name: "dlg-about", project: true, poses: &["dlg-about"], ..StateSpec::NONE },
    StateSpec { name: "dlg-welcome", project: true, poses: &["dlg-welcome"], ..StateSpec::NONE },
    StateSpec { name: "dlg-save", project: true, poses: &["dlg-save"], ..StateSpec::NONE },
    StateSpec { name: "dlg-recovery", project: true, poses: &["dlg-recovery"], ..StateSpec::NONE },
    StateSpec { name: "dlg-relink", project: true, poses: &["dlg-relink"], ..StateSpec::NONE },
    StateSpec { name: "dlg-new-sequence", project: true, poses: &["dlg-form-new-sequence"], ..StateSpec::NONE },
    StateSpec { name: "dlg-find", project: true, poses: &["dlg-form-find"], ..StateSpec::NONE },
    StateSpec { name: "dlg-marker", project: true, poses: &["dlg-form-marker"], ..StateSpec::NONE },
];

/// What a click did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    /// The screen changed by more than the focus frame.
    Responds,
    /// Nothing changed beyond the focus frame, nothing was opened: a bug to look at.
    NoEffect,
    /// It tried to open a link, a folder or a file outside the app (the harness blocks it).
    External,
    /// It opened a file chooser (the harness cancels it).
    Picker,
    /// Not clicked: its tooltip names a link that leaves the app.
    Skipped,
}

impl Outcome {
    fn word(self) -> &'static str {
        match self {
            Outcome::Responds => "responds",
            Outcome::NoEffect => "no-effect",
            Outcome::External => "external",
            Outcome::Picker => "picker",
            Outcome::Skipped => "skipped",
        }
    }
}

/// A control the sweep found: its name (the tooltip), how it was found, its rectangle in points and where to click it.
#[derive(Clone, Debug)]
struct Found {
    name: String,
    how: &'static str,
    rect: [f32; 4],
    aim: (f32, f32),
}

/// One probed control.
struct Row {
    found: Found,
    panel: String,
    outcome: Outcome,
    crop: Option<String>,
}

/// What one screen came to.
#[derive(Default)]
struct StateReport {
    rows: Vec<Row>,
    /// The sweep ran out of time before it reached the last control.
    cut_short: bool,
    /// How many menu and context-menu titles were read, and the ones that read like internal names (where, title, why).
    titles: usize,
    bad_titles: Vec<(String, String, &'static str)>,
}

/// An app of one screen plus its own settings folder (a click that changes a setting never reaches the next one).
struct Open {
    app: Headless,
    dir: PathBuf,
}

impl Drop for Open {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Ctx<'a> {
    out: &'a Path,
    size: (u32, u32),
    pitch: u32,
    fonts: &'a Path,
    project: Option<PathBuf>,
    opened: std::cell::Cell<u32>,
}

/// Writes a small project with offline media: three clips on V1 and one on A1 (a shot with media waits for its pictures).
fn sample_project(dir: &Path) -> Result<PathBuf, String> {
    use sq_core_model::{Clip, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{Id, Time, TimeRange};
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let media: Vec<MediaRef> = (0..3_u128)
        .map(|i| {
            MediaRef::new(
                Id::from_u128(100 + i),
                &format!("clip{i}"),
                &format!("/nonexistent/clip{i}.mp4"),
                MediaFingerprint::new(i as i64 + 1),
            )
        })
        .collect();
    let two = TimeRange::new(Time::ZERO, Time::seconds(2));
    let mut video = Track::new(Id::from_u128(900), TrackKind::Video);
    video.set_clips(
        (0..3_u128)
            .map(|i| {
                Clip::new(
                    Id::from_u128(10 + i),
                    &format!("Clip {i}"),
                    Id::from_u128(100 + i),
                    TrackKind::Video,
                    two,
                    Time::seconds(2 * i as i64),
                )
            })
            .collect(),
    );
    let mut audio = Track::new(Id::from_u128(901), TrackKind::Audio);
    let four = TimeRange::new(Time::ZERO, Time::seconds(4));
    audio.set_clips(vec![Clip::new(
        Id::from_u128(20),
        "Sound",
        Id::from_u128(100),
        TrackKind::Audio,
        four,
        Time::ZERO,
    )]);
    let mut format = SequenceFormat::new(Time::new(1, 25));
    (format.width, format.height) = (1920, 1080);
    let timeline = Timeline::new(Id::from_u128(1), "Sequence 01", format, vec![video, audio]);
    let project = Project::new(Id::from_u128(2), "Use pass", media, vec![timeline]);
    let file = dir.join("use-pass.sqproj");
    let mut session =
        sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.to_path_buf()));
    session.save_as(&file).map_err(|_| String::from("the sample project could not be saved"))?;
    Ok(file)
}

fn frame(app: &Headless, size: (u32, u32)) -> DrawList {
    app.with(|a| a.frame(i64::from(size.0), i64::from(size.1)))
        .unwrap_or_else(|| DrawList::new(size.0 as f32, size.1 as f32))
}

/// Turns the loop until it has nothing more to draw, and returns the last frame it drew (or a fresh one).
fn settle(app: &Headless, size: (u32, u32)) -> DrawList {
    let mut last = None;
    for _ in 0..4 {
        match app.turn().1 {
            Some(list) => last = Some(list),
            None => break,
        }
    }
    last.unwrap_or_else(|| frame(app, size))
}

fn move_to(app: &Headless, at: (f32, f32)) {
    app.input(&InputEvent::MouseMoved { x: at.0, y: at.1 });
}

fn click(app: &Headless, at: (f32, f32)) {
    move_to(app, at);
    app.input(&InputEvent::MouseDown { x: at.0, y: at.1, modifiers: Default::default() });
    app.input(&InputEvent::MouseUp { x: at.0, y: at.1 });
}

fn open(ctx: &Ctx, spec: &StateSpec) -> Result<Open, String> {
    let n = ctx.opened.get();
    ctx.opened.set(n + 1);
    let dir = ctx.out.join("support").join(n.to_string());
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let project = if spec.project { Some(ctx.project.as_deref().ok_or("no sample project")?) } else { None };
    let page = if spec.color_page { WorkspacePage::Color } else { WorkspacePage::Edit };
    let (app, _picture) = build_on(&dir, ctx.size.0, ctx.size.1, 1.0, project, ctx.fonts, page, false);
    let open = Open { app, dir };
    let app = &open.app;
    if spec.select {
        app.with(|a| select_clip(a.session_mut(), "0"));
    }
    frame(app, ctx.size);
    if let Some(name) = spec.focus {
        let panel = parse_focus(name).ok_or_else(|| format!("bad focus {name}"))?;
        app.with(|a| a.dock_mut().map(|d| d.set_focused(Some(panel))));
        app.turn();
    }
    for text in spec.keys {
        let (key, modifiers) = parse_key(text).ok_or_else(|| format!("bad key {text}"))?;
        frame(app, ctx.size);
        app.input(&InputEvent::KeyDown { key, modifiers });
        app.turn();
    }
    for pose in spec.poses {
        frame(app, ctx.size);
        if !app.with(|a| a.shot_pose(pose)).unwrap_or(false) {
            return Err(format!("unknown or failed pose {pose}"));
        }
        app.turn();
        frame(app, ctx.size);
        app.turn();
    }
    settle(app, ctx.size);
    Ok(open)
}

/// The label the panels give the point under the pointer: its tooltip, or the cursor of a clickable thing.
fn hover_label(app: &Headless) -> Option<String> {
    app.with(|a| {
        let hover = &a.ui().hover;
        match (&hover.tooltip.text, hover.cursor) {
            (Some(tip), _) => Some(tip.clone()),
            (None, Some(DrawCursor::PointingHand)) => Some(String::from("(pointing hand)")),
            (None, Some(DrawCursor::IBeam)) => Some(String::from("(text field)")),
            _ => None,
        }
    })
    .flatten()
}

/// Moves the pointer over a grid and joins the touching points that got the same label into controls.
fn pointer_sweep(app: &Headless, size: (u32, u32), pitch: u32) -> Vec<Found> {
    let step = pitch.max(3) as i32;
    let mut cells: BTreeMap<(i32, i32), String> = BTreeMap::new();
    for gy in 0..size.1 as i32 / step {
        for gx in 0..size.0 as i32 / step {
            move_to(app, ((gx * step + step / 2) as f32, (gy * step + step / 2) as f32));
            if let Some(label) = hover_label(app) {
                cells.insert((gx, gy), label);
            }
        }
    }
    move_to(app, AWAY);
    let mut seen = HashSet::new();
    let mut found = Vec::new();
    for (&start, label) in &cells {
        if !seen.insert(start) {
            continue;
        }
        let (mut stack, mut members) = (vec![start], vec![start]);
        while let Some((cx, cy)) = stack.pop() {
            for next in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)] {
                if cells.get(&next) == Some(label) && seen.insert(next) {
                    stack.push(next);
                    members.push(next);
                }
            }
        }
        let min_x = members.iter().map(|m| m.0).min().unwrap_or(0);
        let max_x = members.iter().map(|m| m.0).max().unwrap_or(0);
        let min_y = members.iter().map(|m| m.1).min().unwrap_or(0);
        let max_y = members.iter().map(|m| m.1).max().unwrap_or(0);
        let (mid_x, mid_y) = (f64::from(min_x + max_x) / 2.0, f64::from(min_y + max_y) / 2.0);
        // The member nearest the middle, so a control that is not a rectangle is still hit.
        let nearest = members.iter().min_by(|a, b| {
            let d = |m: &&(i32, i32)| (f64::from(m.0) - mid_x).powi(2) + (f64::from(m.1) - mid_y).powi(2);
            d(a).total_cmp(&d(b))
        });
        let Some(&(nx, ny)) = nearest else { continue };
        found.push(Found {
            name: label.clone(),
            how: if label.starts_with('(') { "cursor" } else { "tip" },
            rect: [
                (min_x * step) as f32,
                (min_y * step) as f32,
                ((max_x - min_x + 1) * step) as f32,
                ((max_y - min_y + 1) * step) as f32,
            ],
            aim: ((nx * step + step / 2) as f32, (ny * step + step / 2) as f32),
        });
    }
    found
}

fn rect_of(q: &DrawQuad) -> [f32; 4] {
    [q.rect.x, q.rect.y, q.rect.w, q.rect.h]
}

fn overlaps(a: [f32; 4], b: [f32; 4]) -> bool {
    a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
}

fn inside(r: [f32; 4], p: (f32, f32), pad: f32) -> bool {
    p.0 >= r[0] - pad && p.0 <= r[0] + r[2] + pad && p.1 >= r[1] - pad && p.1 <= r[1] + r[3] + pad
}

/// The quads that touch `r`, in painter's order.
fn quads_at(list: &DrawList, r: [f32; 4]) -> Vec<DrawQuad> {
    list.quads().iter().filter(|q| overlaps(rect_of(q), r)).copied().collect()
}

/// Button-sized rounded fills with a glyph on them that look different with the pointer on them than without.
fn reacting_shapes(app: &Headless, base: &DrawList, taken: &[Found], size: (u32, u32)) -> Vec<Found> {
    let quads = base.quads();
    // A modal sheet's scrim covers the whole window: what was drawn before it is behind it and no control, and its centre is
    // the sheet's own (the Normal dropdown of Effect Controls behind the Export sheet was swept as a control that did nothing).
    let scrim = quads
        .iter()
        .rposition(|q| q.kind == QuadKind::Shape && q.rect.w >= size.0 as f32 - 1.0 && q.rect.h >= size.1 as f32 - 1.0);
    let marks: Vec<[f32; 4]> = quads
        .iter()
        .filter(|q| matches!(q.kind, QuadKind::Glyph | QuadKind::Segment | QuadKind::Triangle | QuadKind::Image))
        .map(rect_of)
        .collect();
    let mut seen = HashSet::new();
    let mut shapes: Vec<[f32; 4]> = quads
        .iter()
        .enumerate()
        .filter(|(i, _)| scrim.is_none_or(|s| *i > s))
        .map(|(_, q)| q)
        .filter(|q| q.kind == QuadKind::Image || q.kind == QuadKind::Shape && q.stroke == 0.0 && q.radius >= 2.0)
        .filter(|q| {
            q.kind == QuadKind::Image
                || marks.iter().any(|m| inside(rect_of(q), (m[0] + m[2] / 2.0, m[1] + m[3] / 2.0), 0.0))
        })
        .map(rect_of)
        .filter(|r| (14.0..=640.0).contains(&r[2]) && (14.0..=400.0).contains(&r[3]))
        .filter(|r| r[0] >= 0.0 && r[1] >= 0.0 && r[0] + r[2] <= size.0 as f32 && r[1] + r[3] <= size.1 as f32)
        .filter(|r| seen.insert((r[0] as i32, r[1] as i32, r[2] as i32, r[3] as i32)))
        .collect();
    shapes.sort_by(|a, b| (a[1], a[0]).partial_cmp(&(b[1], b[0])).unwrap_or(std::cmp::Ordering::Equal));
    // The frame with the pointer away, taken now: the pointer sweep before took time, and a sheet's own motion since `base`
    // is not the pointer's doing.
    move_to(app, AWAY);
    let base = &settle(app, size);
    let mut found = Vec::new();
    for r in shapes {
        let centre = (r[0] + r[2] / 2.0, r[1] + r[3] / 2.0);
        // The same shape drawn twice (a fill and its highlight a point apart) is one control.
        let twin = |f: &Found| f.rect.iter().zip(&r).all(|(a, b)| (a - b).abs() <= 3.0);
        if found.iter().any(twin) || found.len() >= MAX_SHAPES || taken.iter().any(|t| inside(t.rect, centre, 2.0)) {
            continue;
        }
        // The focus frame lies on the panel's edge: look only at what sits inside the shape.
        let core = [r[0] + 3.0, r[1] + 3.0, (r[2] - 6.0).max(1.0), (r[3] - 6.0).max(1.0)];
        let before = quads_at(base, core);
        move_to(app, centre);
        let hovered = settle(app, size);
        if quads_at(&hovered, core) != before {
            found.push(Found { name: String::from("(no tip)"), how: "hover", rect: r, aim: centre });
        }
    }
    move_to(app, AWAY);
    found
}

/// Controls that show themselves only under the pointer (a segment of a segmented control, a quiet dropdown): they have no
/// tip, no pointing hand and no fill at rest, so the hover fill is the only thing new in the frame. Looked for on a grid, on
/// the modal screens only (Settings, Export): the panels behind a scrim take no pointer, so a new fill under it is the sheet's.
fn hover_fills(app: &Headless, taken: &[Found], size: (u32, u32), pitch: u32) -> Vec<Found> {
    let step = pitch.max(10) as i32;
    move_to(app, AWAY);
    settle(app, size);
    let base = settle(app, size);
    let at_rest = base.quads();
    let mut found: Vec<Found> = Vec::new();
    for gy in 0..size.1 as i32 / step {
        for gx in 0..size.0 as i32 / step {
            let at = ((gx * step + step / 2) as f32, (gy * step + step / 2) as f32);
            if found.len() >= MAX_SHAPES || found.iter().chain(taken).any(|f| inside(f.rect, at, 0.0)) {
                continue;
            }
            move_to(app, at);
            let hovered = settle(app, size);
            let under = [at.0, at.1, 1.0, 1.0];
            let fill = quads_at(&hovered, under)
                .into_iter()
                .filter(|q| q.kind == QuadKind::Shape && !at_rest.contains(q))
                .map(|q| rect_of(&q))
                .filter(|r| (14.0..=640.0).contains(&r[2]) && (14.0..=400.0).contains(&r[3]))
                .min_by(|a, b| (a[2] * a[3]).total_cmp(&(b[2] * b[3])));
            let Some(r) = fill else { continue };
            let twin = |f: &Found| f.rect.iter().zip(&r).all(|(a, b)| (a - b).abs() <= 3.0);
            if !found.iter().chain(taken).any(twin) {
                found.push(Found {
                    name: String::from("(no tip)"),
                    how: "hover",
                    rect: r,
                    aim: (r[0] + r[2] / 2.0, r[1] + r[3] / 2.0),
                });
            }
        }
    }
    move_to(app, AWAY);
    found
}

struct Probed {
    outcome: Outcome,
    before: DrawList,
}

/// Clicks `at` the way a user does (pointer moves there, press, release) on a panel that already has the focus, and tells
/// whether the screen changed by more than that. The pointer waits outside the window for both frames, so a hover
/// highlight or a tooltip is in neither.
fn probe(app: &Headless, size: (u32, u32), at: (f32, f32)) -> Probed {
    let panel =
        app.with(|a| a.dock_mut().and_then(|d| d.panel_at(CGPoint::new(f64::from(at.0), f64::from(at.1))))).flatten();
    app.with(|a| a.dock_mut().map(|d| d.set_focused(panel)));
    move_to(app, AWAY);
    let before = settle(app, size);
    let (opens, pickers) = (sq_app_hosts::blocked_external_opens(), sq_app_shell::file_pickers_cancelled());
    click(app, at);
    settle(app, size);
    move_to(app, AWAY);
    let after = settle(app, size);
    let outcome = if sq_app_hosts::blocked_external_opens() != opens {
        Outcome::External
    } else if sq_app_shell::file_pickers_cancelled() != pickers {
        Outcome::Picker
    } else if before.quads() == after.quads() {
        Outcome::NoEffect
    } else {
        Outcome::Responds
    };
    Probed { outcome, before }
}

/// A click that changed the screen: closes what it opened with Escape; true when the screen is as it was before the click.
fn put_back(app: &Headless, size: (u32, u32), before: &DrawList) -> bool {
    app.input(&InputEvent::KeyDown { key: InputKey::Escape, modifiers: Default::default() });
    move_to(app, AWAY);
    settle(app, size).quads() == before.quads()
}

fn render(app: &Headless, size: (u32, u32)) -> Option<RgbaImage> {
    app.with(|a| {
        let list = a.frame(i64::from(size.0), i64::from(size.1));
        let sources = Sources { atlas: a.atlas(), video: None, images: &[] };
        SoftwareRenderer::render_8bit(
            &list,
            size.0 as usize,
            size.1 as usize,
            Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 },
            &sources,
        )
    })
}

/// The screen around `r` (40 points on each side) with the control outlined in red.
fn crop(image: &RgbaImage, r: [f32; 4]) -> RgbaImage {
    let margin = 40.0;
    let x0 = (r[0] - margin).max(0.0) as usize;
    let y0 = (r[1] - margin).max(0.0) as usize;
    let x1 = ((r[0] + r[2] + margin) as usize).min(image.width);
    let y1 = ((r[1] + r[3] + margin) as usize).min(image.height);
    let (w, h) = (x1.saturating_sub(x0).max(1), y1.saturating_sub(y0).max(1));
    let mut pixels = vec![0u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let from = ((y0 + y) * image.width + x0 + x) * 4;
            if let (Some(src), Some(dst)) =
                (image.pixels.get(from..from + 4), pixels.get_mut((y * w + x) * 4..(y * w + x) * 4 + 4))
            {
                dst.copy_from_slice(src);
            }
        }
    }
    let (rx0, ry0) = ((r[0].max(0.0) as usize).saturating_sub(x0), (r[1].max(0.0) as usize).saturating_sub(y0));
    let (rx1, ry1) = ((rx0 + r[2] as usize).min(w.saturating_sub(1)), (ry0 + r[3] as usize).min(h.saturating_sub(1)));
    let mut mark = |x: usize, y: usize| {
        if let Some(px) = pixels.get_mut((y * w + x) * 4..(y * w + x) * 4 + 4) {
            px.copy_from_slice(&[255, 40, 40, 255]);
        }
    };
    for x in rx0..=rx1 {
        mark(x, ry0.min(h - 1));
        mark(x, ry1);
    }
    for y in ry0..=ry1 {
        mark(rx0.min(w - 1), y);
        mark(rx1, y);
    }
    RgbaImage { width: w, height: h, pixels }
}

/// Menus whose rows are the user's own names (projects, paths): the row itself is read, not what it lists.
const USER_DATA_MENUS: &[&str] = &["Open Recent"];

/// The titles of `items` and of their submenus: each row's title and help line.
fn collect_titles(items: &[SQMenuItem], place: &str, out: &mut BTreeSet<(String, String)>) {
    for i in items {
        if !i.title.is_empty() {
            out.insert((place.to_string(), i.title.clone()));
        }
        if let Some(help) = &i.help {
            out.insert((format!("{place} help"), help.clone()));
        }
        if let Some(sub) = i.submenu.as_ref().filter(|_| !USER_DATA_MENUS.contains(&i.title.as_str())) {
            collect_titles(sub, place, out);
        }
    }
}

/// Every title of the menu bar and, with a `grid` of columns and rows, of the context menus a right click opens over a grid
/// of the window: (where, title).
pub(crate) fn menu_titles(app: &Headless, size: (u32, u32), grid: Option<(u32, u32)>) -> BTreeSet<(String, String)> {
    let mut titles = BTreeSet::new();
    for menu in app.with(|a| a.menus().to_vec()).unwrap_or_default() {
        titles.insert((String::from("menu bar"), menu.title.clone()));
        collect_titles(&menu.items, &format!("menu bar > {}", menu.title), &mut titles);
    }
    let Some((cols, rows)) = grid else { return titles };
    let mut seen = HashSet::new();
    let escape = InputEvent::KeyDown { key: InputKey::Escape, modifiers: Default::default() };
    for gy in 0..rows {
        for gx in 0..cols {
            let at = (size.0 as f32 * (gx as f32 + 0.5) / cols as f32, size.1 as f32 * (gy as f32 + 0.5) / rows as f32);
            app.input(&InputEvent::MouseDown { x: at.0, y: at.1, modifiers: sq_draw::InputModifiers::SECONDARY });
            app.turn();
            let items = app.with(|a| a.open_menu_items()).unwrap_or_default();
            if !items.is_empty() && seen.insert(sq_uikit::menu_outline::menu_outline(&items, 0)) {
                collect_titles(&items, &format!("context menu at {},{}", at.0 as i32, at.1 as i32), &mut titles);
            }
            app.input(&escape);
            app.turn();
        }
    }
    titles
}

/// The titles of `app` and what is wrong with them (the label check U5, over what the user reads in menus).
pub(crate) fn menu_title_problems(
    app: &Headless,
    size: (u32, u32),
    grid: Option<(u32, u32)>,
) -> (usize, Vec<(String, String, &'static str)>) {
    let titles = menu_titles(app, size, grid);
    let bad =
        titles.iter().filter_map(|(place, t)| visible_problem(t).map(|why| (place.clone(), t.clone(), why))).collect();
    (titles.len(), bad)
}

fn sweep(ctx: &Ctx, spec: &StateSpec) -> Result<StateReport, String> {
    let began = Instant::now();
    let mut screen = open(ctx, spec)?;
    let base = settle(&screen.app, ctx.size);
    let picture = render(&screen.app, ctx.size);
    let mut found = pointer_sweep(&screen.app, ctx.size, ctx.pitch);
    let shapes = reacting_shapes(&screen.app, &base, &found, ctx.size);
    found.extend(shapes);
    if !spec.keys.is_empty() {
        let fills = hover_fills(&screen.app, &found, ctx.size, ctx.pitch);
        found.extend(fills);
    }
    found.sort_by(|a, b| (a.aim.1, a.aim.0).partial_cmp(&(b.aim.1, b.aim.0)).unwrap_or(std::cmp::Ordering::Equal));
    let mut report = StateReport::default();
    {
        // A right click selects what is under it: the titles are read on an app of their own. Dialogs and the Settings and
        // Export sheets are modal, a right click there opens no menu.
        let scan = open(ctx, spec)?;
        let grid = (spec.keys.is_empty() && !spec.name.starts_with("dlg-")).then_some((36, 24));
        (report.titles, report.bad_titles) = menu_title_problems(&scan.app, ctx.size, grid);
    }
    for f in found {
        if began.elapsed() > BUDGET {
            report.cut_short = true;
            break;
        }
        let panel = screen
            .app
            .with(|a| a.dock_mut().and_then(|d| d.panel_at(CGPoint::new(f64::from(f.aim.0), f64::from(f.aim.1)))))
            .flatten()
            .map_or_else(|| String::from("-"), |p| format!("{p:?}"));
        let lower = f.name.to_lowercase();
        let outcome = if EXTERNAL.iter().any(|e| lower.contains(e)) {
            Outcome::Skipped
        } else {
            let probed = probe(&screen.app, ctx.size, f.aim);
            if probed.outcome == Outcome::Responds && !put_back(&screen.app, ctx.size, &probed.before) {
                screen = open(ctx, spec)?;
                settle(&screen.app, ctx.size);
            }
            probed.outcome
        };
        let crop_path = match (outcome, &picture) {
            (Outcome::NoEffect, Some(image)) => {
                let name = format!("crops/{}-{}.png", spec.name, report.rows.len());
                std::fs::write(ctx.out.join(&name), png::encode(&crop(image, f.rect))).ok().map(|()| name)
            }
            _ => None,
        };
        report.rows.push(Row { found: f, panel, outcome, crop: crop_path });
    }
    Ok(report)
}

fn clean(text: &str) -> String {
    text.replace(['\t', '\n', '\r'], " ")
}

/// A control that is known to do nothing on purpose: one line of the known file, `screen<TAB>name<TAB>x<TAB>y<TAB>reason`.
struct Known {
    state: String,
    name: String,
    at: (f32, f32),
}

fn read_known(path: Option<&Path>) -> Vec<Known> {
    let Some(text) = path.and_then(|p| std::fs::read_to_string(p).ok()) else { return Vec::new() };
    text.lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let mut cols = l.split('\t');
            let (state, name) = (cols.next()?, cols.next()?);
            let at = (cols.next()?.trim().parse().ok()?, cols.next()?.trim().parse().ok()?);
            Some(Known { state: state.to_string(), name: name.to_string(), at })
        })
        .collect()
}

fn is_known(known: &[Known], state: &str, row: &Row) -> bool {
    known.iter().any(|k| {
        (k.state == state || k.state == "*")
            && k.name == row.found.name
            && (k.at.0 - row.found.aim.0).abs() <= 8.0
            && (k.at.1 - row.found.aim.1).abs() <= 8.0
    })
}

/// A control of the report's list: how it was found, the screens it did nothing on, the crop of the first one.
struct ListedControl {
    how: &'static str,
    screens: Vec<&'static str>,
    crop: String,
}

/// The files one run leaves in `out`: the tables, the report and the one-line results the scripts read.
struct Outputs {
    states: String,
    controls: String,
    labels: String,
    report: String,
    no_effect: usize,
    /// The same controls once each: (panel, name, x, y).
    distinct: BTreeSet<(String, String, i32, i32)>,
    known: usize,
    unopened: usize,
    cut_short: usize,
    controls_total: usize,
    titles: usize,
    bad_titles: usize,
}

impl Outputs {
    fn new() -> Outputs {
        Outputs {
            states: String::from(
                "state\tcontrols\tresponds\tno_effect\texternal\tpicker\tskipped\tcut_short\ttitles\terror\n",
            ),
            controls: String::from("state\toutcome\thow\tx\ty\tw\th\tpanel\tname\tcrop\n"),
            labels: String::from("state\twhere\tproblem\ttitle\n"),
            report: String::new(),
            no_effect: 0,
            distinct: BTreeSet::new(),
            known: 0,
            unopened: 0,
            cut_short: 0,
            controls_total: 0,
            titles: 0,
            bad_titles: 0,
        }
    }

    fn add(&mut self, spec: &StateSpec, result: &Result<StateReport, String>, known: &[Known]) {
        let report = match result {
            Ok(report) => report,
            Err(e) => {
                self.unopened += 1;
                let _ = writeln!(self.states, "{}\t0\t0\t0\t0\t0\t0\t0\t0\t{}", spec.name, clean(e));
                return;
            }
        };
        let count = |o: Outcome| report.rows.iter().filter(|r| r.outcome == o).count();
        let known_here =
            report.rows.iter().filter(|r| r.outcome == Outcome::NoEffect && is_known(known, spec.name, r)).count();
        let _ = writeln!(
            self.states,
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t",
            spec.name,
            report.rows.len(),
            count(Outcome::Responds),
            count(Outcome::NoEffect) - known_here,
            count(Outcome::External),
            count(Outcome::Picker),
            count(Outcome::Skipped),
            u8::from(report.cut_short),
            report.titles
        );
        self.controls_total += report.rows.len();
        self.no_effect += count(Outcome::NoEffect) - known_here;
        for r in report.rows.iter().filter(|r| r.outcome == Outcome::NoEffect && !is_known(known, spec.name, r)) {
            let at = (r.found.aim.0 as i32, r.found.aim.1 as i32);
            self.distinct.insert((clean(&r.panel), clean(&r.found.name), at.0, at.1));
        }
        self.known += known_here;
        self.cut_short += usize::from(report.cut_short);
        self.titles += report.titles;
        self.bad_titles += report.bad_titles.len();
        for r in &report.rows {
            let outcome = if r.outcome == Outcome::NoEffect && is_known(known, spec.name, r) {
                "known"
            } else {
                r.outcome.word()
            };
            let _ = writeln!(
                self.controls,
                "{}\t{outcome}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                spec.name,
                r.found.how,
                r.found.aim.0,
                r.found.aim.1,
                r.found.rect[2],
                r.found.rect[3],
                clean(&r.panel),
                clean(&r.found.name),
                r.crop.as_deref().unwrap_or("")
            );
        }
        for (place, title, why) in &report.bad_titles {
            let _ = writeln!(self.labels, "{}\t{}\t{why}\t{}", spec.name, clean(place), clean(title));
        }
    }

    /// `u1-report.md`: a table per screen and the list of controls that did nothing, with their crops.
    fn render_report(&mut self, results: &[(&'static str, Result<StateReport, String>)], known: &[Known]) {
        let mut out = format!(
            "# U1 click sweep\n\n{} controls on {} screens; {} clicks did nothing, on {} different controls ({} more known to do nothing on purpose).\n\n",
            self.controls_total,
            results.len(),
            self.no_effect,
            self.distinct.len(),
            self.known
        );
        out.push_str("| screen | controls | respond | no effect | external | picker | skipped |\n|---|---|---|---|---|---|---|\n");
        for (name, result) in results {
            match result {
                Ok(r) => {
                    let n = |o: Outcome| r.rows.iter().filter(|x| x.outcome == o).count();
                    let _ = writeln!(
                        out,
                        "| {name}{} | {} | {} | {} | {} | {} | {} |",
                        if r.cut_short { " (cut short)" } else { "" },
                        r.rows.len(),
                        n(Outcome::Responds),
                        n(Outcome::NoEffect),
                        n(Outcome::External),
                        n(Outcome::Picker),
                        n(Outcome::Skipped)
                    );
                }
                Err(e) => {
                    let _ = writeln!(out, "| {name} | did not open: {} | | | | | |", clean(e));
                }
            }
        }
        out.push_str("\n## Controls whose click changed nothing beyond the focus frame\n\n");
        out.push_str("| panel | control | found by | click at | screens | crop |\n|---|---|---|---|---|---|\n");
        // One line per control; the screens that show it in the last column, the crop of the first one.
        let mut lines: BTreeMap<(String, String, i32, i32), ListedControl> = BTreeMap::new();
        for (name, result) in results {
            let Ok(r) = result else { continue };
            for row in r.rows.iter().filter(|x| x.outcome == Outcome::NoEffect && !is_known(known, name, x)) {
                let key = (clean(&row.panel), clean(&row.found.name), row.found.aim.0 as i32, row.found.aim.1 as i32);
                let crop = row.crop.clone().unwrap_or_default();
                let listed =
                    lines.entry(key).or_insert(ListedControl { how: row.found.how, screens: Vec::new(), crop });
                listed.screens.push(*name);
            }
        }
        for ((panel, control, x, y), ListedControl { how, screens, crop }) in &lines {
            let _ = writeln!(out, "| {panel} | {control} | {how} | {x},{y} | {} | {crop} |", screens.join(", "));
        }
        self.report = out;
    }

    fn write(&self, out: &Path) -> Result<(), String> {
        let write = |name: &str, text: &str| std::fs::write(out.join(name), text).map_err(|e| format!("{name}: {e}"));
        write("u1-states.tsv", &self.states)?;
        write("u1-controls.tsv", &self.controls)?;
        write("u1-report.md", &self.report)?;
        write("u5-labels.tsv", &self.labels)?;
        let u1 = if self.unopened > 0 {
            format!("FAIL\t{} screens did not open", self.unopened)
        } else if self.no_effect > 0 {
            format!(
                "FAIL\t{} different controls changed nothing when clicked ({} clicks on {} controls)",
                self.distinct.len(),
                self.no_effect,
                self.controls_total
            )
        } else {
            format!("PASS\t{} controls on every screen respond{}", self.controls_total, self.cut_note())
        };
        write("u1-result.txt", &format!("{u1}\n"))?;
        let u5 = if self.bad_titles > 0 {
            format!("FAIL\t{} of {} menu titles read like internal names", self.bad_titles, self.titles)
        } else {
            format!("PASS\t{} menu and context menu titles read like text", self.titles)
        };
        write("u5-result.txt", &format!("{u5}\n"))
    }

    fn cut_note(&self) -> String {
        if self.cut_short > 0 { format!(" ({} screens cut short)", self.cut_short) } else { String::new() }
    }
}

/// Runs the sweep over `only` (every screen when empty) and writes the tables, `u1-report.md` and the results into `out`.
pub(crate) fn run(
    out: &Path,
    size: (u32, u32),
    pitch: u32,
    only: &[String],
    known: Option<&Path>,
    project: Option<&Path>,
    fonts: &Path,
) -> Result<(), String> {
    if sq_app_hosts::external_open_allowed() {
        return Err(String::from("--use-pass needs the external opens off (SQ_NO_EXTERNAL_OPEN=1)"));
    }
    if let Some(bad) = only.iter().find(|n| !STATES.iter().any(|s| s.name == n.as_str())) {
        let names: Vec<&str> = STATES.iter().map(|s| s.name).collect();
        return Err(format!("--states: no screen {bad}; known: {}", names.join(", ")));
    }
    std::fs::create_dir_all(out.join("crops")).map_err(|e| format!("{}: {e}", out.display()))?;
    let project = match project {
        Some(p) => p.to_path_buf(),
        None => sample_project(&out.join("work"))?,
    };
    let known = read_known(known);
    let ctx = Ctx { out, size, pitch, fonts, project: Some(project), opened: std::cell::Cell::new(0) };
    let mut outputs = Outputs::new();
    let mut results = Vec::new();
    for spec in STATES.iter().filter(|s| only.is_empty() || only.iter().any(|n| n == s.name)) {
        let began = Instant::now();
        let result = sweep(&ctx, spec);
        outputs.add(spec, &result, &known);
        results.push((spec.name, result));
        eprintln!("use-pass: {} done in {:.1} s", spec.name, began.elapsed().as_secs_f64());
        // Written after every screen, so a run that is killed keeps what it had.
        outputs.render_report(&results, &known);
        outputs.write(out)?;
    }
    let _ = std::fs::remove_dir_all(out.join("support"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The sweep screen named "export" shows the Export sheet: the sweep once swept the editor under the name
    /// "export" because its key opened nothing. The sheet is told apart from the editor by the Export sheet's footer buttons.
    #[test]
    fn the_export_screen_shows_the_export_sheet() {
        let dir = std::env::temp_dir().join(format!("sq-use-pass-sheets-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let project = sample_project(&dir.join("work")).expect("a sample project");
        let fonts = crate::break_ui::fonts();
        let ctx = Ctx {
            out: &dir,
            size: (1440, 900),
            pitch: 6,
            fonts: &fonts,
            project: Some(project),
            opened: Default::default(),
        };
        let drawn = |name: &str| -> Vec<String> {
            let spec = STATES.iter().find(|s| s.name == name).expect("a known screen");
            let screen = open(&ctx, spec).expect("the screen opens");
            sq_draw::text_log::start();
            screen.app.with(|a| a.set_needs_redraw());
            settle(&screen.app, ctx.size);
            sq_draw::text_log::finish().into_iter().filter_map(|r| r.drawn).collect()
        };
        let export = drawn("export");
        let editor = drawn("editor");
        let _ = std::fs::remove_dir_all(&dir);
        let has = |texts: &[String], t: &str| texts.iter().any(|d| d == t);
        assert!(has(&export, "Other Formats\u{2026}"), "the export screen shows the Export sheet: {export:?}");
        assert!(!has(&editor, "Other Formats\u{2026}"), "the editor does not");
    }

    /// A sheet is modal for the pointer: with the Export or the Settings sheet up, the panels behind the scrim get no hover
    /// highlight, no tip and no cursor (the use pass found the Effect Controls blend dropdown lighting up behind the Export
    /// sheet). Hovering a strip left of the sheet must leave the frame as it is with the pointer away. One test per sheet:
    /// the sweeps draw about 2,700 frames each, and two tests run side by side where one ran for 80 s.
    #[test]
    fn the_export_sheet_takes_the_hover_of_the_panels_behind_it() {
        assert_no_hover_behind_the_sheet("export");
    }

    #[test]
    fn the_settings_sheet_takes_the_hover_of_the_panels_behind_it() {
        assert_no_hover_behind_the_sheet("settings");
    }

    fn assert_no_hover_behind_the_sheet(name: &str) {
        let dir = std::env::temp_dir().join(format!("sq-use-pass-hover-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let project = sample_project(&dir.join("work")).expect("a sample project");
        let fonts = crate::break_ui::fonts();
        let ctx = Ctx {
            out: &dir,
            size: (1440, 900),
            pitch: 6,
            fonts: &fonts,
            project: Some(project),
            opened: Default::default(),
        };
        let mut leaks = Vec::new();
        let spec = STATES.iter().find(|s| s.name == name).expect("a known screen");
        let screen = open(&ctx, spec).expect("the screen opens");
        move_to(&screen.app, AWAY);
        settle(&screen.app, ctx.size);
        let base = settle(&screen.app, ctx.size);
        // The Export sheet is 1000 points wide and centered: its edge is at x = 220, so the strip to 210 lies behind the scrim.
        for y in (8..840).step_by(8) {
            for x in (8..210).step_by(8) {
                move_to(&screen.app, (x as f32, y as f32));
                let hovered = settle(&screen.app, ctx.size);
                let shape = screen.app.with(|a| a.ui().hover.cursor).flatten();
                // Only what sits at the pointer: a preview that arrives meanwhile changes the sheet elsewhere.
                let near = [x as f32 - 30.0, y as f32 - 30.0, 60.0, 60.0];
                if quads_at(&hovered, near) != quads_at(&base, near) || !matches!(shape, None | Some(DrawCursor::Arrow))
                {
                    let (h, b) = (quads_at(&hovered, near), quads_at(&base, near));
                    let diff: Vec<_> =
                        h.iter().filter(|q| !b.contains(q)).map(|q| format!("{:?} {:?}", q.kind, rect_of(q))).collect();
                    leaks.push(format!("{name} at {x},{y}: cursor {shape:?} new {diff:?}"));
                }
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
        leaks.truncate(12);
        assert!(leaks.is_empty(), "hover reaches the panels behind a sheet: {leaks:?}");
    }

    /// The menu bar and the context menus of the screens that have them read like text for people: no code, snake_case,
    /// Debug text or German leftover in any title (check U5, over the menus the way the user meets them).
    #[test]
    fn every_menu_and_context_menu_title_reads_like_text() {
        let dir = std::env::temp_dir().join(format!("sq-use-pass-labels-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let project = sample_project(&dir.join("work")).expect("a sample project");
        let fonts = crate::break_ui::fonts();
        let ctx = Ctx {
            out: &dir,
            size: (1440, 900),
            pitch: 6,
            fonts: &fonts,
            project: Some(project),
            opened: Default::default(),
        };
        let mut all_bad = Vec::new();
        let mut checked = 0;
        // A coarse grid keeps the test short (a debug build draws a frame per right click); the sweep uses a finer one.
        for name in ["editor", "color", "editor-effects", "captions"] {
            let spec = STATES.iter().find(|s| s.name == name).expect("a known screen");
            let screen = open(&ctx, spec).expect("the screen opens");
            let (n, bad) = menu_title_problems(&screen.app, ctx.size, Some((24, 15)));
            checked += n;
            all_bad.extend(bad.into_iter().map(|(place, title, why)| format!("{name}: {place}: {title:?} ({why})")));
        }
        let _ = std::fs::remove_dir_all(&dir);
        assert!(checked > 300, "the menus were read: {checked} titles");
        all_bad.sort();
        all_bad.dedup();
        assert!(all_bad.is_empty(), "menu titles that read like internal names:\n{}", all_bad.join("\n"));
    }
}
