//! Bugs from the real Windows and Linux windows, reproduced through the whole app (`Headless` over the standard root):
//! the keys and the wheel arrive as the window sends them.

use super::dead_commands_tests::{Scenario, demo_session};
use sq_app_shell::{AppDeps, Headless};
use sq_draw::{InputEvent, InputKey, InputModifiers};
use sq_draw_shell::ShellRoot;
use sq_runtime::FakeClock;
use std::sync::Arc;

/// The real app root over a fresh support folder, 1280 x 800 like the test windows.
fn window() -> Headless {
    let dir = crate::test_rig::unique_dir("sq-real-window");
    std::fs::create_dir_all(&dir).expect("dir");
    let clock = Arc::new(FakeClock::new());
    let h = Headless::new(demo_session(Scenario::Plain), AppDeps::headless(Arc::clone(&clock) as _), 1280, 800);
    let root = crate::standard_root(&dir, clock, sq_draw::DrawTheme::default()).expect("root");
    h.with(|a| {
        a.add_host(Box::new(root));
        a.launch();
    });
    h.turn();
    h
}

fn key(h: &Headless, key: InputKey) {
    h.input(&InputEvent::KeyDown { key, modifiers: InputModifiers::NONE });
    for _ in 0..3 {
        h.turn();
    }
}

fn has_dialog(h: &Headless) -> bool {
    h.with(|a| a.shell_parts().shell.dialog().is_some()).unwrap_or(false)
}

fn open_settings(h: &Headless) {
    h.input(&InputEvent::KeyDown { key: InputKey::Character(','), modifiers: InputModifiers::COMMAND });
    for _ in 0..4 {
        h.turn();
    }
    assert!(has_dialog(h), "Ctrl+, opens Settings");
}

#[test]
fn escape_closes_settings_through_the_whole_app() {
    let h = window();
    open_settings(&h);
    let mut shown = Vec::new();
    for _ in 0..3 {
        key(&h, InputKey::Escape);
        shown.push(has_dialog(&h));
    }
    assert!(!has_dialog(&h), "Escape closes Settings: dialog up after each press {shown:?}");
}

fn form_scroll(h: &Headless) -> (f64, bool) {
    h.with(|a| a.shell_parts().shell.dialog().map(|d| (d.form_scroll(), d.form_scrolls())))
        .flatten()
        .unwrap_or((-1.0, false))
}

fn wheel(h: &Headless, x: f32, y: f32, dy: f32) {
    h.input(&InputEvent::Scroll { x, y, dx: 0.0, dy, modifiers: InputModifiers::NONE });
    h.turn();
}

#[test]
fn the_wheel_scrolls_the_playback_page_through_the_whole_app() {
    let h = window();
    open_settings(&h);
    key(&h, InputKey::Down); // the sidebar list has the keys: Playback
    let before = form_scroll(&h);
    assert!(before.1, "the Playback page is taller than its viewport: {before:?}");
    wheel(&h, 700.0, 300.0, -120.0);
    assert!(form_scroll(&h).0 > 0.0, "the wheel moved the page: {:?}", form_scroll(&h));
}

fn knob(h: &Headless) -> Option<(f64, f64)> {
    h.with(|a| a.shell_parts().shell.dialog().and_then(|d| d.scroll_knob_frame()))
        .flatten()
        .map(|k| (k.mid_x(), k.mid_y()))
}

#[test]
fn dragging_the_settings_scrollbar_scrolls_the_page() {
    let h = window();
    open_settings(&h);
    key(&h, InputKey::Down);
    h.turn();
    let (x, y) = knob(&h).expect("the Playback page has a scroller");
    let none = InputModifiers::NONE;
    h.input(&InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: none });
    h.input(&InputEvent::MouseDragged { x: x as f32, y: y as f32 + 120.0, modifiers: none });
    h.input(&InputEvent::MouseUp { x: x as f32, y: y as f32 + 120.0 });
    h.turn();
    assert!(form_scroll(&h).0 > 100.0, "the knob moved the page: {:?}", form_scroll(&h));
    let (_, y2) = knob(&h).expect("scroller");
    assert!(y2 > y + 60.0, "the knob follows the drag ({y} -> {y2})");
}

#[test]
fn page_and_arrow_keys_scroll_a_long_settings_page() {
    let h = window();
    open_settings(&h);
    key(&h, InputKey::Down); // sidebar: Playback
    key(&h, InputKey::PageDown);
    let after_page = form_scroll(&h).0;
    assert!(after_page > 100.0, "Page Down scrolled: {after_page}");
    key(&h, InputKey::Home);
    assert_eq!(form_scroll(&h).0, 0.0, "Home goes back to the top");
}

/// (frame, typing, text) of the Settings sidebar search field.
fn search_field(h: &Headless) -> Option<(sq_uikit::controls_grid::CGRect, bool, String)> {
    h.with(|a| a.shell_parts().shell.dialog().and_then(|d| d.form.as_ref().and_then(|f| f.search_field()))).flatten()
}

/// Linux check part 5: the Settings search took one character only. Every changed query rebuilds the page, and the new
/// search field opened with the whole text selected, so the next key replaced it ("q", "x", "q" arrived as "q"). Typed key by
/// key through the whole app, the word arrives complete, the field keeps the keyboard, and BackSpace edits it.
#[test]
fn the_settings_search_keeps_the_keyboard_while_a_word_is_typed() {
    let h = window();
    open_settings(&h);
    let (frame, typing, _) = search_field(&h).expect("the Settings sidebar has a search field");
    assert!(!typing, "the field starts closed");
    let (x, y) = (frame.mid_x() as f32, frame.mid_y() as f32);
    h.input(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
    h.input(&InputEvent::MouseUp { x, y });
    h.turn();
    assert!(search_field(&h).is_some_and(|f| f.1), "a click on the field opens it");
    for (i, ch) in "autosave".chars().enumerate() {
        key(&h, InputKey::Character(ch));
        let (_, typing, text) = search_field(&h).expect("search field");
        assert!(typing, "the field lost the keyboard after '{ch}'");
        assert_eq!(text, "autosave".chars().take(i + 1).collect::<String>(), "after typing '{ch}'");
    }
    key(&h, InputKey::Backspace);
    assert_eq!(search_field(&h).map(|f| f.2), Some("autosav".to_string()), "BackSpace edits the field");
}

/// Bug from the real Windows window: Ctrl+, with a clip selected must open Settings and leave the timeline alone (no
/// "Nudge Clips" in Undo). The Windows window reports Ctrl as the Command flag.
#[test]
fn ctrl_comma_with_a_clip_selected_opens_settings_and_edits_nothing() {
    let h = window();
    let before = h.with(|a| a.session().undo_name().map(str::to_string));
    open_settings(&h);
    let after = h.with(|a| a.session().undo_name().map(str::to_string));
    assert_eq!(before, after, "Ctrl+, changed the undo stack");
}

/// (start seconds, kind) of every clip on the active sequence, sorted.
type Starts = Vec<(i64, String)>;

fn clip_starts(h: &Headless) -> Starts {
    h.with(|a| {
        let mut v: Vec<(i64, String)> = a
            .session()
            .active_timeline()
            .map(|t| {
                t.tracks
                    .iter()
                    .flat_map(|tr| {
                        tr.clips().iter().map(|c| (c.start.value() / c.start.timescale(), format!("{:?}", c.kind)))
                    })
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    })
    .unwrap_or_default()
}

/// Select the first video clip only, then press `key` with Shift (the real key event) and return the starts after.
fn shift_delete_with(pressed: InputKey, modifiers: InputModifiers) -> (Starts, Starts) {
    let h = window();
    h.with(|a| {
        let s = a.session_mut();
        s.set_selection_follows_playhead(false);
        // A click on a clip selects it with its linked audio (linked selection): the first video clip and its pair.
        let t = s.active_timeline().expect("sequence");
        let first = t
            .tracks
            .iter()
            .find(|tr| tr.kind == sq_core_model::TrackKind::Video)
            .and_then(|tr| tr.clips().first().cloned())
            .expect("a video clip");
        let pair = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| c.id == first.id || (first.link.is_some() && c.link == first.link));
        let ids: std::collections::BTreeSet<_> = pair.map(|c| c.id).collect();
        s.select(ids, Default::default());
    });
    // A click on the timeline gives it the key focus; the Delete bindings live in the Timeline scope.
    h.with(|a| a.shell_parts().shell.focus = Some(sq_uikit::panel_id::PanelID::Timeline));
    h.turn();
    // A dialog that came up meanwhile (the demo's media files are not on disk) takes the keys until it is closed.
    for _ in 0..3 {
        if has_dialog(&h) {
            key(&h, InputKey::Escape);
        }
    }
    let before = clip_starts(&h);
    h.input(&InputEvent::KeyDown { key: pressed, modifiers });
    for _ in 0..3 {
        h.turn();
    }
    (before, clip_starts(&h))
}

#[test]
fn shift_backspace_ripple_deletes_through_the_whole_app() {
    let (before, after) = shift_delete_with(InputKey::Backspace, InputModifiers::SHIFT);
    assert!(after.len() < before.len(), "the clip went: {before:?} -> {after:?}");
    assert_eq!(after.iter().map(|c| c.0).max(), Some(0), "the next clips closed the gap: {after:?}");
}

#[test]
fn shift_delete_ripple_deletes_through_the_whole_app() {
    let (before, after) = shift_delete_with(InputKey::Delete, InputModifiers::SHIFT);
    assert!(after.len() < before.len(), "the clip went: {before:?} -> {after:?}");
    assert_eq!(after.iter().map(|c| c.0).max(), Some(0), "the next clips closed the gap: {after:?}");
}

#[test]
fn plain_backspace_lifts_the_selected_clip_through_the_whole_app() {
    let (before, after) = shift_delete_with(InputKey::Backspace, InputModifiers::NONE);
    assert!(after.len() < before.len(), "the clip went: {before:?} -> {after:?}");
}

/// Audit ship D #12: Cmd+K on a clicked clip (its linked audio selected with it) cuts both at the playhead.
#[test]
fn cmd_k_splits_a_clip_and_its_linked_audio_through_the_whole_app() {
    let h = window();
    let (id, _) = h
        .with(|a| {
            let s = a.session_mut();
            s.set_selection_follows_playhead(false);
            let t = s.active_timeline().expect("sequence");
            let first = t
                .tracks
                .iter()
                .find(|tr| tr.kind == sq_core_model::TrackKind::Video)
                .and_then(|tr| tr.clips().first().cloned())
                .expect("a video clip");
            let ids: std::collections::BTreeSet<_> = t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .filter(|c| c.id == first.id || (first.link.is_some() && c.link == first.link))
                .map(|c| c.id)
                .collect();
            assert!(first.link.is_some() && ids.len() == 2, "the demo clip has linked audio: {ids:?}");
            let mid = first.start + sq_core_time::Time::scaled_int(first.timeline().duration, 1, 2);
            s.select(ids, Default::default());
            s.seek(mid);
            (first.id, mid)
        })
        .expect("session");
    h.with(|a| a.shell_parts().shell.focus = Some(sq_uikit::panel_id::PanelID::Timeline));
    h.turn();
    for _ in 0..3 {
        if has_dialog(&h) {
            key(&h, InputKey::Escape);
        }
    }
    let before = clip_starts(&h);
    h.input(&InputEvent::KeyDown { key: InputKey::Character('k'), modifiers: InputModifiers::COMMAND });
    for _ in 0..3 {
        h.turn();
    }
    let after = clip_starts(&h);
    assert_eq!(after.len(), before.len() + 2, "video and linked audio both split: {before:?} -> {after:?}");
    let cut = h
        .with(|a| {
            // The playhead is frame-snapped, so the cut is read from it, not from `mid`.
            let at = a.session().playhead();
            let t = a.session().active_timeline().expect("sequence");
            t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| c.start == at).count()
        })
        .expect("session");
    assert_eq!(cut, 2, "one new piece per track starts at the playhead (clip {id:?})");
}

/// What an editor shortcut would change, read from the whole app: the clips, the selection and the undo stack.
fn editor_fingerprint(h: &Headless) -> String {
    let starts = clip_starts(h);
    h.with(|a| {
        let s = a.session();
        format!("{starts:?}, {} selected, undo {:?}, can_undo {}", s.selection().len(), s.undo_name(), s.can_undo())
    })
    .unwrap_or_default()
}

/// One key as the window sends it: the typed text rides along on the UI context.
fn typed_key(h: &Headless, key: InputKey, modifiers: InputModifiers, text: Option<&str>) {
    h.with(|a| a.ui_mut().typed_text = text.map(str::to_string));
    h.input(&InputEvent::KeyDown { key, modifiers });
    h.with(|a| a.ui_mut().typed_text = None);
    for _ in 0..3 {
        h.turn();
    }
}

/// Settings, the Export sheet and the Shortcuts page own the keyboard: typed letters, Ctrl+A, Backspace and Delete never
/// reach the timeline behind them (a Ctrl+A and Backspace behind Quick Apply once deleted every clip). The same rows run
/// on the bare root in `modal_keys_tests`; this one goes through the whole app with its preference and export services.
#[test]
fn settings_the_export_sheet_and_the_shortcuts_page_keep_every_key_from_the_timeline() {
    let c = |ch: char| InputKey::Character(ch);
    let surfaces: [(&str, InputKey, InputModifiers); 3] = [
        ("Settings", c(','), InputModifiers::COMMAND),
        ("the Export sheet", c('m'), InputModifiers::COMMAND),
        ("the Shortcuts page", c('k'), InputModifiers::COMMAND | InputModifiers::OPTION),
    ];
    let mut opened = Vec::new();
    for (name, open_key, open_mods) in surfaces {
        let h = window();
        // The demo's media files are not on disk: a notice that came up meanwhile takes the keys until it is closed.
        for _ in 0..3 {
            if has_dialog(&h) {
                key(&h, InputKey::Escape);
            }
        }
        h.with(|a| a.shell_parts().shell.focus = Some(sq_uikit::panel_id::PanelID::Timeline));
        let before = editor_fingerprint(&h);
        typed_key(&h, open_key, open_mods, None);
        for _ in 0..4 {
            h.turn();
        }
        if !has_dialog(&h) {
            eprintln!("not opened in the headless app: {name}");
            continue;
        }
        opened.push(name);
        let none = InputModifiers::NONE;
        for (k, m, text) in [
            (c('v'), none, Some("v")),
            (c('h'), none, Some("h")),
            (c('s'), none, Some("s")),
            (c('a'), InputModifiers::COMMAND, None),
            (InputKey::Backspace, none, None),
            (InputKey::Delete, none, None),
            (InputKey::Delete, InputModifiers::SHIFT, None),
            (InputKey::Backspace, InputModifiers::SHIFT, None),
            (InputKey::Minus, none, Some("-")),
            (InputKey::Space, none, Some(" ")),
        ] {
            typed_key(&h, k, m, text);
            assert_eq!(editor_fingerprint(&h), before, "{name}: {k:?} {m:?} changed the editor");
        }
    }
    assert_eq!(opened, ["Settings", "the Export sheet", "the Shortcuts page"], "every surface opened and was tested");
}

/// Encodes at once.
struct Quick;

impl sq_export::core::traits::ExportEncoding for Quick {
    fn export(
        &self,
        _: &mut dyn sq_export::core::traits::FrameSource,
        _: Option<&mut dyn sq_export::core::traits::AudioSource>,
        _: &sq_export::core::settings::ExportSettings,
        _: &std::path::Path,
        _: &sq_export::core::error::CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, sq_export::core::error::ExportError> {
        progress(1.0);
        Ok(None)
    }
}

struct OneFrame;

impl sq_export::core::traits::FrameSource for OneFrame {
    fn frame_count(&self) -> usize {
        1
    }
    fn frame_duration(&self) -> sq_core_time::Time {
        sq_core_time::Time::new(1, 30)
    }
    fn frame(&mut self, _: usize) -> Result<sq_export::core::traits::ExportFrame, sq_export::core::error::ExportError> {
        Err(sq_export::core::error::ExportError::EmptySource)
    }
}

/// The real root with File > Export on, over a queue whose encoder finishes at once.
fn window_with_export() -> (Headless, Arc<sq_export::core::queue::ExportQueue>, Arc<FakeClock>) {
    use sq_export::core::queue::{ExportQueue, ExportSources};
    let dir = crate::test_rig::unique_dir("sq-real-window-export");
    std::fs::create_dir_all(&dir).expect("dir");
    let clock = Arc::new(FakeClock::new());
    let h = Headless::new(demo_session(Scenario::Plain), AppDeps::headless(Arc::clone(&clock) as _), 1280, 800);
    let mut root = crate::standard_root(&dir, Arc::clone(&clock) as _, sq_draw::DrawTheme::default()).expect("root");
    let queue = Arc::new(ExportQueue::new(Arc::new(Quick)));
    root.shell.enable_export(crate::export_host::ExportSetup {
        queue: Arc::clone(&queue),
        make_sources: Arc::new(|_, _, _| Ok(ExportSources::new(Box::new(OneFrame), None))),
        frame_pixels: None,
        make_stem_audio: None,
        stem_encoder: None,
    });
    h.with(|a| {
        a.add_host(Box::new(root));
        a.launch();
    });
    h.turn();
    (h, queue, clock)
}

/// Windows bug: after an export finished Ctrl+Z did nothing until a click into a panel.
#[test]
fn ctrl_z_waits_for_the_export_finished_card_then_works() {
    the_export_finished_card_owns_the_keys_until_this_key_closes_it(InputKey::Enter);
}

/// Windows check: the card did not close on Esc and Ctrl+S after it was lost. Esc is as good as OK (the Default button).
#[test]
fn esc_closes_the_export_finished_card_and_the_editor_gets_its_keys_back() {
    the_export_finished_card_owns_the_keys_until_this_key_closes_it(InputKey::Escape);
}

fn the_export_finished_card_owns_the_keys_until_this_key_closes_it(closing_key: InputKey) {
    use sq_uikit::panel_id::PanelID;
    let (h, queue, clock) = window_with_export();
    for _ in 0..6 {
        for _ in 0..5 {
            h.turn();
        }
        if has_dialog(&h) {
            key(&h, InputKey::Escape);
        }
    }
    h.with(|a| {
        let s = a.session_mut();
        s.add_marker_at_playhead();
        a.dock_mut().expect("dock").set_focused(Some(PanelID::EffectControls));
    });
    h.turn();
    let ctrl = InputModifiers::COMMAND;
    typed_key(&h, InputKey::Character('m'), ctrl, None);
    let button = h.with(|a| a.shell_parts().shell.dialog().and_then(|d| d.button_frames().get(&0).copied())).flatten();
    let title = h.with(|a| a.shell_parts().shell.dialog().map(|d| format!("{:?}", d.model.buttons))).flatten();
    eprintln!("PROBE sheet {} {title:?} button {button:?}", has_dialog(&h));
    assert!(button.is_some(), "the Export button");
    // The Export button, then the first button of every question that follows (offline media, name taken).
    for round in 0..4 {
        let Some(b) =
            h.with(|a| a.shell_parts().shell.dialog().and_then(|d| d.button_frames().get(&0).copied())).flatten()
        else {
            break;
        };
        let (x, y) = (b.mid_x() as f32, b.mid_y() as f32);
        h.input(&InputEvent::MouseMoved { x, y });
        h.input(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
        h.input(&InputEvent::MouseUp { x, y });
        for _ in 0..5 {
            h.turn();
        }
        eprintln!("PROBE round {round} jobs {}", queue.all_statuses().len());
    }
    let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::time::Instant::now() < end {
        std::thread::sleep(std::time::Duration::from_millis(20));
        h.with(sq_app_shell::App::set_needs_redraw);
        h.turn();
        let done = queue.all_statuses();
        if !done.is_empty()
            && done.iter().all(|s| {
                matches!(
                    s.state,
                    sq_export::core::queue::ExportJobState::Done(_) | sq_export::core::queue::ExportJobState::Failed(_)
                )
            })
        {
            break;
        }
    }
    for _ in 0..8 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        clock.advance(std::time::Duration::from_millis(300));
        h.with(sq_app_shell::App::set_needs_redraw);
        h.turn();
    }
    // The "Export finished" card is up (Swift `presentExportFinished`, also modal): it owns every key, so Ctrl+Z does
    // nothing behind it and the editor is untouched; OK closes it and Ctrl+Z works again with the focus where it was.
    assert!(queue.all_statuses().iter().all(|s| matches!(s.state, sq_export::core::queue::ExportJobState::Done(_))));
    assert!(has_dialog(&h), "the Export finished card is up");
    let undo_state = |h: &Headless| h.with(|a| (a.session().can_undo(), a.session().can_redo()));
    typed_key(&h, InputKey::Character('z'), ctrl, None);
    assert_eq!(undo_state(&h), Some((true, false)), "the card owns Ctrl+Z");
    key(&h, closing_key);
    assert!(!has_dialog(&h), "{closing_key:?} closes the card");
    assert_eq!(h.with(|a| a.dock_mut().expect("dock").focused()), Some(Some(PanelID::EffectControls)), "focus kept");
    typed_key(&h, InputKey::Character('z'), ctrl, None);
    assert_eq!(undo_state(&h), Some((true, true)), "Ctrl+Z undid the marker after the card closed");
    typed_key(&h, InputKey::Character('z'), ctrl | InputModifiers::SHIFT, None);
    assert_eq!(undo_state(&h), Some((true, false)), "Ctrl+Shift+Z redid it");
}

/// The real app root at `scale` device pixels per point in a `w` x `h` point window.
fn scaled_window(scale: f32, w: i64, h: i64) -> Headless {
    let dir = crate::test_rig::unique_dir("sq-real-window-scaled");
    std::fs::create_dir_all(&dir).expect("dir");
    let clock = Arc::new(FakeClock::new());
    let mut deps = AppDeps::headless(Arc::clone(&clock) as _);
    deps.theme = sq_draw::DrawTheme { scale, ..sq_draw::DrawTheme::default() };
    let theme = deps.theme;
    let px = |v: i64| (v as f32 * scale) as i64;
    let app = Headless::new(demo_session(Scenario::Plain), deps, px(w), px(h));
    let root = crate::standard_root(&dir, clock, theme).expect("root");
    app.with(|a| {
        a.add_host(Box::new(root));
        a.launch();
    });
    app.turn();
    app
}

/// The Welcome tour's Skip button, clicked as the window sends the pointer (device pixels): press and release on it, with
/// and without a hover move before, on a normal and a short window at 1x, 1.5x and 2x.
#[test]
fn a_click_on_skip_closes_the_welcome_through_the_whole_app() {
    // (scale, window size in points, hover before the press)
    let cases = [
        (1.0f32, 1280, 800, true),
        (1.5, 1440, 900, true),
        (2.0, 1440, 900, true),
        (1.0, 1280, 800, false),
        (2.0, 1440, 900, false),
        (1.0, 1000, 520, false),
        (2.0, 900, 480, true),
    ];
    for (scale, w, h, hover) in cases {
        let app = scaled_window(scale, w, h);
        for _ in 0..4 {
            app.turn();
        }
        if !has_dialog(&app) {
            assert!(app.with(|a| a.shell_parts().shell.present_welcome_if_needed()).unwrap_or(false));
            for _ in 0..4 {
                app.turn();
            }
        }
        assert!(has_dialog(&app), "the welcome is up at scale {scale}");
        let skip =
            app.with(|a| a.shell_parts().shell.dialog().and_then(|d| d.button_frames().get(&1).copied())).flatten();
        let Some(skip) = skip else { panic!("the Skip button has a frame at scale {scale}") };
        let (x, y) = (skip.mid_x() as f32 * scale, skip.mid_y() as f32 * scale);
        if hover {
            app.input(&InputEvent::MouseMoved { x, y });
            app.turn();
        }
        app.input(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
        app.input(&InputEvent::MouseUp { x, y });
        for _ in 0..4 {
            app.turn();
        }
        assert!(!has_dialog(&app), "Skip closed the welcome at scale {scale} in {w}x{h}, hover first: {hover}");
    }
}
