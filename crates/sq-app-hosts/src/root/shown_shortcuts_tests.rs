//! "Every shortcut the app shows must work" for the whole app. Every menu row that SHOWS a key is pressed
//! through the real root (focus, key map, enable rule, the panel that sees the key first) and must do what a click on the
//! row does: two identical worlds, one gets the chord, the other the click, and what the user can see must come out the same.
//! A row that shows a key must never be added without a handler: it fails here until the key works or the row is in
//! `ALLOWED` with a reason.

use super::dead_commands_tests::{Scenario, demo_session};
use super::disabled_commands_tests::{clip_ids, first_clip_only, frame, load_source, pick, select_edge};
use super::menu_click_tests::{click, row_center, send};
use super::*;
use crate::test_rig::Rig;
use sq_core_model::{BinItemRef, ClipEdge, TrackKind};
use sq_core_time::{Id, Time};
use sq_draw_shell::ShellKeys;
use sq_os::Platform;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::CommandScope;
use sq_uikit::key_binding::KeyBinding;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind};
use std::collections::BTreeSet;
use std::sync::Arc;

/// Which system the shown keys are for: the Mac (Command and Control are two keys, glyph text) or a PC (one Ctrl, words).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Style {
    Mac,
    Pc,
    /// The system the test runs on, for menus that spell their keys for it only (the panels' context menus).
    Native,
}

impl Style {
    fn platform(self) -> Platform {
        match (self, Platform::current()) {
            (Style::Mac, _) => Platform::Mac,
            (Style::Pc, Platform::Mac) => Platform::Windows,
            (Style::Pc, here) => here,
            (Style::Native, here) => here,
        }
    }
}

/// A root with its session; the folder is removed when it goes.
struct World {
    root: AppRoot,
    rig: Rig,
    dir: std::path::PathBuf,
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl World {
    /// The demo project of `scenario` in the state `prep` builds, the shell speaking `style`, `focus` holding the keyboard.
    fn new(style: Style, fixture: Fixture, focus: PanelID) -> World {
        let Fixture { scenario, prep } = fixture;
        let dir = crate::test_rig::unique_dir("sq-shown-keys");
        std::fs::create_dir_all(&dir).expect("dir");
        let mut root = crate::standard_root_with_source(
            &dir,
            Arc::new(sq_runtime::FakeClock::new()),
            DrawTheme::default(),
            crate::MonitorPicture::default(),
            Box::new(sq_editor_session::StubProgramEngine::new()),
            crate::MonitorPicture::default(),
        )
        .expect("root");
        let mut rig = Rig::new(demo_session(scenario));
        let platform = style.platform();
        let map = CommandMap::sq_default_for(platform);
        {
            let shell = root.shell.shell();
            shell.platform = platform;
            shell.mac_keys = platform == Platform::Mac;
            shell.map = map.clone();
        }
        root.header.set_command_map(map.clone());
        root.tools.set_command_map(map.clone());
        root.timeline.set_command_map(map);
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        let mut w = World { root, rig, dir };
        frame(&mut w.root, &mut w.rig);
        if let Some(prep) = prep {
            prep(&mut w.root, &mut w.rig);
        }
        w.root.dock.set_focused(Some(focus));
        w.root.shell.shell().focus = Some(focus);
        frame(&mut w.root, &mut w.rig);
        // The drawn menu bar builds its menus on the first event it sees.
        send(&mut w.root, &mut w.rig, InputEvent::MouseMoved { x: 700.0, y: 450.0 });
        w
    }

    fn press(&mut self, key: InputKey, modifiers: InputModifiers) -> bool {
        let taken = send(&mut self.root, &mut self.rig, InputEvent::KeyDown { key, modifiers });
        self.settle();
        taken
    }

    /// What the window does after an event before the user sees the next frame: the panels' answers, a second time for
    /// what the first answers queued (a dialog a context menu row asked for).
    fn settle(&mut self) {
        for _ in 0..2 {
            frame(&mut self.root, &mut self.rig);
            self.root.answer(&mut self.rig.cx());
        }
    }

    /// The status lines so far (feedback, never compared).
    fn statuses(&self) -> Vec<String> {
        self.rig
            .events
            .iter()
            .filter_map(|e| if let AppEvent::Status(s) = e { Some(s.clone()) } else { None })
            .collect()
    }

    /// Everything the user can see change, one named field each.
    fn snapshot(&mut self) -> Vec<(&'static str, String)> {
        let (root, rig) = (&mut self.root, &mut self.rig);
        let fields = vec![
            ("project", serde_json::to_string(rig.session.project()).unwrap_or_default()),
            ("selection", format!("{:?}", rig.session.selection())),
            ("caption selection", format!("{:?}", rig.session.caption_selection())),
            ("playhead", format!("{:?}", rig.session.playhead())),
            ("undo/redo names", format!("{:?}", (rig.session.undo_name(), rig.session.redo_name()))),
            ("dialog", format!("{}", root.shell.shell().dialog().is_some())),
            // The status line is feedback (a tool key shows none, its menu row does), not an effect.
            (
                "events",
                format!("{:?}", rig.events.iter().filter(|e| !matches!(e, AppEvent::Status(_))).collect::<Vec<_>>()),
            ),
            ("controls selection", format!("{:?}", root.inspector.controls().model.selection())),
            ("edge selection", format!("{:?}", root.timeline.inner().panel.edge_selection())),
            ("tool", format!("{:?}", root.timeline.inner().panel.tool_state().tool)),
            ("trim mode", format!("{}", root.shell.shell().trim.is_active())),
            ("safe margins", format!("{}", root.monitor.panel.model.safe_margins())),
            ("overlays hidden", format!("{}", root.monitor.panel.model.overlays_hidden())),
            ("focused panel", format!("{:?}", root.dock.focused())),
            ("deferred", format!("{}", root.shell.take_deferred().len())),
            ("last error", format!("{:?}", rig.session.last_error())),
        ];
        fields.into_iter().map(|(name, text)| (name, scrub_temp_paths(&text))).collect()
    }
}

/// The fields in which two snapshots differ, with both values (the project only says it changed).
fn differences(a: &[(&'static str, String)], b: &[(&'static str, String)]) -> String {
    let short = |name: &str, v: &str| {
        if name == "project" { "changed".to_string() } else { v.chars().take(110).collect::<String>() }
    };
    a.iter()
        .zip(b)
        .filter(|(x, y)| x.1 != y.1)
        .map(|(x, y)| format!("{}: key {:?} / click {:?}", x.0, short(x.0, &x.1), short(y.0, &y.1)))
        .collect::<Vec<_>>()
        .join("; ")
}

/// What differs between two worlds that ran the same step without meaning anything: the unique folder names
/// (`sq-xyz-<pid>-<nanos>-<n>`) and the random ids the panels draw for new keys (the demo project's own ids count up from 1).
fn scrub_temp_paths(s: &str) -> String {
    scrub_random_ids(&scrub_folders(s))
}

fn scrub_folders(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(at) = rest.find("sq-") {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let len = tail.find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_')).unwrap_or(tail.len());
        let word = &tail[..len];
        out.push_str(if word.chars().filter(char::is_ascii_digit).count() > 12 { "<dir>" } else { word });
        rest = &tail[len..];
    }
    out.push_str(rest);
    out
}

/// Ids that do not start with the counter's zeros are random.
fn scrub_random_ids(s: &str) -> String {
    const COUNTED: &str = "00000000-0000-0000-0000-";
    let b = s.as_bytes();
    let is_id = |at: usize| {
        b.len() >= at + 36
            && b[at..at + 36]
                .iter()
                .enumerate()
                .all(|(i, c)| if matches!(i, 8 | 13 | 18 | 23) { *c == b'-' } else { c.is_ascii_hexdigit() })
    };
    let mut out = String::with_capacity(s.len());
    let mut at = 0;
    while at < b.len() {
        if is_id(at) && !s[at..].starts_with(COUNTED) {
            out.push_str("<id>");
            at += 36;
        } else {
            let len = s[at..].chars().next().map_or(1, char::len_utf8);
            out.push_str(&s[at..at + len]);
            at += len;
        }
    }
    out
}

/// A row that shows a key.
#[derive(Clone, Debug)]
struct Row {
    menu: String,
    /// The titles of the menu's submenus down to the row, then its own: what the failure messages name.
    path: Vec<String>,
    /// Where the row sits: the title in the bar, then one index per open level (titles repeat inside one menu).
    menu_index: usize,
    indices: Vec<usize>,
    shortcut: String,
    enabled: bool,
}

impl Row {
    /// The row's name without the step Undo and Redo name ("Undo Cut" is "Undo").
    fn id(&self) -> String {
        let plain = |t: &String| match t.split_once(' ') {
            Some((verb @ ("Undo" | "Redo"), _)) => verb.to_string(),
            _ => t.clone(),
        };
        format!("{} > {}", self.menu, self.path.iter().map(plain).collect::<Vec<_>>().join(" > "))
    }
}

fn walk(menu: (usize, &str), items: &[SQMenuItem], at: &mut Vec<(usize, String)>, out: &mut Vec<Row>) {
    for (index, i) in items.iter().enumerate().filter(|(_, i)| i.kind == SQMenuItemKind::Action) {
        at.push((index, i.title.clone()));
        match &i.submenu {
            Some(sub) => walk(menu, sub, at, out),
            None if !i.shortcut.is_empty() => out.push(Row {
                menu: menu.1.to_string(),
                path: at.iter().map(|(_, t)| t.clone()).collect(),
                menu_index: menu.0,
                indices: at.iter().map(|(i, _)| *i).collect(),
                shortcut: i.shortcut.clone(),
                enabled: i.is_enabled,
            }),
            None => {}
        }
        at.pop();
    }
}

/// The rows of the main menu that show a key now.
fn main_menu_rows(w: &mut World) -> Vec<Row> {
    let mut out = Vec::new();
    for (n, m) in w.root.shell.shell().menu_bar.menus().to_vec().iter().enumerate() {
        walk((n, &m.title), &m.items, &mut Vec::new(), &mut out);
    }
    out
}

/// Opens the menu of `row` in the bar and clicks down to the row, as a user would.
fn click_row(w: &mut World, row: &Row) {
    let title = w.root.shell.shell().menu_bar.title_frames()[row.menu_index];
    click(&mut w.root, &mut w.rig, CGPoint::new(title.mid_x(), title.mid_y()));
    for (level, index) in row.indices.iter().enumerate() {
        let shown = w.root.shell.shell().menu_bar.controller.views()[level].items[*index].title.clone();
        assert_eq!(shown, row.path[level], "{}: the open menu lists another row at {index}", row.id());
        let at = row_center(&mut w.root, level, *index);
        click(&mut w.root, &mut w.rig, at);
    }
    w.settle();
}

/// The binding a shown text stands for: the system's own style first, then the other (a host may spell the Mac glyphs).
fn binding_of(text: &str, platform: Platform) -> Option<KeyBinding> {
    KeyBindingText::parse(text, platform)
        .or_else(|| KeyBindingText::parse(text, Platform::Mac))
        .or_else(|| KeyBindingText::parse(text, Platform::Windows))
}

/// What a shown key does instead of acting like its row, and the check that pins it.
#[derive(Clone, Copy, Debug)]
enum Expect {
    /// The row shows or hides a panel while its key moves the keyboard focus to that panel (the frozen Swift menu does the
    /// same, shell_menu_bar.rs `window_menu`): after the key the panel of the row holds the focus.
    FocusesTheRowsPanel,
    /// The key maximizes the panel under the pointer, a click on the menu has the pointer over the menu: with the pointer
    /// on the Program monitor the key maximizes it.
    MaximizesThePanelUnderThePointer,
    /// The focused panel keeps this key for its own use (its grid moves a selection): the key must still be taken.
    TakenByThePanel,
    /// The Mac's system menu bar runs this key equivalent itself (the shared row becomes an NSMenu key equivalent in
    /// sq-platform-mac); the app's key handler never sees the key, so nothing may take it here.
    RunByTheMacSystemMenu,
    /// The command needs the app's export queue, which the test root has none (the same limit as `UNAVAILABLE` in
    /// dead_commands_tests.rs): the shell reports it as not run.
    NeedsTheAppsExportQueue,
}

/// One allowed difference: the rows (by id), where it applies (`None`: in every focus) and why.
struct Allowed {
    ids: &'static [&'static str],
    focus: Option<PanelID>,
    expect: Expect,
    reason: &'static str,
}

/// The main menu rows whose key is not the row's click. Every entry has its reason and its own check; a new row never
/// lands here silently.
const ALLOWED: &[Allowed] = &[
    Allowed {
        ids: &[
            "Window > Project",
            "Window > Program",
            "Window > Timeline",
            "Window > Controls",
            "Window > Audio Meters",
        ],
        focus: None,
        expect: Expect::FocusesTheRowsPanel,
        reason: "the Window rows toggle a panel, their Shift+number key focuses it",
    },
    Allowed {
        ids: &["Window > Maximize Panel Under Pointer"],
        focus: None,
        expect: Expect::MaximizesThePanelUnderThePointer,
        reason: "the key acts on the panel under the pointer, the menu click has the pointer on the menu",
    },
    Allowed {
        ids: &[
            "View > Playback > Step and Keyframes > Step Back 1 Frame",
            "View > Playback > Step and Keyframes > Step Forward 1 Frame",
            "View > Playback > Step and Keyframes > Step Back 10 Frames",
            "View > Playback > Step and Keyframes > Step Forward 10 Frames",
        ],
        focus: Some(PanelID::Library),
        expect: Expect::TakenByThePanel,
        reason: "the Library grid moves its selection with the arrow keys (the Premiere Project panel does too)",
    },
    Allowed {
        ids: &[
            "File > Quit Sequence Studio",
            "File > Hide Sequence Studio",
            "File > Hide Others",
            "File > Project > Save Checkpoint…",
        ],
        focus: None,
        expect: Expect::RunByTheMacSystemMenu,
        reason: "the Mac system menu bar owns these key equivalents (Quit and Hide are the OS's, Save Checkpoint is menu-only text)",
    },
    Allowed {
        ids: &["File > Export…", "File > Quick Export"],
        focus: None,
        expect: Expect::NeedsTheAppsExportQueue,
        reason: "Export runs only with the app's export queue; the test root has none",
    },
];

fn allowed(focus: PanelID, id: &str) -> Option<&'static Allowed> {
    // The ids are the row titles without the key; the shown text follows the system, so compare the title part.
    ALLOWED.iter().find(|a| a.focus.is_none_or(|f| f == focus) && a.ids.contains(&id))
}

/// Rows no fixture enables yet, each with the state it needs. The audit of the Timeline focus must list exactly these:
/// a row that lands here by accident, or one that gets a fixture and stays listed, fails.
const UNCOVERED: &[(&str, &str)] = &[
    (
        "Clip > Audio Options > Loudness and Ducking > Bake Live Duck to Keys",
        "needs live ducking switched on for a Music track; no state helper builds it yet",
    ),
    (
        "Sequence > Storyline > Create Storyline",
        "needs clips connected above the main track of a Fast Cut sequence; no state helper builds it yet",
    ),
    (
        "Sequence > Storyline > Ripple Delete in Storyline",
        "needs a clip inside a storyline of a Fast Cut sequence; no state helper builds it yet",
    ),
];

/// What one audit pass found.
#[derive(Default, Debug)]
struct Report {
    shown: BTreeSet<String>,
    ran: BTreeSet<String>,
    never_enabled: BTreeSet<String>,
    not_in_scope: BTreeSet<String>,
    allowed: BTreeSet<String>,
    failures: Vec<String>,
}

/// A demo project and the state a group of rows needs to be enabled (the states of disabled_commands_tests.rs).
#[derive(Clone, Copy)]
struct Fixture {
    scenario: Scenario,
    prep: Option<Prep>,
}

type Prep = fn(&mut AppRoot, &mut Rig);

fn second_clip(_: &mut AppRoot, rig: &mut Rig) {
    let second = clip_ids(&rig.session)[1];
    pick(&mut rig.session, &[second]);
}

fn copied(_: &mut AppRoot, rig: &mut Rig) {
    assert!(rig.session.copy_selection());
}

fn copied_for_settings(_: &mut AppRoot, rig: &mut Rig) {
    first_clip_only(rig);
    assert!(rig.session.copy_selection());
    let second = clip_ids(&rig.session)[1];
    pick(&mut rig.session, &[second]);
}

fn undone(_: &mut AppRoot, rig: &mut Rig) {
    assert!(rig.session.undo());
}

fn source_for_replace(root: &mut AppRoot, rig: &mut Rig) {
    assert!(root.source.as_mut().expect("source").open(&mut rig.cx(), Id::from_u128(902)));
    first_clip_only(rig);
    root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
}

fn tail_edge(root: &mut AppRoot, rig: &mut Rig) {
    select_edge(root, rig, ClipEdge::Tail);
}

fn head_edge(root: &mut AppRoot, rig: &mut Rig) {
    select_edge(root, rig, ClipEdge::Head);
}

fn grouped(_: &mut AppRoot, rig: &mut Rig) {
    assert!(rig.session.group_selection().is_some());
}

fn bundled(_: &mut AppRoot, rig: &mut Rig) {
    assert!(rig.session.bundle_selection());
}

fn edit_at_playhead(_: &mut AppRoot, rig: &mut Rig) {
    rig.session.select(BTreeSet::new(), BTreeSet::new());
    rig.session.add_edit_at_playhead(false);
}

fn first_clip(_: &mut AppRoot, rig: &mut Rig) {
    first_clip_only(rig);
}

fn angles_clip(_: &mut AppRoot, rig: &mut Rig) {
    let ids = clip_ids(&rig.session);
    assert!(rig.session.create_angles_clip(&ids, None, None, 0, true).is_some(), "angles clip");
}

/// One opacity key on the first clip, selected in Controls (the Ease rows act on selected keys).
fn selected_key(root: &mut AppRoot, rig: &mut Rig) {
    use sq_editor_session::Change;
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    first_clip_only(rig);
    rig.session.seek(Time::seconds(2));
    {
        let model = &mut root.inspector.controls().model;
        model.sync(&rig.session, Change::SELECTION | Change::PROJECT);
        model.focused_property = Some(EffectProperty::Opacity);
    }
    assert!(root.shell.run_command(&mut rig.cx(), sq_uikit::editor_command::EditorCommand::AddKeyframe));
    frame(root, rig);
    root.inspector.pump(&mut rig.cx());
    let model = &mut root.inspector.controls().model;
    let (key, _) = model.keys(&EffectProperty::Opacity).first().copied().expect("a key");
    model.select_key(&EffectProperty::Opacity, key, false);
}

/// A layout that differs from the saved one (the Window menu offers Reset to Saved Layout).
fn changed_layout(root: &mut AppRoot, _: &mut Rig) {
    root.dock.toggle(PanelID::Library);
}

fn speed_point(_: &mut AppRoot, rig: &mut Rig) {
    first_clip_only(rig);
    rig.session.seek(Time::seconds(2));
    assert!(rig.session.add_speed_point_at_playhead());
    assert!(rig.session.unlink_selection());
}

const fn plain(scenario: Scenario) -> Fixture {
    Fixture { scenario, prep: None }
}

const fn with(scenario: Scenario, prep: Prep) -> Fixture {
    Fixture { scenario, prep: Some(prep) }
}

/// The first fixture in which a row is enabled is the one it is audited in.
const FIXTURES: [Fixture; 21] = [
    plain(Scenario::Plain),
    plain(Scenario::InOut),
    plain(Scenario::FastCut),
    with(Scenario::Plain, copied),
    with(Scenario::FastCut, copied),
    with(Scenario::Plain, copied_for_settings),
    with(Scenario::Plain, undone),
    with(Scenario::Plain, load_source_prep),
    with(Scenario::FastCut, load_source_prep),
    with(Scenario::Plain, source_for_replace),
    with(Scenario::Plain, tail_edge),
    with(Scenario::Plain, head_edge),
    with(Scenario::Plain, grouped),
    with(Scenario::Plain, bundled),
    with(Scenario::Plain, edit_at_playhead),
    with(Scenario::Plain, first_clip),
    with(Scenario::Plain, second_clip),
    with(Scenario::Plain, speed_point),
    with(Scenario::Plain, angles_clip),
    with(Scenario::Plain, selected_key),
    with(Scenario::Plain, changed_layout),
];

fn load_source_prep(root: &mut AppRoot, rig: &mut Rig) {
    load_source(root, rig);
}

/// Whether the key a row shows is offered with `focus` holding the keyboard: a binding of one panel's scope applies only
/// there, a global one everywhere. The commands that show this text come from the key map; text no binding owns (the
/// shell's own rows) applies everywhere.
fn offered_in(focus: PanelID, text: &str, map: &CommandMap, platform: Platform) -> bool {
    let owners: Vec<_> = map
        .entries
        .iter()
        .filter(|e| {
            map.shown_binding_for(&e.command, platform) == Some(e.binding)
                && KeyBindingText::text(&e.binding, platform) == text
        })
        .collect();
    owners.is_empty()
        || owners
            .iter()
            .any(|e| e.scope == CommandScope::Global || CommandScope::scope_for(Some(focus)) == Some(e.scope))
}

/// Presses every shown key of the main menu with `focus` holding the keyboard and compares it with the click on the row.
fn audit_main_menu(style: Style, focus: PanelID) -> Report {
    let mut report = Report::default();
    let platform = style.platform();
    let map = CommandMap::sq_default_for(platform);
    let mac = platform == Platform::Mac;
    let mut done: BTreeSet<String> = BTreeSet::new();
    // Debug aid: `SQ_SHOWN_KEYS_ONLY=<text of a row id>` audits only the matching rows.
    let only = std::env::var("SQ_SHOWN_KEYS_ONLY").unwrap_or_default();
    for fixture in FIXTURES {
        let mut probe = World::new(style, fixture, focus);
        for row in main_menu_rows(&mut probe) {
            let id = row.id();
            report.shown.insert(id.clone());
            if !only.is_empty() && !id.contains(&only) {
                continue;
            }
            if done.contains(&id) || !row.enabled {
                continue;
            }
            let Some(binding) = binding_of(&row.shortcut, platform) else {
                report.failures.push(format!("{id}: the shown {:?} names no key", row.shortcut));
                done.insert(id);
                continue;
            };
            let (key, mods) = ShellKeys::press(&binding, mac);
            if !offered_in(focus, &row.shortcut, &map, platform) {
                report.not_in_scope.insert(id);
                continue;
            }
            done.insert(id.clone());
            let mut by_key = World::new(style, fixture, focus);
            let taken = by_key.press(key, mods);
            if let Some(a) = allowed(focus, &id) {
                report.allowed.insert(id.clone());
                if let Some(why) = check_allowed(a.expect, &mut by_key, &row, taken) {
                    report.failures.push(format!("{id} ({}): {why} [allowed: {}]", row.shortcut, a.reason));
                }
                continue;
            }
            let key_state = by_key.snapshot();
            let mut by_click = World::new(style, fixture, focus);
            click_row(&mut by_click, &row);
            let click_state = by_click.snapshot();
            if !taken {
                report.failures.push(format!("{id} ({}): the key {:?} is not taken", row.shortcut, (key, mods)));
            } else if key_state != click_state {
                let diff = differences(&key_state, &click_state);
                report
                    .failures
                    .push(format!("{id} ({}): the key does something else than the row ({diff})", row.shortcut));
            } else {
                report.ran.insert(id);
            }
        }
    }
    for id in &report.shown {
        let seen = report.ran.contains(id) || report.allowed.contains(id) || report.not_in_scope.contains(id);
        if !seen && !done.contains(id) {
            report.never_enabled.insert(id.clone());
        }
    }
    report
}

/// The check of one allowed difference; `Some(why)` when it does not hold.
fn check_allowed(expect: Expect, by_key: &mut World, row: &Row, taken: bool) -> Option<String> {
    match expect {
        Expect::NeedsTheAppsExportQueue | Expect::RunByTheMacSystemMenu => {
            taken.then(|| "the key ran here: drop the allowance".to_string())
        }
        Expect::TakenByThePanel => (!taken).then(|| "nobody took the key".to_string()),
        Expect::FocusesTheRowsPanel => {
            let title = row.path.last().cloned().unwrap_or_default();
            let panel = PanelID::ALL
                .into_iter()
                .find(|p| sq_uikit::editor_command::EditorCommand::localized_panel_title(*p) == title);
            let focused = by_key.root.dock.focused();
            (!taken || focused != panel)
                .then(|| format!("the key left the focus on {focused:?}, the row names {panel:?}"))
        }
        Expect::MaximizesThePanelUnderThePointer => {
            let maximized = by_key.root.dock.maximized();
            (!taken || maximized.is_none()).then(|| format!("the key (taken: {taken}) maximized {maximized:?}"))
        }
    }
}

fn assert_clean(label: &str, focus: PanelID, r: &Report, main_menu: bool) {
    eprintln!(
        "{label} {focus:?}: shown {}, ran same {}, allowed {}, not in this focus {}, never enabled {}, FAILED {}",
        r.shown.len(),
        r.ran.len(),
        r.allowed.len(),
        r.not_in_scope.len(),
        r.never_enabled.len(),
        r.failures.len()
    );
    eprintln!("never enabled: {:?}", r.never_enabled);
    if main_menu && focus == PanelID::Timeline && std::env::var("SQ_SHOWN_KEYS_ONLY").is_err() {
        let expected: BTreeSet<String> =
            UNCOVERED.iter().map(|(id, _)| id.to_string()).filter(|id| r.shown.contains(id)).collect();
        assert_eq!(
            r.never_enabled, expected,
            "rows no fixture enables: give them a state in FIXTURES, or list them in UNCOVERED with the state they need"
        );
    }
    assert!(
        r.failures.is_empty(),
        "{} shown keys do not act like their row:\n{}",
        r.failures.len(),
        r.failures.join("\n")
    );
}

/// One test per system and focus, so the audits run side by side.
macro_rules! main_menu_audit {
    ($($name:ident: $style:expr, $focus:expr;)*) => {
        $(
            #[test]
            fn $name() {
                assert_clean(stringify!($name), $focus, &audit_main_menu($style, $focus), true);
            }
        )*
    };
}

main_menu_audit! {
    every_key_of_the_main_menu_acts_like_its_row_pc_timeline: Style::Pc, PanelID::Timeline;
    every_key_of_the_main_menu_acts_like_its_row_pc_program: Style::Pc, PanelID::ProgramMonitor;
    every_key_of_the_main_menu_acts_like_its_row_pc_project: Style::Pc, PanelID::Project;
    every_key_of_the_main_menu_acts_like_its_row_pc_library: Style::Pc, PanelID::Library;
    every_key_of_the_main_menu_acts_like_its_row_pc_controls: Style::Pc, PanelID::EffectControls;
    every_key_of_the_main_menu_acts_like_its_row_pc_effects: Style::Pc, PanelID::Effects;
    every_key_of_the_main_menu_acts_like_its_row_mac_timeline: Style::Mac, PanelID::Timeline;
    every_key_of_the_main_menu_acts_like_its_row_mac_program: Style::Mac, PanelID::ProgramMonitor;
    every_key_of_the_main_menu_acts_like_its_row_mac_project: Style::Mac, PanelID::Project;
    every_key_of_the_main_menu_acts_like_its_row_mac_library: Style::Mac, PanelID::Library;
    every_key_of_the_main_menu_acts_like_its_row_mac_controls: Style::Mac, PanelID::EffectControls;
    every_key_of_the_main_menu_acts_like_its_row_mac_effects: Style::Mac, PanelID::Effects;
}

// MARK: Context menus

/// A place to right-click, the focus it holds, and the states it is audited in.
struct Place {
    name: &'static str,
    focus: PanelID,
    fixtures: &'static [Fixture],
    /// Where to press, in window pixels (`None`: the layout has no such spot).
    at: fn(&mut World) -> Option<(f32, f32)>,
    /// Rows no fixture enables, each with the state it needs: the audit must list exactly these.
    uncovered: &'static [(&'static str, &'static str)],
}

impl World {
    /// Right-clicks at `at`; true when a menu opened.
    fn open_context(&mut self, at: (f32, f32)) -> bool {
        let (x, y) = at;
        send(&mut self.root, &mut self.rig, InputEvent::MouseMoved { x, y });
        send(&mut self.root, &mut self.rig, InputEvent::MouseDown { x, y, modifiers: InputModifiers::SECONDARY });
        send(&mut self.root, &mut self.rig, InputEvent::MouseUp { x, y });
        frame(&mut self.root, &mut self.rig);
        self.root.menu.is_open()
    }
}

fn context_rows(w: &mut World, place: &str) -> Vec<Row> {
    let mut out = Vec::new();
    walk((0, place), &w.root.menu.root_items(), &mut Vec::new(), &mut out);
    out
}

/// Clicks down the open context menu to `row`.
fn click_context_row(w: &mut World, row: &Row) {
    for (level, index) in row.indices.iter().enumerate() {
        let v = &w.root.menu.views()[level];
        assert_eq!(v.items[*index].title, row.path[level], "{}: the open menu lists another row at {index}", row.id());
        let r = v.row_frames[*index];
        let at = CGPoint::new(v.origin.x + r.mid_x(), v.origin.y + r.mid_y() - v.scroll_offset);
        click(&mut w.root, &mut w.rig, at);
    }
    w.settle();
}

fn video_track(w: &World) -> Option<Id> {
    w.rig.session.active_timeline()?.tracks.iter().find(|t| t.kind == TrackKind::Video).map(|t| t.id)
}

fn on_a_clip(w: &mut World) -> Option<(f32, f32)> {
    let track = video_track(w)?;
    let p = &w.root.timeline.inner().panel;
    Some((p.pixel_x(Time::seconds(15)), p.pixel_y_body_of(track)?))
}

fn on_a_gap(w: &mut World) -> Option<(f32, f32)> {
    let track = video_track(w)?;
    let p = &w.root.timeline.inner().panel;
    Some((p.pixel_x(Time::seconds(25)), p.pixel_y_body_of(track)?))
}

fn on_the_ruler(w: &mut World) -> Option<(f32, f32)> {
    let track = video_track(w)?;
    let p = &w.root.timeline.inner().panel;
    Some((p.pixel_x(Time::seconds(1)), p.pixel_row_of(track)?.0 - 6.0))
}

fn in_the_middle_of(w: &mut World, panel: PanelID) -> Option<(f32, f32)> {
    let r = w.root.dock.content_frame(panel)?;
    Some((r.mid_x() as f32, r.mid_y() as f32))
}

fn on_the_program_picture(w: &mut World) -> Option<(f32, f32)> {
    in_the_middle_of(w, PanelID::ProgramMonitor)
}

fn on_the_project_panel(w: &mut World) -> Option<(f32, f32)> {
    in_the_middle_of(w, PanelID::Project)
}

const PLACES: &[Place] = &[
    Place {
        name: "Timeline clip menu",
        focus: PanelID::Timeline,
        fixtures: &[
            plain(Scenario::Plain),
            with(Scenario::Plain, copied_for_settings),
            with(Scenario::Plain, grouped),
            with(Scenario::Plain, bundled),
        ],
        at: on_a_clip,
        uncovered: &[(
            "Timeline clip menu > Save > Save as Template…",
            "needs a text or graphics clip; the demo project has only footage",
        )],
    },
    Place {
        name: "Timeline empty lane menu",
        focus: PanelID::Timeline,
        fixtures: &[plain(Scenario::Plain), with(Scenario::Plain, copied)],
        at: on_a_gap,
        uncovered: &[],
    },
    Place {
        name: "Timeline ruler menu",
        focus: PanelID::Timeline,
        fixtures: &[plain(Scenario::InOut), with(Scenario::InOut, copied)],
        at: on_the_ruler,
        uncovered: &[],
    },
    Place {
        name: "Program monitor menu",
        focus: PanelID::ProgramMonitor,
        fixtures: &[plain(Scenario::Plain), plain(Scenario::InOut), with(Scenario::Plain, load_source_prep)],
        at: on_the_program_picture,
        uncovered: &[],
    },
    Place {
        name: "Project panel menu",
        focus: PanelID::Project,
        fixtures: &[plain(Scenario::Plain), with(Scenario::Plain, copied)],
        at: on_the_project_panel,
        uncovered: &[],
    },
];

/// Presses every key a context menu shows and compares it with the click on its row.
fn audit_context(place: &Place) -> Report {
    let mut report = Report::default();
    let platform = Style::Native.platform();
    let (map, mac) = (CommandMap::sq_default_for(platform), platform == Platform::Mac);
    let mut done: BTreeSet<String> = BTreeSet::new();
    let only = std::env::var("SQ_SHOWN_KEYS_ONLY").unwrap_or_default();
    for fixture in place.fixtures {
        let mut probe = World::new(Style::Native, *fixture, place.focus);
        let Some(at) = (place.at)(&mut probe) else {
            report.failures.push(format!("{}: the layout has no spot to press", place.name));
            continue;
        };
        if !probe.open_context(at) {
            report.failures.push(format!("{}: the right-click at {at:?} opens no menu", place.name));
            continue;
        }
        let focus = probe.root.shell.shell().focus.unwrap_or(place.focus);
        for row in context_rows(&mut probe, place.name) {
            let id = row.id();
            report.shown.insert(id.clone());
            if (!only.is_empty() && !id.contains(&only)) || done.contains(&id) || !row.enabled {
                continue;
            }
            let Some(binding) = binding_of(&row.shortcut, platform) else {
                report.failures.push(format!("{id}: the shown {:?} names no key", row.shortcut));
                done.insert(id);
                continue;
            };
            let (key, mods) = ShellKeys::press(&binding, mac);
            if !offered_in(focus, &row.shortcut, &map, platform) {
                report.not_in_scope.insert(id);
                continue;
            }
            done.insert(id.clone());
            let mut by_key = World::new(Style::Native, *fixture, place.focus);
            if !by_key.open_context(at) {
                report.failures.push(format!("{id}: the menu does not open again"));
                continue;
            }
            by_key.root.menu.dismiss();
            frame(&mut by_key.root, &mut by_key.rig);
            let taken = by_key.press(key, mods);
            let key_state = by_key.snapshot();
            let mut by_click = World::new(Style::Native, *fixture, place.focus);
            by_click.open_context(at);
            click_context_row(&mut by_click, &row);
            let click_state = by_click.snapshot();
            let (key_lines, click_lines) = (by_key.statuses(), by_click.statuses());
            if !taken {
                report.failures.push(format!("{id} ({}): the key {:?} is not taken", row.shortcut, (key, mods)));
            } else if key_state != click_state {
                let diff = differences(&key_state, &click_state);
                report.failures.push(format!(
                    "{id} ({}): the key does something else than the row ({diff}) [status: key {key_lines:?}, click {click_lines:?}]",
                    row.shortcut
                ));
            } else {
                report.ran.insert(id);
            }
        }
    }
    for id in &report.shown {
        if !report.ran.contains(id) && !report.not_in_scope.contains(id) && !done.contains(id) {
            report.never_enabled.insert(id.clone());
        }
    }
    report
}

macro_rules! context_audit {
    ($($name:ident: $place:expr;)*) => {
        $(
            #[test]
            fn $name() {
                let place = &PLACES[$place];
                let r = audit_context(place);
                assert_clean(place.name, place.focus, &r, false);
                if std::env::var("SQ_SHOWN_KEYS_ONLY").is_err() {
                    let expected: BTreeSet<String> = place.uncovered.iter().map(|(id, _)| id.to_string()).collect();
                    assert_eq!(
                        r.never_enabled, expected,
                        "rows no fixture enables: give them a state in the place's fixtures, or list them in `uncovered`"
                    );
                }
            }
        )*
    };
}

context_audit! {
    every_key_the_timeline_clip_menu_shows_acts_like_its_row: 0;
    every_key_the_timeline_empty_lane_menu_shows_acts_like_its_row: 1;
    every_key_the_timeline_ruler_menu_shows_acts_like_its_row: 2;
    every_key_the_program_monitor_menu_shows_acts_like_its_row: 3;
    every_key_the_project_panel_menu_shows_acts_like_its_row: 4;
}

// MARK: Controls keyframe menu

/// The keys of the selected Opacity property in Controls.
fn opacity_keys(w: &mut World) -> usize {
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    w.root.inspector.controls().model.keys(&EffectProperty::Opacity).len()
}

/// The keyframe menu in Controls shows Cut, Copy, Paste and Delete (effect_keyframe_lanes_draw.rs): each key does what its
/// row does to the selected keyframe, with Controls holding the focus (the section menu has the same check beside its model).
#[test]
fn the_keys_the_keyframe_menu_shows_work_on_the_selected_keyframe() {
    let key = |c: char| (InputKey::Character(c), InputModifiers::COMMAND);
    let start = || World::new(Style::Native, with(Scenario::Plain, selected_key), PanelID::EffectControls);
    for (name, (k, m)) in [("Delete", (InputKey::Backspace, InputModifiers::NONE)), ("Cut", key('x'))] {
        let mut w = start();
        assert_eq!(opacity_keys(&mut w), 1, "{name}: one key to start with");
        assert!(w.press(k, m), "{name} is shown by the keyframe menu but Controls does not take it");
        assert_eq!(opacity_keys(&mut w), 0, "{name} must remove the selected keyframe");
    }
    // Copy, then Paste one second later: a second key.
    let mut w = start();
    let (k, m) = key('c');
    assert!(w.press(k, m), "Copy is shown by the keyframe menu but Controls does not take it");
    assert_eq!(opacity_keys(&mut w), 1, "Copy leaves the key");
    let later = w.rig.session.playhead() + Time::seconds(1);
    w.rig.session.seek(later);
    // The window's next event hands the new playhead to the panels.
    send(&mut w.root, &mut w.rig, InputEvent::MouseMoved { x: 700.0, y: 450.0 });
    w.settle();
    let (k, m) = key('v');
    assert!(w.press(k, m), "Paste is shown by the keyframe menu but Controls does not take it");
    assert_eq!(
        opacity_keys(&mut w),
        2,
        "Paste adds the copied key at the playhead (undo: {:?}, playhead {:?})",
        w.rig.session.undo_name(),
        w.rig.session.playhead()
    );
}

#[test]
fn the_scrub_hides_only_the_unique_folder_names_and_random_ids() {
    assert_eq!(scrub_temp_paths("a /tmp/sq-shown-keys-123-1234567890123-4/x sq-core b"), "a /tmp/<dir>/x sq-core b");
    let counted = "00000000-0000-0000-0000-00000000000B";
    let random = "18E890EC-92AB-A8C6-0025-E25300000001";
    assert_eq!(scrub_temp_paths(&format!("{counted} {random} ü")), format!("{counted} <id> ü"));
}
