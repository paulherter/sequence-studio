//! Headless tests of the Marker List panel.

use super::*;
use crate::test_rig::Rig;
use sq_core_time::{SequentialIds, Time};
use sq_editor_session::SessionDeps;

fn session_with_markers(seconds: &[i64]) -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-marker-list"));
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    for &t in seconds {
        s.seek(Time::new(t, 1));
        s.add_marker_at_playhead();
    }
    s
}

fn down(x: f32, y: f32) -> InputEvent {
    InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }
}

#[test]
fn an_empty_sequence_lists_nothing_and_a_click_selects_nothing() {
    let mut rig = Rig::new(session_with_markers(&[]));
    let mut h = MarkerListHost::new();
    h.layout(CGRect::new(0.0, 0.0, 500.0, 300.0), &mut rig.cx());
    assert!(h.model().entries().is_empty());
    assert!(h.handle(&down(100.0, 120.0), &mut rig.cx()));
    assert_eq!(h.selected_row(), None);
}

#[test]
fn a_click_on_a_row_goes_to_its_marker() {
    let mut rig = Rig::new(session_with_markers(&[1, 3]));
    let mut h = MarkerListHost::new();
    rig.session.seek(Time::ZERO);
    h.layout(CGRect::new(0.0, 0.0, 500.0, 300.0), &mut rig.cx());
    assert_eq!(h.model().entries().len(), 2);
    assert_eq!(h.selected_row(), None, "the playhead is before the first marker");
    // Rows start under the field (8 + 22 + 8) and the 24 pt header.
    let second = 8.0 + 22.0 + 8.0 + 24.0 + 24.0 + 10.0;
    assert!(h.handle(&down(100.0, second), &mut rig.cx()));
    assert_eq!(h.selected_row(), Some(1));
    assert_eq!(rig.session.playhead(), h.model().rows()[1].time, "the playhead sits on the marker");
}

#[test]
fn the_row_of_the_playhead_stays_selected_and_the_filter_narrows_the_rows() {
    let mut rig = Rig::new(session_with_markers(&[1, 3]));
    let mut h = MarkerListHost::new();
    rig.session.seek(Time::new(2, 1));
    h.layout(CGRect::new(0.0, 0.0, 500.0, 300.0), &mut rig.cx());
    assert_eq!(h.selected_row(), Some(0));
    // Click into the field, type a query no marker matches.
    assert!(h.handle(&down(60.0, 19.0), &mut rig.cx()));
    let key = InputEvent::KeyDown { key: InputKey::Character('z'), modifiers: InputModifiers::NONE };
    assert!(h.handle(&key, &mut rig.cx()));
    assert!(h.model().rows().is_empty());
    let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
    assert!(h.handle(&esc, &mut rig.cx()));
    assert_eq!(h.model().rows().len(), 2);
}

#[test]
fn export_without_markers_says_so() {
    let mut rig = Rig::new(session_with_markers(&[]));
    let h = MarkerListHost::new();
    h.export_csv(&mut rig.cx());
    assert!(matches!(rig.events.as_slice(), [AppEvent::Status(l)] if l == "There are no markers to export."));
}

#[test]
fn export_csv_lives_in_the_options_menu_and_runs_from_it() {
    let mut rig = Rig::new(session_with_markers(&[1]));
    let mut h = MarkerListHost::new();
    h.set_options_rect(Some(CGRect::new(470.0, 4.0, 22.0, 22.0)));
    h.layout(CGRect::new(0.0, 0.0, 500.0, 300.0), &mut rig.cx());
    // No button on the panel top bar any more: a click where it used to be is a plain click.
    assert!(h.take_menu().is_none());
    assert!(h.handle(&down(480.0, 15.0), &mut rig.cx()));
    let (items, _) = h.take_menu().expect("the ••• click opens the menu");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Export CSV\u{2026}");
    assert!(items[0].is_enabled);
    (items[0].action.as_ref().expect("action"))();
    h.pump(&mut rig.cx());
    // Nothing is chosen in the headless rig, so the run ends without a status line or a panic.
    assert!(!h.export_asked.get(), "the request was consumed");
}

#[test]
fn the_options_menu_disables_export_without_markers() {
    let h = MarkerListHost::new();
    assert!(!h.options_items()[0].is_enabled);
}

#[test]
fn a_column_head_click_sorts_and_flips_the_order() {
    let mut rig = Rig::new(session_with_markers(&[1, 3]));
    let mut h = MarkerListHost::new();
    h.layout(CGRect::new(0.0, 0.0, 500.0, 300.0), &mut rig.cx());
    let first = h.model().rows()[0].time;
    let head_y = 8.0 + 22.0 + 8.0 + 6.0;
    // The Time column starts after the 22 pt dot column.
    assert!(h.handle(&down(60.0, head_y), &mut rig.cx()));
    assert_eq!(h.model().sort, (MarkerSortKey::Time, false));
    assert_ne!(h.model().rows()[0].time, first, "descending puts the last marker first");
    assert!(h.handle(&down(60.0, head_y), &mut rig.cx()));
    assert_eq!(h.model().rows()[0].time, first);
}

#[test]
fn a_double_click_on_the_name_renames_the_marker_in_one_undo_step() {
    let mut rig = Rig::new(session_with_markers(&[1]));
    let mut h = MarkerListHost::new();
    h.layout(CGRect::new(0.0, 0.0, 500.0, 300.0), &mut rig.cx());
    let row_y = 8.0 + 22.0 + 8.0 + 24.0 + 10.0;
    let name_x = 22.0 + 84.0 + 30.0;
    assert!(h.handle(&down(name_x, row_y), &mut rig.cx()));
    assert!(h.renaming.is_none(), "one click only jumps");
    assert!(h.handle(&down(name_x, row_y), &mut rig.cx()));
    assert!(h.renaming.is_some(), "the second click opens the name field");
    let key = |k| InputEvent::KeyDown { key: k, modifiers: InputModifiers::NONE };
    assert!(h.handle(&key(InputKey::Character('Z')), &mut rig.cx()));
    assert!(h.handle(&key(InputKey::Enter), &mut rig.cx()));
    assert!(h.renaming.is_none());
    h.sync(&rig.session);
    assert!(h.model().entries()[0].name.ends_with('Z') || h.model().entries()[0].name == "Z");
}

#[test]
fn at_the_minimum_width_no_column_runs_past_the_panel() {
    let width = sq_uikit::panel_id::PanelID::MarkerList.min_size().0;
    assert_eq!(width, MIN_WIDTH);
    for total in [width, width + 1.0, 400.0, 900.0] {
        let w = MarkerListHost::column_widths(total);
        assert!(w.iter().sum::<f64>() <= total.max(w[..4].iter().sum()) + 0.001, "{w:?} at {total}");
        assert!(w[..4].iter().all(|c| *c >= 22.0), "{w:?}");
    }
    let narrow = MarkerListHost::column_widths(width);
    assert!(narrow[..4].iter().sum::<f64>() <= width, "{narrow:?}");
}

/// The hint never ends mid-word: every line is whole words (a cut one ends in an ellipsis after a whole word) and
/// fits the width, at any panel width.
#[test]
fn the_hint_breaks_at_word_boundaries() {
    let c = Canvas::with_size(400.0, 100.0, None, 1.0);
    let words: Vec<&str> = HINT.split(' ').collect();
    for width in [120.0, 180.0, 260.0, 400.0, 700.0] {
        let lines = hint_lines(&c, width, 11.0);
        assert!(lines.len() <= 2, "{width}: {lines:?}");
        for line in &lines {
            assert!(c.size_of(line, 11.0, 0).width <= width + 0.5, "{width}: {line:?} is too wide");
            for w in line.trim_end_matches('\u{2026}').split(' ').filter(|w| !w.is_empty()) {
                assert!(words.contains(&w), "{width}: {w:?} is a cut word in {lines:?}");
            }
        }
    }
}
