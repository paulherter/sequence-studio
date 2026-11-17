// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: TransitionLayerTests (model and evaluation; resize needs Timeline.trim, see notes/eb.md)

use super::*;
use crate::transition::tests::{f, fd, ids, range};
use crate::transition::{RenderStyle, TransitionKindExt, TransitionRender};
use TransitionKind as K;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{Clip, EditError, Project, SequenceFormat, Timeline, Track, TrackKind, TransitionAlignment};
use sq_core_time::{Id, TimeRange};

const TL: Id = Id::from_u128(700);

fn track_id(i: u128) -> Id {
    Id::from_u128(800 + i)
}

/// V1..V4 take pictures and layers, V5 is audio.
fn project() -> Project {
    let tracks: Vec<Track> =
        (0..5).map(|i| Track::new(track_id(i), if i < 4 { TrackKind::Video } else { TrackKind::Audio })).collect();
    Project::new(Id::from_u128(1), "P", Vec::new(), vec![Timeline::new(TL, "T", SequenceFormat::new(fd()), tracks)])
}

fn media(n: u128, start: i64, frames: i64, source_start: i64) -> Clip {
    Clip::new(Id::from_u128(n), "m", Id::from_u128(1000 + n), TrackKind::Video, range(source_start, frames), f(start))
}

fn at(track: u128, start: i64, frames: i64) -> GeneratorPlacement {
    GeneratorPlacement { timeline: TL, track: track_id(track), start: f(start), duration: f(frames) }
}

fn layer(p: &Project, id: Id) -> Clip {
    p.timeline(TL).unwrap().tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id).unwrap().clone()
}

/// A on V1 0..30, B on V1 30..60, a b-roll on V2 over the whole range, a transition layer on V3 at frames 20..40 (cut 30).
fn stack(kind: TransitionKind) -> (Project, Id) {
    let mut p = project();
    p.edit(TL, |t| {
        t.tracks[0].overwrite(media(1, 0, 30, 0), &mut ids())?;
        t.tracks[0].overwrite(media(2, 30, 30, 100), &mut ids())?;
        t.tracks[1].overwrite(media(3, 0, 60, 0), &mut ids())
    })
    .unwrap();
    let id = p.add_transition_layer(kind, at(2, 20, 20), &mut ids()).unwrap();
    (p, id)
}

fn edit(p: &mut Project, body: impl FnOnce(&mut Timeline) -> Result<(), EditError>) {
    p.edit(TL, body).unwrap();
}

#[test]
fn placing_creates_a_generator_clip_with_its_cut_in_the_middle() {
    let (p, id) = stack(K::CrossDissolve);
    let c = layer(&p, id);
    assert!(c.is_transition_layer() && c.is_generator() && c.kind == TrackKind::Video);
    assert_eq!(c.name, "Transition Layer");
    assert_eq!(c.timeline(), range(20, 20));
    assert_eq!(c.transition_layer().unwrap().kind, K::CrossDissolve);
    assert_eq!(c.transition_layer_cut(), Some(f(30)));
    let r = c.resolved_transition_layer(fd()).unwrap();
    assert!(r.cut == f(30) && r.span == c.timeline() && r.before == f(10) && r.after == f(10));
    assert!(r.frames() == 20 && r.alignment == TransitionAlignment::Center);
}

#[test]
fn placing_an_odd_length_puts_the_cut_on_a_frame_before_the_middle() {
    let mut p = project();
    let id = p.add_transition_layer(K::Push, at(0, 0, 7), &mut ids()).unwrap();
    assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(3)));
}

#[test]
fn refuses_audio_tracks_and_kinds_without_two_pictures() {
    let mut p = project();
    assert_eq!(p.add_transition_layer(K::CrossDissolve, at(4, 0, 10), &mut ids()), Err(EditError::WrongTrackKind));
    for k in [K::Stinger, K::Move, K::Zoom, K::Pop, K::ConstantPower] {
        assert!(!k.is_layer_kind());
        assert_eq!(p.add_transition_layer(k, at(0, 0, 10), &mut ids()), Err(EditError::WrongTrackKind));
    }
    assert!(K::layer_kinds().contains(&K::CrossDissolve) && K::layer_kinds().contains(&K::Whip));
    assert_eq!(p.add_transition_layer(K::CrossDissolve, at(0, 0, 0), &mut ids()), Err(EditError::EmptyClip));
}

#[test]
fn moving_the_cut_clamps_to_the_clip_and_snaps_to_frames() {
    let (mut p, id) = stack(K::CrossDissolve);
    let mut set = |t: Time| {
        let mut applied = Time::ZERO;
        edit(&mut p, |tl| {
            applied = tl.set_transition_layer_cut(id, t)?;
            Ok(())
        });
        applied
    };
    assert_eq!(set(f(25) + Time::new(1, 100)), f(25));
    assert_eq!(set(f(5)), f(20));
    assert_eq!(set(f(90)), f(40));
    let alignment = |p: &Project| layer(p, id).resolved_transition_layer(fd()).unwrap().alignment;
    assert_eq!(alignment(&p), TransitionAlignment::EndAtCut);
    edit(&mut p, |tl| tl.set_transition_layer_cut(id, f(25)).map(|_| ()));
    assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(25)));
    assert_eq!(alignment(&p), TransitionAlignment::Custom);
    edit(&mut p, |tl| tl.set_transition_layer_cut(id, f(5)).map(|_| ()));
    assert_eq!(alignment(&p), TransitionAlignment::StartAtCut);
    // Not a transition layer.
    let other = Id::from_u128(1);
    assert_eq!(p.edit(TL, |tl| tl.set_transition_layer_cut(other, f(3)).map(|_| ())), Err(EditError::ClipNotFound));
}

#[test]
fn a_cut_outside_the_clip_resolves_at_the_nearest_edge() {
    // The clip was trimmed to 20..<25 while the stored cut (source time) still says 30.
    let (mut p, id) = stack(K::CrossDissolve);
    let mut c = layer(&p, id);
    c.source.duration = f(5);
    edit(&mut p, |t| {
        t.tracks[2].replace(c.clone());
        Ok(())
    });
    let r = layer(&p, id).resolved_transition_layer(fd()).unwrap();
    assert!(r.cut == f(25) && r.after == Time::ZERO && r.before == f(5));
}

#[test]
fn a_layer_shorter_than_a_frame_resolves_to_nothing() {
    let (p, id) = stack(K::CrossDissolve);
    let mut c = layer(&p, id);
    c.source.duration = Time::new(1, 60);
    assert!(c.resolved_transition_layer(fd()).is_none());
    // An unknown kind (a stinger cannot be a layer) resolves to nothing too.
    let mut l = layer(&p, id).transition_layer().unwrap();
    l.kind = K::Stinger;
    let mut c2 = layer(&p, id);
    c2.generator.as_mut().unwrap().payload = l.payload();
    assert!(c2.resolved_transition_layer(fd()).is_none());
}

#[test]
fn alignment_moves_the_clip_around_a_fixed_cut() {
    let (mut p, id) = stack(K::CrossDissolve);
    let mut align = |a| edit(&mut p, |t| t.set_transition_layer_alignment(id, a));
    align(TransitionAlignment::StartAtCut);
    assert_eq!(layer(&p, id).timeline(), range(30, 20));
    assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(30)));
    edit(&mut p, |t| t.set_transition_layer_alignment(id, TransitionAlignment::EndAtCut));
    assert_eq!(layer(&p, id).timeline(), range(10, 20));
    edit(&mut p, |t| t.set_transition_layer_alignment(id, TransitionAlignment::Center));
    assert_eq!(layer(&p, id).timeline(), range(20, 20));
    assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(30)));
}

#[test]
fn a_neighbour_in_the_way_is_a_collision() {
    let (mut p, id) = stack(K::CrossDissolve);
    edit(&mut p, |t| t.tracks[2].overwrite(media(9, 42, 5, 0), &mut ids()));
    assert_eq!(p.edit(TL, |t| t.set_transition_layer_duration(id, f(40))), Err(EditError::Collision));
    assert_eq!(layer(&p, id).timeline(), range(20, 20), "nothing changed");
}

#[test]
fn duration_keeps_the_cut_and_the_split() {
    let (mut p, id) = stack(K::CrossDissolve);
    edit(&mut p, |t| t.set_transition_layer_cut(id, f(25)).map(|_| ())); // 5 before, 15 after
    edit(&mut p, |t| t.set_transition_layer_duration(id, f(40)));
    assert_eq!(layer(&p, id).timeline(), TimeRange::from_end(f(15), f(55)));
    assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(25)));
}

#[test]
fn style_edits_change_only_the_style() {
    let (mut p, id) = stack(K::CrossDissolve);
    edit(&mut p, |t| {
        t.set_transition_layer(id, |s| {
            s.kind = K::Push;
            s.direction = Some(TransitionDirection::Up);
            s.motion_blur = Some(1.0);
        })
    });
    let c = layer(&p, id);
    let l = c.transition_layer().unwrap();
    assert!(l.kind == K::Push && l.direction == Some(TransitionDirection::Up));
    assert!(c.timeline() == range(20, 20) && c.transition_layer_cut() == Some(f(30)));
    assert_eq!(p.edit(TL, |t| t.set_transition_layer(id, |s| s.kind = K::Stinger)), Err(EditError::WrongTrackKind));
    assert_eq!(layer(&p, id).transition_layer().unwrap().kind, K::Push, "refused edits change nothing");
}

#[test]
fn dissolve_weights_follow_the_span_like_a_cut_transition() {
    let (p, id) = stack(K::CrossDissolve);
    let r = layer(&p, id).resolved_transition_layer(fd()).unwrap();
    let w = TransitionMix::video_weight(0, 20);
    let render = stack_render(&r, 0);
    assert_eq!(render.compose, Compose::Sum);
    assert!((render.outgoing.opacity - (1.0 - w)).abs() < 1e-9 && (render.incoming.opacity - w).abs() < 1e-9);
}

#[test]
fn motion_kinds_use_the_shared_transition_render() {
    let (p, id) = stack(K::Push);
    let r = layer(&p, id).resolved_transition_layer(fd()).unwrap();
    let e = K::Push.default_easing();
    let style = RenderStyle::new(
        K::Push,
        TransitionDirection::Left,
        TransitionKind::DEFAULT_SOFTNESS,
        K::Push.default_motion_blur(),
        &e,
    );
    assert_eq!(stack_render(&r, 5), TransitionRender::evaluate(&style, 5, 20));
}

#[test]
fn dips_mix_through_the_dip_colour() {
    let (p, id) = stack(K::DipToWhite);
    let r = layer(&p, id).resolved_transition_layer(fd()).unwrap();
    let m = TransitionMix::video(K::DipToWhite, TransitionMix::video_weight(2, 20));
    let render = stack_render(&r, 2);
    assert_eq!(render.compose, Compose::Sum);
    assert!((render.outgoing.opacity - m.outgoing).abs() < 1e-9 && (render.incoming.opacity - m.incoming).abs() < 1e-9);
}

#[test]
fn every_layer_kind_evaluates_on_every_frame() {
    for k in K::layer_kinds() {
        let mut p = project();
        let id = p.add_transition_layer(k, at(1, 0, 12), &mut ids()).unwrap();
        let r = layer(&p, id).resolved_transition_layer(fd()).unwrap();
        assert!(r.kind == k && r.frames() == 12);
        for i in 0..12 {
            let _ = stack_render(&r, i);
        }
    }
}

#[test]
fn the_active_layer_is_the_enabled_one_under_the_time() {
    let (mut p, id) = stack(K::CrossDissolve);
    let tl = p.timeline(TL).unwrap();
    assert_eq!(tl.tracks[2].active_transition_layer(f(25)).map(|c| c.id), Some(id));
    assert!(tl.tracks[2].active_transition_layer(f(10)).is_none());
    assert!(tl.tracks[0].active_transition_layer(f(10)).is_none(), "a picture clip is no layer");
    let mut c = layer(&p, id);
    c.is_enabled = false;
    edit(&mut p, |t| {
        t.tracks[2].replace(c.clone());
        Ok(())
    });
    assert!(p.timeline(TL).unwrap().tracks[2].active_transition_layer(f(25)).is_none());
}

#[test]
fn the_payload_round_trips_and_marks_the_project() {
    let (p, id) = stack(K::Whip);
    assert!(p.contains_transition_layers());
    assert!(!project().contains_transition_layers());
    let l = layer(&p, id).transition_layer().unwrap();
    assert_eq!(TransitionLayer::decode(&l.payload()), Some(l));
    assert_eq!(TransitionLayer::decode(b"not json"), None);
}

#[test]
fn reversed_layers_travel_the_other_way() {
    let (mut p, id) = stack(K::Push);
    edit(&mut p, |t| t.set_transition_layer(id, |s| s.reversed = Some(true)));
    let r = layer(&p, id).resolved_transition_layer(fd()).unwrap();
    assert_eq!(r.direction, TransitionDirection::Right);
}
