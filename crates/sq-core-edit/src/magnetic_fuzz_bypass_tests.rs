// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagneticBypassVerbsFuzzTests.swift
//
// Third Fast Cut gap fuzz: the Normal-engine verbs the session still calls directly (no `magnetic_edit` wrapper): split
// edits and J/L cuts, Trim mode, Snap/Cut to Beats, Move/Slip into Sync, Close Gap at the playhead, Detach Audio, Move Clip
// Up/Down, extend edit, with random track locks and sync-lock flags. After every applied op: V1 gains no hole, no overlap,
// nothing on a locked track changed. Attachments are not checked: these raw verbs leave them stale and the next
// `magnetic_edit` re-derives them.

use crate::magnetic_fuzz_tests::{holes, make, on_main, placed};
use crate::sync_offsets::SyncOffsetsExt as _;
use crate::timeline_beat_markers::TimelineBeatMarkersExt as _;
use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_cut_keys::{JLCut, TimelineCutKeysExt as _};
use crate::timeline_cut_to_beats::TimelineCutToBeatsExt as _;
use crate::timeline_fuzz_tests::{Lcg, fd, problems};
use crate::timeline_magnetic::{MagneticExt as _, MagneticScope, MagneticStay};
use crate::timeline_magnetic_moves::MagneticGesturesExt as _;
use crate::timeline_magnetic_ops::MagneticOpsExt as _;
use crate::timeline_magnetic_verbs::MagneticVerbsExt as _;
use crate::timeline_mute_detach::TimelineMuteDetachExt as _;
use crate::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt as _};
use crate::timeline_sync::TimelineSyncExt as _;
use crate::timeline_three_point::TimelineThreePointExt as _;
use crate::timeline_trim_mode::{TimelineTrimModeExt as _, TrimPoint, TrimSide};
use sq_core_model::{Clip, ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::collections::BTreeSet;

type Edit = Box<dyn FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>>;
type Setup = Box<dyn FnOnce(&mut Timeline, &mut dyn IdSource)>;

/// Beat markers at random times, set before the edit runs.
fn beats(rng: &mut Lcg, end_frames: usize) -> Setup {
    let n = 2 + rng.int(8);
    let times: Vec<Time> = (0..n).map(|_| fd() * rng.int(end_frames + 20) as i64).collect();
    Box::new(move |t, ids| {
        let range = TimeRange::new(Time::ZERO, t.main_track_end() + fd() * 40);
        t.replace_beat_markers(range, &times, ids);
    })
}

fn run(seed: u64, steps: usize) {
    let mut rng = Lcg(seed.wrapping_mul(6_151));
    let mut ids = SequentialIds::default();
    for _ in 0..(seed % 5) * 1000 {
        ids.next_id();
    }
    let mut tl = make(seed, &mut ids);
    let (mut applied, mut log) = (0usize, Vec::<String>::new());
    for step in 0..steps {
        let all: Vec<Clip> = tl.tracks.iter().flat_map(|x| x.clips().to_vec()).collect();
        let Some(mi) = tl.main_track_index().filter(|&mi| !tl.tracks[mi].clips().is_empty() && all.len() < 50) else {
            tl = make(seed + step as u64 + 7000, &mut ids);
            continue;
        };
        let main: Vec<Clip> = tl.tracks[mi].clips().to_vec();
        let end_frames = tl.main_track_end().frame_index(fd()).max(1) as usize;
        let at = fd() * rng.int(end_frames + 10) as i64;
        let d = fd() * (rng.int(41) as i64 - 20);
        let any = all[rng.int(all.len())].clone();
        let main_clip = main[rng.int(main.len())].clone();
        let sel: BTreeSet<Id> = if rng.chance(2) {
            BTreeSet::from([any.id])
        } else {
            all.iter().filter(|_| rng.chance(6)).map(|c| c.id).collect()
        };
        let mut setup: Option<Setup> = None;
        let (name, edit): (String, Edit);
        match rng.int(24) {
            0 | 1 => {
                let side = if rng.chance(2) { SplitEditSide::Audio } else { SplitEditSide::Video };
                let cuts: Vec<Time> = main.iter().skip(1).map(|c| c.start).collect();
                let cut = if cuts.is_empty() { at } else { cuts[rng.int(cuts.len())] };
                name = "split edit".into();
                edit = Box::new(move |t, _| t.split_edit(cut, side, cut + d, None).map(drop));
            }
            2 => {
                let k = if rng.chance(2) { JLCut::JCut } else { JLCut::LCut };
                name = "jl".into();
                edit = Box::new(move |t, _| t.split_edit_jl(k, at).map(drop));
            }
            3..=5 => {
                let ti = rng.int(tl.tracks.len());
                let tr = &tl.tracks[ti];
                if tr.clips().is_empty() {
                    continue;
                }
                let c = &tr.clips()[rng.int(tr.clips().len())];
                let prev = tr.clips().iter().find(|p| p.timeline().end() == c.start);
                let side = [TrimSide::Outgoing, TrimSide::Incoming, TrimSide::Roll][rng.int(3)];
                let outgoing = if rng.chance(4) { None } else { prev.map(|p| p.id) };
                let p = TrimPoint { track: tr.id, outgoing, incoming: Some(c.id), time: c.start };
                name = format!("trim edit {side:?} on T{ti}");
                edit = Box::new(move |t, ids| t.trim_edit(&p, side, d, ids).map(drop));
            }
            6 | 7 => {
                name = "snap to beats".into();
                setup = Some(beats(&mut rng, end_frames));
                let v: Vec<Id> = sel.iter().copied().collect();
                edit = Box::new(move |t, ids| t.snap_to_beats(&v, ids).map(drop));
            }
            8 => {
                name = "cut to beats".into();
                setup = Some(beats(&mut rng, end_frames));
                edit = Box::new(move |t, ids| t.cut_to_beats(&sel, ids).map(drop));
            }
            9..=11 => {
                // Drift a clip out of sync, then bring it back with Move into Sync / Slip into Sync.
                let slip = rng.chance(2);
                let pick = if rng.chance(2) { main_clip.clone() } else { any.clone() };
                if pick.link.is_none() {
                    continue;
                }
                let k = fd() * (1 + rng.int(6)) as i64;
                name = format!("{} into sync", if slip { "slip" } else { "move" });
                let pid = pick.id;
                setup = Some(Box::new(move |t, _| {
                    let Some(ti) = t.tracks.iter().position(|x| x.clip(pid).is_some()) else { return };
                    let Some(mut c) = t.tracks[ti].clip(pid).cloned() else { return };
                    if c.media_duration.is_some_and(|md| c.source.end() + k > md) {
                        c.source.start -= k;
                    } else {
                        c.source.start += k;
                    }
                    if c.source.start >= Time::ZERO {
                        t.tracks[ti].replace(c);
                    }
                }));
                edit = Box::new(move |t, ids| {
                    let offsets = t.sync_offsets();
                    if slip { t.slip_into_sync(pid, &offsets) } else { t.move_into_sync(pid, &offsets, ids) }
                });
            }
            12 | 13 => {
                // The session guards Close Gap in Fast Cut (Delete Spacer); the raw verb only runs on tracks with a gap.
                name = "delete spacer".into();
                edit = Box::new(move |t, ids| t.delete_spacer(at, false, ids).map(drop));
            }
            14 => {
                name = "detach audio".into();
                edit = Box::new(move |t, _| t.detach_audio(&sel).map(drop));
            }
            15 | 16 => {
                let up = rng.chance(2);
                // A main-track clip going up is Lift off Main Track: its spacer stays by design.
                let lift = up && sel.iter().any(|id| on_main(&tl, *id));
                name = if lift {
                    "spacer lane up".into()
                } else {
                    format!("move to lane {}", if up { "up" } else { "down" })
                };
                edit = Box::new(move |t, ids| t.magnetic_move_to_lane(&sel, up, ids).map(drop));
            }
            17 => {
                let i = rng.int(tl.tracks.len());
                name = "toggle lock".into();
                edit = Box::new(move |t, _| {
                    t.tracks[i].is_locked = !t.tracks[i].is_locked;
                    Ok(())
                });
            }
            18 => {
                let i = rng.int(tl.tracks.len());
                name = "toggle sync lock".into();
                edit = Box::new(move |t, _| {
                    t.tracks[i].sync_lock = !t.tracks[i].sync_lock;
                    Ok(())
                });
            }
            19 => {
                let e = if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail };
                let id = main_clip.id;
                name = "extend edit".into();
                let scope = MagneticScope { stay: MagneticStay::All, ..MagneticScope::default() };
                edit = Box::new(move |t, ids| t.magnetic_edit(scope, ids, |t, _| t.extend_edit(id, e, at).map(drop)));
            }
            20 => {
                let e = if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail };
                name = "ripple trim to playhead".into();
                edit = Box::new(move |t, ids| t.magnetic_ripple_trim_to_playhead(e, at, None, false, ids).map(drop));
            }
            21 => {
                name = "add edit all".into();
                edit = Box::new(move |t, ids| t.magnetic_add_edit_all(at, ids).map(drop));
            }
            22 => {
                let link = any.link;
                let group: BTreeSet<Id> =
                    all.iter().filter(|c| link.is_some() && c.link == link).map(|c| c.id).collect();
                name = "unlink group".into();
                edit = Box::new(move |t, _| t.unlink(&group));
            }
            _ => {
                let picked: BTreeSet<Id> =
                    main.iter().filter(|c| c.start >= main_clip.start).take(2).map(|c| c.id).collect();
                name = format!("nudge {}", picked.len());
                edit = Box::new(move |t, ids| t.magnetic_nudge(&picked, d, ids));
            }
        }
        log.push(format!("{step}: {name}"));
        let mut work = tl.clone();
        if let Some(s) = setup {
            s(&mut work, &mut ids);
        }
        let t0 = work.clone();
        if edit(&mut work, &mut ids).is_err() || work == t0 {
            tl = t0;
            continue;
        }
        applied += 1;
        let tail = log[log.len().saturating_sub(6)..].join(" | ");
        let probs = problems(&work);
        assert!(probs.is_empty(), "seed {seed} step {step}: {name}: {probs:?}\n{tail}");
        assert!(
            name.starts_with("spacer") || holes(&work) <= holes(&t0),
            "seed {seed} step {step}: V1 gained a hole after {name}: {:?} -> {:?}\n{tail}",
            holes(&t0),
            holes(&work)
        );
        if !name.starts_with("toggle") {
            let (b0, b1) = (placed(&t0), placed(&work));
            for tk in t0.tracks.iter().filter(|t| t.is_locked) {
                for c in tk.clips() {
                    assert!(
                        b0.get(&c.id) == b1.get(&c.id),
                        "seed {seed} step {step}: {name} changed a clip on a locked track\n{tail}"
                    );
                }
            }
        }
        // A spacer (Lift off Main Track) leaves a hole by design; later ops on a holey V1 may widen it, so start over.
        tl = if holes(&work) == Time::ZERO { work } else { make(seed + step as u64 + 9000, &mut ids) };
    }
    assert!(applied > steps / 10, "seed {seed}: too little applied ({applied})");
}

#[test]
fn direct_session_verbs_keep_fast_cut_gapless() {
    for seed in 201..=206u64 {
        run(seed, 300);
    }
}
