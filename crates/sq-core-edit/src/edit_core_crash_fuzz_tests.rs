// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EditCoreCrashFuzzTests.swift
//
// Crash fuzz for the edit core: seeded random edits (split, trim, ripple, roll, slip, slide, move, speed incl. ramps and
// speed-key edits, reverse, rate stretch, paste, jump cut, close gap, lift/extract, J/L split edits, keys, undo/redo) over
// generated timelines with linked A/V, speed ramps and keyframes. Every input must apply or return an `EditError`; after
// every step the timeline must be valid: no overlap, every clip longer than zero, speed keys inside the clip and its media.
// Seeds 1, 5: whole-frame edits without retiming (clip edges stay on the frame grid); 4, 8: off-frame drags.

use crate::history::History;
use crate::jump_cut::TimelineJumpCutExt as _;
use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_cut_keys::{JLCut, TimelineCutKeysExt as _};
use crate::timeline_edit_targets::TimelineEditTargetsExt as _;
use crate::timeline_edits::{SlipKeyframes, TimelineEditsExt as _};
use crate::timeline_fuzz_tests::{Lcg, fd};
use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use crate::timeline_speed::{SpeedChange, TimelineSpeedExt as _};
use crate::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt as _};
use crate::timeline_three_point::TimelineThreePointExt as _;
use sq_core_model::{Clip, ClipEdge, ClipSpeed, EditError, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

const SEEDS: u64 = 8;
const STEPS: usize = 400;

/// Whole frames (+-max); with `off_frame`, sometimes an off-frame time (a drag at sample precision).
fn delta(rng: &mut Lcg, max: usize, off_frame: bool) -> Time {
    let f = fd() * (rng.int(max * 2 + 1) as i64 - max as i64);
    if off_frame && rng.chance(8) { f + Time::new(rng.int(1600) as i64 - 800, 48_000) } else { f }
}

fn make(seed: u64, retime: bool, ids: &mut impl IdSource) -> Timeline {
    let mut rng = Lcg(seed.wrapping_mul(104_729));
    let mut tracks: Vec<Track> = [TrackKind::Video, TrackKind::Video, TrackKind::Audio, TrackKind::Audio]
        .into_iter()
        .map(|k| Track::new(ids.next_id(), k))
        .collect();
    for lane in 0..2usize {
        let mut t = fd() * rng.int(4) as i64;
        for _ in 0..5 {
            let len = fd() * (8 + rng.int(60) as i64);
            let (media, link) = (ids.next_id(), ids.next_id());
            let handle = fd() * rng.int(30) as i64;
            let md = handle + len + fd() * rng.int(30) as i64;
            for (track, kind) in [(lane, TrackKind::Video), (lane + 2, TrackKind::Audio)] {
                let mut c = Clip::new(ids.next_id(), "c", media, kind, TimeRange::new(handle, len), t);
                c.media_duration = Some(md);
                c.link = Some(link);
                let mut clips = tracks[track].clips().to_vec();
                clips.push(c);
                tracks[track].set_clips(clips);
            }
            t += len + if rng.chance(2) { Time::ZERO } else { fd() * rng.int(12) as i64 };
        }
    }
    let mut tl = Timeline::new(ids.next_id(), "Fuzz", SequenceFormat::new(fd()), tracks);
    if retime {
        let video: Vec<Id> = tl
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| t.clips().iter().map(|c| c.id))
            .collect();
        for id in video {
            match rng.int(5) {
                0 => drop(tl.apply_speed_change(
                    &SpeedChange {
                        speed: Some(ClipSpeed::from_percent((25 + rng.int(300)) as f64)),
                        ..SpeedChange::default()
                    },
                    id,
                )),
                1 => drop(tl.apply_speed_change(&SpeedChange { reversed: Some(true), ..SpeedChange::default() }, id)),
                2 => drop(tl.edit_speed_keys(id, false, false, |k| {
                    let (k2, b) = k.adding_key(k.duration().halved(), fd())?;
                    let k3 = k2.setting_speed(b, ClipSpeed::from_percent(250.0), fd());
                    Some(k3.splitting_key(b, fd() * 2, fd()).unwrap_or(k3))
                })),
                _ => {}
            }
        }
    }
    tl
}

/// `whole_frames`: every input was on frames and nothing was retimed, so every clip edge stays on the frame grid and every
/// clip is at least one frame long. Otherwise edges may leave the grid legitimately (a retimed clip's media limit is
/// `handle / speed`, an audio edit at sample precision) and a clip only has to stay longer than zero. `slack` is how far a
/// source edge may pass the media edge (rounding of chained fractions).
fn problems(t: &Timeline, whole_frames: bool, slack: Time) -> Vec<String> {
    let mut out = Vec::new();
    for (i, tr) in t.tracks.iter().enumerate() {
        if !tr.is_consistent() {
            out.push(format!("track {i} overlaps or starts before 0"));
        }
        for c in tr.clips() {
            let d = c.timeline().duration;
            let f = t.frame_duration();
            if whole_frames && (c.start != c.start.snapped(f) || d != d.snapped(f)) {
                out.push(format!("track {i}: clip off the frame grid {:?}+{d:?}", c.start));
            }
            if if whole_frames { d < f } else { d <= Time::ZERO } {
                out.push(format!("track {i}: clip too short {d:?}"));
            }
            if let Some(k) = &c.speed_keys {
                if k.segments.is_empty() {
                    out.push(format!("track {i}: speed track without segments"));
                }
                if k.segments.iter().any(|s| s.duration <= Time::ZERO) {
                    out.push(format!("track {i}: empty speed segment"));
                }
                if c.source != k.hull() {
                    out.push(format!("track {i}: source is not the speed track's hull"));
                }
                // Speed-key positions are stored rounded to 2^-20 s: a clip trimmed to the media edge may show its hull one
                // tick past it.
                let tick = slack.max(Time::new(1, 1 << 20));
                if k.hull().start < Time::ZERO - tick || c.media_duration.is_some_and(|m| k.hull().end() > m + tick) {
                    out.push(format!("track {i}: speed keys visit source outside the media {:?}", k.hull()));
                }
            } else if c.hold_frame.is_none() && !c.is_generator() && !c.is_still {
                if c.source.start < Time::ZERO - slack {
                    out.push(format!("track {i}: source before the media start"));
                }
                if c.media_duration.is_some_and(|m| c.source.end() > m + slack) {
                    out.push(format!("track {i}: source beyond the media end"));
                }
            }
        }
    }
    out
}

fn run(seed: u64) {
    let mut rng = Lcg(seed.wrapping_mul(7919));
    let (off_frame, whole_frames) = (seed.is_multiple_of(4), seed % 4 == 1);
    let slack = if off_frame { Time::new(1, 1_000_000) } else { Time::ZERO };
    let mut ids = SequentialIds::default();
    let first = make(seed, !whole_frames, &mut ids);
    assert!(problems(&first, whole_frames, Time::ZERO).is_empty(), "seed {seed}: generated timeline invalid");
    let mut hist = History::new(first, 50);
    let (mut applied, mut log) = (0usize, Vec::<String>::new());
    for step in 0..STEPS {
        let t0 = hist.current().clone();
        let all: Vec<Clip> = t0.tracks.iter().flat_map(|t| t.clips().to_vec()).collect();
        // Keep the timeline small (paste and jump cut grow it): start over from a fresh one.
        if all.is_empty() || all.len() > 80 || t0.tracks.len() > 10 {
            hist = History::new(make(seed.wrapping_add(step as u64), !whole_frames, &mut ids), 50);
            continue;
        }
        let c = all[rng.int(all.len())].clone();
        let d = delta(&mut rng, 40, off_frame);
        let at = if rng.chance(3) {
            c.start + fd() * rng.int((c.timeline().duration.frame_index(fd())).max(1) as usize) as i64
        } else {
            fd() * rng.int(400) as i64
        };
        let track = t0.tracks[rng.int(t0.tracks.len())].id;
        let mut op = rng.int(30);
        if whole_frames && (11..=16).contains(&op) {
            op = [0, 2, 3, 5, 7, 17][op - 11];
        }
        let mut work = t0.clone();
        let id = c.id;
        let one = BTreeSet::from([id]);
        let all_tracks: Vec<Id> = t0.tracks.iter().map(|t| t.id).collect();
        let name = format!("op {op}");
        let res: Option<Result<(), EditError>> = match op {
            0 => Some(work.add_edit(at, None, &mut ids).map(drop)),
            1 => Some(work.add_edit_for_selection(at, &one, &mut ids).map(drop)),
            2 => Some(work.trim(id, ClipEdge::Tail, d).map(drop)),
            3 => Some(work.trim(id, ClipEdge::Head, d).map(drop)),
            4 => Some(work.ripple_trim(id, if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail }, d).map(drop)),
            5 => Some(work.roll(id, d).map(drop)),
            6 => Some(
                work.slip(id, d, if rng.chance(2) { SlipKeyframes::Stay } else { SlipKeyframes::FollowContent })
                    .map(drop),
            ),
            7 => Some(work.slide(id, d).map(drop)),
            8 => Some(work.move_clip(id, at, None, &BTreeMap::new(), None, &mut ids).map(drop)),
            9 => Some(work.move_insert(id, at, None, &mut ids)),
            10 => Some(work.ripple_delete(&[id]).map(drop)),
            11 => {
                let p = [1.0, 10.0, 33.0, 50.0, 99.0, 100.0, 150.0, 200.0, 400.0, 1000.0, 10_000.0][rng.int(11)];
                let ch = SpeedChange {
                    speed: Some(ClipSpeed::from_percent(p)),
                    ripple: rng.chance(2),
                    holding_duration: rng.chance(4),
                    ..SpeedChange::default()
                };
                Some(work.apply_speed_change(&ch, id).map(drop))
            }
            12 => {
                let dur = fd() * rng.int(200) as i64 + if rng.chance(4) { Time::new(1, 96_000) } else { Time::ZERO };
                let ch = SpeedChange { duration: Some(dur), ripple: rng.chance(2), ..SpeedChange::default() };
                Some(work.apply_speed_change(&ch, id).map(drop))
            }
            13 => {
                let ch = SpeedChange { reversed: Some(!c.reversed), ripple: rng.chance(2), ..SpeedChange::default() };
                Some(work.apply_speed_change(&ch, id).map(drop))
            }
            14 => Some(work.rate_stretch(id, if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail }, d).map(drop)),
            15 | 16 => {
                let local = fd() * (rng.int((c.timeline().duration.frame_index(fd()).max(1) + 2) as usize) as i64 - 1);
                let (seg, b) = (rng.int(6).wrapping_sub(1), rng.int(6).wrapping_sub(1));
                let v = ClipSpeed::from_percent([5.0, 50.0, 80.0, 120.0, 200.0, 400.0, 2000.0][rng.int(7)]);
                let w = fd() * rng.int(30) as i64;
                let kind = rng.int(9);
                // An index of -1 (the Swift fuzz's "no such segment") wraps to a huge one here: out of range either way.
                Some(
                    work.edit_speed_keys(id, false, false, |k| match kind {
                        0 => k.adding_key(local, fd()).map(|x| x.0),
                        1 => Some(k.setting_speed(seg, v, fd())),
                        2 => k.splitting_key(b, w, fd()),
                        3 => k.splitting_key_taking(b, w, d, fd()),
                        4 => k.removing_ramp(seg, fd()),
                        5 => k.setting_ramp_width(seg, w, fd()),
                        6 => k.moving_key(b, d, fd()),
                        7 => k.moving_ramp(seg, d, fd()),
                        _ => k.removing_key(b),
                    })
                    .map(drop),
                )
            }
            17 => {
                let ids_set: BTreeSet<Id> = if rng.chance(2) {
                    one.clone()
                } else {
                    all.iter().filter(|_| rng.chance(6)).map(|x| x.id).collect()
                };
                let insert = rng.chance(2);
                Some(match work.clipboard(&ids_set) {
                    Some(cb) => work.paste(&cb, at, None, insert, &mut ids).map(drop),
                    None => Err(EditError::ClipNotFound),
                })
            }
            18 => {
                let sel = if rng.chance(2) { one.clone() } else { BTreeSet::new() };
                let n = rng.int(12) as i64 - 1;
                Some(work.jump_cut_alternate(at, &sel, n, &mut ids).map(drop))
            }
            19 => Some(work.close_gap(track, at, &mut ids).map(drop)),
            20 | 21 => {
                let r = TimeRange::new(at, fd() * (1 + rng.int(40) as i64));
                Some(if op == 20 {
                    work.lift(r, &all_tracks, &mut ids)
                } else {
                    work.extract(r, &all_tracks, &mut ids).map(drop)
                })
            }
            22 => {
                let side = if rng.chance(2) { SplitEditSide::Audio } else { SplitEditSide::Video };
                Some(work.split_edit(at, side, at + d, None).map(drop))
            }
            23 => Some(work.split_edit_jl(if rng.chance(2) { JLCut::JCut } else { JLCut::LCut }, at).map(drop)),
            24 => {
                // A key at a local time (also off the clip): the clip's own animation grows a key.
                let kt = at - c.start + if rng.chance(3) { d } else { Time::ZERO };
                for tr in &mut work.tracks {
                    if let Some(mut n) = tr.clip(id).cloned() {
                        n.animation.opacity.track.insert(sq_core_time::Keyframe::new(ids.next_id(), kt, 0.5));
                        tr.replace(n);
                    }
                }
                Some(Ok(()))
            }
            25 | 26 => Some(work.nudge(&one, d, &mut ids).map(drop)),
            _ => None, // undo / redo / undo x3 below
        };
        log.push(format!("{step}: {name} {}", res.as_ref().map_or("history".to_string(), |r| format!("{r:?}"))));
        match res {
            None => match op {
                27 => _ = hist.undo(),
                28 => _ = hist.redo(),
                _ => (0..3).for_each(|_| _ = hist.undo()),
            },
            Some(Ok(())) => {
                applied += 1;
                if work != t0 {
                    hist.commit(&name, |s| *s = work.clone());
                }
            }
            Some(Err(_)) => {}
        }
        let p = problems(hist.current(), whole_frames, slack);
        assert!(
            p.is_empty(),
            "seed {seed} step {step} after {name}: {p:?}\n{}",
            log[log.len().saturating_sub(8)..].join("\n")
        );
    }
    assert!(applied > STEPS / 5, "seed {seed}: the fuzz run did too little (applied {applied})");
}

#[test]
fn random_edits_never_trap_and_keep_the_timeline_valid() {
    for seed in 1..=SEEDS {
        run(seed);
    }
}

/// A speed-key edit that changes nothing leaves the clip (and the timeline) as it was.
#[test]
fn a_speed_key_edit_that_changes_nothing_leaves_the_clip() {
    let mut ids = SequentialIds::default();
    let mut tl = make(3, false, &mut ids);
    let c = tl.tracks[0].clips()[0].id;
    let before = tl.clone();
    let change = tl.edit_speed_keys(c, false, false, |k| Some(k.clone())).unwrap();
    assert_eq!(change, Time::ZERO);
    assert!(tl == before);
}
