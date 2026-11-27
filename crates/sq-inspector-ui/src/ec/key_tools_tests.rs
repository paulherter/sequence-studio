//! Ported from EffectControlsKeyToolsTests (the dialog-number cases live next to `KeyToolsInput`).

use sq_core_model::keyframes_editing::{PropertyTrack, SummaryMember};
use sq_core_model::keyframes_speed_overlay::KeySide;
use sq_core_model::{Clip, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_uikit::keyframe_graph_geometry::GraphMode;

use crate::ec::effect_controls_model::core::{EffectControlsEvent, EffectControlsModel};
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
use crate::ec::key_tools::GraphHandleReadout;

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

/// The host applies every edit back to the model (Swift `onEdit = { m.setClip($0) }`).
fn pump(m: &mut EffectControlsModel) {
    for ev in m.take_events() {
        if let EffectControlsEvent::Edit { clip, .. } = ev {
            m.set_clip(Some(clip), None, Vec::new(), None);
        }
    }
}

fn animated() -> EffectControlsModel {
    let c = Clip::new(
        Id::from_u128(900),
        "c",
        Id::from_u128(901),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, s(10)),
        s(5),
    );
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.set_clip(Some(c), None, Vec::new(), None);
    m.set_playhead(s(5));
    m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.1);
    pump(&mut m);
    m.toggle_stopwatch(&EffectProperty::Opacity, false);
    pump(&mut m);
    m.set_playhead(s(7));
    m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5);
    pump(&mut m);
    m.set_playhead(s(9));
    m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.9);
    pump(&mut m);
    m
}

fn opacity_ids(m: &EffectControlsModel) -> Vec<Id> {
    m.track_of(&EffectProperty::Opacity).map(|t| t.key_ids()).unwrap_or_default()
}

fn select_all(m: &mut EffectControlsModel) {
    let v: Vec<SummaryMember> =
        opacity_ids(m).into_iter().map(|id| SummaryMember::new(EffectProperty::Opacity.id(), id)).collect();
    m.select(&v, false);
}

fn key_count(m: &EffectControlsModel) -> usize {
    opacity_ids(m).len()
}

#[test]
fn per_property_graph_mode_leaves_others_alone() {
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.set_graph_mode_for(GraphMode::Value, &EffectProperty::Opacity);
    assert_eq!(m.graph_mode_for(&EffectProperty::Opacity), GraphMode::Value);
    assert_eq!(m.graph_mode_for(&EffectProperty::Scale), GraphMode::Speed);
    assert_eq!(m.graph_mode, GraphMode::Speed);
}

#[test]
fn time_scale_doubles_distance_from_first_selected_key() {
    let mut m = animated();
    select_all(&mut m);
    assert!(m.scale_selection_time(2, 1));
    pump(&mut m);
    let Some(PropertyTrack::Scalar(t)) = m.track_of(&EffectProperty::Opacity) else { panic!("scalar track") };
    assert_eq!(t.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![s(0), s(4), s(8)]);
}

#[test]
fn loop_repeats_pattern() {
    let mut m = animated();
    select_all(&mut m);
    assert!(m.loop_selected_tracks(1));
    pump(&mut m);
    assert_eq!(key_count(&m), 5);
}

#[test]
fn convert_to_keys_samples_range() {
    let mut m = animated();
    select_all(&mut m);
    assert!(m.bake_selected_keys(10));
    pump(&mut m);
    assert_eq!(key_count(&m), 41);
}

#[test]
fn wiggle_on_number_track_is_deterministic() {
    let mut m = animated();
    select_all(&mut m);
    assert!(m.has_selected_scalar_key());
    assert!(m.wiggle_selected_keys(4, 0.1, 3));
    pump(&mut m);
    assert_eq!(key_count(&m), 17);
}

#[test]
fn velocity_keeps_influence_and_sets_speed_relative_to_segment() {
    let mut m = animated();
    let ids = opacity_ids(&m);
    let member = SummaryMember::new(EffectProperty::Opacity.id(), ids[0]);
    m.select(std::slice::from_ref(&member), false);
    // Segment 0.1 -> 0.5 over 2 s: average 0.2 per s (opacity shows x100: 20 %/s). 40 %/s is twice the average.
    assert!(m.set_graph_velocity(40.0, 0.5, KeySide::Outgoing));
    pump(&mut m);
    let Some(PropertyTrack::Scalar(t)) = m.track_of(&EffectProperty::Opacity) else { panic!("scalar track") };
    assert!((t.keys[0].out_handle.dx - 0.5).abs() < 1e-9);
    assert!((t.keys[0].out_handle.dy - 1.0).abs() < 1e-6);
    let v = m.graph_velocity(&member, KeySide::Outgoing);
    assert!(v.is_some_and(|v| (v.influence - 0.5).abs() < 1e-6));
}

#[test]
fn handle_readout_names_speed_and_influence() {
    let text = GraphHandleReadout::text("Opacity", 12.5, 0.33, "%");
    assert!(text.starts_with("Opacity\n"));
    assert!(text.contains("%/s") && text.contains("33 %"));
}

#[test]
fn graph_snap_targets_clip_ends() {
    let mut m = animated();
    m.graph_snap = true;
    let ids = opacity_ids(&m);
    m.select(&[SummaryMember::new(EffectProperty::Opacity.id(), ids[2])], false);
    m.begin_gesture();
    // Key at 4 s; clip lasts 10 s. A move of 5.9 s lands exactly on the end with a 0.2 s tolerance.
    m.move_graph_selection(5.9, Some(0.2));
    m.end_graph_key_move();
    pump(&mut m);
    let Some(PropertyTrack::Scalar(t)) = m.track_of(&EffectProperty::Opacity) else { panic!("scalar track") };
    assert_eq!(t.keys.last().map(|k| k.time), Some(s(10)));
}

/// Shutter Angle typed in the inspector on a moving clip reaches the clip and opens the motion blur samples.
#[test]
fn a_shutter_angle_set_in_the_inspector_opens_the_motion_blur_of_a_moving_clip() {
    use sq_core_effects::effect_transform_stage::ClipStageEval;
    use sq_core_model::SequenceFormat;
    let c = Clip::new(
        Id::from_u128(900),
        "c",
        Id::from_u128(901),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, s(10)),
        s(5),
    );
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.set_clip(Some(c), None, Vec::new(), None);
    m.set_playhead(s(5));
    m.set_value(&EffectProperty::Rotation, EffectComponent::All, 0.0);
    pump(&mut m);
    m.toggle_stopwatch(&EffectProperty::Rotation, false);
    pump(&mut m);
    m.set_playhead(s(7));
    m.set_value(&EffectProperty::Rotation, EffectComponent::All, 90.0);
    pump(&mut m);
    m.set_value(&EffectProperty::ShutterAngle, EffectComponent::All, 180.0);
    let mut edited = None;
    for ev in m.take_events() {
        if let EffectControlsEvent::Edit { clip, .. } = ev {
            edited = Some(clip);
        }
    }
    let clip = edited.expect("the shutter edit reaches the host");
    assert_eq!(clip.animation.shutter_angle.value, 180.0);
    let mut format = SequenceFormat::new(Time::new(1, 25));
    (format.width, format.height) = (320, 180);
    assert!(clip.motion_blur(s(6), Time::new(1, 25), &format, 1.0).is_some(), "180 degrees must blur");
}
