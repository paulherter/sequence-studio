//! Tests of the Effects host: the ghost follows the drag, and drops and double clicks change the session with undo.

use super::*;
use crate::test_rig::Rig;
use sq_core_time::{SequentialIds, Time};
use sq_draw::InputModifiers;
use sq_draw_monitor::memory_defaults::MemoryDefaults;
use sq_editor_session::SessionDeps;
use std::collections::BTreeSet;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-effects-tests"));
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        let c = sq_core_model::Clip::new(
            Id::from_u128(1),
            "clip",
            Id::from_u128(101),
            TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        assert!(t.tracks[0].insert(c, &mut ids).is_ok());
    });
    s.take_changes();
    s
}

fn with_clip_selected(s: &mut EditorSession) {
    s.select(BTreeSet::from([Id::from_u128(1)]), BTreeSet::new());
}

fn effects_count(s: &EditorSession) -> usize {
    s.active_timeline().map_or(0, |t| t.tracks[0].clips().iter().map(|c| c.effects.len()).sum())
}

fn apply<'a>() -> EffectsApply<'a> {
    EffectsApply { presets: &[], mode: ApplyMode::Absolute, transitions: TransitionDefaults::STANDARD, edges: None }
}

fn host() -> EffectsHost {
    EffectsHost::new(EffectsDrawPanel::new(Box::new(MemoryDefaults::default()), Box::new(SequentialIds::default())))
}

#[test]
fn the_ghost_shows_on_the_first_move_follows_and_goes_on_release() {
    let mut rig = Rig::new(session());
    let mut h = host();
    h.layout(CGRect::new(20.0, 10.0, 300.0, 600.0), &mut rig.cx());
    let folders: Vec<String> = h.inner.panel.rows().iter().filter(|r| r.is_folder).map(|r| r.id.clone()).collect();
    for f in &folders {
        if !h.inner.panel.expanded().contains(f) {
            h.inner.panel.toggle_folder(f);
        }
    }
    let i = h.inner.panel.rows().iter().position(|r| !r.is_header && !r.is_folder).expect("an item row");
    let row = h.inner.panel.row_rect(i);
    let (x, y) = ((20.0 + row.min_x() + 30.0) as f32, (10.0 + row.min_y() + 8.0) as f32);
    h.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    assert!(!h.is_dragging(), "a press alone is no drag");
    h.handle(&InputEvent::dragged(x + 60.0, y + 5.0), &mut rig.cx());
    assert!(h.is_dragging(), "the ghost shows at the first move");
    let at = CGPoint::new(f64::from(x + 60.0), f64::from(y + 5.0));
    assert!(matches!(h.take_events().as_slice(), [EffectsDeferred::Moved(ids, p)] if !ids.is_empty() && *p == at));
    h.handle(&InputEvent::MouseUp { x: 600.0, y: 300.0 }, &mut rig.cx());
    assert!(!h.is_dragging());
    assert!(matches!(h.take_events().as_slice(), [EffectsDeferred::Dropped(_, p)] if p.x == 600.0 && p.y == 300.0));
}

#[test]
fn a_double_click_applies_an_effect_to_the_selection_with_undo() {
    let mut s = session();
    with_clip_selected(&mut s);
    let blur = vec!["gaussianBlur".to_string()];
    assert_eq!(apply_to_selection(&mut s, &blur, &apply()), None);
    assert_eq!(effects_count(&s), 1);
    assert!(s.undo_name().is_some_and(|n| n.contains("Blur")));
    s.undo();
    assert_eq!(effects_count(&s), 0);
}

#[test]
fn applying_without_a_selection_says_so() {
    let mut s = session();
    let status = apply_to_selection(&mut s, &["gaussianBlur".to_string()], &apply());
    assert_eq!(status.as_deref(), Some("Select a video clip first, then double-click Blur."));
    assert_eq!(effects_count(&s), 0);
}

#[test]
fn a_drop_on_a_clip_adds_the_effect_to_that_clip_with_one_undo_step() {
    let mut s = session();
    let status = apply_drop(&mut s, &["gaussianBlur".to_string()], EffectDrop::Clip(Id::from_u128(1)), &apply());
    assert_eq!(status, None);
    assert_eq!(effects_count(&s), 1);
    s.undo();
    assert_eq!(effects_count(&s), 0);
}

#[test]
fn saved_presets_are_listed_again_after_the_library_changes() {
    let now = sq_core_time::Timestamp::from_reference_seconds(0.0);
    let mut h = host();
    let base = h.panel_host().panel.all_entries().len();
    let warm = PresetItem::new(Id::from_u128(7), PresetKind::Effect, "Warm", now, Vec::new(), 1);
    h.list_presets(std::slice::from_ref(&warm));
    let entries = h.panel_host().panel.all_entries();
    assert_eq!(entries.len(), base + 1);
    assert!(entries.iter().any(|e| e.title == "Warm"));
    let mut renamed = warm;
    renamed.name = "Cool".to_string();
    h.list_presets(&[renamed]);
    let titles: Vec<_> = h.panel_host().panel.all_entries().into_iter().map(|e| e.title).collect();
    assert!(titles.contains(&"Cool".to_string()) && !titles.contains(&"Warm".to_string()));
    h.list_presets(&[]);
    assert_eq!(h.panel_host().panel.all_entries().len(), base);
}

#[test]
fn rows_are_nodes_a_click_opens_folders_and_applies_items() {
    let mut rig = Rig::new(session());
    let mut h = host();
    h.layout(CGRect::new(0.0, 0.0, 300.0, 600.0), &mut rig.cx());
    let node = |h: &EffectsHost, pick: &dyn Fn(&sq_draw_library::effects::effects_catalog::EffectsRow) -> bool| {
        let r = h.inner.panel.rows().iter().find(|r| pick(r)).cloned().expect("row");
        (sq_draw::A11y::node_id("effects", accesskit::Role::ListItem, &r.id), r)
    };
    let mut a = sq_draw::A11y::new(true);
    h.a11y(&mut a);
    assert!(a.nodes().iter().any(|(_, n)| n.role() == accesskit::Role::List));
    let (folder_id, folder) = node(&h, &|r| r.is_folder || r.is_header);
    let was = h.inner.panel.expanded().contains(&folder.id);
    assert!(h.a11y_action(folder_id, sq_app_shell::A11yAction::Click, &mut rig.cx()));
    assert_ne!(was, h.inner.panel.expanded().contains(&folder.id), "the folder toggles");
    let (item_id, item) = node(&h, &|r| !r.is_folder && !r.is_header);
    assert!(h.a11y_action(item_id, sq_app_shell::A11yAction::Click, &mut rig.cx()));
    assert_eq!(h.inner.panel.selected_id(), Some(item.id.as_str()));
    assert!(matches!(h.take_events().as_slice(), [EffectsDeferred::Apply(_)]));
}

#[test]
fn a_drop_on_the_clip_shown_in_effect_controls_adds_the_effect_in_one_undo_step() {
    let mut s = session();
    let targets = BTreeSet::from([Id::from_u128(1)]);
    assert_eq!(drop_on_clips(&mut s, &["gaussianBlur".to_string()], &targets, &apply()), None);
    assert_eq!(effects_count(&s), 1);
    s.undo();
    assert_eq!(effects_count(&s), 0);
}

#[test]
fn a_refused_drop_on_clips_names_the_effect_and_what_it_needs_and_transitions_are_skipped() {
    let mut s = session();
    let targets = BTreeSet::from([Id::from_u128(1)]);
    let status = drop_on_clips(&mut s, &["nope".to_string()], &targets, &apply());
    assert_eq!(status.as_deref(), Some("nope needs a video clip."));
    assert_eq!(drop_on_clips(&mut s, &["gaussianBlur".to_string()], &BTreeSet::new(), &apply()), None);
    assert_eq!(effects_count(&s), 0);
}
