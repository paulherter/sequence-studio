//! The component catalogue renderer: every component x state x dark/light at 2x into `$SQ_CATALOGUE_DIR` as
//! `<id>-<state>-<dark|light>@2x.png` (the names `design/components/<id>.md` links). One function per group so batches that
//! add components do not touch the same lines: `controls`, `overlays`, `shell`, `timeline`, `inspector`, `lists`, `start`, `color`, `forms`, `settings_group`, `dialogs`, `panels`, `menus`.
//!
//! Render: `SQ_CATALOGUE_DIR=<dir> cargo test -p sq-app-hosts catalogue_shots -- --ignored`. The shots use the bundled Inter,
//! while the Mac app draws with SF, so glyph shapes differ from the app.

use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::ui_cx::UiCx;
use sq_draw::{Canvas, DrawTheme, GlyphAtlas, SoftwareRenderer, Sources, TextMeasure};
use crate::chrome::test_access::{Mouse, StatusBarContent, TitleRow, status_bar};
use sq_draw::{InputEvent, InputModifiers};
use sq_draw_shell::{FormRow, MenuListView, ShellDialog, ShellDock, ShellForm, Sidebar};
use sq_draw_timeline::tool_strip::ToolStrip;
use sq_editor_session::{MonitorQuality, SaveStatus, TimelineTool, ToolState};
use sq_uikit::command_map::CommandMap;
use sq_uikit::panel_id::PanelID;
use std::time::{Duration, SystemTime};
use sq_uikit::sqdialog_model::SQDialogRole;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use sq_uikit::appearance_palette::{AppearanceMode, AppearanceSettings};
use sq_uikit::controls_grid::CGRect;
use sq_uikit::controls_grid::CGPoint;
use std::path::{Path, PathBuf};

const SCALE: f32 = 2.0;

/// A state a component can be shown in. `Selected` means on / checked / active, where the component has that.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Default,
    Hover,
    Pressed,
    Focus,
    Disabled,
    Selected,
}

impl State {
    const ALL: [State; 6] = [State::Default, State::Hover, State::Pressed, State::Focus, State::Disabled, State::Selected];
    fn name(self) -> &'static str {
        match self {
            State::Default => "default",
            State::Hover => "hover",
            State::Pressed => "pressed",
            State::Focus => "focus",
            State::Disabled => "disabled",
            State::Selected => "selected",
        }
    }
    fn touch(self) -> Touch {
        Touch {
            hovering: self == State::Hover,
            pressed: self == State::Pressed,
            disabled: self == State::Disabled,
            focused: self == State::Focus,
        }
    }
}

/// What a draw function gets: the canvas, the theme of the mode, the state and its touch.
struct Cx<'a, 'b> {
    c: &'a mut Canvas<'b>,
    t: &'a DrawTheme,
    state: State,
    touch: Touch,
}

/// One catalogue entry: id, size in points, the states it shows, and its drawing.
struct Entry {
    id: &'static str,
    size: (f32, f32),
    states: &'static [State],
    draw: fn(&mut Cx),
}

const MODES: [(&str, AppearanceMode); 2] = [("dark", AppearanceMode::Dark), ("light", AppearanceMode::Light)];

fn theme(mode: AppearanceMode) -> DrawTheme {
    DrawTheme::new(&AppearanceSettings::new(mode, 0, 50), 1.0)
}

fn out_dir() -> Option<PathBuf> {
    let dir = PathBuf::from(std::env::var_os("SQ_CATALOGUE_DIR")?);
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn write_png(path: &Path, w: usize, h: usize, rgba: &[u8]) {
    let file = std::fs::File::create(path).unwrap_or_else(|e| panic!("create {}: {e}", path.display()));
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().unwrap_or_else(|e| panic!("png header: {e}"));
    writer.write_image_data(rgba).unwrap_or_else(|e| panic!("png data: {e}"));
}

/// Renders a list onto a transparent ground. The software renderer is opaque RGB, so the list is rendered over black and
/// over white: per pixel alpha = 1 - (white - black) / 255 and the color is the black render divided by alpha (exact for
/// source-over blending). Never flatten onto a color: the Pip and cursor PNGs must keep their alpha.
fn render_transparent(list: &sq_draw::DrawList, side: usize, src: &Sources) -> Vec<u8> {
    let on = |c: f32| SoftwareRenderer::render(list, side, side, sq_draw::Color::new(c, c, c, 1.0), src).pixels;
    matte_rgba(&on(0.0), &on(1.0))
}

fn matte_rgba(black: &[u8], white: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; black.len()];
    for ((o, b), w) in out.chunks_exact_mut(4).zip(black.chunks_exact(4)).zip(white.chunks_exact(4)) {
        let diff = (0..3).map(|k| i32::from(w[k]) - i32::from(b[k])).sum::<i32>() as f32 / 3.0;
        let a = (1.0 - diff / 255.0).clamp(0.0, 1.0);
        if a > 0.0 {
            for k in 0..3 {
                o[k] = (f32::from(b[k]) / a).clamp(0.0, 255.0).round() as u8;
            }
        }
        o[3] = (a * 255.0).round() as u8;
    }
    out
}

/// Renders every entry in every state and both modes; returns the number of files written.
fn render(dir: &Path, atlas: &GlyphAtlas, entries: &[Entry]) -> usize {
    sq_draw::motion::set_snap(true);
    atlas.set_point_scale(SCALE);
    let mut written = 0;
    for e in entries {
        for (mode_name, mode) in MODES {
            let t = theme(mode);
            for &state in e.states {
                let (w, h) = ((e.size.0 * SCALE) as usize, (e.size.1 * SCALE) as usize);
                let mut c = Canvas::with_size(w as f32, h as f32, Some(atlas), SCALE);
                (e.draw)(&mut Cx { c: &mut c, t: &t, state, touch: state.touch() });
                let img = SoftwareRenderer::render(&c.list, w, h, t.panel(), &Sources { atlas: Some(atlas), ..Sources::default() });
                write_png(&dir.join(format!("{}-{}-{mode_name}@2x.png", e.id, state.name())), w, h, &img.pixels);
                written += 1;
            }
        }
    }
    written
}

const PAD: f64 = 10.0;
const ALL: &[State] = &State::ALL;
const NO_SELECTED: &[State] = &[State::Default, State::Hover, State::Pressed, State::Focus, State::Disabled];

fn label(cx: &mut Cx, text: &str, at: CGPoint) {
    cx.c.draw_text(text, at, 12.0, cx.t.label(), f64::INFINITY, 0);
}

fn button(cx: &mut Cx, kind: ButtonKind, text: &str, w: f64) {
    let r = CGRect::new(PAD, PAD, w, 22.0);
    cx.c.stone_button(r, kind, cx.touch, cx.t);
    // The filled kinds carry the on-accent / on-destructive text (white), the others the label color.
    let ink = match kind {
        ButtonKind::Accent | ButtonKind::Destructive => cx.t.token(sq_uikit::redesign_tokens::color::ON_ACCENT),
        _ => cx.t.label(),
    };
    let ink = if cx.touch.disabled { ink.with_alpha(ink.a * sq_draw::stone::DISABLED_ALPHA) } else { ink };
    cx.c.draw_text(text, CGPoint::new(PAD + 10.0, PAD + 4.0), 12.0, ink, f64::INFINITY, 0);
}

fn on(cx: &Cx) -> bool {
    cx.state == State::Selected
}

/// Buttons, fields, switch, checkbox, radio, segmented control, slider, chips.
fn controls() -> Vec<Entry> {
    vec![
        Entry { id: "button-raised", size: (100.0, 42.0), states: NO_SELECTED, draw: |cx| button(cx, ButtonKind::Raised, "Button", 59.0) },
        Entry { id: "button-primary", size: (120.0, 42.0), states: NO_SELECTED, draw: |cx| button(cx, ButtonKind::Accent, "Export", 84.0) },
        Entry { id: "button-destructive", size: (120.0, 42.0), states: NO_SELECTED, draw: |cx| button(cx, ButtonKind::Destructive, "Delete", 84.0) },
        Entry {
            id: "field-number",
            size: (90.0, 40.0),
            states: &[State::Default, State::Hover, State::Focus, State::Disabled, State::Selected],
            // The real panel number (`ScrubFieldControl`, `well: false`): plain text at rest, the well on hover. Focus is the
            // field with keyboard focus (the ring shows; a pointer scrub still shows none, PRUEF-LIN-3 D4); Selected is the editing state.
            draw: |cx| {
                let mut f = sq_draw::ScrubFieldControl::new(100.0);
                f.well = false;
                f.unit = "%".into();
                f.hovering = cx.state == State::Hover;
                f.keyboard_focus = cx.state == State::Focus;
                f.is_enabled = cx.state != State::Disabled;
                if on(cx) {
                    f.begin_editing();
                }
                let bounds = CGRect::new(PAD, PAD, 62.0, 20.0);
                f.draw(cx.c, bounds, cx.t, cx.state == State::Focus || on(cx), &mut UiCx::new());
            },
        },
        Entry {
            id: "button-pressed-pair",
            size: (200.0, 42.0),
            states: &[State::Default],
            // The default button next to the same button pressed: both have the same size (press = darker, never smaller).
            draw: |cx| {
                let rest = CGRect::new(PAD, PAD, 84.0, 22.0);
                let down = CGRect::new(PAD + 100.0, PAD, 84.0, 22.0);
                cx.c.stone_button(rest, ButtonKind::Raised, Touch::default(), cx.t);
                label(cx, "Default", CGPoint::new(rest.x + 10.0, PAD + 4.0));
                cx.c.stone_button(down, ButtonKind::Raised, Touch { pressed: true, ..Touch::default() }, cx.t);
                label(cx, "Pressed", CGPoint::new(down.x + 10.0, PAD + 4.0));
            },
        },
        Entry {
            id: "switch",
            size: (56.0, 40.0),
            states: ALL,
            draw: |cx| {
                let on = on(cx);
                cx.c.stone_switch(CGRect::new(PAD, PAD, 34.0, 20.0), on, cx.touch, cx.t);
            },
        },
        Entry {
            id: "checkbox",
            size: (40.0, 40.0),
            states: ALL,
            draw: |cx| {
                let on = on(cx);
                cx.c.stone_checkbox(CGRect::new(PAD, PAD, 14.0, 14.0), on, cx.touch, cx.t);
            },
        },
        Entry {
            id: "radio",
            size: (40.0, 40.0),
            states: ALL,
            draw: |cx| {
                let on = on(cx);
                cx.c.stone_radio(CGRect::new(PAD, PAD, 14.0, 14.0), on, cx.touch, cx.t);
            },
        },
        Entry {
            id: "segmented",
            size: (120.0, 44.0),
            states: ALL,
            draw: |cx| {
                let on = on(cx);
                cx.c.stone_segment_track(CGRect::new(PAD, PAD, 100.0, 24.0), cx.touch, cx.t);
                cx.c.stone_segment(CGRect::new(PAD + 2.0, PAD + 2.0, 48.0, 20.0), on, cx.touch, cx.t);
                label(cx, "A", CGPoint::new(PAD + 20.0, PAD + 5.0));
                label(cx, "B", CGPoint::new(PAD + 72.0, PAD + 5.0));
            },
        },
        Entry {
            id: "slider",
            size: (140.0, 32.0),
            states: NO_SELECTED,
            draw: |cx| {
                let r = CGRect::new(PAD, 10.0, 120.0, 12.0);
                cx.c.stone_slider_track(r, Some((PAD, 59.0)), cx.touch, cx.t);
                cx.c.stone_slider_knob(PAD + 55.0, 16.0, false, cx.touch, cx.t);
            },
        },
        Entry {
            id: "chip",
            size: (70.0, 36.0),
            states: ALL,
            draw: |cx| {
                let on = on(cx);
                cx.c.stone_chip(CGRect::new(PAD, 8.0, 50.0, 20.0), on, true, cx.touch, cx.t);
                label(cx, "Chip", CGPoint::new(PAD + 9.0, 11.0));
            },
        },
        Entry {
            id: "filter-chip",
            size: (80.0, 36.0),
            states: ALL,
            draw: |cx| {
                let on = on(cx);
                cx.c.stone_filter_chip(CGRect::new(PAD, 8.0, 58.0, 20.0), on, cx.touch, cx.t);
                label(cx, "Filter", CGPoint::new(PAD + 9.0, 11.0));
            },
        },
    ]
}

thread_local! {
    /// Inter at 2x for layout widths (an entry's draw function gets only the canvas).
    static MEASURE_ATLAS: GlyphAtlas = {
        let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let Some(atlas) = GlyphAtlas::inter(&fonts) else { panic!("bundled Inter loads") };
        atlas.set_point_scale(SCALE);
        atlas
    };
}

fn with_measure<R>(f: impl FnOnce(&TextMeasure) -> R) -> R {
    MEASURE_ATLAS.with(|a| f(&TextMeasure::new(Some(a), SCALE)))
}

/// A menu level over `items` at the canvas corner (shadow room 12 pt); `hot` is the highlighted row.
fn menu(cx: &mut Cx, items: Vec<SQMenuItem>, hot: Option<usize>) {
    let mut v = MenuListView::new(items);
    with_measure(|m| v.relayout(m));
    v.origin = CGPoint::new(12.0, 12.0);
    v.highlighted = hot;
    v.draw(cx.c, cx.t);
}

fn row(title: &str, shortcut: &str) -> SQMenuItem {
    let mut i = SQMenuItem::new(title);
    i.shortcut = shortcut.to_string();
    i
}

fn menu_rows() -> Vec<SQMenuItem> {
    let mut paste = row("Paste", "");
    paste.is_checked = true;
    let mut more = row("Transform", "");
    more.submenu = Some(vec![row("Flip", "")]);
    vec![row("Cut", "\u{2318}X"), row("Copy", "\u{2318}C"), paste, more, SQMenuItem::separator(), row("Delete", "")]
}

fn dialog_cx(cx: &mut Cx, mut d: ShellDialog, window: CGRect) {
    with_measure(|m| d.layout(window, m));
    d.draw(cx.c, cx.t, window, &mut UiCx::new());
}

/// Menus, tooltips, settings rows and cards, dialogs.
fn overlays() -> Vec<Entry> {
    const MENU_STATES: &[State] = &[State::Default, State::Hover, State::Disabled, State::Selected];
    vec![
        Entry {
            id: "menu-item",
            size: (224.0, 48.0),
            states: MENU_STATES,
            // Hover is the highlighted row; Selected is the checked row.
            draw: |cx| {
                let mut i = row("Copy", "\u{2318}C");
                i.is_enabled = cx.state != State::Disabled;
                i.is_checked = on(cx);
                let hot = (cx.state == State::Hover).then_some(0);
                menu(cx, vec![i], hot);
            },
        },
        Entry {
            id: "menu",
            size: (224.0, 192.0),
            states: &[State::Default, State::Hover, State::Disabled],
            draw: |cx| {
                let mut items = menu_rows();
                if cx.state == State::Disabled {
                    items[1].is_enabled = false;
                }
                let hot = (cx.state == State::Hover).then_some(1);
                menu(cx, items, hot);
            },
        },
        Entry {
            id: "menu-scroll",
            size: (224.0, 140.0),
            states: &[State::Default],
            // A menu taller than its room: the 3 pt scroll thumb.
            draw: |cx| {
                let mut v = MenuListView::new((1..=12).map(|n| row(&format!("Item {n}"), "")).collect());
                with_measure(|m| v.relayout(m));
                v.max_height = Some(116.0);
                v.origin = CGPoint::new(12.0, 12.0);
                v.draw(cx.c, cx.t);
            },
        },
        Entry {
            id: "tooltip",
            size: (150.0, 56.0),
            states: &[State::Default],
            draw: |cx| tip(cx, "Selection (V)"),
        },
        Entry {
            id: "tooltip-long",
            size: (360.0, 90.0),
            states: &[State::Default],
            draw: |cx| tip(cx, "Ripples the timeline: every clip after the cut moves left to close the gap, on all unlocked tracks (Q)"),
        },
        Entry {
            id: "settings-row",
            size: (640.0, 150.0),
            states: &[State::Default],
            draw: |cx| settings(cx, 2),
        },
        Entry {
            id: "card",
            size: (640.0, 300.0),
            states: &[State::Default],
            draw: |cx| settings(cx, 4),
        },
        Entry {
            id: "dialog-shell",
            size: (480.0, 240.0),
            states: &[State::Default],
            // The alert: Save changes to "T2"? with Don't Save at the left.
            draw: |cx| {
                let mut d = ShellDialog::new(
                    "Save changes to \u{201c}T2\u{201d}?",
                    "Your changes will be lost if you do not save them.",
                );
                d.asks_to_save = true;
                d.add_button("Don't Save", SQDialogRole::DontSave, true);
                d.add_button("Cancel", SQDialogRole::Cancel, false);
                d.add_button("Save", SQDialogRole::Save, false);
                dialog_cx(cx, d, CGRect::new(0.0, 0.0, 480.0, 240.0));
            },
        },
        Entry {
            id: "dialog-shell-form",
            size: (480.0, 300.0),
            states: &[State::Default],
            // The form card: rows between the title and the footer.
            draw: |cx| {
                let mut d = ShellDialog::new("Rename Marker", "Give the marker a name and a note.");
                d.form = Some(Box::new(ShellForm::new(vec![
                    FormRow::field("name", "Name", "Marker 1"),
                    FormRow::check("ripple", "Show on the timeline", true),
                ])));
                d.kit_layout = true;
                d.add_button("Delete Marker", SQDialogRole::Destructive, true);
                d.add_button("Cancel", SQDialogRole::Cancel, false);
                d.add_button("Done", SQDialogRole::Default, false);
                dialog_cx(cx, d, CGRect::new(0.0, 0.0, 480.0, 300.0));
            },
        },
    ]
}

fn tip(cx: &mut Cx, text: &str) {
    let mut ui = UiCx::new();
    ui.hover.tooltip.text = Some(text.to_string());
    ui.hover.tooltip.anchor = (12.0 * SCALE, 8.0 * SCALE);
    ui.hover.draw_tooltip(cx.c, cx.t, 1.0);
}

/// A settings page: a card of rows with a title, help and a control each, `n` rows.
fn settings(cx: &mut Cx, n: usize) {
    let rows = [
        ("labels", "Show experimental labels", "Marks features that are still being built, so you know they can change.", true),
        ("autosave", "Autosave", "Saves a backup of your project every few minutes.", true),
        ("reopen", "Reopen last project", "Opens the project you worked on when the app starts.", false),
        ("tips", "Show tips", "Shows a short hint when you hover a control.", true),
    ];
    let mut f = ShellForm::with_sidebar(
        rows.iter().take(n).map(|r| FormRow::check(r.0, r.1, r.3)).collect(),
        Some(Sidebar { id: "page".into(), items: vec![("General".into(), SQIcon::Check)] }),
        0,
    );
    for r in rows.iter().take(n) {
        f.helps.insert(r.0.to_string(), r.2.to_string());
    }
    with_measure(|m| f.layout_at(CGPoint::ZERO, 640.0, m));
    f.draw_rows(cx.c, cx.t, &mut UiCx::new());
}

const BAR_W: f64 = 760.0;
/// Wide enough for every status part (a narrow bar drops the version, then the playback and grade texts).
const STATUS_W: f64 = 1200.0;

/// The title row at `top` in a bar `BAR_W` wide: laid out with a project, then `hover` moves the pointer over `at`.
fn title_row(cx: &mut Cx, color_page: bool, hover: Option<fn(&TitleRow) -> CGPoint>) {
    let bar = f64::from(sq_uikit::design_tokens::sq_tokens::metrics::TOP_BAR);
    cx.c.fill(CGRect::new(0.0, 0.0, BAR_W, bar), cx.t.titlebar());
    cx.c.fill(CGRect::new(0.0, bar - 1.0, BAR_W, 1.0), cx.t.hair());
    let mut row = TitleRow::default();
    row.project_name = "Summer Trip".into();
    row.edited = Some(SystemTime::UNIX_EPOCH);
    row.saved = true;
    row.workspace_name = "Editing".into();
    row.color_page = color_page;
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(300);
    with_measure(|m| row.layout(78.0, (BAR_W, BAR_W - 12.0), 0.0, bar, m, now));
    if let Some(at) = hover {
        row.mouse(Mouse::Moved, at(&row));
    }
    row.draw(cx.c, cx.t, now);
}

/// Runs `f` with the theme of a window that is not the active one (grey focus edge and Export, `window_inactive`).
fn inactive(cx: &mut Cx, f: &dyn Fn(&mut Cx)) {
    let t = DrawTheme { window_inactive: true, ..*cx.t };
    f(&mut Cx { c: &mut *cx.c, t: &t, state: cx.state, touch: cx.touch });
}

fn status_bar(cx: &mut Cx, s: &StatusBarContent) {
    let h = f64::from(sq_uikit::design_tokens::sq_tokens::metrics::STATUS_BAR);
    status_bar::draw(cx.c, s, CGRect::new(0.0, 0.0, STATUS_W, h), cx.t);
}

fn status_content() -> StatusBarContent {
    StatusBarContent {
        format: StatusBarContent::format_text(1920, 1080, 25.0, false),
        save: Some(SaveStatus::make(false, true, None, None, 0)),
        playback: StatusBarContent::playback_text(MonitorQuality::Full),
        ..StatusBarContent::default()
    }
}

/// The dock over `w` x `h` points with the default Edit workspace, `focus` the panel with the accent frame.
fn dock(cx: &mut Cx, (w, h): (f64, f64), focus: Option<PanelID>, hover_tab: Option<CGPoint>) {
    let mut d = ShellDock::default();
    with_measure(|m| d.set_measure(m));
    d.set_frame(CGRect::new(0.0, 0.0, w, h));
    d.set_focused(focus);
    if let Some(p) = hover_tab {
        d.pointer = Some(p);
    }
    d.draw(cx.c, cx.t);
    d.draw_focus_frame(cx.c, cx.t);
}

/// The Tools column (spec 06): a card 36 wide with the header line, the grip and the tools. `hover` is a tool slot index,
/// `tool` the active tool.
fn tools_panel(cx: &mut Cx, tool: TimelineTool, hover: Option<usize>) {
    let frame = CGRect::new(PAD, PAD, f64::from(sq_uikit::redesign_tokens::size::TOOL_PANEL), 404.0);
    cx.c.fill_rounded(frame, cx.t.panel_radius(), cx.t.panel());
    cx.c.fill(CGRect::new(frame.x, frame.y + 28.0 - 1.0, frame.width, 1.0), cx.t.separator());
    let mut strip = ToolStrip::new(*cx.t);
    strip.place(frame, SCALE);
    if let Some(i) = hover {
        let r = strip.slots().1[i];
        let k = f64::from(SCALE);
        let e = InputEvent::MouseMoved { x: (r.mid_x() * k) as f32, y: (r.mid_y() * k) as f32 };
        strip.handle(&e, &ToolState::default(), &mut UiCx::new(), &CommandMap::premiere_default());
    }
    let mut state = ToolState::default();
    state.tool = tool;
    strip.draw(cx.c, &state);
}

/// Header, panel chrome, project list.
fn shell() -> Vec<Entry> {
    vec![
        Entry {
            id: "page-switch",
            size: (BAR_W as f32, 36.0),
            states: &[State::Default, State::Hover, State::Selected],
            // Default = Edit shown; Selected = Color shown; Hover = the pointer over the other segment (Color).
            draw: |cx| match cx.state {
                State::Hover => title_row(cx, false, Some(|r| {
                    let f = r.controls()[2];
                    CGPoint::new(f.min_x() + f.width * 0.75, f.mid_y())
                })),
                s => title_row(cx, s == State::Selected, None),
            },
        },
        Entry {
            id: "topbar",
            size: (BAR_W as f32, 36.0),
            states: &[State::Default, State::Hover],
            // Hover = the pointer over the Export button.
            draw: |cx| title_row(cx, false, (cx.state == State::Hover).then_some(|r| centre(r.controls()[0]))),
        },
        Entry {
            id: "statusbar",
            size: (STATUS_W as f32, 24.0),
            states: &[State::Default],
            draw: |cx| status_bar(cx, &status_content()),
        },
        Entry {
            id: "statusbar-busy",
            size: (STATUS_W as f32, 24.0),
            states: &[State::Default],
            // A message, the Linked Selection warning, the relink chip and the export ring at 40 %.
            draw: |cx| {
                let mut s = status_content();
                s.message = "Imported 2 files".into();
                s.linked_selection_off = true;
                s.relink_offer = "Found 4 offline files \u{b7} Reconnect".into();
                s.export_progress = Some(0.4);
                status_bar(cx, &s);
            },
        },
        Entry {
            id: "statusbar-unsaved",
            size: (STATUS_W as f32, 24.0),
            states: &[State::Default],
            // Unsaved edits (amber dot) and the Color page's grade text with the amber "experimental".
            draw: |cx| {
                let mut s = status_content();
                s.save = Some(SaveStatus::make(true, true, None, None, 0));
                s.grade = "No Pro grade \u{b7} experimental".into();
                status_bar(cx, &s);
            },
        },
        Entry {
            id: "topbar-inactive",
            size: (BAR_W as f32, 36.0),
            states: &[State::Default],
            // The title row of a window in the background: Export is grey, not blue.
            draw: |cx| inactive(cx, &|cx| title_row(cx, false, None)),
        },
        Entry {
            id: "panel-frame-inactive",
            size: (720.0, 360.0),
            states: &[State::Default],
            // The Edit dock with the Timeline focused in an inactive window: the focus edge is grey.
            draw: |cx| inactive(cx, &|cx| dock(cx, (720.0, 360.0), Some(PanelID::Timeline), None)),
        },
        Entry {
            id: "panel-frame",
            size: (720.0, 360.0),
            states: &[State::Default, State::Hover, State::Focus],
            // The whole Edit dock: cards on the panel ground (the gap is the splitter), tab strips with the 2 pt underline.
            // Hover = the pointer over a tab; Focus = the accent frame on the Timeline.
            draw: |cx| {
                let at = (cx.state == State::Hover).then(|| CGPoint::new(60.0, 14.0));
                dock(cx, (720.0, 360.0), (cx.state == State::Focus).then_some(PanelID::Timeline), at);
            },
        },
        Entry {
            id: "tool-button",
            size: (56.0, 424.0),
            states: &[State::Default, State::Hover, State::Selected],
            // Selected = the active tool (raised); Hover = a quiet fill under the pointer; the same column as tools-panel.
            draw: |cx| match cx.state {
                State::Hover => tools_panel(cx, TimelineTool::Selection, Some(2)),
                State::Selected => tools_panel(cx, TimelineTool::Razor, None),
                _ => tools_panel(cx, TimelineTool::Selection, None),
            },
        },
        Entry {
            id: "tools-panel",
            size: (56.0, 424.0),
            states: &[State::Default],
            draw: |cx| tools_panel(cx, TimelineTool::Selection, None),
        },
    ]
}

fn centre(r: CGRect) -> CGPoint {
    CGPoint::new(r.mid_x(), r.mid_y())
}

// ---- Timeline group: the real panel (`TimelineAppHost`) over a small scene, cropped to the component. ----

const FD: sq_core_time::Time = sq_core_time::Time::new(1, 25);

fn tid(n: u128) -> sq_core_time::Id {
    sq_core_time::Id::from_u128((1 << 80) + n)
}

/// A clip of `frames` frames at `start` seconds (media of its own).
fn tl_clip(n: u128, name: &str, kind: sq_core_model::TrackKind, start_s: i64, frames: i64) -> sq_core_model::Clip {
    sq_core_model::Clip::new(
        tid(n),
        name,
        tid(n + 500),
        kind,
        sq_core_time::TimeRange::new(sq_core_time::Time::new(0, 1), FD * frames),
        sq_core_time::Time::new(start_s, 1),
    )
}

fn tl_track(n: u128, kind: sq_core_model::TrackKind, clips: Vec<sq_core_model::Clip>) -> sq_core_model::Track {
    let mut t = sq_core_model::Track::new(tid(n), kind);
    t.set_clips(clips);
    t
}

/// The media source that reports the given media as missing.
struct Missing(Vec<sq_core_time::Id>);

impl sq_draw_timeline::TimelineMediaSource for Missing {
    fn waveform(&self, _media: sq_core_time::Id) -> Option<std::sync::Arc<sq_media::waveform_data::WaveformData>> {
        None
    }
    fn is_offline(&self, media: sq_core_time::Id) -> bool {
        self.0.contains(&media)
    }
}

/// One scene: the panel is `view` points big, `pps` points per second wide; `drive` runs the pointer (positions in
/// panel points) before the draw; `crop` (panel points) is what the canvas shows.
struct Scene {
    tracks: Vec<sq_core_model::Track>,
    view: (f64, f64),
    pps: f64,
    selected: Vec<sq_core_time::Id>,
    offline: Vec<sq_core_time::Id>,
    playhead_s: i64,
    in_out: Option<(i64, i64)>,
    marker_s: Option<i64>,
}

impl Scene {
    fn new(tracks: Vec<sq_core_model::Track>) -> Scene {
        Scene { tracks, view: (640.0, 196.0), pps: 40.0, selected: Vec::new(), offline: Vec::new(), playhead_s: 0, in_out: None, marker_s: None }
    }
}

/// Pointer events in panel points, as the device pixels the panel takes.
fn px(x: f64, y: f64) -> (f32, f32) {
    ((x * f64::from(SCALE)) as f32, (y * f64::from(SCALE)) as f32)
}

fn moved(h: &mut sq_draw_timeline::TimelineAppHost, ui: &mut UiCx, x: f64, y: f64) {
    let (x, y) = px(x, y);
    h.panel.handle(&InputEvent::MouseMoved { x, y }, ui);
}

/// Builds the scene, lets `drive` move the pointer, then draws the `crop` rect of the panel into the canvas.
fn draw_scene(cx: &mut Cx, sc: &Scene, crop: CGRect, drive: &dyn Fn(&mut sq_draw_timeline::TimelineAppHost, &mut UiCx)) {
    use sq_app_shell::{AppHost as _, AppServices, HostCx};
    use sq_core_model::{LabelResolver, Marker, MarkerColor, Project, SequenceFormat, Timeline};
    use sq_core_time::{Time, TimeRange};
    let mut tl = Timeline::new(tid(9000), "t", SequenceFormat::new(FD), sc.tracks.clone());
    tl.in_out = sc.in_out.map(|(a, b)| TimeRange::new(Time::new(a, 1), Time::new(b - a, 1)));
    if let Some(m) = sc.marker_s {
        tl.markers.push(Marker {
            id: tid(9500),
            time: Time::new(m, 1),
            name: "Cut".into(),
            color: MarkerColor::Green,
            comment: String::new(),
            duration: Time::ZERO,
        });
    }
    let mut host = sq_draw_timeline::TimelineAppHost::new(*cx.t);
    host.panel.layout_px(sq_draw::Rect::new(0.0, 0.0, sc.view.0 as f32 * SCALE, sc.view.1 as f32 * SCALE), SCALE);
    if !sc.offline.is_empty() {
        host.panel.media = Some(std::rc::Rc::new(Missing(sc.offline.iter().map(|c| tid(c.as_u128() - (1 << 80) + 500)).collect())));
    }
    host.panel.cached_ranges = vec![TimeRange::new(Time::new(1, 1), Time::new(3, 1))];
    let sel: std::collections::BTreeSet<_> = sc.selected.iter().copied().collect();
    host.panel.sync(sq_draw_timeline::SessionView {
        timeline: &tl,
        selection: &sel,
        captions: &Default::default(),
        playhead: Time::new(sc.playhead_s, 1),
        selected_transition: None,
        labels: LabelResolver::default(),
        line_keys: Default::default(),
    });
    host.panel.set_zoom(sc.pps, None);
    host.panel.settle_zoom_animation();
    let mut ui = UiCx::new();
    drive(&mut host, &mut ui);
    let mut session = sq_editor_session::EditorSession::new(
        Project::new(tid(7000), "P", Vec::new(), vec![tl]),
        sq_editor_session::SessionDeps::headless(std::env::temp_dir().join("sq-catalogue-session")),
    );
    let (mut services, mut events) = (AppServices::headless(), Vec::new());
    let mut hcx = HostCx { session: &mut session, ui: &mut ui, services: &mut services, events: &mut events, atlas: None, scale: SCALE };
    cx.c.save_gstate();
    cx.c.translate_by(-crop.x, -crop.y);
    host.draw(cx.c, cx.t, &mut hcx);
    cx.c.restore_gstate();
}

/// Panel point of a clip: its left x and its row's top and height.
fn row_of(sc: &Scene, track: usize) -> (f64, f64) {
    // Rows from the top: video tracks in reverse order, then audio; heights follow `TimelineGeometry`.
    let mut host = sq_draw_timeline::TimelineAppHost::new(DrawTheme::default());
    host.panel.layout_px(sq_draw::Rect::new(0.0, 0.0, sc.view.0 as f32 * SCALE, sc.view.1 as f32 * SCALE), SCALE);
    let tl = sq_core_model::Timeline::new(tid(9000), "t", sq_core_model::SequenceFormat::new(FD), sc.tracks.clone());
    host.panel.sync(sq_draw_timeline::SessionView {
        timeline: &tl,
        selection: &Default::default(),
        captions: &Default::default(),
        playhead: sq_core_time::Time::ZERO,
        selected_transition: None,
        labels: sq_core_model::LabelResolver::default(),
        line_keys: Default::default(),
    });
    let (y0, y1) = host.panel.pixel_row_of(sc.tracks[track].id).expect("row");
    (f64::from(y0 / SCALE), f64::from((y1 - y0) / SCALE))
}

const ORIGIN: f64 = sq_timeline_ui::TimelineGeometry::CONTENT_ORIGIN_X;
const TOOLS: f64 = sq_timeline_ui::TimelineGeometry::TOOL_COLUMN_WIDTH;
const HEADER: f64 = sq_timeline_ui::TimelineGeometry::HEADER_WIDTH;
const RULER: f64 = sq_timeline_ui::TimelineGeometry::RULER_HEIGHT;

/// The one video clip scene (V2 empty above, A1 below), the clip at 2 s, 3 s long (120 pt at 40 pt/s).
fn clip_scene(clip: sq_core_model::Clip, audio: bool, st: State, offline: bool) -> (Scene, CGRect, Box<dyn Fn(&mut sq_draw_timeline::TimelineAppHost, &mut UiCx)>) {
    use sq_core_model::TrackKind::{Audio, Video};
    let id = clip.id;
    let mut clip = clip;
    clip.is_enabled = st != State::Disabled;
    let tracks = if audio {
        vec![tl_track(1, Video, Vec::new()), tl_track(2, Audio, vec![clip]), tl_track(3, Audio, Vec::new())]
    } else {
        vec![tl_track(2, Video, vec![clip]), tl_track(1, Video, Vec::new()), tl_track(3, Audio, Vec::new())]
    };
    let mut sc = Scene::new(tracks);
    sc.selected = if st == State::Selected { vec![id] } else { Vec::new() };
    sc.offline = if offline { vec![id] } else { Vec::new() };
    let (top, h) = row_of(&sc, if audio { 1 } else { 0 });
    let x = ORIGIN + 2.0 * sc.pps;
    let crop = CGRect::new(x - 12.0, top - 8.0, 144.0, h + 16.0);
    let drive: Box<dyn Fn(&mut sq_draw_timeline::TimelineAppHost, &mut UiCx)> = Box::new(move |h2, ui| {
        if st == State::Pressed {
            // Trimming: press the clip's right edge and drag it 14 pt to the left.
            let y = top + h / 2.0;
            let (px0, py0) = px(x + 120.0 - 2.0, y);
            let (px1, py1) = px(x + 120.0 - 16.0, y);
            h2.panel.handle(&InputEvent::MouseMoved { x: px0, y: py0 }, ui);
            h2.panel.handle(&InputEvent::MouseDown { x: px0, y: py0, modifiers: sq_draw::InputModifiers::NONE }, ui);
            h2.panel.handle(&InputEvent::MouseDragged { x: px1, y: py1, modifiers: sq_draw::InputModifiers::NONE }, ui);
        }
        if st == State::Hover {
            // The pointer rests on the clip body (r8 `clip-hover` ring).
            let (px0, py0) = px(x + 60.0, top + h / 2.0);
            h2.panel.handle(&InputEvent::MouseMoved { x: px0, y: py0 }, ui);
        }
    });
    (sc, crop, drive)
}

fn clip_entry(cx: &mut Cx, clip: sq_core_model::Clip, audio: bool, offline: bool) {
    let (sc, crop, drive) = clip_scene(clip, audio, cx.state, offline);
    draw_scene(cx, &sc, crop, &*drive);
}

const CLIP_STATES: &[State] = &[State::Default, State::Selected, State::Pressed, State::Disabled];
const CLIP_STATES_HOVER: &[State] = &[State::Default, State::Hover, State::Selected, State::Pressed, State::Disabled];

/// The four header rows (top to bottom V2, V1, A1, A2; the model lists V1 first) (`all` = every toggle on: hidden, locked, muted, solo), V1 targeted.
fn header_scene(all: bool) -> Scene {
    use sq_core_model::TrackKind::{Audio, Video};
    let mut v2 = tl_track(1, Video, Vec::new());
    let mut v1 = tl_track(2, Video, Vec::new());
    let mut a1 = tl_track(3, Audio, Vec::new());
    let mut a2 = tl_track(4, Audio, Vec::new());
    v1.is_targeted = true;
    if all {
        v2.is_visible = false;
        v2.is_locked = true;
        a1.is_muted = true;
        a2.is_solo = true;
        a2.is_locked = true;
    }
    Scene::new(vec![v1, v2, a1, a2])
}

/// The header column of `header_scene` cropped to `x0..x0 + w`; hover = the pointer at (`hx`, `hy`) in the column.
fn header_draw(cx: &mut Cx, x0: f64, w: f64, hover: Option<(f64, f64)>) {
    let sc = header_scene(cx.state == State::Selected);
    let crop = CGRect::new(TOOLS + x0, RULER, w, 144.0);
    let at = hover.filter(|_| cx.state == State::Hover);
    draw_scene(cx, &sc, crop, &move |h, ui| {
        if let Some((x, y)) = at {
            moved(h, ui, TOOLS + x, RULER + y);
        }
    });
}

/// A video track with many clips of all sizes, for the stress shot: a 1-frame sliver, a short clip, a long name.
fn stress_scene() -> Scene {
    use sq_core_model::TrackKind::Video;
    let long = "C2171_interview_with_a_very_long_file_name_final_v3_graded.MP4";
    let clips = vec![
        tl_clip(10, "A", Video, 0, 1),
        tl_clip(11, "B", Video, 1, 4),
        tl_clip(12, "Short", Video, 2, 25),
        tl_clip(13, long, Video, 4, 100),
        tl_clip(14, long, Video, 9, 250),
    ];
    let mut sc = Scene::new(vec![tl_track(1, Video, clips)]);
    sc.view = (640.0, 160.0);
    sc.selected = vec![tid(12)];
    sc
}

/// A project far zoomed out: `pps` = 1.5 pt/s over 5 minutes of clips and 100 tracks' worth of rows is `many`.
fn many_tracks_scene(n: u128) -> Scene {
    use sq_core_model::TrackKind::{Audio, Video};
    let mut tracks: Vec<_> = (0..n).map(|i| tl_track(100 + i, Video, vec![tl_clip(200 + i, "Clip", Video, (i % 5) as i64, 100)])).collect();
    tracks.push(tl_track(1, Audio, Vec::new()));
    let mut sc = Scene::new(tracks);
    sc.view = (640.0, 260.0);
    sc
}

/// The timecode cell above the heads (spec 06): timecode plus Snapping, Linked Selection and Marker.
fn timecode_cell(cx: &mut Cx, snapping: bool, hover_snap: bool) {
    use sq_draw_timeline::header::{TimelineHeaderState, TimelineHeaderStrip};
    let mut strip = TimelineHeaderStrip::new(*cx.t);
    let mut st = TimelineHeaderState::default();
    st.timecode = "00:00:04:12".into();
    st.snapping = snapping;
    st.linked_selection = snapping;
    strip.compact = true;
    strip.layout(sq_draw::Rect::new(0.0, 0.0, 190.0 * SCALE, 26.0 * SCALE), SCALE, st);
    strip.set_cell_origin(0.0, 0.0);
    let map = CommandMap::premiere_default();
    let mut ui = UiCx::new();
    if hover_snap && matches!(cx.state, State::Hover | State::Pressed) {
        let r = strip.frames().snap;
        let (x, y) = px(r.mid_x(), r.mid_y());
        strip.handle(&InputEvent::MouseMoved { x, y }, &mut ui, &map);
        if cx.state == State::Pressed {
            strip.handle(&InputEvent::MouseDown { x, y, modifiers: sq_draw::InputModifiers::NONE }, &mut ui, &map);
        }
    }
    strip.draw(cx.c);
}

/// Ruler, playhead, track header parts, zoom bar and the five clip kinds.
fn timeline() -> Vec<Entry> {
    use sq_core_model::TrackKind::{Audio, Video};
    vec![
        Entry {
            id: "ruler",
            size: (560.0, 26.0),
            states: &[State::Default, State::Hover, State::Selected],
            // Default = ticks and labels; Hover = the pointer on the ruler; Selected = In/Out range (3 s to 6 s), a marker at 5 s, a cached span and the playhead head.
            draw: |cx| {
                let mut sc = header_scene(false);
                sc.view = (640.0, 120.0);
                if cx.state == State::Selected {
                    sc.in_out = Some((3, 6));
                    sc.marker_s = Some(5);
                    sc.playhead_s = 4;
                }
                let hover = cx.state == State::Hover;
                draw_scene(cx, &sc, CGRect::new(TOOLS, 0.0, 560.0, RULER), &move |h, ui| {
                    if hover {
                        moved(h, ui, TOOLS + 200.0, RULER / 2.0);
                    }
                });
            },
        },
        Entry {
            id: "playhead",
            size: (100.0, 120.0),
            states: &[State::Default, State::Pressed],
            // The head in the ruler and the line down over the lanes; Pressed = the pointer dragging the ruler.
            draw: |cx| {
                let mut sc = Scene::new(vec![tl_track(1, Video, vec![tl_clip(10, "Clip", Video, 0, 250)]), tl_track(2, Audio, Vec::new())]);
                sc.playhead_s = 3;
                sc.view = (640.0, 160.0);
                let x = ORIGIN + 3.0 * sc.pps;
                let pressed = cx.state == State::Pressed;
                draw_scene(cx, &sc, CGRect::new(x - 50.0, 0.0, 100.0, 120.0), &move |h, ui| {
                    if pressed {
                        let (px0, py0) = px(x, RULER / 2.0);
                        h.panel.handle(&InputEvent::MouseDown { x: px0, y: py0, modifiers: sq_draw::InputModifiers::NONE }, ui);
                    }
                });
            },
        },
        Entry {
            id: "track-chip",
            size: (64.0, 144.0),
            states: &[State::Default],
            // V1 targeted (raised, outline), the others not; the column to the left of the name.
            draw: |cx| header_draw(cx, 0.0, 64.0, None),
        },
        Entry {
            id: "track-toggle",
            size: (100.0, 144.0),
            states: &[State::Default, State::Hover, State::Selected],
            // The right edge of the header: eye / lock on video, M / S / lock on audio. Hover = the pointer over A1's M;
            // Selected = V2 hidden and locked, A1 muted, A2 solo and locked.
            draw: |cx| header_draw(cx, HEADER - 100.0, 100.0, Some((HEADER - 54.0, 40.0 + 40.0 + 16.0))),
        },
        Entry {
            id: "track-header",
            size: (190.0, 144.0),
            states: &[State::Default, State::Selected],
            // V2, V1 (targeted), A1, A2. Selected = every toggle on. The row has no hover look of its own.
            draw: |cx| header_draw(cx, 0.0, HEADER, None),
        },
        Entry {
            id: "track-header-many",
            size: (190.0, 260.0),
            states: &[State::Default],
            // 30 tracks do not fit: the column scrolls with the lanes and the thin bar on the right shows there is more.
            draw: |cx| {
                let sc = many_tracks_scene(30);
                draw_scene(cx, &sc, CGRect::new(TOOLS, RULER, HEADER, 260.0 - RULER), &|_, _| {});
            },
        },
        Entry {
            id: "timecode-cell",
            size: (190.0, 26.0),
            states: &[State::Default, State::Hover, State::Pressed],
            // Snapping and Linked Selection on (the defaults). Hover and Pressed = the Snapping toggle.
            draw: |cx| timecode_cell(cx, true, true),
        },
        Entry {
            id: "timecode-cell-off",
            size: (190.0, 26.0),
            states: &[State::Default],
            draw: |cx| timecode_cell(cx, false, false),
        },
        Entry {
            id: "zoom-bar",
            size: (440.0, 18.0),
            states: &[State::Default, State::Hover, State::Pressed],
            // Zoomed in on a 60 s sequence: the knobs sit at the viewport's ends. Hover = over the bar, Pressed = dragging the middle.
            draw: |cx| {
                let mut sc = Scene::new(vec![tl_track(1, Video, vec![tl_clip(10, "Clip", Video, 0, 1500)])]);
                sc.pps = 12.0;
                sc.view = (640.0, 120.0);
                let (state, y) = (cx.state, 120.0 - 7.0);
                let bar_x = ORIGIN + 200.0;
                draw_scene(cx, &sc, CGRect::new(ORIGIN, 120.0 - 18.0, 440.0, 18.0), &move |h, ui| match state {
                    State::Hover => moved(h, ui, bar_x, y),
                    State::Pressed => {
                        let (x, yy) = px(bar_x, y);
                        h.panel.handle(&InputEvent::MouseDown { x, y: yy, modifiers: sq_draw::InputModifiers::NONE }, ui);
                    }
                    _ => {}
                });
            },
        },
        Entry {
            id: "clip-video",
            size: (144.0, 56.0),
            states: CLIP_STATES_HOVER,
            // Selected = lifted band, white ring, trim bars at both ends; Pressed = dragging the right trim edge; Disabled = Clip > Enable off.
            draw: |cx| clip_entry(cx, tl_clip(10, "C2171.MP4", Video, 2, 75), false, false),
        },
        Entry {
            id: "clip-video-offline",
            size: (144.0, 56.0),
            states: &[State::Default, State::Selected],
            draw: |cx| clip_entry(cx, tl_clip(10, "C2171.MP4", Video, 2, 75), false, true),
        },
        Entry {
            id: "clip-audio",
            size: (144.0, 56.0),
            states: CLIP_STATES,
            draw: |cx| clip_entry(cx, tl_clip(10, "C2171.MP4", Audio, 2, 75), true, false),
        },
        Entry {
            id: "clip-graphic",
            size: (144.0, 56.0),
            states: CLIP_STATES,
            draw: |cx| {
                let mut c = tl_clip(10, "Title", Video, 2, 75);
                c.generator = Some(sq_core_model::GeneratorRef { kind: "text".into(), payload: Vec::new(), payload_version: 1 });
                clip_entry(cx, c, false, false)
            },
        },
        Entry {
            id: "clip-adjustment",
            size: (144.0, 56.0),
            states: CLIP_STATES,
            draw: |cx| {
                let mut c = tl_clip(10, "Adjustment", Video, 2, 75);
                c.generator = Some(sq_core_effects::adjustment_clip::adjustment_layer());
                clip_entry(cx, c, false, false)
            },
        },
        Entry {
            id: "clip-nested",
            size: (144.0, 56.0),
            states: CLIP_STATES,
            draw: |cx| {
                let mut c = tl_clip(10, "Nested 1", Video, 2, 75);
                c.sequence = Some(tid(8000));
                c.media = tid(8000);
                clip_entry(cx, c, false, false)
            },
        },
        Entry {
            id: "clip-video-stress",
            size: (410.0, 56.0),
            states: &[State::Default],
            // A 1-frame and a 4-frame sliver, a 1 s clip, and two clips with a 60-character name (selected one = "Short").
            draw: |cx| {
                let sc = stress_scene();
                let (top, h) = row_of(&sc, 0);
                draw_scene(cx, &sc, CGRect::new(ORIGIN - 4.0, top - 8.0, 410.0, h + 16.0), &|_, _| {});
            },
        },
    ]
}

// ---- Inspector group: the real Effect Controls view (`EffectControlsDrawView`) over a small clip, cropped to the component. ----

use sq_core_model::{Clip, ClipEffect, TrackKind};
use sq_core_time::{Id, Keyframe, KeyframeTrack, SequentialIds, Time, TimeRange, Vec2};
use sq_editor_session::EffectSection;
use sq_inspector_ui::ec::effect_controls_model::core::EffectControlsModel;
use sq_inspector_ui::ec::effect_controls_model::layout::EffectRowKind;
use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
use sq_inspector_ui::ec_draw::effect_controls_draw_panel::Target;
use sq_inspector_ui::ec_draw::effect_controls_draw_view::EffectControlsDrawView;
use sq_uikit::controls_grid::CGSize;

/// The width of the spec frames (rows column 326 + lane 221 + seam).
const INS_W: f64 = 548.0;

fn ins_secs(n: i64) -> Time {
    Time::new(n, 1)
}

fn ins_clip(kind: TrackKind, name: &str) -> Clip {
    Clip::new(tid(1000), name, tid(1001), kind, TimeRange::new(Time::ZERO, ins_secs(10)), Time::ZERO)
}

/// Two keys on a track, ids derived from `base`.
fn ins_keys<V: sq_core_time::KeyframeValue>(base: u128, a: V, b: V) -> KeyframeTrack<V> {
    KeyframeTrack::with_keys(vec![
        Keyframe::new(Id::from_u128(base), ins_secs(2), a),
        Keyframe::new(Id::from_u128(base + 1), ins_secs(6), b),
    ])
}

/// A sharpen effect (one real catalogue kind), `on` = its fx toggle.
fn ins_effect(n: u128, on: bool) -> ClipEffect {
    let mut fx = ClipEffect::new(tid(2000 + n), ClipEffect::SHARPEN_KIND);
    fx.enabled = on;
    fx
}

/// The view over `clip` in a `w` x `h` panel, playhead at 2 s; `setup` edits the model before the first layout.
fn ins_view(
    t: &DrawTheme,
    clip: Clip,
    peers: Vec<Clip>,
    (w, h): (f64, f64),
    setup: &dyn Fn(&mut EffectControlsModel),
) -> EffectControlsDrawView {
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.set_clip(Some(clip), None, peers, None);
    m.set_playhead(ins_secs(2));
    setup(&mut m);
    let mut v = EffectControlsDrawView::new(m, 0.0);
    v.set_theme(*t);
    v.set_size(CGSize::new(w, h));
    v.relayout();
    v
}

/// The row of `kind` in view points, full width.
fn ins_row(v: &EffectControlsDrawView, pick: &dyn Fn(&EffectRowKind) -> bool) -> CGRect {
    let Some(r) = v.rows_panel.rows().iter().find(|r| pick(&r.kind)) else {
        panic!("row missing, rows: {:?}", v.rows_panel.rows().iter().map(|r| &r.kind).collect::<Vec<_>>())
    };
    CGRect::new(0.0, v.top() + r.y, v.size().width, r.height)
}

fn ins_prop(p: EffectProperty) -> impl Fn(&EffectRowKind) -> bool {
    move |k| *k == EffectRowKind::Property(p.clone())
}

/// The first point left to right on the middle of `row` that the rows column reports as `want` (view points).
fn ins_target(v: &EffectControlsDrawView, row: CGRect, want: &dyn Fn(&Target) -> bool) -> CGPoint {
    let y = row.mid_y();
    let mut x = 1.0;
    while x < v.lane_x() {
        let p = CGPoint::new(x, y);
        if want(&v.rows_panel.target_at(&v.model, CGPoint::new(p.x, p.y - v.top()))) {
            return p;
        }
        x += 1.0;
    }
    panic!("no such target on the row")
}

fn is_field(t: &Target) -> bool {
    matches!(t, Target::Field(_))
}

/// Pointer moves to `hover` (view points), then the `crop` of the view is drawn.
fn ins_draw(cx: &mut Cx, v: &mut EffectControlsDrawView, hover: Option<CGPoint>, crop: CGRect) {
    let mut ui = UiCx::new();
    v.mouse_moved(hover);
    cx.c.save_gstate();
    cx.c.translate_by(-crop.x, -crop.y);
    v.draw(cx.c, &mut ui);
    cx.c.restore_gstate();
}

/// A click in the row's rows column: starts editing the field under it.
fn ins_click(v: &mut EffectControlsDrawView, at: CGPoint) {
    let mut ui = UiCx::new();
    v.mouse_moved(Some(at));
    v.mouse_down(&mut ui, at, 1, InputModifiers::NONE);
    v.mouse_up(&mut ui, at);
}

/// One property row. Hover rests on the first field, Focus clicks it (editing); `peers` make a multi-selection.
fn ins_row_shot(
    cx: &mut Cx,
    pick: &dyn Fn(&EffectRowKind) -> bool,
    clip: &dyn Fn(&mut Clip),
    peers: Vec<Clip>,
    open: &[EffectProperty],
    interact: Option<&dyn Fn(&Target) -> bool>,
    open_sections: bool,
) {
    let mut c = ins_clip(TrackKind::Video, "Interview A");
    clip(&mut c);
    let open = open.to_vec();
    let mut v = ins_view(cx.t, c, peers, (INS_W, 600.0), &move |m| {
        if open_sections {
            m.set_collapsed_sections(Default::default());
        }
        for p in &open {
            m.toggle_open(p);
        }
    });
    let row = ins_row(&v, pick);
    let mut hover = None;
    if let Some(want) = interact {
        let at = ins_target(&v, row, want);
        hover = Some(at);
        if cx.state == State::Focus {
            ins_click(&mut v, at);
        }
    }
    let hover = if cx.state == State::Hover || cx.state == State::Selected { hover } else { None };
    ins_draw(cx, &mut v, hover, row);
}

fn ins_rot(c: &mut Clip) {
    c.animation.rotation.value = 0.0;
}

fn ins_opacity_60(c: &mut Clip) {
    c.animation.opacity.value = 0.6;
}

fn ins_position(c: &mut Clip) {
    c.animation.position.value = Vec2::new(120.0, -48.0);
}

fn ins_keyed(c: &mut Clip) {
    c.animation.scale.track = ins_keys(41, Vec2::new(1.0, 1.0), Vec2::new(1.4, 1.4));
    c.animation.rotation.track = ins_keys(51, 0.0, 90.0);
}

fn ins_effect_off(c: &mut Clip) {
    c.effects.push(ins_effect(1, false));
}

fn ins_sharpen_amount() -> EffectProperty {
    EffectProperty::Fx { id: tid(2001), kind: ClipEffect::SHARPEN_KIND.to_string(), key: ClipEffect::SHARPEN_AMOUNT_KEY.to_string() }
}

/// The section header `which` (Transform = `Motion`, or the disabled sharpen effect) in view points, hover on its eye.
fn ins_header_shot(cx: &mut Cx, closed: bool, off: bool) {
    let mut c = ins_clip(TrackKind::Video, "Interview A");
    if off {
        ins_effect_off(&mut c);
    }
    let section = if off { EffectSection::Effect { id: tid(2001), kind: ClipEffect::SHARPEN_KIND.to_string() } } else { EffectSection::Motion };
    let s2 = section.clone();
    let mut v = ins_view(cx.t, c, Vec::new(), (INS_W, 600.0), &move |m| {
        if closed {
            m.set_collapsed_sections(std::iter::once(s2.clone()).collect());
        }
    });
    let row = ins_row(&v, &|k| *k == EffectRowKind::Section(section.clone()));
    let hover = (cx.state == State::Hover).then(|| ins_target(&v, row, &|t| matches!(t, Target::Eye(_))));
    ins_draw(cx, &mut v, hover, row);
}

/// The lane of `pick`'s row: from the divider to the panel's right edge (`INS_W - lane_x`, 221 pt at the default split).
fn ins_lane_shot(cx: &mut Cx, pick: &dyn Fn(&EffectRowKind) -> bool, keyed: bool, hover_key: bool) {
    let mut c = ins_clip(TrackKind::Video, "Interview A");
    if keyed {
        ins_keyed(&mut c);
    }
    let rot = EffectProperty::Rotation;
    let select = keyed && cx.state == State::Selected;
    let mut v = ins_view(cx.t, c, Vec::new(), (INS_W, 600.0), &move |m| {
        if select {
            m.select_key(&rot, Id::from_u128(51), false);
        }
    });
    let row = ins_row(&v, pick);
    let lane = v.lane_x();
    let hover = if cx.state == State::Hover {
        let x = if hover_key { lane + v.model.lane_geometry(v.lanes_size().width).x(ins_secs(2)) } else { lane + 150.0 };
        Some(CGPoint::new(x, row.mid_y()))
    } else {
        None
    };
    ins_draw(cx, &mut v, hover, CGRect::new(lane, row.y, INS_W - lane, row.height));
}

/// The opened curve row of Rotation (Value / Speed toggle, ease chips, hint, scale, curve). Default is the panel's Speed
/// mode, Selected the Value mode, Hover rests on the third chip.
fn ins_curve_shot(cx: &mut Cx) {
    let value_mode = cx.state == State::Selected;
    let mut c = ins_clip(TrackKind::Video, "Interview A");
    ins_keyed(&mut c);
    let mut v = ins_view(cx.t, c, Vec::new(), (INS_W, 600.0), &move |m| {
        m.toggle_open(&EffectProperty::Rotation);
        if value_mode {
            m.set_graph_mode_for(sq_uikit::keyframe_graph_geometry::GraphMode::Value, &EffectProperty::Rotation);
        }
    });
    let row = ins_row(&v, &|k| *k == EffectRowKind::Graph(EffectProperty::Rotation));
    let hover = (cx.state == State::Hover).then(|| CGPoint::new(172.0, row.y + 49.0));
    ins_draw(cx, &mut v, hover, row);
}

/// A narrow panel (300 pt) with a 60-character clip name, huge and negative numbers and twelve stacked effects.
fn ins_stress_shot(cx: &mut Cx) {
    let mut c = ins_clip(TrackKind::Video, "A very long interview clip name that goes on and on and on.mov");
    c.animation.position.value = Vec2::new(1_234_567.89, -9_876_543.21);
    c.animation.rotation.value = -99_999.0;
    c.animation.scale.value = Vec2::new(999.0, 0.0001);
    for n in 0..12 {
        c.effects.push(ins_effect(n, n % 3 != 2));
    }
    let mut v = ins_view(cx.t, c, Vec::new(), (300.0, 420.0), &|_| {});
    ins_draw(cx, &mut v, None, CGRect::new(0.0, 0.0, 300.0, 420.0));
}

fn ins_eyebrow_shot(cx: &mut Cx, kind: TrackKind) {
    let mut v = ins_view(cx.t, ins_clip(kind, "Interview A"), Vec::new(), (INS_W, 600.0), &|_| {});
    let y = v.video_header_y();
    ins_draw(cx, &mut v, None, CGRect::new(0.0, y, INS_W, 24.0));
}

const INS_PROP_STATES: &[State] = &[State::Default, State::Hover, State::Focus];

/// Group header, eyebrow, property row, keyframe lane, curve block.
fn inspector() -> Vec<Entry> {
    vec![
        Entry {
            id: "inspector-group-header",
            size: (614.0, 24.0),
            states: &[State::Default, State::Hover, State::Selected, State::Disabled],
            // Default = open, Hover = pointer on the eye, Selected = closed, Disabled = a switched-off effect.
            draw: |cx| ins_header_shot(cx, cx.state == State::Selected, cx.state == State::Disabled),
        },
        Entry {
            id: "inspector-eyebrow",
            size: (614.0, 24.0),
            states: &[State::Default],
            draw: |cx| ins_eyebrow_shot(cx, TrackKind::Video),
        },
        Entry {
            id: "inspector-eyebrow-audio",
            size: (614.0, 24.0),
            states: &[State::Default],
            draw: |cx| ins_eyebrow_shot(cx, TrackKind::Audio),
        },
        Entry {
            id: "inspector-property-row",
            size: (614.0, 24.0),
            states: INS_PROP_STATES,
            draw: |cx| ins_row_shot(cx, &ins_prop(EffectProperty::Rotation), &ins_rot, Vec::new(), &[], Some(&is_field), false),
        },
        Entry {
            id: "inspector-reset-hidden",
            size: (614.0, 24.0),
            states: &[State::Default],
            // An unchanged row at rest: no reset arrow.
            draw: |cx| ins_row_shot(cx, &ins_prop(EffectProperty::Rotation), &ins_rot, Vec::new(), &[], Some(&is_field), false),
        },
        Entry {
            id: "inspector-reset-shown",
            size: (614.0, 24.0),
            states: &[State::Default],
            // A changed row at rest: the reset arrow shows without the pointer.
            draw: |cx| ins_row_shot(cx, &ins_prop(EffectProperty::Opacity), &ins_opacity_60, Vec::new(), &[], Some(&is_field), false),
        },
        Entry {
            id: "inspector-property-row-changed",
            size: (614.0, 24.0),
            states: &[State::Default, State::Hover],
            draw: |cx| ins_row_shot(cx, &ins_prop(EffectProperty::Opacity), &ins_opacity_60, Vec::new(), &[], Some(&is_field), false),
        },
        Entry {
            id: "inspector-property-row-two",
            size: (614.0, 24.0),
            states: &[State::Default, State::Hover, State::Focus],
            draw: |cx| ins_row_shot(cx, &ins_prop(EffectProperty::Position), &ins_position, Vec::new(), &[], Some(&is_field), false),
        },
        Entry {
            id: "inspector-property-row-keyed",
            size: (614.0, 24.0),
            states: &[State::Default, State::Hover, State::Selected],
            // Selected = the pointer on the keyframe button; Hover = on the field.
            draw: |cx| {
                let p = ins_prop(EffectProperty::Scale);
                if cx.state == State::Selected {
                    ins_row_shot(cx, &p, &ins_keyed, Vec::new(), &[EffectProperty::Scale], Some(&|t| matches!(t, Target::Key(_))), false);
                } else {
                    ins_row_shot(cx, &p, &ins_keyed, Vec::new(), &[EffectProperty::Scale], Some(&is_field), false);
                }
            },
        },
        Entry {
            id: "inspector-property-row-mixed",
            size: (614.0, 24.0),
            states: &[State::Default],
            // Two clips selected, one at 60 %: the opacity field shows the dash.
            draw: |cx| {
                let mut other = ins_clip(TrackKind::Video, "Interview B");
                other.id = tid(1100);
                other.animation.opacity.value = 0.6;
                ins_row_shot(cx, &ins_prop(EffectProperty::Opacity), &|_| {}, vec![other], &[], None, false);
            },
        },
        Entry {
            id: "inspector-property-row-menu",
            size: (614.0, 24.0),
            states: &[State::Default],
            draw: |cx| ins_row_shot(cx, &|k| *k == EffectRowKind::BlendMode, &|_| {}, Vec::new(), &[], None, false),
        },
        Entry {
            id: "inspector-property-row-disabled",
            size: (614.0, 24.0),
            states: &[State::Default],
            // Sharpen Amount of a switched-off effect.
            draw: |cx| ins_row_shot(cx, &ins_prop(ins_sharpen_amount()), &ins_effect_off, Vec::new(), &[], None, true),
        },
        Entry {
            id: "inspector-keyframe-lane",
            size: (221.0, 24.0),
            states: &[State::Default, State::Hover],
            draw: |cx| ins_lane_shot(cx, &ins_prop(EffectProperty::Rotation), false, false),
        },
        Entry {
            id: "inspector-keyframe-lane-keyed",
            size: (221.0, 24.0),
            states: &[State::Default, State::Hover, State::Selected],
            draw: |cx| ins_lane_shot(cx, &ins_prop(EffectProperty::Rotation), true, true),
        },
        Entry {
            id: "inspector-curve-block",
            size: (614.0, 120.0),
            states: &[State::Default, State::Hover, State::Selected],
            draw: ins_curve_shot,
        },
        Entry { id: "inspector-stress", size: (300.0, 420.0), states: &[State::Default], draw: ins_stress_shot },
    ]
}

// ---- Lists group: the real Project list, Library panel and meter card over small scenes, cropped to the component. ----

/// The Project list scene: a sequence, an open folder (video, audio, picture) and a missing clip. `long` = very long
/// names inside five nested folders. Returns the project and the ids of the interesting rows.
fn ls_project(long: bool) -> (sq_core_model::Project, Vec<sq_core_model::BinItem>, Vec<sq_core_time::Id>) {
    use sq_core_model::{Bin, BinItem, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline};
    let media = |n: u128, name: &str, video: bool, audio: bool| -> MediaRef {
        let time = |a: i64, b: i64| serde_json::to_value(sq_core_time::Time::new(a, b)).expect("time");
        let mut info = serde_json::json!({"duration": time(10, 1)});
        if video {
            info["video"] = serde_json::json!({"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                "nominalFrameDuration": time(1001, 30000), "isVariableFrameRate": false});
        }
        if audio {
            info["audio"] = serde_json::json!({"sampleRate": 48000, "channels": 2, "codec": "aac"});
        }
        let mut m = MediaRef::new(tid(n), name, &format!("/x/{name}"), MediaFingerprint::new(1));
        m.info = Some(serde_json::from_value(info).expect("info"));
        m.duration = Some(sq_core_time::Time::new(10, 1));
        m
    };
    let seq = Timeline::new(tid(9000), "Main Edit", SequenceFormat::new(FD), Vec::new());
    if long {
        let name = "Interview with the director on the roof terrace, second take, unedited, camera A, all lenses.mov";
        let m = media(1, name, true, true);
        let mut inner = BinItem::Media(tid(1));
        for d in (0..5).rev() {
            let label = format!("Day {} of the shoot in the old harbor district with a very long folder name", d + 1);
            inner = BinItem::Bin(Bin::new(tid(7100 + d as u128), label, vec![inner]));
        }
        let ids = (0..5).map(|d| tid(7100 + d)).collect();
        return (Project::new(tid(7000), "P", vec![m], vec![seq]), vec![inner], ids);
    }
    let all = vec![
        media(1, "C2170.MP4", true, true),
        media(2, "Music bed.wav", false, true),
        media(3, "Title card.png", false, false),
        media(4, "Drone 04.mov", true, false),
    ];
    let folder = BinItem::Bin(Bin::new(
        tid(7100),
        "Footage",
        vec![BinItem::Media(tid(1)), BinItem::Media(tid(2)), BinItem::Media(tid(3))],
    ));
    (Project::new(tid(7000), "P", all, vec![seq]), vec![folder, BinItem::Media(tid(4))], vec![tid(7100)])
}

/// Draws the Project list (`w` wide, rows below the 54 pt chrome) into the canvas, shifted by `crop`.
/// `select` = an item to mark selected, `hover` = a row index the pointer is on.
fn ls_project_draw(cx: &mut Cx, long: bool, w: f64, rows: f64, crop: CGRect, select: Option<sq_core_model::BinItemRef>, hover: Option<usize>) {
    use sq_core_model::MediaStatus;
    use sq_draw_shell::{ProjectListCx, ProjectListSettings, ProjectListView};
    use sq_editor_session::{EditorSession, ProjectPanelDeps, ProjectPanelModel, SessionDeps};
    let (mut project, children, open) = ls_project(long);
    project.root_bin.children = children;
    let mut session = EditorSession::new(project.clone(), SessionDeps::headless(std::env::temp_dir().join("sq-catalogue-session")));
    let mut deps = ProjectPanelDeps::headless();
    deps.status = std::sync::Arc::new(|m| if m.name.starts_with("Drone") { MediaStatus::Missing } else { MediaStatus::Ok });
    let mut model = ProjectPanelModel::new(project, deps);
    let mut v = ProjectListView::new(ProjectListSettings::default());
    // Room under the rows for the info card and the health line, which the panel pins below the last row.
    v.frame = CGRect::new(0.0, 0.0, w, 54.0 + rows * ProjectListView::ROW_HEIGHT + 100.0);
    v.shows_title = false;
    for id in open {
        v.toggle(id);
    }
    if let Some(r) = select {
        v.select(vec![r]);
    }
    let mut ui = UiCx::new();
    let mut ids = sq_core_time::SequentialIds::default();
    MEASURE_ATLAS.with(|a| {
        let mut pcx = ProjectListCx {
            model: &mut model,
            session: &mut session,
            measure: TextMeasure::new(Some(a), SCALE),
            ui: &mut ui,
            ids: &mut ids,
            can_collect: false,
            now: 100.0,
            modifiers: InputModifiers::NONE,
        };
        if let Some(i) = hover {
            let y = 54.0 + (i as f64 + 0.5) * ProjectListView::ROW_HEIGHT;
            v.handle(&mut pcx, &InputEvent::MouseMoved { x: (w / 2.0) as f32, y: y as f32 }, 1.0);
        }
        cx.c.save_gstate();
        cx.c.translate_by(-crop.x, -crop.y);
        v.draw(cx.c, cx.t, &mut pcx);
        cx.c.restore_gstate();
    });
}

fn ls_rows(cx: &mut Cx, long: bool, w: f64, rows: usize) {
    use sq_core_model::BinItemRef;
    let (select, hover) = match (long, cx.state) {
        (false, State::Selected) => (Some(BinItemRef::Media(tid(1))), None),
        (false, State::Hover) => (None, Some(2)),
        _ => (None, None),
    };
    ls_project_draw(cx, long, w, rows as f64, CGRect::new(0.0, 54.0, w, rows as f64 * 24.0), select, hover);
}

/// A Library panel over a scratch folder: `setup` shapes it, `size` is the panel in points.
fn ls_library(size: (f64, f64), setup: &dyn Fn(&mut sq_draw_library::library::library_draw_panel::LibraryDrawPanel, &Path)) -> sq_draw_library::library::library_draw_panel::LibraryDrawPanel {
    let root = std::env::temp_dir().join(format!("sq-catalogue-library-{}", std::process::id()));
    let media = root.join("Footage");
    std::fs::create_dir_all(&media).expect("scratch folder");
    let mut panel = crate::standard::library_panel(&root).expect("library panel");
    panel.size = sq_uikit::controls_grid::CGSize::new(size.0, size.1);
    setup(&mut panel, &media);
    panel.refresh();
    let _ = std::fs::remove_dir_all(&root);
    panel
}

/// Draws the panel twice (the first draw measures the chips and places the buttons the pointer then finds), shifted by `crop`.
fn ls_library_draw(cx: &mut Cx, panel: &mut sq_draw_library::library::library_draw_panel::LibraryDrawPanel, hover: &dyn Fn(&sq_draw_library::library::library_draw_panel::LibraryDrawPanel) -> Option<CGPoint>, crop: CGRect) {
    let mut ui = UiCx::new();
    for pass in 0..2 {
        if pass == 1 {
            panel.mouse_moved(hover(panel));
        }
        cx.c.save_gstate();
        cx.c.translate_by(-crop.x, -crop.y);
        panel.draw(cx.c, cx.t, &mut ui, &|_, _| None);
        cx.c.restore_gstate();
    }
}

fn ls_sidebar_shot(cx: &mut Cx) {
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let selected = cx.state == State::Selected;
    let mut panel = ls_library((600.0, 300.0), &|p, media| {
        p.model.add_folder(media.to_path_buf(), None);
        p.model.add_folder(media.join("../Old drive with a very long folder name"), None);
        p.model.add_folder(media.join("../Below the crop"), None);
        p.refresh();
        // Selected = the Footage folder; the other states select the last folder, which is below the crop.
        let folders = p.model.folders().to_vec();
        let pick = if selected { folders.first() } else { folders.last() };
        if let Some(f) = pick {
            p.model.set_selection(LibrarySection::Folder(f.folder.id));
        }
    });
    let sb = panel.sidebar_rect();
    let row = |i: f64| CGPoint::new(sb.x + 40.0, sb.y + 4.0 + 24.0 * (i + 0.5));
    let hovering = cx.state == State::Hover;
    let hover = |_: &sq_draw_library::library::library_draw_panel::LibraryDrawPanel| hovering.then(|| row(1.0));
    ls_library_draw(cx, &mut panel, &hover, CGRect::new(0.0, sb.y, sb.width, 4.0 * 24.0 + 8.0));
}

fn ls_chips_shot(cx: &mut Cx, width: f64, rows: usize) {
    use sq_draw_library::library::library_panel_model::LibrarySection;
    use sq_library::preset_store::PresetKind;
    let (selected, hovering) = (cx.state == State::Selected, cx.state == State::Hover);
    let mut panel = ls_library((width, 300.0), &|p, _| {
        p.model.set_selection(if selected { LibrarySection::Presets(Some(PresetKind::Effect)) } else { LibrarySection::Presets(None) });
    });
    let hover = |p: &sq_draw_library::library::library_draw_panel::LibraryDrawPanel| {
        hovering.then(|| p.chip_frames().get(2).map(|f| centre(f.2))).flatten()
    };
    let top = 38.0 + 0.0;
    ls_library_draw(cx, &mut panel, &hover, CGRect::new(0.0, top, width, 8.0 + 24.0 * rows as f64 + 4.0));
}

/// The Library with media: the switch row carries the "N items" count at its right end.
fn ls_items_shot(cx: &mut Cx) {
    let mut panel = ls_library((420.0, 220.0), &|p, media| {
        for n in ["Beach.mp4", "Drone.mov", "Interview.mp4", "Music.wav", "Title.png"] {
            let _ = std::fs::write(media.join(n), b"x");
        }
        p.model.add_folder(media.to_path_buf(), None);
        p.refresh();
    });
    ls_library_draw(cx, &mut panel, &|_| None, CGRect::new(0.0, 0.0, 420.0, 220.0));
}

fn ls_empty_shot(cx: &mut Cx, width: f64, query: &str, favorites: bool) {
    let hovering = cx.state == State::Hover;
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let mut panel = ls_library((width, 260.0), &|p, _| {
        // The panel starts on Favorites; "No library folders" shows on the Library row.
        p.model.set_selection(if favorites { LibrarySection::Favorites } else { LibrarySection::All });
        if !query.is_empty() {
            p.model.set_query(query);
        }
    });
    let hover = |p: &sq_draw_library::library::library_draw_panel::LibraryDrawPanel| {
        (hovering && p.offers_add_folder()).then(|| centre(p.add_folder_button_rect()))
    };
    ls_library_draw(cx, &mut panel, &hover, CGRect::new(0.0, 38.0, width, 222.0));
}

/// The meter card: `peaks` are two linear readings fed one after the other (the second below the first leaves the hold
/// line), `loud` the loudness columns, `solo_mute` a solo on bar 0 and a mute on bar 1.
fn ls_meter_shot(cx: &mut Cx, (w, h): (f64, f64), peaks: &[[f32; 2]], loud: Option<sq_draw::monitor::loudness_meter::LoudnessReading>, solo_mute: bool) {
    use sq_draw::monitor::audio_meter::MeterReading;
    let mut panel = sq_draw_monitor::meter_panel::MeterPanel::new(Box::new(sq_draw_monitor::memory_defaults::MemoryDefaults::default()));
    panel.layout_frame(CGRect::new(0.0, 0.0, w, h));
    for (i, p) in peaks.iter().enumerate() {
        panel.reading = Some(MeterReading { source: 1, sequence: i as i64 + 1, peaks: p.to_vec() });
        panel.loudness_reading = loud;
        panel.loudness_target = Some(Default::default());
        panel.poll(i as f64 * 0.1);
    }
    if solo_mute {
        panel.toggle_solo(0);
        panel.toggle_mute(1);
    }
    panel.draw_card(cx.c, cx.t);
}

fn lists() -> Vec<Entry> {
    use sq_draw::monitor::loudness_meter::LoudnessReading;
    vec![
        Entry { id: "project-row", size: (330.0, 144.0), states: &[State::Default, State::Hover, State::Selected], draw: |cx| ls_rows(cx, false, 330.0, 6) },
        Entry { id: "project-row-stress", size: (220.0, 168.0), states: &[State::Default], draw: |cx| ls_rows(cx, true, 220.0, 7) },
        Entry {
            id: "list-header",
            size: (330.0, 25.0),
            states: &[State::Default],
            draw: |cx| ls_project_draw(cx, false, 330.0, 3.0, CGRect::new(0.0, 30.0, 330.0, 25.0), None, None),
        },
        Entry {
            id: "list-header-narrow",
            size: (180.0, 25.0),
            states: &[State::Default],
            draw: |cx| ls_project_draw(cx, false, 180.0, 3.0, CGRect::new(0.0, 30.0, 180.0, 25.0), None, None),
        },
        Entry { id: "library-tree-row", size: (132.0, 104.0), states: &[State::Default, State::Hover, State::Selected], draw: ls_sidebar_shot },
        Entry { id: "filter-row", size: (540.0, 36.0), states: &[State::Default, State::Hover, State::Selected], draw: |cx| ls_chips_shot(cx, 540.0, 1) },
        Entry { id: "filter-row-narrow", size: (200.0, 84.0), states: &[State::Default], draw: |cx| ls_chips_shot(cx, 200.0, 3) },
        Entry { id: "library-items", size: (420.0, 220.0), states: &[State::Default], draw: ls_items_shot },
        Entry { id: "empty-state", size: (330.0, 222.0), states: &[State::Default, State::Hover], draw: |cx| ls_empty_shot(cx, 330.0, "", false) },
        Entry { id: "empty-state-favorites", size: (330.0, 222.0), states: &[State::Default], draw: |cx| ls_empty_shot(cx, 330.0, "", true) },
        Entry { id: "empty-state-no-results", size: (330.0, 222.0), states: &[State::Default], draw: |cx| ls_empty_shot(cx, 330.0, "zzz", false) },
        Entry { id: "empty-state-narrow", size: (150.0, 222.0), states: &[State::Default], draw: |cx| ls_empty_shot(cx, 150.0, "", false) },
        Entry { id: "meter", size: (110.0, 300.0), states: &[State::Default], draw: |cx| ls_meter_shot(cx, (110.0, 300.0), &[], None, false) },
        Entry {
            id: "meter-level",
            size: (110.0, 300.0),
            states: &[State::Default],
            draw: |cx| {
                let l = LoudnessReading { momentary_lufs: Some(-16.0), short_term_lufs: Some(-15.0), integrated_lufs: Some(-14.5), true_peak_db: -2.0 };
                ls_meter_shot(cx, (110.0, 300.0), &[[0.5, 0.35], [0.2, 0.1]], Some(l), false);
            },
        },
        Entry {
            id: "meter-clip",
            size: (110.0, 300.0),
            states: &[State::Default],
            draw: |cx| {
                let l = LoudnessReading { momentary_lufs: Some(-8.0), short_term_lufs: Some(-9.0), integrated_lufs: Some(-10.0), true_peak_db: 1.5 };
                ls_meter_shot(cx, (110.0, 300.0), &[[1.4, 0.7]], Some(l), false);
            },
        },
        Entry { id: "meter-solo-mute", size: (110.0, 300.0), states: &[State::Default], draw: |cx| ls_meter_shot(cx, (110.0, 300.0), &[[0.5, 0.5]], None, true) },
        Entry { id: "meter-narrow", size: (60.0, 300.0), states: &[State::Default], draw: |cx| ls_meter_shot(cx, (60.0, 300.0), &[[0.5, 0.35]], None, false) },
        Entry { id: "meter-short", size: (110.0, 90.0), states: &[State::Default], draw: |cx| ls_meter_shot(cx, (110.0, 90.0), &[[0.9, 0.5]], None, false) },
    ]
}

/// What one start-screen shot shows.
#[derive(Clone)]
struct StartScene {
    tab: sq_draw_shell::StartTab,
    list: bool,
    /// How many recents (0 = first launch).
    recents: usize,
    /// Very long names and paths.
    long: bool,
    /// Index of the recent whose file is gone.
    missing: Option<usize>,
    size: (f64, f64),
    hover: Option<fn(&StartScene) -> sq_draw_shell::StartHit>,
    /// Index of the recent chosen with the arrow keys.
    selected: Option<usize>,
    /// The open-last box is on in the Selected state.
    checked: bool,
}

const ST_WINDOW: (f64, f64) = (1280.0, 800.0);

impl StartScene {
    fn listed(tab: sq_draw_shell::StartTab) -> StartScene {
        StartScene { list: true, ..StartScene::new(tab) }
    }
    fn new(tab: sq_draw_shell::StartTab) -> StartScene {
        StartScene { tab, list: false, recents: 6, long: false, missing: None, size: ST_WINDOW, hover: None, selected: None, checked: false }
    }
}

fn st_path(i: usize) -> String {
    format!("/sample/{}.sqproj", i)
}

/// The same six sample projects the `--pose start-*` shots use, repeated with a number past six.
fn st_recents(sc: &StartScene) -> Vec<sq_editor_session::RecentEntry> {
    const NAMES: [&str; 6] = ["T2", "TCL C7L x Paul Herter", "C2171", "C2170", "Sequence 01", "Beep"];
    let now = 1_800_000_000.0_f64;
    (0..sc.recents)
        .map(|i| {
            let base = NAMES[i % 6];
            let name = if sc.long {
                format!("{base} - the very long working title of a documentary about the harbor in winter, final cut {i}")
            } else if i >= 6 {
                format!("{base} {}", i + 1)
            } else {
                base.to_string()
            };
            sq_editor_session::RecentEntry::new(st_path(i), name, sq_core_time::Timestamp::from_unix_seconds(now - 600.0 - i as f64 * 86_400.0))
        })
        .collect()
}

/// Draws the whole start window at `sc.size`, cropped to `crop`.
fn st_draw(cx: &mut Cx, sc: &StartScene, crop: CGRect) {
    use sq_draw_shell::{LocalCalendar, ShellStartScreen, StartEnv, StartSettings};
    let recents = st_recents(sc);
    let mut screen = ShellStartScreen::new(&StartSettings { tab: Some(sc.tab.raw().into()), list_layout: sc.list, reopen_last: cx.state == State::Selected && sc.checked, ..StartSettings::default() });
    screen.frame = CGRect::new(0.0, 0.0, sc.size.0, sc.size.1);
    for (i, e) in recents.iter().enumerate() {
        if sc.missing == Some(i) {
            screen.missing.insert(e.path.clone());
        }
    }
    if let Some(i) = sc.selected.filter(|_| cx.state == State::Selected) {
        screen.selected_path = Some(st_path(i));
    }
    if cx.state == State::Hover {
        screen.hover = sc.hover.map(|h| h(sc));
    }
    let mut ui = UiCx::new();
    MEASURE_ATLAS.with(|a| {
        let measure = TextMeasure::new(Some(a), SCALE);
        let env = StartEnv {
            recents: &recents,
            measure: &measure,
            now: sq_core_time::Timestamp::from_unix_seconds(1_800_000_000.0),
            steady: 0.0,
            calendar: &LocalCalendar,
            has_real_project: false,
            projects_root: "~/Movies/Sequence Studio",
            open_name: "",
            poster: None,
        };
        cx.c.save_gstate();
        cx.c.translate_by(-crop.x, -crop.y);
        screen.draw(cx.c, cx.t, &env, &mut ui, true);
        cx.c.restore_gstate();
    });
}

/// One start entry: id, crop `(x, y, w, h)` of the window in points (the shot is that size), states, scene.
macro_rules! st {
    ($id:expr, $crop:expr, $states:expr, $scene:expr) => {
        Entry {
            id: $id,
            size: ($crop.2 as f32, $crop.3 as f32),
            states: $states,
            draw: |cx| st_draw(cx, &$scene, CGRect::new($crop.0, $crop.1, $crop.2, $crop.3)),
        }
    };
}

fn start() -> Vec<Entry> {
    use sq_core_project::support_policy::SupportEntry;
    use sq_draw_shell::{StartHit, StartTab};
    const WIN: (f64, f64, f64, f64) = (0.0, 0.0, 1280.0, 800.0);
    const HD: &[State] = &[State::Default, State::Hover];
    const HDS: &[State] = &[State::Default, State::Hover, State::Selected];
    const D: &[State] = &[State::Default];
    vec![
        // Controls
        st!("start-button-primary", (8.0, 50.0, 238.0, 36.0), HD, StartScene { hover: Some(|_| StartHit::NewProject), ..StartScene::new(StartTab::Home) }),
        st!("start-button-raised", (8.0, 82.0, 238.0, 36.0), HD, StartScene { hover: Some(|_| StartHit::OpenOther), ..StartScene::new(StartTab::Home) }),
        st!("start-button-open", (660.0, 290.0, 110.0, 44.0), HD, StartScene { hover: Some(|_| StartHit::ContinueOpen), ..StartScene::new(StartTab::Home) }),
        st!("start-button-small", (1110.0, 50.0, 150.0, 36.0), HD, StartScene { hover: Some(|_| StartHit::Sort), ..StartScene::new(StartTab::Recent) }),
        st!("start-button-compact", (22.0, 648.0, 120.0, 38.0), HD, StartScene { hover: Some(|_| StartHit::Support(SupportEntry::Support)), ..StartScene::new(StartTab::Home) }),
        st!("start-search", (980.0, 4.0, 290.0, 32.0), HD, StartScene { hover: Some(|_| StartHit::Search), ..StartScene::new(StartTab::Recent) }),
        st!("start-view-toggle", (1030.0, 52.0, 80.0, 36.0), HD, StartScene { hover: Some(|_| StartHit::Layout(true)), ..StartScene::new(StartTab::Recent) }),
        st!("start-view-toggle-list", (1030.0, 52.0, 80.0, 36.0), D, StartScene::listed(StartTab::Recent)),
        st!("start-checkbox", (8.0, 706.0, 250.0, 28.0), HDS, StartScene { hover: Some(|_| StartHit::ReopenLast), checked: true, ..StartScene::new(StartTab::Home) }),
        // Cards and rows
        st!("start-nav-item", (8.0, 150.0, 240.0, 150.0), HD, StartScene { hover: Some(|_| StartHit::Tab(StartTab::Templates)), ..StartScene::new(StartTab::Home) }),
        st!("start-nav-item-recent", (8.0, 150.0, 240.0, 150.0), D, StartScene::new(StartTab::Recent)),
        st!("start-support-card", (8.0, 552.0, 240.0, 152.0), D, StartScene::new(StartTab::Home)),
        st!("start-card", (272.0, 100.0, 570.0, 290.0), HDS, StartScene { hover: Some(|_| StartHit::Card(st_path(1))), selected: Some(1), ..StartScene::new(StartTab::Recent) }),
        st!("start-card-missing", (272.0, 100.0, 570.0, 290.0), HD, StartScene { missing: Some(0), hover: Some(|_| StartHit::Card(st_path(0))), ..StartScene::new(StartTab::Recent) }),
        st!("start-card-stress", (272.0, 100.0, 570.0, 290.0), D, StartScene { long: true, ..StartScene::new(StartTab::Recent) }),
        st!("start-list-row", (272.0, 100.0, 1000.0, 190.0), HDS, StartScene { hover: Some(|_| StartHit::Card(st_path(2))), selected: Some(2), ..StartScene::listed(StartTab::Recent) }),
        st!("start-list-row-missing", (272.0, 100.0, 1000.0, 190.0), D, StartScene { missing: Some(1), ..StartScene::listed(StartTab::Recent) }),
        st!("start-list-row-stress", (272.0, 100.0, 1000.0, 190.0), D, StartScene { long: true, ..StartScene::listed(StartTab::Recent) }),
        st!("start-size-tile", (280.0, 400.0, 980.0, 150.0), HD, StartScene { hover: Some(|_| StartHit::QuickSize("builtin-horizontal-16x9".into())), ..StartScene::new(StartTab::Home) }),
        // The window
        st!("start-top-bar", (0.0, 0.0, 1280.0, 40.0), HD, StartScene { hover: Some(|_| StartHit::Search), ..StartScene::new(StartTab::Recent) }),
        st!("start-status-bar", (0.0, 776.0, 1280.0, 24.0), D, StartScene::new(StartTab::Recent)),
        st!("start-rail", (0.0, 40.0, 256.0, 760.0), HD, StartScene { hover: Some(|_| StartHit::Tab(StartTab::Learn)), ..StartScene::new(StartTab::Home) }),
        st!("start-window-home", WIN, D, StartScene::new(StartTab::Home)),
        st!("start-window-recent", WIN, HDS, StartScene { hover: Some(|_| StartHit::Card(st_path(3))), selected: Some(3), ..StartScene::new(StartTab::Recent) }),
        st!("start-window-recent-list", WIN, D, StartScene::listed(StartTab::Recent)),
        st!("start-window-templates", WIN, D, StartScene::new(StartTab::Templates)),
        st!("start-window-learn", WIN, D, StartScene::new(StartTab::Learn)),
        st!("start-window-whats-new", WIN, D, StartScene::new(StartTab::WhatsNew)),
        st!("start-window-first-launch", WIN, D, StartScene { recents: 0, ..StartScene::new(StartTab::Home) }),
        st!("start-window-no-recents", WIN, D, StartScene { recents: 0, ..StartScene::new(StartTab::Recent) }),
        st!("start-window-missing", WIN, D, StartScene { missing: Some(0), ..StartScene::new(StartTab::Recent) }),
        st!("start-window-many", WIN, D, StartScene { recents: 100, ..StartScene::new(StartTab::Recent) }),
        st!("start-window-many-list", WIN, D, StartScene { recents: 100, ..StartScene::listed(StartTab::Recent) }),
        st!("start-window-long-names", WIN, D, StartScene { long: true, ..StartScene::new(StartTab::Recent) }),
        st!("start-window-small", (0.0, 0.0, 720.0, 480.0), D, StartScene { size: (720.0, 480.0), ..StartScene::new(StartTab::Recent) }),
        st!("start-window-small-home", (0.0, 0.0, 720.0, 480.0), D, StartScene { size: (720.0, 480.0), ..StartScene::new(StartTab::Home) }),
    ]
}

// ---- Color group ----------------------------------------------------------------------------------------------------
// The Color page's panels are drawn by `ColorGradeDraw` (grade panel), `ColorStepsDraw` (Steps) and `ColorStripToolsDraw`
// (the strip dropdowns). Each shot builds a one-clip scene (an Adjustment Layer, which carries a Color effect), drives the
// real draw object with pointer calls and crops the component out of the panel.

use sq_inspector_ui::color::color_grade_controller::ColorGradeController;
use sq_inspector_ui::color::color_grade_draw::{ColorGradeDraw, ColorGradeHost, Control, Mac, Row, Slider, Wheel};
use sq_inspector_ui::color::color_inspector_model::{ColorInspectorModel, ColorPanelKey, ColorParam, ColorWheelSlot};
use sq_inspector_ui::color::color_steps_draw::ColorStepsDraw;
use sq_inspector_ui::color::color_viewer_header_draw::{ColorStripToolsDraw, StripButton, StripPanel};

/// One Color scene: the session, the controller over it and the clipboard the draw calls borrow together.
struct CmScene {
    rig: crate::test_rig::Rig,
    ctl: ColorGradeController,
    clip: sq_editor_session::ColorClipboard,
    effect: i64,
    dir: PathBuf,
}

impl Drop for CmScene {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A model edit that also gets the state the shot shows.
type CmSetup = dyn Fn(&mut ColorInspectorModel, i64, State);

fn cm_scene(select: bool, setup: &CmSetup, state: State) -> CmScene {
    use sq_editor_session::{Change, EditorSession, SessionDeps};
    let dir = crate::test_rig::unique_dir("sq-catalogue-color");
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut rig = crate::test_rig::Rig::new(EditorSession::new(project, SessionDeps::headless(dir.clone())));
    let layer = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection(if select { [layer].into() } else { Default::default() }, Default::default());
    let mut ctl = ColorGradeController::new(&rig.session, Box::new(|| Box::new(SequentialIds::default())));
    ctl.sync(&mut rig.session, Change::PROJECT | Change::SELECTION);
    let mut sc = CmScene { rig, ctl, clip: Default::default(), effect: 0, dir };
    if let Some(m) = sc.ctl.model_mut() {
        let e = m.effects()[0].id;
        sc.effect = e;
        // Every section open, so the rows exist.
        for kind in sq_inspector_ui::color::color_page_models::ColorSectionText::ORDER {
            m.set_collapsed(ColorPanelKey::new(e, kind, None), false);
        }
        setup(m, e, state);
        if state == State::Disabled {
            for kind in sq_inspector_ui::color::color_page_models::ColorSectionText::ORDER {
                m.set_enabled(e, kind, false);
            }
        }
    }
    sc
}

fn cm_host(sc: &mut CmScene) -> ColorGradeHost<'_> {
    ColorGradeHost { controller: &mut sc.ctl, session: &mut sc.rig.session, clipboard: &mut sc.clip }
}

fn cm_grade(w: f64) -> ColorGradeDraw {
    let mut d = ColorGradeDraw::new();
    d.size = CGSize::new(w, 2600.0);
    d
}

/// The first control `pick` accepts: (its frame in panel points, its row's frame).
fn cm_find(rows: &[Row], pick: &dyn Fn(&Control) -> bool) -> (CGRect, CGRect) {
    for r in rows {
        if let Some((_, f)) = r.controls.iter().find(|(k, _)| pick(k)) {
            return (CGRect::new(f.x, r.y + f.y, f.width, f.height), CGRect::new(0.0, r.y, 0.0, r.height));
        }
    }
    panic!("control not in the rows: {:?}", rows.iter().map(|r| (&r.label, r.y)).collect::<Vec<_>>())
}

enum CmAct {
    None,
    /// The pointer rests at this fraction of the control's width.
    Hover(f64),
    /// A press at the first fraction of the control, dragged to the second (the press stays down).
    Drag(f64, f64),
    /// A wheel: press on the disc's middle, drag by (dx, dy).
    Puck(f64, f64),
}

fn cm_point(ctrl: CGRect, frac: f64) -> CGPoint {
    CGPoint::new(ctrl.x + ctrl.width * frac, ctrl.mid_y())
}

/// Draws `crop` of the grade panel (`w` wide) after `act` on the control `pick` finds.
fn cm_paint(cx: &mut Cx, sc: &mut CmScene, w: f64, pick: &dyn Fn(&Control) -> bool, crop: &dyn Fn(CGRect, CGRect) -> CGRect, act: CmAct) {
    let mut d = cm_grade(w);
    let mut ui = UiCx::new();
    let rows = match sc.ctl.model() {
        Some(m) => d.rows(m, false),
        None => Vec::new(),
    };
    let (ctrl, row) = if rows.is_empty() { (CGRect::new(0.0, 0.0, w, 20.0), CGRect::new(0.0, 0.0, 0.0, 20.0)) } else { cm_find(&rows, pick) };
    {
        let mut host = cm_host(sc);
        match act {
            CmAct::None => {}
            CmAct::Hover(f) => d.mouse_moved(&mut host, &mut ui, Some(cm_point(ctrl, f))),
            CmAct::Drag(a, b) => {
                // The slider's track is the control minus the number column.
                let track = CGRect::new(ctrl.x, ctrl.y, ctrl.width - Mac::VALUE_COLUMN, ctrl.height);
                d.mouse_moved(&mut host, &mut ui, Some(cm_point(track, a)));
                d.mouse_down(&mut host, &mut ui, cm_point(track, a), InputModifiers::NONE, Some(1));
                d.mouse_dragged(&mut host, &mut ui, cm_point(track, b), InputModifiers::NONE);
            }
            CmAct::Puck(dx, dy) => {
                let at = CGPoint::new(ctrl.mid_x(), ctrl.mid_y());
                d.mouse_moved(&mut host, &mut ui, Some(at));
                d.mouse_down(&mut host, &mut ui, at, InputModifiers::NONE, Some(1));
                d.mouse_dragged(&mut host, &mut ui, CGPoint::new(at.x + dx, at.y + dy), InputModifiers::NONE);
            }
        }
    }
    let rect = crop(ctrl, row);
    cx.c.save_gstate();
    cx.c.translate_by(-rect.x, -rect.y);
    d.draw(cx.c, cx.t, &sc.ctl, &mut ui);
    cx.c.restore_gstate();
}

/// The whole-row crop of a panel `w` wide.
fn cm_row(w: f64) -> impl Fn(CGRect, CGRect) -> CGRect {
    move |_, row| CGRect::new(0.0, row.y, w, row.height)
}

fn cm_none(_: &mut ColorInspectorModel, _: i64, _: State) {}

const CM_W: f64 = 340.0;
const CM_PANEL: &[State] = &[State::Default, State::Hover, State::Pressed, State::Disabled];

/// One Simple slider row: `p` at `value`; Hover rests on the track, Pressed drags it.
fn cm_slider(cx: &mut Cx, p: ColorParam, value: f32, w: f64) {
    let mut sc = cm_scene(true, &move |m, e, _| m.set(e, p, value), cx.state);
    let act = match cx.state {
        State::Hover => CmAct::Hover(0.5),
        State::Pressed => CmAct::Drag(0.3, 0.7),
        _ => CmAct::None,
    };
    cm_paint(cx, &mut sc, w, &move |k| matches!(k, Control::Slider(Slider::Param(_, q)) if *q == p), &cm_row(w), act);
}

fn cm_lut(cx: &mut Cx, slot: sq_inspector_ui::color::color_inspector_model::ColorLUTSlot, star: bool) {
    // The star acts only on a LUT file, so the star shots load one (a dim star would look the same hovered).
    let file = move |m: &mut ColorInspectorModel, e: i64, _: State| {
        if star {
            m.set_lut(e, slot, Some(&sq_inspector_ui::color::color_inspector_model::LUTChoice::file("/LUTs/Warm Film.cube")));
        }
    };
    let mut sc = cm_scene(true, &file, cx.state);
    let act = if cx.state == State::Hover { CmAct::Hover(0.5) } else { CmAct::None };
    let pick = move |k: &Control| match (k, star) {
        (Control::LutStar(_, s), true) | (Control::Lut(_, s), false) => *s == slot,
        _ => false,
    };
    cm_paint(cx, &mut sc, CM_W, &pick, &cm_row(CM_W), act);
}

/// The Basic section's header. Hover rests on the eyedropper (the header itself has no hover look); Selected = closed.
fn cm_header(cx: &mut Cx, closed: bool) {
    use sq_core_model::ColorSectionKind::BasicCorrection;
    let mut sc = cm_scene(
        true,
        &move |m, e, _| {
            if closed {
                m.set_collapsed(ColorPanelKey::new(e, BasicCorrection, None), true);
            }
        },
        cx.state,
    );
    sc.ctl.can_pick_screen_color = true;
    let hover = cx.state == State::Hover;
    let pick = move |k: &Control| if hover { matches!(k, Control::Eyedropper(_)) } else { matches!(k, Control::Section(_, BasicCorrection)) };
    let w = CM_W;
    let mut d = cm_grade(w);
    let mut ui = UiCx::new();
    let rows = d.rows(sc.ctl.model().expect("model"), false);
    let (ctrl, _) = cm_find(&rows, &|k| matches!(k, Control::Section(_, BasicCorrection)));
    if hover {
        let (eye, _) = cm_find(&rows, &pick);
        d.mouse_moved(&mut cm_host(&mut sc), &mut ui, Some(CGPoint::new(eye.mid_x(), eye.mid_y())));
    }
    cx.c.save_gstate();
    cx.c.translate_by(0.0, -ctrl.y);
    d.draw(cx.c, cx.t, &sc.ctl, &mut ui);
    cx.c.restore_gstate();
}

fn cm_wheel(cx: &mut Cx, hue: f32, amount: f32, w: f64) {
    let mut sc = cm_scene(true, &move |m, e, _| m.set_wheel(e, ColorWheelSlot::Shadows, hue, amount), cx.state);
    let act = match cx.state {
        State::Hover => CmAct::Hover(0.5),
        State::Pressed => CmAct::Puck(28.0, -18.0),
        _ => CmAct::None,
    };
    let pick = |k: &Control| matches!(k, Control::Wheel(Wheel::Slot(_, ColorWheelSlot::Shadows)));
    // The block: the title above the disc, the disc and the master slider to its right.
    cm_paint(cx, &mut sc, w, &pick, &|d, _| CGRect::new(d.x - 17.0, d.y - 32.0, 128.0, d.height + 38.0), act);
}

/// The whole top of the grade panel `w` wide, `h` high (stress shots).
fn cm_page(cx: &mut Cx, select: bool, w: f64, setup: &CmSetup) {
    let mut sc = cm_scene(select, setup, cx.state);
    cm_paint(cx, &mut sc, w, &|_| true, &|_, _| CGRect::new(0.0, 0.0, w, 620.0), CmAct::None);
}

fn cm_many(m: &mut ColorInspectorModel, first: i64, _: State) {
    for _ in 0..5 {
        m.add_effect();
    }
    let ids: Vec<i64> = m.effects().iter().map(|e| e.id).collect();
    for id in ids.into_iter().filter(|id| *id != first) {
        for kind in sq_inspector_ui::color::color_page_models::ColorSectionText::ORDER {
            m.set_collapsed(ColorPanelKey::new(id, kind, None), true);
        }
    }
    for kind in sq_inspector_ui::color::color_page_models::ColorSectionText::ORDER {
        m.set_collapsed(ColorPanelKey::new(first, kind, None), true);
    }
}

fn cm_extreme(m: &mut ColorInspectorModel, e: i64, _: State) {
    m.set(e, ColorParam::Temperature, -100.0);
    m.set(e, ColorParam::Tint, 100.0);
    m.set(e, ColorParam::Exposure, 5.0);
    m.set(e, ColorParam::Contrast, 100.0);
    m.set(e, ColorParam::Saturation, 200.0);
    m.set(e, ColorParam::Vibrance, -100.0);
    m.set_wheel(e, ColorWheelSlot::Shadows, 20.0, 1.0);
}

/// The Steps panel with `steps` boxes; `crop` names the part to show (panel points, from the layout after the first frame).
fn cm_steps(cx: &mut Cx, size: (f64, f64), steps: usize, select_last: bool, crop: &dyn Fn(&ColorStepsDraw) -> CGRect, hover: bool) {
    use sq_core_model::StepKind;
    let mut sc = cm_scene(true, &cm_none, cx.state);
    if let Some(m) = sc.ctl.model_mut() {
        m.start_from_simple();
    }
    cm_host(&mut sc).pump();
    if let Some(m) = sc.ctl.model_mut() {
        for _ in 1..steps {
            m.add_step_at_end(StepKind::Serial);
        }
        if !select_last {
            let first = m.graph().and_then(|g| g.steps().first().map(|s| s.id));
            m.set_selected_step(first);
        }
    }
    cm_host(&mut sc).pump();
    let mut d = ColorStepsDraw::new();
    d.size = CGSize::new(size.0, size.1);
    let mut ui = UiCx::new();
    // First frame: the view fits itself to the content, so the second one has the boxes where they will be. Its ops are
    // painted over by the second frame's panel fill.
    d.draw(cx.c, cx.t, &mut cm_host(&mut sc), &mut ui);
    let at = crop(&d);
    if hover {
        d.mouse_moved(&sc.ctl, &mut ui, Some(CGPoint::new(at.mid_x(), at.mid_y())));
    }
    cx.c.save_gstate();
    cx.c.translate_by(-at.x, -at.y);
    d.draw(cx.c, cx.t, &mut cm_host(&mut sc), &mut ui);
    cx.c.restore_gstate();
}

/// A box's rectangle in panel points: `which` picks it from the layout (0 = first Step).
fn cm_box(d: &ColorStepsDraw, which: usize) -> CGRect {
    let l = d.canvas().layout();
    let id = l.order[which];
    let r = d.canvas().view_rect(&l.rects[&id]);
    let w = d.well();
    CGRect::new(w.x + r.x, w.y + r.y, r.width, r.height)
}

fn cm_slot(d: &ColorStepsDraw, input: bool) -> CGRect {
    let l = d.canvas().layout();
    let r = d.canvas().view_rect(if input { &l.in_slot } else { &l.out_slot });
    let w = d.well();
    CGRect::new(w.x + r.x, w.y + r.y, r.width, r.height)
}

fn cm_strip(cx: &mut Cx, mode: bool) {
    let mut sc = cm_scene(true, &cm_none, cx.state);
    let strip = CGRect::new(0.0, 0.0, 400.0, 31.0);
    let want = if mode { StripButton::Mode } else { StripButton::Fit };
    let Some((_, r)) = ColorStripToolsDraw::frames(StripPanel::Timeline, strip).into_iter().find(|(b, _)| *b == want) else {
        panic!("no {want:?} button in the Timeline strip")
    };
    let mut tools = ColorStripToolsDraw::default();
    tools.sequence = "Sequence 1".to_string();
    if cx.state == State::Hover {
        tools.mouse_moved(Some(StripPanel::Timeline), Some(strip), CGPoint::new(r.mid_x(), r.mid_y()));
    }
    cx.c.save_gstate();
    cx.c.translate_by(-(r.x - 4.0), -strip.y);
    tools.draw(cx.c, cx.t, &sc.ctl, &sc.rig.session, &sc.clip, StripPanel::Timeline, strip, 0.0);
    cx.c.restore_gstate();
}

fn cm_steps_empty(cx: &mut Cx) {
    let mut sc = cm_scene(false, &cm_none, cx.state);
    let mut d = ColorStepsDraw::new();
    let mut ui = UiCx::new();
    d.draw(cx.c, cx.t, &mut cm_host(&mut sc), &mut ui);
}

fn color() -> Vec<Entry> {
    use sq_inspector_ui::color::color_inspector_model::ColorLUTSlot;
    const HD: &[State] = &[State::Default, State::Hover];
    const D: &[State] = &[State::Default];
    vec![
        Entry { id: "color-flat-dropdown", size: (60.0, 31.0), states: HD, draw: |cx| cm_strip(cx, false) },
        Entry { id: "color-flat-dropdown-icon", size: (96.0, 31.0), states: HD, draw: |cx| cm_strip(cx, true) },
        Entry { id: "color-group-header", size: (340.0, 26.0), states: &[State::Default, State::Hover, State::Selected, State::Disabled], draw: |cx| cm_header(cx, cx.state == State::Selected) },
        Entry { id: "color-slider-row", size: (340.0, 24.0), states: CM_PANEL, draw: |cx| cm_slider(cx, ColorParam::Exposure, 1.2, CM_W) },
        Entry { id: "color-slider-row-neutral", size: (340.0, 24.0), states: D, draw: |cx| cm_slider(cx, ColorParam::Exposure, 0.0, CM_W) },
        Entry { id: "color-slider-row-temp", size: (340.0, 24.0), states: HD, draw: |cx| cm_slider(cx, ColorParam::Temperature, 35.0, CM_W) },
        Entry { id: "color-slider-row-tint", size: (340.0, 24.0), states: HD, draw: |cx| cm_slider(cx, ColorParam::Tint, -30.0, CM_W) },
        Entry { id: "color-slider-row-sat", size: (340.0, 24.0), states: HD, draw: |cx| cm_slider(cx, ColorParam::Saturation, 130.0, CM_W) },
        Entry { id: "color-lut-row", size: (340.0, 24.0), states: &[State::Default, State::Hover, State::Disabled], draw: |cx| cm_lut(cx, ColorLUTSlot::Input, false) },
        Entry { id: "color-lut-row-star", size: (340.0, 24.0), states: HD, draw: |cx| cm_lut(cx, ColorLUTSlot::Input, true) },
        Entry { id: "color-wheel-block", size: (128.0, 108.0), states: CM_PANEL, draw: |cx| cm_wheel(cx, 220.0, 0.5, CM_W) },
        Entry { id: "color-wheel-block-neutral", size: (128.0, 108.0), states: D, draw: |cx| cm_wheel(cx, 0.0, 0.0, CM_W) },
        Entry { id: "color-node-slot", size: (120.0, 36.0), states: D, draw: |cx| cm_steps(cx, (900.0, 300.0), 3, true, &|d| cm_slot(d, true), false) },
        Entry { id: "color-node", size: (140.0, 48.0), states: &[State::Default, State::Hover, State::Selected], draw: |cx| {
            // The last Step is selected: Selected shows it, Default and Hover show the first Step, which is not selected.
            let sel = cx.state == State::Selected;
            cm_steps(cx, (900.0, 300.0), 3, true, &move |d| cm_box(d, if sel { 2 } else { 0 }), cx.state == State::Hover)
        } },
        Entry { id: "color-node-ghost", size: (90.0, 36.0), states: D, draw: |cx| cm_steps(cx, (900.0, 300.0), 3, true, &|d| cm_slot(d, false), false) },
        // Stress
        Entry { id: "color-stress-narrow", size: (240.0, 620.0), states: D, draw: |cx| cm_page(cx, true, 240.0, &cm_none) },
        Entry { id: "color-stress-extreme", size: (340.0, 620.0), states: D, draw: |cx| cm_page(cx, true, 340.0, &cm_extreme) },
        Entry { id: "color-stress-many", size: (340.0, 320.0), states: D, draw: |cx| cm_page(cx, true, 340.0, &cm_many) },
        Entry { id: "color-stress-steps-many", size: (480.0, 300.0), states: D, draw: |cx| cm_steps(cx, (480.0, 300.0), 30, true, &|_| CGRect::new(0.0, 0.0, 480.0, 300.0), false) },
        Entry { id: "color-stress-steps-narrow", size: (240.0, 300.0), states: D, draw: |cx| cm_steps(cx, (240.0, 300.0), 6, true, &|_| CGRect::new(0.0, 0.0, 240.0, 300.0), false) },
        Entry { id: "color-stress-steps-empty", size: (480.0, 300.0), states: D, draw: cm_steps_empty },
    ]
}

/// What a forms shot varies: the sheet width, the texts, the chosen card.
struct Fm {
    width: f64,
    name: String,
    rate_label: &'static str,
    path: String,
    select: usize,
}

impl Default for Fm {
    fn default() -> Fm {
        Fm { width: 623.0, name: "Untitled Project".into(), rate_label: "Frame rate", path: "~/Movies".into(), select: 1 }
    }
}

/// A scripted input before the shot: a click or a key. Points are relative to the card.
#[derive(Clone, Copy)]
enum Ev {
    Click(f64, f64),
    Key(sq_draw::InputKey),
}

/// The New project sheet's form rebuilt from public APIs (`ShellNewProject::form` is crate-private): same rows, cards, pill, swap and chip.
fn fm_form(o: &Fm) -> ShellForm {
    use sq_draw_shell::{Chip, NumberField, ShapeCard};
    let dims = 1.0..=16384.0;
    let field = |id: &str, v: f64| NumberField { default_value: Some(v), ..NumberField::new(id, v, dims.clone()) };
    let mut f = ShellForm::new(vec![
        FormRow::field("name", "Name", &o.name),
        FormRow::segmented("shape", "Start from", &["9:16", "16:9", "1:1", "4:5", "Custom"], o.select as i64, 0.0),
        FormRow::Size { label: "Frame size".into(), width: field("width", 1920.0), height: field("height", 1080.0) },
        FormRow::popup("rate", o.rate_label, &["23.976 fps", "24 fps", "25 fps", "30 fps"], 3),
        FormRow::buttons("location", "Location", &o.path, &["Choose\u{2026}"]),
        FormRow::check("more", "More options", false),
    ]);
    let cards = [("9:16", 9, 16), ("16:9", 16, 9), ("1:1", 1, 1), ("4:5", 4, 5), ("Custom", 0, 0)];
    f.shape_cards = [("shape".to_string(), cards.iter().map(|c| ShapeCard { title: c.0.into(), width: c.1, height: c.2 }).collect())].into();
    f.disclosures.insert("more".into());
    f.pill_hints.insert("width".into());
    f.hints.insert("width".into(), "16:9".into());
    f.control_widths.insert("rate".into(), 120.0);
    f.control_widths.insert("width".into(), 84.0);
    f.side_pad = 24.0;
    f.label_inset = 2.0;
    f.dialog_row = Some(30.0);
    f.extra_gap_before = (1..=5).map(|i| (i, 8.0)).collect();
    f.field_heights.insert("name".into(), 22.0);
    f.dialog_field_font_size = 12.0;
    f.dialog_font_size = Some(12.0);
    f.labeled_field_bleed = false;
    f.chips.insert("location".into(), Chip { icon: SQIcon::Folder, button_width: 92.0 });
    f.swap_between.insert("width".into());
    f
}

/// Draws the sheet, plays `events`, hovers `hover`, and crops to `crop` (all card-relative). The Name field starts in editing with
/// its text selected (the sheet focuses it on open); a click on a label blurs it.
fn fm_draw(cx: &mut Cx, o: &Fm, disabled: &[&str], events: &[Ev], hover: Option<(f64, f64)>, crop: CGRect) {
    let mut ui = UiCx::new();
    let mut form = fm_form(o);
    form.disabled.extend(disabled.iter().map(|s| s.to_string()));
    let mut d = ShellDialog::new("New project", "Settings can change later in Sequence Settings.");
    d.width = o.width;
    d.form = Some(Box::new(form));
    d.close_button = true;
    d.heading_font_size = Some(15.0);
    d.add_button("Create", SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    let window = CGRect::new(0.0, 0.0, o.width + 80.0, 640.0);
    with_measure(|m| d.layout(window, m));
    let card = d.card();
    let at = |x: f64, y: f64| ((card.x + x) as f32, (card.y + y) as f32);
    for e in events {
        match *e {
            Ev::Click(x, y) => {
                let (x, y) = at(x, y);
                for ev in [InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, InputEvent::MouseUp { x, y }] {
                    with_measure(|m| d.handle(&ev, 1.0, m, &mut ui));
                }
            }
            Ev::Key(key) => with_measure(|m| d.handle(&InputEvent::KeyDown { key, modifiers: InputModifiers::NONE }, 1.0, m, &mut ui)),
        }
    }
    if let Some((x, y)) = hover {
        let (x, y) = at(x, y);
        with_measure(|m| d.handle(&InputEvent::MouseMoved { x, y }, 1.0, m, &mut ui));
    }
    cx.c.save_gstate();
    cx.c.translate_by(-(card.x + crop.x), -(card.y + crop.y));
    d.draw(cx.c, cx.t, window, &mut ui);
    cx.c.restore_gstate();
}

const FM_BLUR: Ev = Ev::Click(20.0, 150.0);

/// A crop of the default sheet (Name blurred); `hover_at` is the pointer in the Hover state.
fn fm_crop(cx: &mut Cx, crop: CGRect, hover_at: (f64, f64)) {
    let hover = (cx.state == State::Hover).then_some(hover_at);
    fm_draw(cx, &Fm::default(), &[], &[FM_BLUR], hover, crop);
}

fn fm_name(cx: &mut Cx) {
    let crop = CGRect::new(30.0, 70.0, 580.0, 34.0);
    let events: &[Ev] = match cx.state {
        State::Default => &[FM_BLUR],
        State::Focus => &[Ev::Key(sq_draw::InputKey::Right)],
        State::Hover => &[FM_BLUR],
        _ => &[],
    };
    let hover = (cx.state == State::Hover).then_some((300.0, 87.0));
    fm_draw(cx, &Fm::default(), &[], events, hover, crop);
}

fn fm_stress_name(cx: &mut Cx) {
    let long = "Sommerurlaub am Nordkap mit der ganzen Familie und allen Freunden, Teil 1 \u{2013} Anreise \u{1F30A}\u{1F3A5} \u{65E5}\u{672C}\u{8A9E}\u{306E}\u{540D}\u{524D}\u{30D7}\u{30ED}\u{30B8}\u{30A7}\u{30AF}\u{30C8}";
    let o = Fm { name: long.into(), ..Fm::default() };
    fm_draw(cx, &o, &[], &[Ev::Key(sq_draw::InputKey::End)], None, CGRect::new(30.0, 70.0, 580.0, 34.0));
}

fn forms() -> Vec<Entry> {
    const D: &[State] = &[State::Default];
    const HD: &[State] = &[State::Default, State::Hover];
    vec![
        Entry { id: "form-sheet", size: (623.0, 436.0), states: D, draw: |cx| fm_draw(cx, &Fm::default(), &[], &[FM_BLUR], None, CGRect::new(0.0, 0.0, 623.0, 436.0)) },
        Entry { id: "form-field-name", size: (580.0, 34.0), states: &[State::Default, State::Hover, State::Focus, State::Selected], draw: fm_name },
        Entry { id: "form-field-path", size: (580.0, 34.0), states: HD, draw: |cx| fm_crop(cx, CGRect::new(30.0, 289.0, 580.0, 34.0), (553.0, 306.0)) },
        Entry { id: "form-shape-card", size: (580.0, 70.0), states: HD, draw: |cx| fm_crop(cx, CGRect::new(30.0, 110.0, 580.0, 70.0), (350.0, 125.0)) },
        Entry { id: "form-aspect-tag", size: (150.0, 30.0), states: D, draw: |cx| fm_crop(cx, CGRect::new(255.0, 207.0, 150.0, 30.0), (0.0, 0.0)) },
        Entry { id: "form-icon-swap", size: (50.0, 30.0), states: HD, draw: |cx| fm_crop(cx, CGRect::new(182.0, 207.0, 50.0, 30.0), (207.0, 222.0)) },
        Entry { id: "form-icon-close", size: (50.0, 36.0), states: HD, draw: |cx| fm_crop(cx, CGRect::new(573.0, 9.0, 50.0, 36.0), (597.0, 27.0)) },
        Entry { id: "form-popup", size: (330.0, 30.0), states: HD, draw: |cx| fm_crop(cx, CGRect::new(30.0, 250.0, 330.0, 30.0), (160.0, 265.0)) },
        Entry { id: "form-check-more", size: (180.0, 30.0), states: HD, draw: |cx| fm_crop(cx, CGRect::new(90.0, 330.0, 180.0, 30.0), (140.0, 344.0)) },
        Entry { id: "form-chip", size: (70.0, 36.0), states: ALL, draw: |cx| {
            let on = on(cx);
            let w = with_measure(|m| m.width("9:16", 12.0, 0)).ceil() + 20.0;
            cx.c.stone_chip(CGRect::new(PAD, 7.0, w, 22.0), on, true, cx.touch, cx.t);
            label(cx, "9:16", CGPoint::new(PAD + 10.0, 11.0));
        } },
        // Stress
        Entry { id: "form-stress-name", size: (580.0, 34.0), states: D, draw: fm_stress_name },
        Entry { id: "form-stress-narrow", size: (380.0, 436.0), states: D, draw: |cx| fm_draw(cx, &Fm { width: 360.0, ..Fm::default() }, &[], &[FM_BLUR], None, CGRect::new(0.0, 0.0, 360.0, 436.0)) },
        Entry { id: "form-stress-german", size: (623.0, 436.0), states: D, draw: |cx| fm_draw(cx, &Fm { rate_label: "Bildwiederholfrequenz der Zeitleiste", path: "~/Filme/Familienarchiv/Urlaube/2026/Nordkap/Rohmaterial/Kamera A/Projekte".into(), ..Fm::default() }, &[], &[FM_BLUR], None, CGRect::new(0.0, 0.0, 623.0, 436.0)) },
    ]
}

/// What a settings shot varies: the page, the search text, the window size, the pointer (card-relative), the sidebar focus.
struct Se {
    page: sq_draw_shell::PreferencesPage,
    search: &'static str,
    window: (f64, f64),
    hover: Option<(f64, f64)>,
    sidebar_focus: bool,
    counts: bool,
    extra: Option<fn(&mut sq_editor_session::AppSettings, &mut sq_draw_shell::PreferencesExtras)>,
}

impl Default for Se {
    fn default() -> Se {
        Se { page: sq_draw_shell::PreferencesPage::General, search: "", window: (1000.0, 760.0), hover: None, sidebar_focus: false, counts: false, extra: None }
    }
}

/// The Settings window rebuilt from public APIs (`ShellHost::install_preferences_page` is crate-private): the same form, header, search,
/// size and buttons as `present_preferences` (`shell_preferences.rs:1799`). `crop` is card-relative.
fn se_draw(cx: &mut Cx, o: &Se, crop: CGRect) {
    use sq_draw_shell::{PreferencesExtras, PreferencesHost, ShellPreferences};
    let defaults = sq_draw_shell::ShellDefaults::default();
    let mut s = sq_editor_session::AppSettings::standard();
    let mut x = PreferencesExtras::default();
    if let Some(f) = o.extra {
        f(&mut s, &mut x);
    }
    let host = PreferencesHost { edit_api: Some((false, sq_draw_shell::EditApiState::new("Off", sq_draw_shell::StatusTone::Idle))), cache_used: Some("1.2 GB".into()), ..PreferencesHost::default() };
    let mut f = if o.search.is_empty() {
        let mut f = ShellPreferences::form(o.page, &s, &x, &host, &defaults, "");
        f.page_header = Some((o.page.title().to_string(), o.page.subtitle().to_string()));
        f
    } else {
        let mut f = ShellPreferences::search_form(o.search, &s, &x, &host, &defaults);
        f.page_header = Some(("Results".to_string(), format!("Settings matching \u{201C}{}\u{201D}.", o.search)));
        f
    };
    f.set_sidebar_focused(o.sidebar_focus);
    f.enable_search(o.search);
    if o.counts {
        f.set_sidebar_counts(vec![2, 0, 1, 0, 0, 3, 0]);
    }
    let mut d = ShellDialog::new("Settings", "");
    d.width = 900.0;
    d.card_height = Some(640.0);
    d.headerless = true;
    d.add_button("Done", SQDialogRole::Default, false);
    d.add_button("Reset to Defaults", SQDialogRole::Normal, true);
    d.button_widths.insert(0, 70.0);
    d.keep_open = vec![1];
    d.footer_hint = Some(if o.counts { "3 changes \u{B7} apply right away".to_string() } else { "Changes apply right away.".to_string() });
    d.form = Some(Box::new(f));
    let window = CGRect::new(0.0, 0.0, o.window.0, o.window.1);
    let mut ui = UiCx::new();
    with_measure(|m| d.layout(window, m));
    let card = d.card();
    if let Some((px, py)) = o.hover {
        with_measure(|m| d.handle(&InputEvent::MouseMoved { x: (card.x + px) as f32, y: (card.y + py) as f32 }, 1.0, m, &mut ui));
    }
    cx.c.save_gstate();
    cx.c.translate_by(-(card.x + crop.x), -(card.y + crop.y));
    d.draw(cx.c, cx.t, window, &mut ui);
    cx.c.restore_gstate();
}

const SE_FULL: CGRect = CGRect { x: 0.0, y: 0.0, width: 900.0, height: 640.0 };

fn se_page(cx: &mut Cx, page: sq_draw_shell::PreferencesPage) {
    se_draw(cx, &Se { page, ..Se::default() }, SE_FULL);
}

/// The shortcuts editor over a default key map; `setup` puts it in a state; the whole window is 900 x 640 in a `window` frame.
fn se_keys(cx: &mut Cx, window: (f64, f64), crop: Option<CGRect>, setup: &dyn Fn(&mut sq_draw_shell::ShellShortcutsEditor)) {
    let mut e = sq_draw_shell::ShellShortcutsEditor::new(&sq_draw_shell::ShellDefaults::default(), sq_os::Platform::Mac);
    e.frame = CGRect::new(0.0, 0.0, window.0, window.1);
    setup(&mut e);
    let card_origin = CGPoint::new(((window.0 - 900.0) / 2.0).round().max(24.0).min(window.0), ((window.1 - 640.0) / 2.0).floor().max(24.0));
    let at = crop.unwrap_or(CGRect::new(0.0, 0.0, 900.0, 640.0));
    cx.c.save_gstate();
    cx.c.translate_by(-(card_origin.x + at.x), -(card_origin.y + at.y));
    e.draw(cx.c, cx.t, &mut UiCx::new());
    cx.c.restore_gstate();
}

fn se_select_undo(e: &mut sq_draw_shell::ShellShortcutsEditor) {
    e.set_query("Undo");
    e.select(Some(0));
}

fn se_conflict(cx: &mut Cx) {
    use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
    let map = sq_uikit::keymap_store::KeymapStore::load(&sq_draw_shell::ShellDefaults::default()).map();
    let b = KeyBinding::new(Key::Char('z'), KeyModifiers::COMMAND | KeyModifiers::SHIFT);
    let c = sq_uikit::keymap_store::Keymap::conflicts(&sq_uikit::editor_command::EditorCommand::Undo, &b, sq_uikit::editor_command::CommandScope::Global, &map);
    let lines: Vec<String> = c.iter().map(|c| c.message(&b, sq_os::Platform::Mac)).collect();
    let mut d = ShellDialog::new("Replace the existing shortcut?", &(lines.join("\n") + "\n\nThe other command loses this key."));
    d.add_button("Replace", SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    dialog_cx(cx, d, CGRect::new(0.0, 0.0, 440.0, 220.0));
}

/// The Settings window (sidebar, choice cards, slider and path rows) and the Shortcuts editor.
fn settings_group() -> Vec<Entry> {
    use sq_draw_shell::PreferencesPage as P;
    const D: &[State] = &[State::Default];
    const NAV: &[State] = &[State::Default, State::Hover, State::Focus, State::Selected];
    const HD: &[State] = &[State::Default, State::Hover];
    vec![
        // 01-nav
        Entry { id: "settings-nav-item", size: (212.0, 40.0), states: NAV, draw: |cx| {
            let (page, hover) = if cx.state == State::Selected { (P::General, None) } else { (P::General, (cx.state == State::Hover).then_some((100.0, 98.0))) };
            let o = Se { page, hover, sidebar_focus: cx.state == State::Focus, ..Se::default() };
            // Selected and Focus show the General row (the open page; the focus line only goes on it); the others show the Playback row beneath it.
            let y = if matches!(cx.state, State::Selected | State::Focus) { 47.0 } else { 82.0 };
            se_draw(cx, &o, CGRect::new(0.0, y, 212.0, 40.0));
        } },
        Entry { id: "settings-nav-counts", size: (212.0, 330.0), states: D, draw: |cx| se_draw(cx, &Se { counts: true, ..Se::default() }, CGRect::new(0.0, 50.0, 212.0, 330.0)) },
        Entry { id: "settings-nav-search", size: (212.0, 60.0), states: D, draw: |cx| se_draw(cx, &Se::default(), CGRect::new(0.0, 0.0, 212.0, 60.0)) },
        Entry { id: "settings-window-general", size: (900.0, 640.0), states: D, draw: |cx| se_page(cx, P::General) },
        Entry { id: "settings-window-playback", size: (900.0, 640.0), states: D, draw: |cx| se_page(cx, P::Playback) },
        Entry { id: "settings-window-editing", size: (900.0, 640.0), states: D, draw: |cx| se_page(cx, P::Editing) },
        Entry { id: "settings-window-audio", size: (900.0, 640.0), states: D, draw: |cx| se_page(cx, P::Audio) },
        Entry { id: "settings-window-media", size: (900.0, 640.0), states: D, draw: |cx| se_page(cx, P::Media) },
        Entry { id: "settings-window-advanced", size: (900.0, 640.0), states: D, draw: |cx| se_page(cx, P::Advanced) },
        Entry { id: "settings-window-shortcuts", size: (900.0, 640.0), states: D, draw: |cx| se_keys(cx, (1000.0, 760.0), None, &|_| {}) },
        // 02-choices
        Entry { id: "settings-choice", size: (620.0, 180.0), states: HD, draw: |cx| {
            let hover = (cx.state == State::Hover).then_some((553.0, 234.0));
            se_draw(cx, &Se { hover, ..Se::default() }, CGRect::new(250.0, 138.0, 620.0, 180.0));
        } },
        Entry { id: "settings-choice-light", size: (620.0, 180.0), states: D, draw: |cx| {
            se_draw(cx, &Se { extra: Some(|_, x| x.appearance = sq_uikit::appearance_palette::AppearanceSettings::new(sq_uikit::appearance_palette::AppearanceMode::Light, 0, 50)), ..Se::default() }, CGRect::new(250.0, 138.0, 620.0, 180.0));
        } },
        // 03-fields
        Entry { id: "settings-slider-row", size: (620.0, 48.0), states: HD, draw: |cx| {
            let hover = (cx.state == State::Hover).then_some((700.0, 338.0));
            se_draw(cx, &Se { hover, ..Se::default() }, CGRect::new(250.0, 312.0, 620.0, 48.0));
        } },
        Entry { id: "settings-field-path", size: (620.0, 100.0), states: HD, draw: |cx| {
            let hover = (cx.state == State::Hover).then_some((715.0, 426.0));
            se_draw(cx, &Se { page: P::Media, hover, ..Se::default() }, CGRect::new(250.0, 396.0, 620.0, 100.0));
        } },
        Entry { id: "settings-stress-path", size: (620.0, 100.0), states: D, draw: |cx| {
            let o = Se { page: P::Media, extra: Some(|s, _| s.cache_folder = Some(PathBuf::from("/home/alex/Filme/Familienarchiv/Urlaube/2026/Nordkap/Rohmaterial/Kamera A/Zwischenspeicher f\u{FC}r Proxys"))), ..Se::default() };
            se_draw(cx, &o, CGRect::new(250.0, 396.0, 620.0, 100.0));
        } },
        // 04-keys
        Entry { id: "settings-key", size: (340.0, 90.0), states: &[State::Default, State::Selected, State::Focus], draw: |cx| {
            let sel = cx.state;
            se_keys(cx, (1000.0, 760.0), Some(CGRect::new(270.0, 232.0, 340.0, 90.0)), &move |e| match sel {
                State::Selected => e.select_key(Some(sq_uikit::key_binding::Key::Char('z'))),
                State::Focus => e.set_query("Undo"),
                _ => {}
            });
        } },
        Entry { id: "settings-key-modifier", size: (340.0, 48.0), states: &[State::Default, State::Selected], draw: |cx| {
            let on = cx.state == State::Selected;
            se_keys(cx, (1000.0, 760.0), Some(CGRect::new(270.0, 324.0, 340.0, 48.0)), &move |e| if on { e.toggle_modifier(sq_uikit::key_binding::KeyModifiers::COMMAND) });
        } },
        Entry { id: "settings-keyboard", size: (900.0, 640.0), states: D, draw: |cx| se_keys(cx, (1000.0, 760.0), None, &|e| e.select_key(Some(sq_uikit::key_binding::Key::Char('z')))) },
        Entry { id: "settings-keys-recording", size: (900.0, 640.0), states: D, draw: |cx| se_keys(cx, (1000.0, 760.0), None, &|e| { se_select_undo(e); e.begin_capture(); }) },
        Entry { id: "settings-keys-conflict", size: (440.0, 220.0), states: D, draw: se_conflict },
        // Stress
        Entry { id: "settings-stress-small", size: (640.0, 400.0), states: D, draw: |cx| se_draw(cx, &Se { window: (640.0, 400.0), ..Se::default() }, CGRect::new(-24.0, -24.0, 640.0, 400.0)) },
        Entry { id: "settings-stress-nomatch", size: (900.0, 640.0), states: D, draw: |cx| se_draw(cx, &Se { search: "Zeitleistenbildwiederholfrequenz", ..Se::default() }, SE_FULL) },
        Entry { id: "settings-stress-search", size: (900.0, 640.0), states: D, draw: |cx| se_draw(cx, &Se { search: "autosave", ..Se::default() }, SE_FULL) },
        Entry { id: "settings-stress-keys-nomatch", size: (900.0, 640.0), states: D, draw: |cx| se_keys(cx, (1000.0, 760.0), None, &|e| e.set_query("zzzxq")) },
        Entry { id: "settings-stress-keys-small", size: (640.0, 400.0), states: D, draw: |cx| se_keys(cx, (640.0, 400.0), Some(CGRect::new(-0.0, 0.0, 640.0, 400.0)), &|_| {}) },
    ]
}

// ---- 11-Dialogs: dialog parts and the export queue -------------------------------------------------------------------

/// What the pointer or keyboard does to a dialog before it is drawn.
#[derive(Clone, Copy)]
enum Dg {
    Rest,
    Hover(usize),
    Press(usize),
    Tab,
}

fn dg_for(state: State, button: usize) -> Dg {
    match state {
        State::Hover => Dg::Hover(button),
        State::Pressed => Dg::Press(button),
        State::Focus => Dg::Tab,
        _ => Dg::Rest,
    }
}

/// A real shell host: its sample dialogs (`present_sample_dialog`) are the app's own dialogs with the kit texts.
fn dg_host() -> sq_draw_shell::ShellHost {
    sq_draw_shell::ShellHost::new(
        CommandMap::premiere_default(),
        sq_editor_session::RecentProjects::new(Vec::new()),
        std::sync::Arc::new(sq_runtime::FakeClock::new()),
        Box::new(|| sq_core_time::Timestamp::from_unix_seconds(0.0)),
    )
}

/// Lays the dialog out in `window`, applies `act`, and draws the `crop(card)` part of the window.
fn dg_show(cx: &mut Cx, d: &mut ShellDialog, window: CGRect, act: Dg, crop: &dyn Fn(CGRect) -> CGRect) {
    use sq_draw::{InputKey, InputModifiers as M};
    with_measure(|m| d.layout(window, m));
    let mut ui = UiCx::new();
    let card = d.card();
    // The button frames are private: find button `i` by moving the pointer over the footer until it is the hovered one.
    let find = |d: &mut ShellDialog, i: usize, ui: &mut UiCx| -> Option<(f32, f32)> {
        let mut y = card.max_y() - 6.0;
        while y > card.max_y() - 80.0 {
            let mut x = card.min_x() + 2.0;
            while x < card.max_x() {
                with_measure(|m| d.handle(&InputEvent::MouseMoved { x: x as f32, y: y as f32 }, 1.0, m, ui));
                if d.hovered() == Some(i) {
                    return Some((x as f32, y as f32));
                }
                x += 3.0;
            }
            y -= 4.0;
        }
        None
    };
    match act {
        Dg::Rest => {}
        Dg::Hover(i) => {
            find(d, i, &mut ui);
        }
        Dg::Press(i) => {
            if let Some((x, y)) = find(d, i, &mut ui) {
                with_measure(|m| d.handle(&InputEvent::MouseDown { x, y, modifiers: M::NONE }, 1.0, m, &mut ui));
            }
        }
        Dg::Tab => with_measure(|m| d.handle(&InputEvent::KeyDown { key: InputKey::Character('\t'), modifiers: M::NONE }, 1.0, m, &mut ui)),
    }
    let r = crop(card);
    cx.c.save_gstate();
    cx.c.translate_by(-r.x, -r.y);
    d.draw(cx.c, cx.t, window, &mut ui);
    cx.c.restore_gstate();
}

fn dg_whole(cx: &mut Cx, d: &mut ShellDialog, size: (f64, f64), act: Dg) {
    dg_show(cx, d, CGRect::new(0.0, 0.0, size.0, size.1), act, &|_| CGRect::new(0.0, 0.0, size.0, size.1));
}

fn dg_sample(cx: &mut Cx, name: &str, size: (f64, f64), act: Dg, crop: &dyn Fn(CGRect) -> CGRect) {
    let mut host = dg_host();
    assert!(host.present_sample_dialog(name), "sample dialog {name}");
    let d = host.dialog_mut().expect("the sample dialog is up");
    dg_show(cx, d, CGRect::new(0.0, 0.0, size.0, size.1), act, crop);
}

fn dg_save() -> ShellDialog {
    let mut d = ShellDialog::new("Save changes to \u{201c}T2\u{201d}?", "Your changes will be lost if you do not save them.");
    d.asks_to_save = true;
    d.add_button("Don't Save", SQDialogRole::DontSave, true);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.add_button("Save", SQDialogRole::Default, false);
    d
}

fn dg_delete(title: &str, note: &str, buttons: (&str, &str)) -> ShellDialog {
    let mut d = ShellDialog::new(title, note);
    d.add_button(buttons.0, SQDialogRole::Destructive, false);
    d.add_button(buttons.1, SQDialogRole::Cancel, false);
    d
}

/// An alert whose kind picks the icon slot (`ShellDialog::slot_icon`: an explicit tone, else a red or Cancel button asks
/// a warning, else the app icon), cropped to the slot. `kind` sets the tone and buttons of the dialog.
// shortcut: the "ok" slot (`SlotIcon::Ok`) has no public setter, only the update check sets it; its shot shows the app
// icon until the dialog gets a public result kind.
fn dg_slot(cx: &mut Cx, title: &str, kind: fn(&mut ShellDialog)) {
    let mut d = ShellDialog::new(title, "Sequence Studio could not finish the last step.");
    d.add_button("OK", SQDialogRole::Default, false);
    kind(&mut d);
    dg_show(cx, &mut d, CGRect::new(0.0, 0.0, 480.0, 200.0), Dg::Rest, &|c| CGRect::new(c.x + 8.0, c.y + 8.0, 64.0, 64.0));
}

fn dg_report_rows(n: usize, long: bool) -> Vec<sq_draw_shell::ReportRow> {
    use sq_draw_shell::{ReportRow, ReportTone};
    let names = ["Cut A.mov", "Interview B-Roll.mov", "Nordkap Rohmaterial Kamera A Zwischenspeicher f\u{FC}r Proxys 2026.mov"];
    (0..n)
        .map(|i| ReportRow {
            tone: [ReportTone::Green, ReportTone::Orange, ReportTone::Red][i % 3],
            head: if long { names[2].to_string() } else { names[i % 2].to_string() },
            detail: "Found in /Volumes/Footage".to_string(),
            item: None,
            action: None,
        })
        .collect()
}

fn dg_report(cx: &mut Cx, rows: Vec<sq_draw_shell::ReportRow>, size: (f64, f64), crop: &dyn Fn(CGRect) -> CGRect) {
    let mut d = ShellDialog::new("Import report", "What came over from the project.");
    d.content = Some(Box::new(sq_draw_shell::ShellImportReportContent::new(rows)));
    d.add_button("Done", SQDialogRole::Default, false);
    dg_show(cx, &mut d, CGRect::new(0.0, 0.0, size.0, size.1), Dg::Rest, crop);
}

use sq_draw_shell::{BackgroundJob, ExportQueuePopover, QueueJob};
use sq_export::core::queue::ExportJobState as JobState;

fn qj(n: u128, name: &str, state: JobState, progress: f64) -> QueueJob {
    QueueJob { id: tid(n), name: name.to_string(), state, progress }
}

fn qbg(title: &str, progress: Option<f64>) -> BackgroundJob {
    BackgroundJob { id: title.to_string(), title: title.to_string(), progress }
}

const Q_HEAD: f64 = ExportQueuePopover::HEADER_HEIGHT;

/// Draws the popover over `window` (anchored at its bottom right corner, like the status bar ring); `hover` is a point
/// relative to the popover frame; `crop(frame)` is the part of the window that becomes the shot.
fn qp(cx: &mut Cx, jobs: &[QueueJob], bg: Vec<BackgroundJob>, window: (f64, f64), hover: Option<(f64, f64)>, crop: &dyn Fn(CGRect) -> CGRect) {
    use sq_draw::InputModifiers as M;
    let win = CGRect::new(0.0, 0.0, window.0, window.1);
    let mut p = ExportQueuePopover::new(CGPoint::new(window.0 - 30.0, window.1 - 10.0));
    p.update(jobs, Some(bg));
    p.layout(win);
    let f = p.frame();
    if let Some((x, y)) = hover {
        p.handle(&InputEvent::MouseMoved { x: (f.x + x) as f32, y: (f.y + y) as f32 }, 1.0, &mut UiCx::new(), 0.0);
        let _ = M::NONE;
    }
    let r = crop(f);
    cx.c.save_gstate();
    cx.c.translate_by(-r.x, -r.y);
    p.draw(cx.c, cx.t, 0.0);
    cx.c.restore_gstate();
}

/// One row: the list part of a popover with only this job (a section label on top where the popover draws one).
fn qrow(cx: &mut Cx, job: QueueJob, bg: Vec<BackgroundJob>, section: bool, hover: bool) {
    let rows = if section { 25.0 } else { 0.0 } + match (&job.state, bg.is_empty()) {
        (JobState::Running, true) => 58.0,
        _ => 46.0,
    };
    let jobs = if job.name.is_empty() { Vec::new() } else { vec![job] };
    let at = (100.0, Q_HEAD + if section { 25.0 } else { 0.0 } + 23.0);
    qp(cx, &jobs, bg, (500.0, 400.0), hover.then_some(at), &|f| CGRect::new(f.x, f.y + Q_HEAD, 340.0, rows));
}

fn q_whole(cx: &mut Cx, jobs: &[QueueJob], bg: Vec<BackgroundJob>, window: (f64, f64), size: (f64, f64)) {
    qp(cx, jobs, bg, window, None, &|f| CGRect::new(f.x - 12.0, f.y - 12.0, size.0, size.1));
}

fn q_mixed() -> Vec<QueueJob> {
    vec![
        qj(1, "Rough cut.mp4", JobState::Running, 0.42),
        qj(2, "Rough cut 9x16.mp4", JobState::Waiting, 0.0),
        qj(3, "Trailer.mov", JobState::Waiting, 0.0),
        qj(4, "Cut A.mp4", JobState::Done("/Volumes/Footage/Cut A.mp4".into()), 1.0),
        qj(5, "Cut B.mp4", JobState::Failed("disk full".into()), 0.3),
        qj(6, "Cut C.mp4", JobState::Cancelled, 0.1),
    ]
}

fn q_fifty() -> Vec<QueueJob> {
    (0..50u128)
        .map(|i| {
            let name = format!("Familienurlaub Nordkap Rohschnitt Kamera A final v{} mit Untertiteln.mp4", i + 1);
            match i {
                0 => qj(100 + i, &name, JobState::Running, 0.07),
                1..=24 => qj(100 + i, &name, JobState::Waiting, 0.0),
                25..=44 => qj(100 + i, &name, JobState::Done("/Volumes/Backup/Exports/x.mp4".into()), 1.0),
                _ => qj(100 + i, &name, JobState::Failed("disk full".into()), 0.5),
            }
        })
        .collect()
}

const LONG_ERROR: &str = "The disk is full: 4.2 GB needed, 310 MB free on \u{201c}Footage Backup\u{201d} while writing /Volumes/Footage Backup/Exports/Familienurlaub 2026/Rohschnitt Kamera A final v12.mp4";

/// Dialog parts and the export queue (spec 11-Dialogs).
fn dialogs() -> Vec<Entry> {
    const D: &[State] = &[State::Default];
    const HD: &[State] = &[State::Default, State::Hover];
    const BTN: &[State] = &[State::Default, State::Hover, State::Pressed, State::Focus];
    vec![
        // 01-parts: icon slots (the title picks the slot)
        Entry { id: "dialog-icon-slot-warn", size: (64.0, 64.0), states: D, draw: |cx| dg_slot(cx, "Replace the file?", |d| d.add_button("Cancel", SQDialogRole::Cancel, false)) },
        Entry { id: "dialog-icon-slot-err", size: (64.0, 64.0), states: D, draw: |cx| dg_slot(cx, "Export failed", |d| d.header_icon = Some(sq_draw_shell::Tone::Error)) },
        Entry { id: "dialog-icon-slot-ok", size: (64.0, 64.0), states: D, draw: |cx| dg_slot(cx, "Export finished", |_| {}) },
        Entry { id: "dialog-icon-slot-app", size: (64.0, 64.0), states: D, draw: |cx| dg_slot(cx, "Sequence Studio", |_| {}) },
        // 01-parts: list row, key chip, welcome tile
        Entry { id: "dialog-list-row", size: (480.0, 130.0), states: D, draw: |cx| dg_report(cx, dg_report_rows(3, false), (520.0, 330.0), &|c| CGRect::new(c.x, c.y + 70.0, 480.0, 130.0)) },
        Entry { id: "dialog-key-chip", size: (480.0, 102.0), states: D, draw: |cx| dg_sample(cx, "welcome", (520.0, 560.0), Dg::Rest, &|c| CGRect::new(c.x, c.y + 100.0, 480.0, 102.0)) },
        Entry { id: "dialog-welcome-tile", size: (200.0, 150.0), states: D, draw: |cx| dg_sample(cx, "welcome", (520.0, 560.0), Dg::Rest, &|c| CGRect::new(c.x + 16.0, c.y + 100.0, 200.0, 150.0)) },
        // Whole dialogs
        Entry { id: "dialog-welcome", size: (520.0, 560.0), states: D, draw: |cx| dg_sample(cx, "welcome", (520.0, 560.0), Dg::Rest, &|_| CGRect::new(0.0, 0.0, 520.0, 560.0)) },
        Entry { id: "dialog-recovery", size: (520.0, 260.0), states: D, draw: |cx| dg_sample(cx, "recovery", (520.0, 260.0), Dg::Rest, &|_| CGRect::new(0.0, 0.0, 520.0, 260.0)) },
        Entry { id: "dialog-relink", size: (620.0, 440.0), states: D, draw: |cx| dg_sample(cx, "relink", (620.0, 440.0), Dg::Rest, &|_| CGRect::new(0.0, 0.0, 620.0, 440.0)) },
        Entry { id: "dialog-pack-clash", size: (520.0, 280.0), states: D, draw: |cx| dg_sample(cx, "library-import", (520.0, 280.0), Dg::Rest, &|_| CGRect::new(0.0, 0.0, 520.0, 280.0)) },
        Entry { id: "dialog-import-report", size: (520.0, 330.0), states: D, draw: |cx| dg_report(cx, dg_report_rows(3, false), (520.0, 330.0), &|_| CGRect::new(0.0, 0.0, 520.0, 330.0)) },
        Entry { id: "dialog-about", size: (520.0, 460.0), states: D, draw: |cx| dg_sample(cx, "about", (520.0, 460.0), Dg::Rest, &|_| CGRect::new(0.0, 0.0, 520.0, 460.0)) },
        // Buttons of an alert and of a destructive alert
        Entry { id: "dialog-alert", size: (480.0, 240.0), states: BTN, draw: |cx| { let mut d = dg_save(); dg_whole(cx, &mut d, (480.0, 240.0), dg_for(cx.state, 1)) } },
        Entry { id: "dialog-alert-default", size: (480.0, 240.0), states: &[State::Hover, State::Pressed], draw: |cx| { let mut d = dg_save(); dg_whole(cx, &mut d, (480.0, 240.0), dg_for(cx.state, 2)) } },
        Entry { id: "dialog-destructive", size: (480.0, 220.0), states: BTN, draw: |cx| {
            let mut d = dg_delete("Delete 3 clips?", "They leave the timeline. You can bring them back with Undo.", ("Delete Clips", "Cancel"));
            dg_whole(cx, &mut d, (480.0, 220.0), dg_for(cx.state, 0));
        } },
        // 02-queue rows
        Entry { id: "queue-row-running", size: (340.0, 83.0), states: HD, draw: |cx| qrow(cx, qj(1, "Rough cut.mp4", JobState::Running, 0.42), vec![], true, cx.state == State::Hover) },
        Entry { id: "queue-row-waiting", size: (340.0, 71.0), states: HD, draw: |cx| qrow(cx, qj(1, "Rough cut 9x16.mp4", JobState::Waiting, 0.0), vec![], true, cx.state == State::Hover) },
        Entry { id: "queue-row-cancelling", size: (340.0, 71.0), states: D, draw: |cx| qrow(cx, qj(1, "Rough cut.mp4", JobState::Cancelling, 0.5), vec![], true, false) },
        Entry { id: "queue-row-done", size: (340.0, 46.0), states: HD, draw: |cx| qrow(cx, qj(1, "Cut A.mp4", JobState::Done("/Volumes/Footage/Cut A.mp4".into()), 1.0), vec![], false, cx.state == State::Hover) },
        Entry { id: "queue-row-failed", size: (340.0, 46.0), states: D, draw: |cx| qrow(cx, qj(1, "Cut A.mp4", JobState::Failed("disk full".into()), 0.3), vec![], false, false) },
        Entry { id: "queue-row-canceled", size: (340.0, 46.0), states: D, draw: |cx| qrow(cx, qj(1, "Cut A.mp4", JobState::Cancelled, 0.3), vec![], false, false) },
        Entry { id: "queue-row-stack", size: (340.0, 83.0), states: D, draw: |cx| qrow(cx, qj(0, "", JobState::Waiting, 0.0), vec![qbg("Analyzing scenes", Some(0.35))], true, false) },
        Entry { id: "queue-row-subtitles", size: (340.0, 71.0), states: D, draw: |cx| qrow(cx, qj(0, "", JobState::Waiting, 0.0), vec![qbg("Transcribing Interview.mov", None)], true, false) },
        // Whole popover
        Entry { id: "queue-popover", size: (364.0, 466.0), states: D, draw: |cx| q_whole(cx, &q_mixed(), vec![qbg("Transcribing Interview.mov", Some(0.6))], (800.0, 600.0), (364.0, 466.0)) },
        Entry { id: "queue-popover-empty", size: (364.0, 144.0), states: D, draw: |cx| q_whole(cx, &[], vec![], (800.0, 600.0), (364.0, 144.0)) },
        // Stress
        Entry { id: "queue-stress-fifty", size: (364.0, 466.0), states: D, draw: |cx| q_whole(cx, &q_fifty(), vec![], (800.0, 700.0), (364.0, 466.0)) },
        Entry { id: "queue-stress-error", size: (364.0, 152.0), states: D, draw: |cx| q_whole(cx, &[qj(1, "Rough cut.mp4", JobState::Failed(LONG_ERROR.into()), 0.3)], vec![], (800.0, 600.0), (364.0, 152.0)) },
        Entry { id: "queue-stress-small", size: (640.0, 400.0), states: D, draw: |cx| qp(cx, &q_fifty(), vec![], (640.0, 400.0), None, &|_| CGRect::new(0.0, 0.0, 640.0, 400.0)) },
        Entry { id: "dialog-stress-german", size: (520.0, 320.0), states: D, draw: |cx| {
            let mut d = ShellDialog::new(
                "M\u{F6}chten Sie die \u{C4}nderungen am Projekt \u{201e}Familienurlaub Nordkap Rohmaterial Kamera A Zwischenspeicher f\u{FC}r Proxys\u{201c} sichern?",
                "Ihre \u{C4}nderungen gehen verloren, wenn Sie sie nicht sichern. Der letzte automatische Stand ist vom 20. November 2026, 21:41 Uhr.",
            );
            d.asks_to_save = true;
            d.add_button("Nicht sichern", SQDialogRole::DontSave, true);
            d.add_button("Abbrechen", SQDialogRole::Cancel, false);
            d.add_button("Sichern", SQDialogRole::Default, false);
            dg_whole(cx, &mut d, (520.0, 320.0), Dg::Rest);
        } },
        Entry { id: "dialog-stress-small", size: (300.0, 200.0), states: D, draw: |cx| { let mut d = dg_save(); dg_whole(cx, &mut d, (300.0, 200.0), Dg::Rest) } },
        Entry { id: "dialog-stress-list", size: (520.0, 400.0), states: D, draw: |cx| dg_report(cx, dg_report_rows(40, true), (520.0, 400.0), &|_| CGRect::new(0.0, 0.0, 520.0, 400.0)) },
    ]
}

// ---- 12-Panels and 13-Menus ---------------------------------------------------------------------------------------------
// The Track tab of the audio inspector (`TrackAudioDraw`) holds the kit's section header (Compressor, with its On switch)
// and the compressor curve; the transition inspector (`TransitionControlsDraw`) holds the ease chips; the graphic's layer
// list (`GraphicsLayerListDraw`) holds the layer rows; the in-window menu bar (`MenuBar`) holds the bar titles.

use sq_editor_session::{EditorSession, SessionDeps};

/// The audio model starts with the compressor bypassed (Off); `on` clicks its switch once.
fn pn_audio(t: &DrawTheme, on: bool) -> sq_inspector_ui::audio_masks::track_audio_draw::TrackAudioDraw {
    use sq_inspector_ui::audio_masks::track_audio_draw::{Control, TrackAudioDraw};
    use sq_inspector_ui::audio_masks::track_audio_inspector_model::TrackAudioInspectorModel;
    let mut b = TrackAudioDraw::new(TrackAudioInspectorModel::new(
        sq_audiofx::presets::PresetLibrary::new(),
        None,
        None,
        Box::new(SequentialIds::default()),
    ));
    b.theme = *t;
    b.width = 320.0;
    if on {
        let f = b.frame(Control::Bypass).expect("compressor switch");
        let (p, mut ui) = (centre(f), UiCx::new());
        b.mouse_down(p, Some(1), &mut ui);
        b.mouse_up(p, &mut ui);
    }
    b
}

fn pn_header(cx: &mut Cx, hover: bool, on: bool) {
    use sq_inspector_ui::audio_masks::track_audio_draw::Control;
    let mut b = pn_audio(cx.t, on);
    let head = b.rows().into_iter().find(|r| r.label == Some("Compressor")).expect("Compressor header");
    if hover {
        let f = b.frame(Control::Bypass).expect("switch");
        b.mouse_moved(Some(centre(f)));
    }
    cx.c.save_gstate();
    cx.c.translate_by(0.0, -head.y);
    b.draw(cx.c, &mut UiCx::new());
    cx.c.restore_gstate();
}

fn pn_curve(cx: &mut Cx, on: bool) {
    use sq_inspector_ui::audio_masks::track_audio_draw::Control;
    let b = pn_audio(cx.t, on);
    let f = b.frame(Control::Curve).expect("compressor curve");
    cx.c.save_gstate();
    cx.c.translate_by(-(f.x - 8.0), -(f.y - 8.0));
    b.draw(cx.c, &mut UiCx::new());
    cx.c.restore_gstate();
}

fn pn_transition(width: f64, pick: Option<usize>) -> sq_inspector_ui::audio_masks::transition_controls_draw::TransitionControlsDraw {
    use sq_core_effects::transition::NewTransition;
    use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind, TransitionAlignment, TransitionKind};
    use sq_core_time::TimeRange;
    use sq_inspector_ui::audio_masks::transition_controls_draw::{Control, TransitionControlsDraw};
    use sq_inspector_ui::audio_masks::transition_controls_model::{Row, TransitionControlsActions};
    use sq_core_effects::transition::TimelineTransitions;
    let f = |n: i64| Time::new(1, 30) * n;
    let mut ids = SequentialIds::default();
    let mut v = Track::new(Id::from_u128(100), TrackKind::Video);
    let clip = |n: u128, at: i64, src: i64| {
        let mut c = Clip::new(Id::from_u128(n), "A", Id::from_u128(900 + n), TrackKind::Video, TimeRange::new(f(at), f(120)), f(src));
        c.media_duration = Some(f(240));
        c
    };
    let (a, b) = (clip(1, 0, 0), clip(2, 60, 120));
    assert!(v.overwrite(a.clone(), &mut ids).is_ok() && v.overwrite(b.clone(), &mut ids).is_ok());
    let mut t = Timeline::new(Id::from_u128(50), "Main", SequenceFormat::new(Time::new(1, 30)), vec![v]);
    let new = NewTransition {
        kind: TransitionKind::SoftWipe,
        track: Id::from_u128(100),
        outgoing: Some(a.id),
        incoming: Some(b.id),
        duration: f(30),
        alignment: TransitionAlignment::Center,
        custom_before: Time::ZERO,
    };
    let id = t.add_transition(&new, &mut ids).expect("transition");
    let project = Project::new(Id::from_u128(1), "P", Vec::new(), vec![t]);
    let mut ses = EditorSession::new(project, SessionDeps::headless(std::env::temp_dir().join("sq-catalogue-session")));
    ses.select_transition(Some(id), false);
    let mut actions = TransitionControlsActions::new();
    actions.selected_transition = Some(id);
    let mut p = TransitionControlsDraw::new(actions);
    p.size = CGSize::new(width, 300.0);
    let shown = p.actions.shown(&ses);
    p.show(shown);
    // The pre-draw needs the atlas: the chips take their label widths from it.
    MEASURE_ATLAS.with(|a| p.draw(&mut Canvas::with_size(width as f32, 300.0, Some(a), SCALE), &mut UiCx::new()));
    if let Some(i) = pick {
        let e = p.frame(&Control::Row(Row::Easing));
        let xs: Vec<f64> = (0..width as i64).map(|x| x as f64).filter(|&x| p.chip_at(x, e) == i && x > 80.0).collect();
        let x = xs[xs.len() / 2];
        let mut ui = UiCx::new();
        p.mouse_down(&mut ses, &mut ui, CGPoint::new(x, e.mid_y()), Some(1), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut ui, CGPoint::new(x, e.mid_y()));
        let shown = p.actions.shown(&ses);
        p.show(shown);
    }
    p
}

fn pn_ease(cx: &mut Cx, width: f64, pick: Option<usize>, h: f64) {
    use sq_inspector_ui::audio_masks::transition_controls_draw::Control;
    use sq_inspector_ui::audio_masks::transition_controls_model::Row;
    let mut p = pn_transition(width, pick);
    p.theme = *cx.t;
    let e = p.frame(&Control::Row(Row::Easing));
    cx.c.save_gstate();
    cx.c.translate_by(0.0, -(e.min_y() - 4.0));
    cx.c.fill(CGRect::new(0.0, e.min_y() - 4.0, width, h), cx.t.panel());
    p.draw(cx.c, &mut UiCx::new());
    cx.c.restore_gstate();
}

fn pn_layers(cx: &mut Cx, hover_row: Option<usize>, rows: usize) {
    use sq_core_model::ShapeKind;
    use sq_inspector_ui::graphics::editor::GraphicsEditor;
    use sq_inspector_ui::graphics::layer_list_draw::GraphicsLayerListDraw;
    let mut s = EditorSession::new(
        sq_core_model::Project::new(
            tid(1),
            "P",
            Vec::new(),
            vec![sq_core_model::Timeline::new(
                tid(2),
                "Main",
                sq_core_model::SequenceFormat::new(Time::new(1, 30)),
                vec![
                    sq_core_model::Track::new(tid(3), sq_core_model::TrackKind::Video),
                    sq_core_model::Track::new(tid(4), sq_core_model::TrackKind::Audio),
                ],
            )],
        ),
        SessionDeps::headless(std::env::temp_dir().join("sq-catalogue-session")),
    );
    let mut ed = GraphicsEditor::new(Box::new(SequentialIds::default()));
    let _ = ed.new_graphics_clip(&mut s);
    for k in [ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line].into_iter().cycle().take(rows) {
        ed.add_shape(&mut s, k);
    }
    let mut d = GraphicsLayerListDraw::default();
    d.theme = *cx.t;
    d.size = CGSize::new(300.0, (28.0 + 24.0 * rows as f64 + 32.0).min(300.0));
    d.reload(&ed, &s);
    if let Some(i) = hover_row {
        let f = d.row_frame(i);
        d.mouse_moved(Some(CGPoint::new(f.x + 60.0, f.mid_y())));
    }
    d.draw(cx.c, &ed, &s, true, &mut UiCx::new());
}

fn panels() -> Vec<Entry> {
    const D: &[State] = &[State::Default];
    const HD: &[State] = &[State::Default, State::Hover];
    vec![
        // 02-section-headers: the Compressor header (title, On note, stone switch)
        Entry { id: "panel-section-header", size: (320.0, 26.0), states: HD, draw: |cx| pn_header(cx, cx.state == State::Hover, true) },
        Entry { id: "panel-section-header-off", size: (320.0, 26.0), states: HD, draw: |cx| pn_header(cx, cx.state == State::Hover, false) },
        // 01-panel-parts
        Entry { id: "panel-graph-compressor", size: (136.0, 96.0), states: D, draw: |cx| pn_curve(cx, true) },
        Entry { id: "panel-graph-compressor-off", size: (136.0, 96.0), states: D, draw: |cx| pn_curve(cx, false) },
        Entry { id: "panel-ease-chip", size: (760.0, 32.0), states: &[State::Default, State::Selected], draw: |cx| pn_ease(cx, 760.0, (cx.state == State::Selected).then_some(2), 32.0) },
        Entry { id: "panel-ease-chip-custom", size: (760.0, 32.0), states: D, draw: |cx| pn_ease(cx, 760.0, Some(4), 32.0) },
        Entry { id: "panel-ease-chip-narrow", size: (420.0, 32.0), states: D, draw: |cx| pn_ease(cx, 420.0, None, 32.0) },
        Entry { id: "panel-layer-row", size: (300.0, 132.0), states: HD, draw: |cx| pn_layers(cx, (cx.state == State::Hover).then_some(2), 3) },
        Entry { id: "panel-layer-row-many", size: (300.0, 300.0), states: D, draw: |cx| pn_layers(cx, None, 12) },
    ]
}

fn mb_bar(cx: &mut Cx, titles: &[&str], max: Option<f64>, act: &dyn Fn(&mut sq_draw_shell::MenuBar, &TextMeasure), open_menu: bool) {
    use sq_draw_shell::{MenuBar, ShellMenu};
    let mut bar = MenuBar::new();
    let width = 330.0;
    with_measure(|m| {
        bar.set_menus(titles.iter().map(|t| ShellMenu::new(t, menu_rows())).collect(), m);
        if let Some(w) = max {
            bar.set_max_width(Some(w), m);
        }
        act(&mut bar, m);
    });
    bar.draw(cx.c, cx.t, width);
    if open_menu {
        bar.draw_menus(cx.c, cx.t);
    }
}

const MB_EN: [&str; 6] = ["File", "Edit", "Clip", "Sequence", "View", "Help"];

fn menus() -> Vec<Entry> {
    const D: &[State] = &[State::Default];
    vec![
        Entry { id: "menu-bar-title", size: (330.0, 40.0), states: &[State::Default, State::Hover, State::Focus], draw: |cx| {
            let st = cx.state;
            mb_bar(cx, &MB_EN, None, &|b, m| match st {
                State::Hover => {
                    let p = centre(b.title_frames()[1]);
                    b.handle(&InputEvent::MouseMoved { x: p.x as f32, y: p.y as f32 }, 1.0, m, &mut None);
                }
                State::Focus => b.alt_tapped(m, &mut None),
                _ => {}
            }, false);
        } },
        Entry { id: "menu-bar-title-open", size: (330.0, 240.0), states: D, draw: |cx| {
            mb_bar(cx, &MB_EN, None, &|b, m| b.open_menu(1, None, false, m, &mut None), true);
        } },
        Entry { id: "menu-bar-title-overflow", size: (330.0, 40.0), states: D, draw: |cx| {
            mb_bar(cx, &["File", "Edit", "Clip", "Sequence", "Markers", "Graphics", "View", "Window", "Help"], Some(250.0), &|_, _| {}, false);
        } },
        Entry { id: "menu-bar-title-german", size: (330.0, 40.0), states: D, draw: |cx| {
            mb_bar(cx, &["Datei", "Bearbeiten", "Clip", "Sequenz", "Markierungen", "Grafiken", "Ansicht", "Fenster", "Hilfe"], Some(330.0), &|_, _| {}, false);
        } },
        Entry { id: "menu-item-disabled-destructive", size: (224.0, 48.0), states: D, draw: |cx| {
            let mut i = row("Delete", "\u{2318}\u{232B}");
            i.is_destructive = true;
            i.is_enabled = false;
            menu(cx, vec![i], None);
        } },
    ]
}

#[test]
#[ignore = "writes the catalogue PNGs to $SQ_CATALOGUE_DIR"]
fn catalogue_shots() {
    let Some(dir) = out_dir() else { return };
    let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let Some(atlas) = GlyphAtlas::inter(&fonts) else { panic!("bundled Inter loads") };
    let mut n = 0;
    for group in [controls(), overlays(), shell(), timeline(), inspector(), lists(), start(), color(), forms(), settings_group(), dialogs(), panels(), menus()] {
        n += render(&dir, &atlas, &group);
    }
    assert!(n >= 2 * 5, "button-raised alone is 5 states x 2 modes, wrote {n}");
    println!("catalogue_shots: {n} files in {}", dir.display());
}

/// Every `SQIcon` in a grid (24 pt, then 16 pt below), in `SQIcon::ALL` order: the contact sheet for checking an icon set.
#[test]
#[ignore = "writes icons-sheet PNGs to $SQ_CATALOGUE_DIR"]
fn icon_contact_sheet() {
    let Some(dir) = out_dir() else { return };
    let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let Some(atlas) = GlyphAtlas::inter(&fonts) else { panic!("bundled Inter loads") };
    const COLS: usize = 20;
    const CELL: f64 = 44.0;
    let rows = sq_uikit::sqicon::SQIcon::ALL.len().div_ceil(COLS);
    let e = Entry {
        id: "icons-sheet",
        size: (COLS as f32 * CELL as f32, rows as f32 * CELL as f32),
        states: &[State::Default],
        draw: |cx| {
            let ink = cx.t.label();
            for (i, icon) in sq_uikit::sqicon::SQIcon::ALL.into_iter().enumerate() {
                let (x, y) = ((i % COLS) as f64 * CELL, (i / COLS) as f64 * CELL);
                cx.c.draw_icon(icon, CGPoint::new(x + 4.0, y + 4.0), 24.0, ink, None);
                cx.c.draw_icon(icon, CGPoint::new(x + 28.0, y + 22.0), 14.0, ink, None);
            }
        },
    };
    assert_eq!(render(&dir, &atlas, &[e]), 2);
}

/// Pip's poses and the cursor glyphs as PNGs in `$SQ_CATALOGUE_DIR/export/`, from the real drawing code (nothing redrawn):
/// `pip-<anim>.png` (still of each animation, 512 px, transparent) and `cursor-<shape>.png` (the drawn glyph at 4x).
#[test]
#[ignore = "writes the Pip and cursor PNGs to $SQ_CATALOGUE_DIR/export"]
fn export_pip_and_cursors() {
    use sq_draw::ui_cx::DrawCursor as K;
    use sq_uikit::sqmascot_model::SQMascotAnim;
    let Some(dir) = out_dir() else { return };
    let dir = dir.join("export");
    std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("create {}: {e}", dir.display()));
    let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let Some(atlas) = GlyphAtlas::inter(&fonts) else { panic!("bundled Inter loads") };
    let side = 512usize;
    for anim in SQMascotAnim::ALL {
        let mut c = Canvas::with_size(side as f32, side as f32, Some(&atlas), 1.0);
        sq_draw_shell::ShellMascot::draw(anim, CGRect::new(0.0, 0.0, side as f64, side as f64), &mut c);
        let pixels = render_transparent(&c.list, side, &Sources { atlas: Some(&atlas), ..Sources::default() });
        assert_eq!(pixels[3], 0, "pip-{} corner is transparent", anim.raw_value());
        write_png(&dir.join(format!("pip-{}.png", anim.raw_value())), side, side, &pixels);
    }
    let shapes: [(&str, K); 15] = [
        ("trim-in", K::TrimIn),
        ("trim-out", K::TrimOut),
        ("ripple-in", K::RippleIn),
        ("ripple-out", K::RippleOut),
        ("rate-in", K::RateIn),
        ("rate-out", K::RateOut),
        ("roll", K::Roll),
        ("slip", K::Slip),
        ("slide", K::Slide),
        ("razor", K::Razor),
        ("track-select", K::TrackSelect),
        ("drag-copy", K::DragCopy),
        ("zoom-in", K::ZoomIn),
        ("overlay-move", K::Move),
        ("overlay-rotate", K::OverlayRotate(45)),
    ];
    let mut n = 0;
    for (name, shape) in shapes.into_iter().chain([("overlay-resize", K::OverlayResize(0))]) {
        let Some(img) = sq_draw::cursor_glyph::render(shape, 4.0) else { panic!("{name} has a drawn glyph") };
        write_png(&dir.join(format!("cursor-{name}.png")), img.side as usize, img.side as usize, &img.rgba);
        n += 1;
    }
    assert_eq!(n, 16);
}

#[test]
fn transparent_export_keeps_alpha_zero_in_the_corner() {
    let side = 32;
    let mut c = Canvas::with_size(side as f32, side as f32, None, 1.0);
    c.fill_rounded(CGRect::new(8.0, 8.0, 16.0, 16.0), 4.0, sq_draw::Color::new(1.0, 0.0, 0.0, 1.0));
    let px = render_transparent(&c.list, side, &Sources::default());
    assert_eq!(px[3], 0, "corner alpha");
    let mid = (16 * side + 16) * 4;
    assert_eq!(&px[mid..mid + 4], &[255, 0, 0, 255], "an opaque red stays red");
}
