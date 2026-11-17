//! Ported from the SQInspectorUI tests: EffectControlsGroupingTests, EffectControlsGestureEndTests,
//! EffectControlsKeyNudgeTests and the parameter-row cases of EffectParamRowsTests. The Swift `onEdit` closure that
//! feeds the clip back becomes `Rig::pump`, which applies the model's events the way the host does.

use std::collections::BTreeSet;

use sq_core_model::{BlendMode, Clip, ClipEffect, EffectColor, TrackKind};
use sq_core_time::{Id, Keyframe, KeyframeTrack, SequentialIds, Time, TimeRange};
use sq_editor_session::EffectSection;

use super::*;

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

fn clip(kind: TrackKind) -> Clip {
    Clip::new(Id::from_u128(1000), "c", Id::from_u128(1001), kind, TimeRange::new(Time::ZERO, s(10)), Time::ZERO)
}

fn clip_at(kind: TrackKind, start: i64) -> Clip {
    Clip::new(Id::from_u128(1000), "c", Id::from_u128(1001), kind, TimeRange::new(Time::ZERO, s(10)), s(start))
}

struct Rig {
    m: EffectControlsModel,
    edits: usize,
    ends: usize,
    names: Vec<(String, bool)>,
}

impl Rig {
    fn new() -> Rig {
        Rig { m: EffectControlsModel::new(Box::new(SequentialIds::default())), edits: 0, ends: 0, names: Vec::new() }
    }

    fn with(c: Clip) -> Rig {
        let mut r = Rig::new();
        r.m.set_clip(Some(c), None, Vec::new(), None);
        r
    }

    /// The host: applies every edit event back to the model (Swift `onEdit = { m.setClip($0) }`).
    fn pump(&mut self) {
        for ev in self.m.take_events() {
            match ev {
                EffectControlsEvent::Edit { clip, name, coalescing, .. } => {
                    self.edits += 1;
                    self.names.push((name, coalescing));
                    self.m.set_clip(Some(clip), None, Vec::new(), None);
                }
                EffectControlsEvent::GestureEnded => self.ends += 1,
                _ => {}
            }
        }
    }
}

fn rows(sections: Vec<EffectSection>) -> EffectRowsRequest {
    EffectRowsRequest::new(sections)
}

#[test]
fn motion_lists_opacity_directly_under_anchor_point() {
    assert_eq!(
        EffectSection::Motion.properties(),
        vec![
            EffectProperty::Position,
            EffectProperty::Scale,
            EffectProperty::Rotation,
            EffectProperty::TiltX,
            EffectProperty::TiltY,
            EffectProperty::Anchor,
            EffectProperty::Opacity,
            EffectProperty::ShutterAngle,
            EffectProperty::AntiFlicker,
        ]
    );
}

#[test]
fn video_clip_has_no_separate_opacity_section() {
    let r = Rig::with(clip(TrackKind::Video));
    assert_eq!(r.m.visible_sections(), vec![EffectSection::Motion]);
}

#[test]
fn rows_put_opacity_and_blend_mode_under_anchor() {
    let mut req = rows(vec![EffectSection::Motion]);
    req.blend_mode_row = true;
    let kinds: Vec<EffectRowKind> = EffectControlsLayout::rows(&req).into_iter().map(|r| r.kind).collect();
    assert_eq!(
        kinds,
        vec![
            EffectRowKind::Section(EffectSection::Motion),
            EffectRowKind::Property(EffectProperty::Position),
            EffectRowKind::Property(EffectProperty::Scale),
            EffectRowKind::Property(EffectProperty::Rotation),
            EffectRowKind::Property(EffectProperty::TiltX),
            EffectRowKind::Property(EffectProperty::TiltY),
            EffectRowKind::Property(EffectProperty::Anchor),
            EffectRowKind::Property(EffectProperty::Opacity),
            EffectRowKind::BlendMode,
            EffectRowKind::Property(EffectProperty::ShutterAngle),
            EffectRowKind::Property(EffectProperty::AntiFlicker),
        ]
    );
}

#[test]
fn group_headers_split_video_and_audio() {
    let mut req = rows(vec![EffectSection::Motion, EffectSection::Volume]);
    req.group_headers = true;
    let kinds: Vec<EffectRowKind> = EffectControlsLayout::rows(&req).into_iter().map(|r| r.kind).collect();
    assert_eq!(kinds[0], EffectRowKind::Group(EffectGroup::Video));
    assert_eq!(kinds[1], EffectRowKind::Section(EffectSection::Motion)); // board: VIDEO label above the first section
    let audio = kinds.iter().position(|k| *k == EffectRowKind::Group(EffectGroup::Audio));
    let volume = kinds.iter().position(|k| *k == EffectRowKind::Section(EffectSection::Volume));
    assert_eq!(audio, volume.map(|v| v - 1));
    assert_eq!(EffectControlsLayout::group_of(&EffectSection::Motion), EffectGroup::Video);
    assert_eq!(EffectControlsLayout::group_of(&EffectSection::Volume), EffectGroup::Audio);
}

#[test]
fn panel_header_names_the_first_side_so_only_the_second_repeats() {
    let kinds = |sections: Vec<EffectSection>| -> Vec<EffectRowKind> {
        let mut req = rows(sections);
        req.group_headers = true;
        req.first_group_header = false;
        EffectControlsLayout::rows(&req).into_iter().map(|r| r.kind).collect()
    };
    // Video and audio: one repeated "Audio" header, none above the first side.
    let both = kinds(vec![EffectSection::Motion, EffectSection::Volume]);
    assert_eq!(both[0], EffectRowKind::Section(EffectSection::Motion));
    let groups: Vec<&EffectRowKind> = both.iter().filter(|k| matches!(k, EffectRowKind::Group(_))).collect();
    assert_eq!(groups, vec![&EffectRowKind::Group(EffectGroup::Audio)]);
    let audio = both.iter().position(|k| *k == EffectRowKind::Group(EffectGroup::Audio));
    let volume = both.iter().position(|k| *k == EffectRowKind::Section(EffectSection::Volume));
    assert_eq!(audio, volume.map(|v| v - 1));
    // One side only: no repeated header at all.
    assert!(!kinds(vec![EffectSection::Motion]).contains(&EffectRowKind::Group(EffectGroup::Video)));
    assert_eq!(
        kinds(vec![EffectSection::Volume]),
        vec![EffectRowKind::Section(EffectSection::Volume), EffectRowKind::Property(EffectProperty::Volume)]
    );
}

#[test]
fn audio_clip_only_gets_audio_group_with_volume_row() {
    let mut req = rows(vec![EffectSection::Volume]);
    req.group_headers = true;
    let kinds: Vec<EffectRowKind> = EffectControlsLayout::rows(&req).into_iter().map(|r| r.kind).collect();
    assert_eq!(
        kinds,
        vec![
            EffectRowKind::Group(EffectGroup::Audio),
            EffectRowKind::Section(EffectSection::Volume),
            EffectRowKind::Property(EffectProperty::Volume)
        ]
    );
}

#[test]
fn audio_clip_shows_volume_keyframes() {
    let mut r = Rig::new();
    r.m.set_playhead(s(2));
    r.m.set_clip(Some(clip(TrackKind::Audio)), None, Vec::new(), None);
    assert_eq!(r.m.visible_sections(), vec![EffectSection::Volume]);
    assert_eq!(r.m.toggle_stopwatch(&EffectProperty::Volume, false), StopwatchOutcome::Added);
    r.pump();
    assert!(r.m.is_animated(&EffectProperty::Volume) && r.m.keys(&EffectProperty::Volume).len() == 1);
}

#[test]
fn resetting_motion_also_resets_opacity_and_blend() {
    let mut c = clip(TrackKind::Video);
    c.blend_mode = BlendMode::Multiply;
    let mut r = Rig::with(c);
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.4);
    r.pump();
    r.m.reset_section(&EffectSection::Motion);
    r.pump();
    assert!(r.m.clip().is_some_and(|c| c.blend_mode == BlendMode::Normal));
    assert_eq!(r.m.scalar_value(&EffectProperty::Opacity), 1.0);
}

#[test]
fn switch_symbol_is_not_the_premiere_fx() {
    assert_ne!(EffectControlsSwitch::symbol(true), EffectControlsSwitch::symbol(false));
}

#[test]
fn tilt_rows_are_scalar_degrees_in_motion() {
    for p in [EffectProperty::TiltX, EffectProperty::TiltY] {
        assert_eq!(p.kind(), EffectPropertyKind::Scalar);
        assert_eq!(p.section(), EffectSection::Motion);
        assert_eq!(p.display_unit(None), "\u{00B0}");
        assert_eq!(EffectProperty::from_raw_value(&p.raw_value()), Some(p.clone()));
        assert_eq!(p.clamped_native(200.0, None), 89.0);
        assert_eq!(p.clamped_native(-200.0, None), -89.0);
    }
    assert_eq!(EffectProperty::TiltX.title(), "Tilt X");
    assert_eq!(EffectProperty::TiltY.title(), "Tilt Y");
}

#[test]
fn raw_values_round_trip_for_every_kind_of_property() {
    let id = Id::from_u128(77);
    for p in [
        EffectProperty::Position,
        EffectProperty::Volume,
        EffectProperty::Fx { id, kind: "gaussianBlur".to_string(), key: "blurriness".to_string() },
        EffectProperty::Mask(id, MaskParam::Expansion),
        EffectProperty::MaskPath(id),
    ] {
        assert_eq!(EffectProperty::from_raw_value(&p.raw_value()), Some(p.clone()));
    }
    assert_eq!(EffectProperty::from_raw_value("nope"), None);
}

#[test]
fn display_units_follow_the_resolve_convention() {
    // Position shows y up, rotation counterclockwise positive; volume in dB with a floor.
    assert_eq!(EffectProperty::Position.display(10.0, EffectComponent::Y, None), -10.0);
    assert_eq!(EffectProperty::Position.display(10.0, EffectComponent::X, None), 10.0);
    assert_eq!(EffectProperty::Rotation.display(30.0, EffectComponent::All, None), -30.0);
    assert_eq!(EffectProperty::Opacity.display(0.5, EffectComponent::All, None), 50.0);
    assert_eq!(EffectProperty::Volume.display(0.0, EffectComponent::All, None), EffectProperty::SILENCE_DB);
    assert_eq!(EffectProperty::Volume.native_from_display(EffectProperty::SILENCE_DB, EffectComponent::All, None), 0.0);
    assert!((EffectProperty::Volume.native_from_display(0.0, EffectComponent::All, None) - 1.0).abs() < 1e-12);
}

// EffectControlsGestureEndTests

fn gesture_rig() -> Rig {
    let mut r = Rig::with(clip_at(TrackKind::Video, 5));
    r.m.set_playhead(s(5));
    r
}

#[test]
fn a_value_drag_ends_once() {
    let mut r = gesture_rig();
    r.m.begin_gesture();
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5);
    r.pump();
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.4);
    r.pump();
    assert!(r.edits == 2 && r.ends == 0);
    r.m.end_gesture();
    r.pump();
    assert_eq!(r.ends, 1);
    r.m.end_gesture();
    r.pump();
    assert_eq!(r.ends, 1);
}

#[test]
fn a_gesture_that_changed_nothing_stays_silent() {
    let mut r = gesture_rig();
    r.m.begin_gesture();
    r.m.end_gesture();
    r.m.begin_gesture();
    r.m.cancel_gesture();
    r.pump();
    assert!(r.edits == 0 && r.ends == 0);
}

#[test]
fn a_canceled_gesture_ends_too() {
    let mut r = gesture_rig();
    r.m.begin_gesture();
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5);
    r.pump();
    r.m.cancel_gesture();
    r.pump();
    assert!(r.ends == 1 && r.m.clip().is_some_and(|c| c.animation.opacity.value == 1.0));
}

#[test]
fn a_key_drag_ends_once_after_its_one_edit() {
    let mut r = gesture_rig();
    r.m.toggle_stopwatch(&EffectProperty::Opacity, false);
    r.pump();
    let id = r.m.clip().map(|c| c.animation.opacity.track.keys[0].id).unwrap_or(Id::from_u128(0));
    r.m.select_key(&EffectProperty::Opacity, id, false);
    let before = r.edits;
    r.m.begin_gesture();
    r.m.move_selection(s(2), false);
    r.m.end_key_move();
    r.pump();
    assert!(r.edits == before + 1 && r.ends == 1);
    // A drag that moved nothing: no edit, no end.
    r.m.begin_gesture();
    r.m.move_selection(Time::ZERO, false);
    r.m.end_key_move();
    r.pump();
    assert_eq!(r.ends, 1);
}

// EffectControlsKeyNudgeTests

fn nudge_rig() -> (Rig, Vec<Id>) {
    let mut c = clip_at(TrackKind::Video, 5);
    let ks = vec![
        Keyframe::new(Id::from_u128(11), s(1), 0.1),
        Keyframe::new(Id::from_u128(12), s(2), 0.2),
        Keyframe::new(Id::from_u128(13), s(3), 0.3),
    ];
    let ids: Vec<Id> = ks.iter().map(|k| k.id).collect();
    c.animation.opacity.track = KeyframeTrack::with_keys(ks);
    (Rig::with(c), ids)
}

fn times(r: &Rig) -> Vec<Time> {
    r.m.clip().map(|c| c.animation.opacity.track.keys.iter().map(|k| k.time).collect()).unwrap_or_default()
}

#[test]
fn nudges_by_whole_frames_as_one_edit_and_keeps_selection() {
    let (mut r, ids) = nudge_rig();
    let fd = r.m.frame_duration;
    r.m.set_selection_for(&EffectProperty::Opacity, &BTreeSet::from([ids[1]]));
    assert_eq!(r.m.nudge_selected_keys(1), fd);
    r.pump();
    assert_eq!(times(&r), vec![s(1), s(2) + fd, s(3)]);
    assert_eq!(r.edits, 1);
    assert_eq!(r.m.selected_key_ids(&EffectProperty::Opacity), BTreeSet::from([ids[1]]));
    assert_eq!(r.m.nudge_selected_keys(-10), fd * -10);
    r.pump();
    assert_eq!(times(&r)[1], s(2) + fd - fd * 10);
    assert_eq!(r.edits, 2);
}

#[test]
fn nudge_may_leave_the_clip() {
    let (mut r, ids) = nudge_rig();
    r.m.set_selection_for(&EffectProperty::Opacity, &BTreeSet::from([ids[0]]));
    r.m.nudge_selected_keys(-1000);
    r.pump();
    assert!(times(&r)[0] < Time::ZERO);
}

#[test]
fn nudge_never_merges_with_a_neighbor_key() {
    let (mut r, ids) = nudge_rig();
    r.m.set_selection_for(&EffectProperty::Opacity, &BTreeSet::from([ids[1]]));
    let one_second = r.m.frame_duration.timescale() / r.m.frame_duration.value().max(1);
    r.m.nudge_selected_keys(one_second); // exactly onto the key at 3 s
    r.pump();
    assert_eq!(times(&r).len(), 3);
    assert_eq!(times(&r).into_iter().collect::<BTreeSet<_>>().len(), 3);
}

#[test]
fn nudge_without_selection_does_nothing() {
    let (mut r, _) = nudge_rig();
    assert_eq!(r.m.nudge_selected_keys(1), Time::ZERO);
    r.pump();
    assert_eq!(r.edits, 0);
}

// EffectParamRowsTests (color and checkbox rows)

fn shadow_rig() -> (Rig, EffectSection) {
    use sq_core_effects::effects_editing::ClipEffectsEditingExt;
    let mut c = clip_at(TrackKind::Video, 5);
    let mut ids = SequentialIds::default();
    let id = c.add_effect(ClipEffect::DROP_SHADOW_KIND, None, &mut ids).unwrap_or(Id::from_u128(0));
    let mut r = Rig::with(c);
    r.m.set_playhead(s(6));
    (r, EffectSection::Effect { id, kind: ClipEffect::DROP_SHADOW_KIND.to_string() })
}

fn prop(s: &EffectSection, key: &str) -> EffectProperty {
    s.properties().into_iter().find(|p| p.raw_value().ends_with(key)).unwrap_or(EffectProperty::Position)
}

#[test]
fn colour_and_checkbox_rows_have_their_kinds() {
    let (_, sec) = shadow_rig();
    let color = prop(&sec, ClipEffect::SHADOW_COLOR_KEY);
    let only = prop(&sec, ClipEffect::SHADOW_ONLY_KEY);
    assert!(color.kind() == EffectPropertyKind::Color && !color.has_graph());
    assert!(matches!(only.param_kind(), Some(sq_core_model::EffectParamKind::Checkbox)) && !only.has_graph());
    assert!(prop(&sec, ClipEffect::SHADOW_OPACITY_KEY).has_graph());
    let mut req = rows(vec![sec]);
    req.expanded = BTreeSet::from([color, only]);
    assert!(!EffectControlsLayout::rows(&req).iter().any(|r| matches!(r.kind, EffectRowKind::Graph(_))));
}

#[test]
fn colour_sets_statically_then_keyframes() {
    let (mut r, sec) = shadow_rig();
    let p = prop(&sec, ClipEffect::SHADOW_COLOR_KEY);
    let red = EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    assert!(r.m.set_color(&p, red));
    r.pump();
    assert!(r.m.color_value(&p) == red && !r.m.is_animated(&p));
    assert!(!r.m.is_default(&p));
    assert_eq!(r.m.toggle_stopwatch(&p, false), StopwatchOutcome::Added);
    r.pump();
    r.m.set_playhead(s(8));
    assert!(r.m.set_color(&p, EffectColor::WHITE));
    r.pump();
    assert_eq!(r.m.track_of(&p).map(|t| t.key_ids().len()), Some(2));
    r.m.set_playhead(s(7));
    let mid = r.m.color_value(&p);
    assert!(mid.red == 1.0 && mid.green > 0.0 && mid.green < 1.0);
    r.m.reset_all(&p);
    r.pump();
    assert!(r.m.is_default(&p) && r.m.color_value(&p) == EffectColor::BLACK);
}

#[test]
fn text_slots_follow_transform_and_arrange_hides_while_transform_is_collapsed() {
    use super::layout::TextSlot;
    let kinds = |req: &EffectRowsRequest| -> Vec<EffectRowKind> {
        EffectControlsLayout::rows(req).into_iter().map(|r| r.kind).collect()
    };
    let mut req = rows(vec![EffectSection::Motion, EffectSection::Volume]);
    req.text_slots = (30.0, 50.0);
    let k = kinds(&req);
    let at = |kind: EffectRowKind| k.iter().position(|x| *x == kind).expect("row");
    let (arrange, animation) =
        (at(EffectRowKind::TextSlot(TextSlot::Arrange)), at(EffectRowKind::TextSlot(TextSlot::Animation)));
    assert_eq!(animation, arrange + 1);
    assert_eq!(
        arrange + 2,
        at(EffectRowKind::Section(EffectSection::Volume)),
        "both parts sit before the next section"
    );
    let out = EffectControlsLayout::rows(&req);
    let (a, v) = (&out[arrange], &out[arrange + 2]);
    assert_eq!((a.height, out[animation].height), (30.0, 50.0));
    assert!((v.y - (a.y + 80.0)).abs() < 1e-9, "the next section moves down by both parts");
    req.collapsed.insert(EffectSection::Motion);
    let k = kinds(&req);
    assert!(!k.contains(&EffectRowKind::TextSlot(TextSlot::Arrange)), "no Arrange while Transform is collapsed");
    assert!(k.contains(&EffectRowKind::TextSlot(TextSlot::Animation)), "Animation stays");
    req.text_slots = (0.0, 0.0);
    assert!(!kinds(&req).iter().any(|k| matches!(k, EffectRowKind::TextSlot(_))), "no text clip, no rows");
}

// MARK: Edits carry their base (stale-safe writes)

fn peer_clip() -> Clip {
    let mut c = clip(TrackKind::Video);
    c.id = Id::from_u128(2000);
    c
}

#[test]
fn an_edit_carries_the_clip_shown_before_it_as_its_base() {
    let mut r = Rig::with(clip(TrackKind::Video));
    let first = r.m.clip().cloned();
    assert!(r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5));
    let events = r.m.take_events();
    let [EffectControlsEvent::Edit { clip: edited, base, .. }] = events.as_slice() else {
        panic!("one Edit event, got {events:?}")
    };
    assert_eq!(*base, first, "the base is what the panel showed before the edit");
    assert_ne!(Some(edited), first.as_ref());
    // The next edit starts from the clip the panel shows now (it has not been polled back from the session).
    assert!(r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.25));
    let events = r.m.take_events();
    let [EffectControlsEvent::Edit { base, .. }] = events.as_slice() else { panic!("one Edit event, got {events:?}") };
    assert_eq!(base.as_ref(), Some(edited));
}

#[test]
fn an_edit_of_a_multi_selection_carries_the_shown_clip_and_every_peer_as_bases() {
    let (first, peer) = (clip(TrackKind::Video), peer_clip());
    let mut r = Rig::new();
    r.m.set_clip(Some(first.clone()), None, vec![peer.clone()], None);
    assert!(r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5));
    let events = r.m.take_events();
    let [EffectControlsEvent::EditMany { clips, bases, .. }] = events.as_slice() else {
        panic!("one EditMany event, got {events:?}")
    };
    assert_eq!(bases, &vec![first, peer], "the shown clip first, then the peers as they were");
    assert_eq!(clips.len(), bases.len());
}

#[test]
fn edits_under_a_video_clip_with_an_audio_partner_carry_the_part_each_event_changes() {
    let (video, mut partner) = (clip(TrackKind::Video), clip(TrackKind::Audio));
    partner.id = Id::from_u128(3000);
    let mut r = Rig::new();
    r.m.set_clip(Some(video.clone()), Some(partner.clone()), Vec::new(), None);
    assert!(r.m.set_value(&EffectProperty::Volume, EffectComponent::All, 0.5));
    let events = r.m.take_events();
    let [EffectControlsEvent::AudioEdit { clip: audio, base, .. }] = events.as_slice() else {
        panic!("one AudioEdit event, got {events:?}")
    };
    assert_eq!(base.as_ref(), Some(&partner), "the audio edit starts from the partner as it was");
    assert_ne!(audio.animation.volume, partner.animation.volume);
    // A video-side edit starts from the video clip without the partner's volume and audio effects.
    assert!(r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5));
    let events = r.m.take_events();
    let [EffectControlsEvent::Edit { base, .. }] = events.as_slice() else { panic!("one Edit event, got {events:?}") };
    assert_eq!(base.as_ref(), Some(&video));
}

// MARK: A drag keeps the edits other panels make while it is open

/// The session hands the panel its clip back with another panel's rename in it, in the middle of a drag.
fn rename_from_outside(r: &mut Rig, name: &str) {
    let mut renamed = r.m.clip().cloned().unwrap_or_else(|| clip(TrackKind::Video));
    renamed.name = name.to_string();
    r.m.set_clip(Some(renamed), None, Vec::new(), None);
}

#[test]
fn a_drag_step_after_an_outside_rename_keeps_the_name() {
    let mut r = gesture_rig();
    r.m.begin_gesture();
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5);
    r.pump();
    rename_from_outside(&mut r, "renamed");
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.4);
    r.pump();
    let shown = r.m.clip();
    assert_eq!(shown.map(|c| c.name.as_str()), Some("renamed"), "the next step must not put the old name back");
    assert_eq!(shown.map(|c| c.animation.opacity.value), Some(0.4));
}

#[test]
fn escape_after_an_outside_rename_restores_the_value_and_keeps_the_name() {
    let mut r = gesture_rig();
    r.m.begin_gesture();
    r.m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5);
    r.pump();
    rename_from_outside(&mut r, "renamed");
    r.m.cancel_gesture();
    r.pump();
    let shown = r.m.clip();
    assert_eq!(shown.map(|c| c.name.as_str()), Some("renamed"), "Escape restores the drag's value only");
    assert_eq!(shown.map(|c| c.animation.opacity.value), Some(1.0));
}

#[test]
fn a_multi_drag_keeps_an_outside_edit_of_a_peer() {
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.set_clip(Some(clip(TrackKind::Video)), None, vec![peer_clip()], None);
    m.begin_gesture();
    assert!(m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5));
    let shown = m.clip().cloned();
    let mut peers = m.peers().to_vec();
    for p in &mut peers {
        p.name = "renamed".to_string();
    }
    m.set_clip(shown, None, peers, None);
    assert!(m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.4));
    let step = m.peers().first().map(|p| (p.name.clone(), p.animation.opacity.value));
    assert_eq!(step, Some(("renamed".to_string(), 0.4)), "the next step keeps the peer's new name");
    m.cancel_gesture();
    let back = m.peers().first().map(|p| (p.name.clone(), p.animation.opacity.value));
    assert_eq!(back, Some(("renamed".to_string(), 1.0)), "Escape restores the value and keeps the name");
}
