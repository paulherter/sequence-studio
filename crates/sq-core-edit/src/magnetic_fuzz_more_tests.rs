// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagneticInvariantFuzzMoreVerbsTests.swift
//
// Second invariant fuzz of the Fast Cut verbs: speed keys, speed and reverse, frame holds, nest and unnest, transitions,
// link / unlink / add track, caption edits, locked tracks and `editing_only` moves of linked audio, mixed with delete,
// ripple trim and rearrange so the verbs meet transitions. After every applied op V1 is gapless (the sequence starts
// gapless and none of these makes a spacer), attachments are valid, no clip of a locked track changed, linked groups keep
// their offsets (the group an op edits on purpose is exempt) and caption edits leave every clip alone.

use crate::grouping::ProjectGroupingExt as _;
use crate::magnetic_fuzz_tests::{attachment_problems, holes, link_offsets, make, placed};
use crate::timeline_add_track::AddTrackExt as _;
use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_edits::SlipKeyframes;
use crate::timeline_fuzz_tests::{Lcg, fd, problems};
use crate::timeline_magnetic_moves::MagneticGesturesExt as _;
use crate::timeline_magnetic_ops::MagneticOpsExt as _;
use crate::timeline_magnetic_verbs::{MagneticNestExt as _, MagneticVerbsExt as _};
use crate::timeline_solo::SoloExt as _;
use crate::timeline_speed::SpeedChange;
use sq_core_audio::timeline_caption_edits::TimelineCaptionEditsExt as _;
use sq_core_effects::transition::{NewTransition, TimelineTransitions as _};
use sq_core_model::{
    CaptionItem, Clip, ClipEdge, ClipSpeed, EditError, Project, SpeedKeys, Timeline, TrackKind, TransitionAlignment,
    TransitionKind,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::collections::BTreeSet;

type Edit = Box<dyn FnOnce(&mut Project, &mut dyn IdSource) -> Result<(), EditError>>;

fn on_timeline(f: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError> + 'static) -> Edit {
    Box::new(move |p, ids| f(&mut p.timelines[0], ids))
}

fn fresh_project(tl: Timeline, ids: &mut impl IdSource) -> Project {
    Project::new(ids.next_id(), "P", Vec::new(), vec![tl])
}

/// A generated sequence with a dissolve at some cuts and a caption track of four items.
fn start(seed: u64, rng: &mut Lcg, ids: &mut SequentialIds) -> Timeline {
    let mut tl = make(seed, ids);
    for ti in 0..tl.tracks.len() {
        let kind = if tl.tracks[ti].kind == TrackKind::Video {
            TransitionKind::CrossDissolve
        } else {
            TransitionKind::ConstantPower
        };
        let (track, clips) = (tl.tracks[ti].id, tl.tracks[ti].clips().to_vec());
        for w in clips.windows(2).filter(|w| w[0].timeline().end() == w[1].start) {
            if rng.chance(3) {
                let new = NewTransition {
                    kind,
                    track,
                    outgoing: Some(w[0].id),
                    incoming: Some(w[1].id),
                    duration: fd() * (2 + rng.int(8)) as i64,
                    alignment: TransitionAlignment::Center,
                    custom_before: Time::ZERO,
                };
                let _ = tl.add_transition(&new, ids);
            }
        }
    }
    let cap = tl.add_caption_track(ids);
    let items: Vec<CaptionItem> = (0..4)
        .map(|i| CaptionItem {
            id: ids.next_id(),
            lines: vec![format!("c{i}")],
            range: TimeRange::new(fd() * (i * 40), fd() * 30),
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        })
        .collect();
    let _ = tl.replace_captions(items, Some(cap), ids);
    tl
}

fn run(seed: u64, steps: usize) {
    let mut rng = Lcg(seed.wrapping_mul(4_241));
    let mut ids = SequentialIds::default();
    for _ in 0..(seed % 5) * 1000 {
        ids.next_id();
    }
    let tl0 = start(seed, &mut rng, &mut ids);
    let first = [problems(&tl0), attachment_problems(&tl0)].concat();
    assert!(first.is_empty() && holes(&tl0) == Time::ZERO, "seed {seed}: generated {first:?}");
    let mut project = fresh_project(tl0, &mut ids);
    let (mut applied, mut log) = (0usize, Vec::<String>::new());
    for step in 0..steps {
        let t0 = project.timelines[0].clone();
        let all: Vec<Clip> = t0.tracks.iter().flat_map(|x| x.clips().to_vec()).collect();
        let main_ok = t0.main_track_index().is_some_and(|mi| !t0.tracks[mi].clips().is_empty());
        if !t0.is_fast_cut() || all.is_empty() || all.len() >= 50 || t0.tracks.len() >= 9 || !main_ok {
            project = fresh_project(make(seed + step as u64 + 5000, &mut ids), &mut ids);
            log.push(format!("{step}: fresh"));
            continue;
        }
        let Some(mi) = t0.main_track_index() else { continue };
        let main: Vec<Clip> = t0.tracks[mi].clips().to_vec();
        let any = all[rng.int(all.len())].clone();
        let main_clip = main[rng.int(main.len())].clone();
        let linked_audio: Vec<&Clip> = all
            .iter()
            .filter(|a| a.kind == TrackKind::Audio && a.link.is_some() && main.iter().any(|m| m.link == a.link))
            .collect();
        let audio: Option<Clip> = (!linked_audio.is_empty()).then(|| linked_audio[rng.int(linked_audio.len())].clone());
        let end_frames = t0.main_track_end().frame_index(fd()).max(1) as usize;
        let at = fd() * rng.int(end_frames + 10) as i64;
        let d = fd() * (rng.int(41) as i64 - 20);
        let pct = [25.0, 50.0, 100.0, 150.0, 250.0, 400.0][rng.int(6)];
        let tr = t0.tracks[rng.int(t0.tracks.len())].clone();
        let (name, mut group, mut caption_op): (String, Option<Id>, bool);
        group = None;
        caption_op = false;
        let edit: Edit;
        let tl_id = t0.id;
        let (any_id, main_id) = (any.id, main_clip.id);
        let speed = ClipSpeed::from_percent(pct);
        let edge = if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail };
        match rng.int(30) {
            0 | 1 => {
                name = format!("speed {pct}% on any");
                group = any.link;
                edit = on_timeline(move |t, ids| {
                    t.magnetic_apply(&SpeedChange { speed: Some(speed), ..SpeedChange::default() }, &[any_id], ids)
                });
            }
            2 => {
                name = "reverse main".into();
                group = main_clip.link;
                edit = on_timeline(move |t, ids| {
                    t.magnetic_apply(&SpeedChange { reversed: Some(true), ..SpeedChange::default() }, &[main_id], ids)
                });
            }
            3 | 4 => {
                name = format!("speed keys add+set {pct}%");
                group = any.link;
                edit = on_timeline(move |t, ids| {
                    let f = |k: &SpeedKeys| {
                        let (k2, b) = k.adding_key(k.duration().halved().snapped(fd()), fd())?;
                        Some(k2.setting_speed(b, speed, fd()))
                    };
                    t.magnetic_edit_speed_keys(any_id, false, false, f, ids).map(drop)
                });
            }
            5..=7 => {
                let local = fd() * rng.int(30) as i64;
                name = format!("set key value {pct}%");
                group = any.link;
                edit = on_timeline(move |t, ids| {
                    t.magnetic_edit_speed_keys(any_id, true, true, |k| k.setting_key_speed(local, speed, fd()), ids)
                        .map(drop)
                });
            }
            8 => {
                name = "remove speed key".into();
                group = any.link;
                edit = on_timeline(move |t, ids| {
                    let f = |k: &SpeedKeys| if k.segments.len() > 1 { k.removing_key(1) } else { None };
                    t.magnetic_edit_speed_keys(any_id, false, false, f, ids).map(drop)
                });
            }
            9 => {
                name = "remove ramp".into();
                group = any.link;
                edit = on_timeline(move |t, ids| {
                    let f = |k: &SpeedKeys| {
                        let h = k.hull();
                        Some(SpeedKeys::constant(ClipSpeed::NORMAL, false, h.duration, h.start))
                    };
                    t.magnetic_edit_speed_keys(any_id, false, false, f, ids).map(drop)
                });
            }
            10 => {
                let l = fd() * (1 + rng.int(15)) as i64;
                name = "insert hold".into();
                edit = on_timeline(move |t, ids| t.magnetic_insert_frame_hold(Some(any_id), at, l, ids).map(drop));
            }
            11 => {
                name = "add hold".into();
                edit = on_timeline(move |t, ids| t.magnetic_add_frame_hold(Some(any_id), at, ids).map(drop));
            }
            12 => {
                let n = 1 + rng.int(3);
                let picked: Vec<Id> =
                    main.iter().filter(|c| c.start >= main_clip.start).take(n).map(|c| c.id).collect();
                name = format!("nest {}", picked.len());
                edit = Box::new(move |p, ids| p.magnetic_nest(&picked, tl_id, None, ids).map(drop));
            }
            13 => {
                let Some(n) = all.iter().find(|c| c.sequence.is_some()) else { continue };
                let nid = n.id;
                name = "unnest".into();
                edit = Box::new(move |p, ids| p.unnest(nid, tl_id, ids).map(drop));
            }
            14 | 15 => {
                let kind = if tr.kind == TrackKind::Video {
                    TransitionKind::CrossDissolve
                } else {
                    TransitionKind::ConstantPower
                };
                let cl = tr.clips();
                if cl.len() < 2 {
                    continue;
                }
                let k = rng.int(cl.len() - 1);
                let new = NewTransition {
                    kind,
                    track: tr.id,
                    outgoing: Some(cl[k].id),
                    incoming: Some(cl[k + 1].id),
                    duration: fd() * (2 + rng.int(10)) as i64,
                    alignment: TransitionAlignment::Center,
                    custom_before: Time::ZERO,
                };
                name = format!("transition at cut {k}");
                edit = on_timeline(move |t, ids| t.add_transition(&new, ids).map(drop));
            }
            16 => {
                let Some(x) = tr.transitions.first() else { continue };
                let xid = x.id;
                name = "remove transition".into();
                edit = on_timeline(move |t, _| t.remove_transition(xid));
            }
            17 => {
                name = "unlink".into();
                edit = on_timeline(move |t, _| t.unlink(&BTreeSet::from([any_id])));
            }
            18 => {
                // A pair that plays together: a clip of the other kind overlapping a main clip.
                let Some(m) = main.iter().find(|m| m.kind != any.kind && m.timeline().contains(any.start)) else {
                    continue;
                };
                let mid = m.id;
                name = "link".into();
                edit = on_timeline(move |t, ids| t.link(&BTreeSet::from([any_id, mid]), ids));
            }
            19 => {
                let k = if rng.chance(2) { TrackKind::Video } else { TrackKind::Audio };
                name = "add track".into();
                edit = on_timeline(move |t, ids| {
                    t.add_track(k, ids);
                    Ok(())
                });
            }
            20 => {
                let Some(ct) = t0.caption_tracks.first().filter(|c| !c.items().is_empty()) else { continue };
                let cid = ct.items()[rng.int(ct.items().len())].id;
                caption_op = true;
                match rng.int(3) {
                    0 => {
                        name = "move caption".into();
                        edit = on_timeline(move |t, _| t.move_caption(cid, at).map(drop));
                    }
                    1 => {
                        name = "trim caption".into();
                        edit = on_timeline(move |t, _| t.trim_caption(cid, edge, at).map(drop));
                    }
                    _ => {
                        name = "delete caption".into();
                        edit = on_timeline(move |t, _| t.delete_caption(cid));
                    }
                }
            }
            21 => {
                // Lock / unlock a track (V1 included: every verb then refuses).
                let i = rng.int(t0.tracks.len());
                name = format!("toggle lock T{i}");
                edit = on_timeline(move |t, _| {
                    t.tracks[i].is_locked = !t.tracks[i].is_locked;
                    Ok(())
                });
            }
            22 | 23 => {
                let Some(a) = &audio else { continue };
                let aid = a.id;
                name = "only move audio".into();
                group = a.link;
                edit = on_timeline(move |t, ids| {
                    t.editing_only(&BTreeSet::from([aid]), ids, |t, ids| t.move_attached(aid, at, None, ids))
                });
            }
            24 => {
                let Some(a) = &audio else { continue };
                let aid = a.id;
                name = "only ripple trim audio".into();
                group = a.link;
                edit = on_timeline(move |t, ids| {
                    t.editing_only(&BTreeSet::from([aid]), ids, |t, ids| {
                        t.magnetic_ripple_trim(aid, edge, d, ids).map(drop)
                    })
                });
            }
            25 => {
                let Some(a) = &audio else { continue };
                let aid = a.id;
                name = "only delete audio".into();
                group = a.link;
                edit = on_timeline(move |t, ids| {
                    t.editing_only(&BTreeSet::from([aid]), ids, |t, ids| {
                        t.magnetic_delete(&BTreeSet::from([aid]), false, ids)
                    })
                });
            }
            26 => {
                let Some(a) = &audio else { continue };
                let aid = a.id;
                name = "only slip audio".into();
                group = a.link;
                edit = on_timeline(move |t, ids| {
                    t.editing_only(&BTreeSet::from([aid]), ids, |t, ids| {
                        t.magnetic_slip(aid, d, SlipKeyframes::Stay, ids).map(drop)
                    })
                });
            }
            27 => {
                name = "delete main".into();
                edit = on_timeline(move |t, ids| t.magnetic_delete(&BTreeSet::from([main_id]), false, ids));
            }
            28 => {
                name = "ripple trim main".into();
                edit = on_timeline(move |t, ids| t.magnetic_ripple_trim(main_id, edge, d, ids).map(drop));
            }
            _ => {
                name = "rearrange main".into();
                edit = on_timeline(move |t, ids| t.magnetic_rearrange(main_id, at, false, ids));
            }
        }
        log.push(format!("{step}: {name}"));
        let tail = |log: &Vec<String>| log[log.len().saturating_sub(10)..].join(" | ");
        let mut p = project.clone();
        if edit(&mut p, &mut ids).is_err() {
            continue;
        }
        let after = p.timelines[0].clone();
        if after == t0 {
            continue;
        }
        applied += 1;
        let lock_toggle = name.starts_with("toggle lock");
        let mut probs = problems(&after);
        if after.is_fast_cut() {
            probs.extend(attachment_problems(&after));
        }
        assert!(probs.is_empty(), "seed {seed}: after {name}: {probs:?}\n{}", tail(&log));
        assert!(holes(&after) == Time::ZERO, "seed {seed}: V1 gained a hole after {name}\n{}", tail(&log));
        assert!(!caption_op || after.tracks == t0.tracks, "seed {seed}: {name} moved clips");
        let (b0, b1) = (placed(&t0), placed(&after));
        if !lock_toggle {
            for tk in t0.tracks.iter().filter(|t| t.is_locked) {
                for c in tk.clips() {
                    assert!(
                        b0.get(&c.id) == b1.get(&c.id),
                        "seed {seed}: {name} changed a clip on a locked track\n{}",
                        tail(&log)
                    );
                }
            }
        }
        // Linked groups other than the edited one keep their offsets.
        let structural = ["link", "unlink", "nest", "unnest", "toggle"].iter().any(|s| name.starts_with(s));
        if !structural {
            let o0 = link_offsets(&t0);
            for (k, v) in link_offsets(&after) {
                let Some(&was) = o0.get(&k) else { continue };
                if was == v || (if was < Time::ZERO { Time::ZERO - was } else { was }) > fd() * 10 {
                    continue;
                }
                let ids2 = [k.0, k.1];
                let same = |id: &Id| b0.get(id).zip(b1.get(id)).is_some_and(|(x, y)| x.1 == y.1 && x.2 == y.2);
                if !ids2.iter().all(same) {
                    continue;
                }
                if group.is_some() && t0.find(k.0).map(|m| m.clip.link) == Some(group) {
                    continue;
                }
                if ids2.iter().any(|id| t0.find(*id).is_some_and(|m| t0.tracks[m.track].is_locked)) {
                    continue;
                }
                panic!("seed {seed}: {name}: linked pair {k:?} changed offset {was:?} -> {v:?}\n{}", tail(&log));
            }
        }
        project = p;
    }
    assert!(applied > steps / 8, "seed {seed}: too little applied ({applied})");
}

#[test]
fn more_verbs_keep_fast_cut_gapless_and_in_sync() {
    for seed in 201..=206u64 {
        run(seed, 300);
    }
}
