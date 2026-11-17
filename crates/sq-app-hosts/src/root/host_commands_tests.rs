//! The panel-host command chain (`ShellHooks::command_handler` -> `AppRoot::run_host_command`): each command goes through
//! the shell like a menu pick, the root answers it, and the observable effect (and its undo) is checked.

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use sq_core_time::{Id, Time};
use sq_runtime::FakeClock;
use sq_uikit::editor_command::EditorCommand as C;
use std::sync::Arc;

/// The source and the sequence snap times to a frame (29.97 fps): within one frame at or after `secs`.
fn at_frame_of(t: Time, secs: i64) -> bool {
    t >= Time::seconds(secs) && t < Time::seconds(secs) + Time::new(1, 20)
}

pub(super) struct Setup {
    pub(super) root: AppRoot,
    pub(super) rig: crate::test_rig::Rig,
    dir: PathBuf,
}

impl Setup {
    pub(super) fn new() -> Setup {
        let dir = crate::test_rig::unique_dir("sq-host-commands");
        std::fs::create_dir_all(&dir).expect("dir");
        let mut root = crate::standard_root_with_source(
            &dir,
            Arc::new(FakeClock::new()),
            DrawTheme::default(),
            crate::MonitorPicture::default(),
            Box::new(sq_editor_session::StubProgramEngine::new()),
            crate::MonitorPicture::default(),
        )
        .expect("root");
        let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain));
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        root.shell.shell().focus = Some(PanelID::Timeline);
        // The panels follow the session through its changes (the Project model keeps its own copy of the project).
        root.on_change(sq_editor_session::Change::from_raw(u32::MAX), &mut rig.cx());
        Setup { root, rig, dir }
    }

    /// Picks `c` as the menu would and lets the root answer; the status lines it produced.
    pub(super) fn run(&mut self, c: C) -> Vec<String> {
        assert!(self.root.shell.command_enabled(&self.rig.session, c), "{c:?} enabled");
        assert!(self.root.shell.run_command(&mut self.rig.cx(), c), "{c:?} run");
        let mut lines = Vec::new();
        self.root.answer_timeline(&mut self.rig.cx(), &mut lines);
        lines
    }
}

impl Drop for Setup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn new_bin_adds_a_folder_selects_it_and_undoes() {
    let mut t = Setup::new();
    let bins = |t: &Setup| t.rig.session.project().root_bin.children.len();
    let before = bins(&t);
    t.run(C::NewBin);
    assert_eq!(bins(&t), before + 1);
    assert_eq!(t.rig.session.undo_name(), Some("New Folder"));
    assert!(matches!(t.root.project.view().selection(), [sq_core_model::BinItemRef::Bin(_)]));
    assert!(t.root.shell.shell().focus.is_some());
    t.rig.session.undo();
    assert_eq!(bins(&t), before);
}

/// Another panel's edit that reached the session after the Project panel's last sync: New Bin must keep it, and one
/// Undo takes back only the folder.
#[test]
fn new_bin_keeps_an_edit_another_panel_made_since_the_project_panel_synced() {
    let mut t = Setup::new();
    t.rig.session.set_project_notes("kept");
    t.run(C::NewBin);
    assert_eq!(t.rig.session.project().notes(), "kept", "the Project panel did not write its stale copy back");
    assert_eq!(t.rig.session.undo_name(), Some("New Folder"));
    t.rig.session.undo();
    assert_eq!(t.rig.session.project().notes(), "kept", "Undo took back only the folder");
}

#[test]
fn poster_frame_follows_the_source_monitor_and_clear_resets_it() {
    let mut t = Setup::new();
    let media = Id::from_u128(901);
    // nothing selected in the Project panel
    assert_eq!(t.run(C::SetPosterFrame), vec!["Select a clip first.".to_string()]);
    t.root.project.view().select(vec![sq_core_model::BinItemRef::Media(media)]);
    // selected, but the Source monitor shows nothing
    assert_eq!(t.run(C::SetPosterFrame).len(), 1);
    assert!(t.root.source.as_mut().expect("source").open_at(&mut t.rig.cx(), media, Time::seconds(4)));
    assert!(t.run(C::SetPosterFrame).is_empty());
    assert!(at_frame_of(t.rig.session.project().media(media).expect("media").poster_time.expect("poster"), 4));
    assert_eq!(t.rig.session.undo_name(), Some("Set Poster Frame"));
    t.run(C::ClearPosterFrame);
    assert_eq!(t.rig.session.project().media(media).expect("media").poster_time, None);
    assert_eq!(t.rig.session.undo_name(), Some("Clear Poster Frame"));
    t.rig.session.undo();
    assert!(t.rig.session.project().media(media).expect("media").poster_time.is_some_and(|p| at_frame_of(p, 4)));
}

#[test]
fn match_frame_opens_the_media_under_the_playhead_and_reverse_goes_back() {
    let mut t = Setup::new();
    assert!(t.run(C::MatchFrame).is_empty());
    let source = t.root.source.as_ref().expect("source");
    assert_eq!(source.core().media_id(), Some(Id::from_u128(901)));
    assert!(at_frame_of(source.core().current_time(), 3));
    assert_eq!(t.root.dock.focused(), Some(PanelID::SourceMonitor));
    t.rig.session.seek(Time::seconds(15));
    assert!(t.run(C::ReverseMatchFrame).is_empty());
    // the playhead snaps to a frame of the sequence (29.97 fps)
    let at = t.rig.session.playhead();
    assert!(at_frame_of(at, 3), "playhead back at 3 s, got {at:?}");
    assert_eq!(t.root.dock.focused(), Some(PanelID::Timeline));
}

#[test]
fn reverse_match_frame_says_so_without_a_source_clip() {
    let mut t = Setup::new();
    assert_eq!(t.run(C::ReverseMatchFrame), vec!["Open a clip in the Source monitor first.".to_string()]);
}

/// Puts a Graphic with at least two layers on the timeline (the first preset that has them).
pub(super) fn add_two_layer_graphic(t: &mut Setup) {
    let ids: Vec<String> =
        sq_editor_session::GraphicPresetCatalog::all().into_iter().map(|e| e.id.to_string()).collect();
    let mut found = false;
    for id in ids {
        let Some(clip) = t.rig.session.add_graphic_preset(&id, Some(Time::seconds(30)), None) else { continue };
        let layers = t.rig.session.active_timeline().and_then(|tl| {
            tl.tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .find(|c| c.id == clip)
                .and_then(|c| c.graphics().map(|g| g.layers.len()))
        });
        if layers.unwrap_or(0) >= 2 {
            found = true;
            break;
        }
        t.rig.session.undo();
    }
    assert!(found, "a preset with two layers");
}

#[test]
fn select_layer_steps_through_the_open_graphic_and_says_so_without_one() {
    let mut t = Setup::new();
    assert_eq!(t.run(C::SelectLayerAbove), vec!["No Graphic with layers is open.".to_string()]);
    add_two_layer_graphic(&mut t);
    assert!(t.run(C::SelectLayerAbove).is_empty());
    let first = t.rig.session.graphic_layer_selection().cloned().expect("a layer is selected");
    assert_eq!(first.layers.len(), 1);
    assert!(t.run(C::SelectLayerBelow).is_empty());
    let second = t.rig.session.graphic_layer_selection().cloned();
    assert_ne!(second, Some(first), "the other direction moves the selection");
}

#[test]
fn add_keyframe_keys_the_focused_property_once_and_names_the_undo() {
    use sq_editor_session::Change;
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    let mut t = Setup::new();
    assert_eq!(t.run(C::AddKeyframe), vec!["Select a property in Effect Controls first.".to_string()]);
    let one = t.rig.session.selection().iter().next().copied().expect("clip");
    t.rig.session.select([one].into_iter().collect(), Default::default());
    t.rig.session.seek(Time::seconds(2));
    let model = &mut t.root.inspector.controls().model;
    model.sync(&t.rig.session, Change::SELECTION | Change::PROJECT);
    model.focused_property = Some(EffectProperty::Opacity);
    assert!(t.run(C::AddKeyframe).is_empty());
    t.root.inspector.pump(&mut t.rig.cx());
    assert_eq!(t.rig.session.undo_name(), Some("Add Keyframe"));
    let again = t.run(C::AddKeyframe);
    assert_eq!(again, vec!["There is already a keyframe here, or the playhead is outside the clip.".to_string()]);
}

#[test]
fn select_next_and_previous_panel_move_the_focus_through_the_layout() {
    let mut t = Setup::new();
    let start = t.root.dock.focused();
    t.run(C::SelectNextPanel);
    let next = t.root.dock.focused();
    assert!(next.is_some() && next != Some(PanelID::Timeline) || next != start, "next panel focused");
    assert_eq!(t.root.shell.shell().focus, next);
    t.run(C::SelectPreviousPanel);
    assert_eq!(t.root.shell.shell().focus, Some(PanelID::Timeline));
    assert_eq!(t.root.dock.focused(), Some(PanelID::Timeline));
}

#[test]
fn edit_dynamic_zoom_toggles_the_editor_and_a_drag_is_one_undo_step() {
    use sq_app_shell::AppHost;
    use sq_core_effects::dynamic_zoom::ZoomRect;
    use sq_draw_monitor::transform_overlay::Phase;
    use sq_draw_monitor::zoom_edit_overlay::ZoomEditEvent;
    let mut t = Setup::new();
    t.rig.session.select(Default::default(), Default::default());
    assert_eq!(
        t.run(C::EditDynamicZoom),
        vec!["Select a video clip and put the playhead on it to edit its zoom.".to_string()]
    );
    assert!(!t.root.monitor.is_editing_dynamic_zoom());
    let one = t.rig.session.selection().iter().next().copied();
    let clip = one.unwrap_or_else(|| {
        let tl = t.rig.session.active_timeline().expect("timeline");
        tl.tracks.iter().flat_map(|tr| tr.clips()).next().expect("clip").id
    });
    t.rig.session.select([clip].into_iter().collect(), Default::default());
    t.rig.session.seek(Time::seconds(2));
    t.root.monitor.sync(&t.rig.session);
    assert!(t.run(C::EditDynamicZoom).is_empty());
    assert!(t.root.monitor.is_editing_dynamic_zoom());
    assert!(t.root.monitor.panel.zoom_edit.is_some());
    let end = ZoomRect::centred(2.0, sq_core_time::Vec2::new(0.5, 0.5));
    let drag = |t: &mut Setup, phase: Phase, end: ZoomRect| {
        let z = t.root.monitor.panel.zoom_edit.as_mut().expect("editor");
        z.events.push(ZoomEditEvent::Change(phase, ZoomRect::FULL, end));
        t.root.monitor.on_change(sq_editor_session::Change::from_raw(0), &mut t.rig.cx());
    };
    drag(&mut t, Phase::Began, ZoomRect::FULL);
    drag(&mut t, Phase::Changed, ZoomRect::centred(1.5, sq_core_time::Vec2::new(0.5, 0.5)));
    drag(&mut t, Phase::Changed, end);
    drag(&mut t, Phase::Ended, end);
    let name = t.rig.session.undo_name().map(str::to_string);
    assert_eq!(name.as_deref(), Some("Dynamic Zoom"));
    let windows = {
        let c = t
            .rig
            .session
            .active_timeline()
            .and_then(|tl| tl.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == clip).cloned());
        t.rig.session.dynamic_zoom_windows(&c.expect("clip"))
    };
    assert!((windows.expect("windows").end.width - end.width).abs() < 1e-6, "the drag wrote the end window");
    t.rig.session.undo(); // the whole drag is one step
    assert_ne!(t.rig.session.undo_name(), Some("Dynamic Zoom"));
    // Done closes; the command toggles it off too
    t.root.monitor.panel.zoom_edit.as_mut().expect("editor").events.push(ZoomEditEvent::Done);
    t.root.monitor.on_change(sq_editor_session::Change::from_raw(0), &mut t.rig.cx());
    assert!(!t.root.monitor.is_editing_dynamic_zoom());
    assert!(t.run(C::EditDynamicZoom).is_empty());
    assert!(t.run(C::EditDynamicZoom).is_empty());
    assert!(!t.root.monitor.is_editing_dynamic_zoom());
}

#[test]
fn the_preroll_and_postroll_settings_size_play_around() {
    use sq_core_time::TimeRange;
    let mut t = Setup::new();
    t.rig.session.seek(Time::seconds(4));
    let settings = std::rc::Rc::clone(&t.root.shell.shell().settings);
    let range_with = |t: &mut Setup, pre: i64, post: i64| {
        let s = sq_editor_session::AppSettings {
            preroll_seconds: pre,
            postroll_seconds: post,
            ..sq_editor_session::AppSettings::standard()
        };
        s.save(&mut *settings.borrow_mut());
        t.rig.session.seek(Time::seconds(4));
        t.run(C::PlayAround);
        let range: Option<TimeRange> = t
            .rig
            .session
            .engine()
            .as_any()
            .downcast_ref::<sq_editor_session::StubProgramEngine>()
            .and_then(|e| e.play_range);
        t.rig.session.stop_playback();
        range.expect("Play Around sets a range")
    };
    let short = range_with(&mut t, 1, 1);
    let long = range_with(&mut t, 3, 2);
    assert!(
        long.start < short.start && long.end() >= short.end(),
        "{short:?} then {long:?}: Preroll and Postroll apply"
    );
}

pub(super) fn key(t: &mut Setup, key: InputKey, modifiers: InputModifiers) -> bool {
    t.root.handle(&InputEvent::KeyDown { key, modifiers }, &mut t.rig.cx())
}

pub(super) fn type_chars(t: &mut Setup, text: &str) {
    for ch in text.chars() {
        t.rig.ui.typed_text = Some(ch.to_string());
        key(t, InputKey::Character(ch), InputModifiers::NONE);
        t.rig.ui.typed_text = None;
    }
}

/// A press on `panel`, found by asking the dock where it is (the middle of its first hit on a coarse grid of the window).
fn press_on(t: &mut Setup, panel: PanelID) {
    let hits: Vec<CGPoint> = (0..28)
        .flat_map(|j| (0..45).map(move |i| CGPoint::new(10.0 + 30.0 * f64::from(i), 10.0 + 30.0 * f64::from(j))))
        .filter(|p| t.root.dock.panel_at(*p) == Some(panel))
        .collect();
    let at = hits[hits.len() / 2];
    let (x, y) = (at.x as f32 * t.rig.scale, at.y as f32 * t.rig.scale);
    t.root.handle(&InputEvent::MouseMoved { x, y }, &mut t.rig.cx());
    t.root.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut t.rig.cx());
    t.root.handle(&InputEvent::MouseUp { x, y }, &mut t.rig.cx());
}

/// New Folder, then Enter on the selected folder: its name field is open. The folder's id.
fn new_folder_with_name_field(t: &mut Setup) -> sq_core_model::BinItemRef {
    press_on(t, PanelID::Project);
    t.run(C::NewBin);
    let folder = *t.root.project.view().selection().first().expect("the new folder is selected");
    key(t, InputKey::Enter, InputModifiers::NONE);
    assert!(t.root.project.is_renaming(), "Enter on the selected folder opens its name field");
    folder
}

/// Windows VM, 2026-11-16: the field stayed open after a press on the timeline, kept eating keys and Ctrl+S did nothing.
#[test]
fn a_press_on_the_timeline_commits_and_closes_the_project_name_field() {
    let mut t = Setup::new();
    let folder = new_folder_with_name_field(&mut t);
    type_chars(&mut t, "Shots");
    press_on(&mut t, PanelID::Timeline);
    assert!(!t.root.project.is_renaming(), "the press closed the field");
    assert_eq!(t.root.project.model().display_name(folder), "Shots", "the typed name was kept");
    // The keys after it are the timeline's again, not a closed field's.
    assert_eq!(t.rig.session.undo_name(), Some("Rename"));
}

#[test]
fn enter_commits_the_project_name_field_whatever_panel_has_the_focus() {
    let mut t = Setup::new();
    let folder = new_folder_with_name_field(&mut t);
    t.root.dock.set_focused(Some(PanelID::Timeline));
    type_chars(&mut t, "Reels");
    assert!(key(&mut t, InputKey::Enter, InputModifiers::NONE));
    assert!(!t.root.project.is_renaming());
    assert_eq!(t.root.project.model().display_name(folder), "Reels");
}

#[test]
fn a_menu_chord_commits_the_project_name_field_and_runs() {
    let mut t = Setup::new();
    let folder = new_folder_with_name_field(&mut t);
    type_chars(&mut t, "Cuts");
    let timelines = t.rig.session.project().timelines.len();
    // Group (Command+G, a global key of the Clip menu) with the name field open.
    key(&mut t, InputKey::Character('g'), InputModifiers::COMMAND);
    assert!(!t.root.project.is_renaming(), "the chord closed the field");
    assert_eq!(t.root.project.model().display_name(folder), "Cuts");
    assert_eq!(t.rig.session.project().timelines.len(), timelines + 1, "Group ran with the field open");
}

/// Group (Command+G, a global key of the Clip menu) with a search field typing in the focused panel.
#[test]
fn a_menu_chord_runs_while_a_library_or_effects_search_field_has_the_keyboard() {
    for panel in [PanelID::Library, PanelID::Effects] {
        let mut t = Setup::new();
        t.root.dock.show(panel);
        t.root.dock.set_focused(Some(panel));
        let editing = |t: &mut Setup| match panel {
            PanelID::Library => t.root.library.panel_host().panel.is_editing_search(),
            _ => t.root.effects.as_mut().is_some_and(|f| f.panel_host().panel.is_editing_search()),
        };
        match panel {
            PanelID::Library => t.root.library.panel_host().panel.focus_search(),
            _ => t.root.effects.as_mut().expect("effects panel").panel_host().panel.focus_search(),
        }
        assert!(editing(&mut t), "{panel:?}: the search field is open");
        type_chars(&mut t, "bl");
        let timelines = t.rig.session.project().timelines.len();
        key(&mut t, InputKey::Character('g'), InputModifiers::COMMAND);
        assert_eq!(t.rig.session.project().timelines.len(), timelines + 1, "{panel:?}: the chord reached the menu");
        assert!(!editing(&mut t), "{panel:?}: the search field closed");
    }
}

// MARK: Text panel, Graphics panel and timeline caption fields

/// One kind of field that used to swallow menu chords: how to open it with "Zed" typed in, how to see that the typed
/// text was kept, and which panel a press outside of it lands on.
struct FieldCase {
    name: &'static str,
    open: fn(&mut Setup) -> Id,
    kept: fn(&mut Setup, Id) -> bool,
    outside: PanelID,
}

const FIELD_CASES: [FieldCase; 3] = [
    FieldCase {
        name: "Text panel caption field",
        open: open_text_panel_field,
        kept: text_panel_kept,
        outside: PanelID::Timeline,
    },
    FieldCase {
        name: "Graphics layer name field",
        open: open_graphics_field,
        kept: graphics_kept,
        outside: PanelID::Timeline,
    },
    FieldCase {
        name: "timeline caption word field",
        open: open_timeline_word_field,
        kept: timeline_word_kept,
        outside: PanelID::Project,
    },
];

/// A caption "First line" on a new caption track of the demo timeline; its id.
fn caption_for_typing(t: &mut Setup) -> Id {
    let id = Id::from_u128(701);
    let item = sq_core_model::CaptionItem {
        id,
        lines: vec!["First line".to_string()],
        range: sq_core_time::TimeRange::new(Time::seconds(0), Time::seconds(3)),
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    };
    assert!(t.rig.session.add_caption_track().is_some());
    assert!(t.rig.session.add_captions(vec![item]));
    t.root.sync(&t.rig.session);
    t.root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut t.rig.cx());
    t.root.on_change(sq_editor_session::Change::from_raw(u32::MAX), &mut t.rig.cx());
    id
}

fn caption_text(t: &Setup, id: Id) -> String {
    let timeline = t.rig.session.active_timeline();
    let item = timeline.and_then(|tl| tl.caption_tracks.iter().flat_map(|c| c.items().iter()).find(|i| i.id == id));
    item.map(|i| i.lines.join(" ")).unwrap_or_default()
}

fn open_text_panel_field(t: &mut Setup) -> Id {
    let id = caption_for_typing(t);
    t.root.dock.show(PanelID::Text);
    t.root.dock.set_focused(Some(PanelID::Text));
    let text = t.root.text.as_mut().expect("text panel");
    text.panel().select(&t.rig.session, sq_inspector_ui::text::panel_draw::Tab::Captions);
    text.panel().captions.begin_editing(&mut t.rig.session, id);
    assert!(text.panel().captions.is_editing_caption(), "the caption row is open for typing");
    id
}

fn text_panel_kept(t: &mut Setup, id: Id) -> bool {
    let open = t.root.text.as_mut().is_some_and(|x| x.panel().captions.is_editing_caption());
    !open && caption_text(t, id).contains("Zed")
}

fn open_graphics_field(t: &mut Setup) -> Id {
    t.root.dock.show(PanelID::Graphics);
    t.root.dock.set_focused(Some(PanelID::Graphics));
    let graphics = t.root.graphics.as_mut().expect("graphics panel");
    graphics.panel().with_session(&mut t.rig.session, |p| {
        assert!(p.host.editor.new_graphics_clip(&mut p.host.session).is_some());
        p.host.editor.add_shape(&mut p.host.session, sq_core_model::ShapeKind::Rectangle);
    });
    t.root.on_change(sq_editor_session::Change::from_raw(u32::MAX), &mut t.rig.cx());
    // Return on the one selected layer opens its name field.
    key(t, InputKey::Enter, InputModifiers::NONE);
    Id::from_u128(0)
}

fn graphics_kept(t: &mut Setup, _: Id) -> bool {
    let graphics = t.root.graphics.as_mut().expect("graphics panel");
    let name = graphics.panel().with_session(&mut t.rig.session, |p| {
        p.host.editor.selected_layer(&p.host.session).map(|l| l.name.clone()).unwrap_or_default()
    });
    name.contains("Zed")
}

fn open_timeline_word_field(t: &mut Setup) -> Id {
    let id = caption_for_typing(t);
    t.root.dock.set_focused(Some(PanelID::Timeline));
    let panel = &mut t.root.timeline.inner().panel;
    assert!(panel.begin_word_editing(sq_timeline_ui::CaptionWordRef::new(id, 1)).is_some());
    assert!(panel.is_editing_word(), "the word field is open");
    id
}

fn timeline_word_kept(t: &mut Setup, id: Id) -> bool {
    !t.root.timeline.inner().panel.is_editing_word() && caption_text(t, id).contains("Zed")
}

fn press_outside_commits(case: &FieldCase) {
    let mut t = Setup::new();
    let id = (case.open)(&mut t);
    type_chars(&mut t, "Zed");
    press_on(&mut t, case.outside);
    assert!((case.kept)(&mut t, id), "{}: the press committed the typed text and closed the field", case.name);
}

/// New Bin (Command+/, a global key that needs no selection) with the field open: the chord commits the typed text
/// first, then the command runs.
fn menu_chord_commits_and_runs(case: &FieldCase) {
    let mut t = Setup::new();
    let id = (case.open)(&mut t);
    type_chars(&mut t, "Zed");
    key(&mut t, InputKey::Character('/'), InputModifiers::COMMAND);
    assert_eq!(t.rig.session.undo_name(), Some("New Folder"), "{}: New Bin ran with the field open", case.name);
    assert!((case.kept)(&mut t, id), "{}: the chord committed the typed text and closed the field", case.name);
}

#[test]
fn a_menu_chord_commits_a_text_panel_field_and_runs() {
    menu_chord_commits_and_runs(&FIELD_CASES[0]);
}

#[test]
fn a_menu_chord_commits_a_graphics_layer_name_field_and_runs() {
    menu_chord_commits_and_runs(&FIELD_CASES[1]);
}

#[test]
fn a_menu_chord_commits_a_timeline_caption_word_field_and_runs() {
    menu_chord_commits_and_runs(&FIELD_CASES[2]);
}

#[test]
fn a_press_outside_commits_a_text_panel_field() {
    press_outside_commits(&FIELD_CASES[0]);
}

#[test]
fn a_press_outside_commits_a_graphics_layer_name_field() {
    press_outside_commits(&FIELD_CASES[1]);
}

#[test]
fn a_press_outside_commits_a_timeline_caption_word_field() {
    press_outside_commits(&FIELD_CASES[2]);
}

/// Select all and the cursor keys are no menu chords: the open field keeps them.
#[test]
fn select_all_keeps_a_text_panel_field_open() {
    let mut t = Setup::new();
    let id = open_text_panel_field(&mut t);
    type_chars(&mut t, "Zed");
    key(&mut t, InputKey::Character('a'), InputModifiers::COMMAND);
    assert!(
        t.root.text.as_mut().is_some_and(|x| x.panel().captions.is_editing_caption()),
        "Command+A stays the field's"
    );
    assert!(!caption_text(&t, id).contains("Zed"), "nothing was committed yet");
}
