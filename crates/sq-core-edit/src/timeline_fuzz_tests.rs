// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TimelineFuzzTests.swift, EditInvariantFuzzTests.swift
//
// Seeded random edit sequences on a small linked A/V timeline. After every edit the timeline must stay valid (clips sorted,
// no overlap, nothing before 0, no empty clip, source range inside the media), a refused edit must leave it as it was, undo
// must restore the snapshot exactly and redo must re-apply the edit. A failure prints the seed and the last commands.

use crate::history::History;
use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_edit_targets::TimelineEditTargetsExt as _;
use crate::timeline_edits::{SlipKeyframes, TimelineEditsExt as _};
use crate::timeline_join_cuts::TimelineJoinCutsExt as _;
use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use crate::timeline_speed::{SpeedChange, TimelineSpeedExt as _};
use crate::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt as _};
use crate::timeline_three_point::TimelineThreePointExt as _;
use crate::timeline_trim_to_playhead::{PlayheadTrimMode, TimelineTrimToPlayheadExt as _};
use sq_core_model::{Clip, ClipEdge, ClipSpeed, EditError, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// The Swift fuzz generator: a 64-bit LCG so a seed means the same sequence of picks.
pub(crate) struct Lcg(pub(crate) u64);

impl Lcg {
    pub(crate) fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    pub(crate) fn int(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
    pub(crate) fn chance(&mut self, n: usize) -> bool {
        self.int(n) == 0
    }
}

pub(crate) fn fd() -> Time {
    Time::new(1001, 30000)
}

/// Offset of `n` frames, negative or positive, up to `max` either way.
fn delta(rng: &mut Lcg, max: usize) -> Time {
    fd() * (rng.int(max * 2 + 1) as i64 - max as i64)
}

/// A fresh id source far from the counters the generator uses, so ids never clash across edits.
pub(crate) fn id_source(seed: u64) -> SequentialIds {
    let mut ids = SequentialIds::default();
    for _ in 0..(seed % 7) {
        ids.next_id();
    }
    ids
}

/// Two linked V/A lanes of four clips each, frame-exact, with spare media around every clip.
pub(crate) fn start(seed: u64, ids: &mut impl IdSource) -> Timeline {
    let mut rng = Lcg(seed);
    let mut tracks: Vec<Track> = [TrackKind::Video, TrackKind::Video, TrackKind::Audio, TrackKind::Audio]
        .into_iter()
        .map(|k| Track::new(ids.next_id(), k))
        .collect();
    for lane in 0..2usize {
        let mut t = Time::ZERO;
        for i in 0..4 {
            let len = fd() * (10 + rng.int(40) as i64);
            if i > 0 {
                t += fd() * rng.int(6) as i64;
            }
            let media = ids.next_id();
            let link = ids.next_id();
            let source = TimeRange::new(fd() * rng.int(10) as i64, len);
            let md = len + fd() * rng.int(20) as i64 + fd() * 10;
            for (track, kind) in [(lane, TrackKind::Video), (lane + 2, TrackKind::Audio)] {
                let mut c = Clip::new(ids.next_id(), "c", media, kind, source, t);
                c.media_duration = Some(md);
                c.link = Some(link);
                let mut clips = tracks[track].clips().to_vec();
                clips.push(c);
                tracks[track].set_clips(clips);
            }
            t += len;
        }
    }
    Timeline::new(ids.next_id(), "T", SequenceFormat::new(fd()), tracks)
}

pub(crate) fn problems(t: &Timeline) -> Vec<String> {
    let mut out = vec![];
    for (i, tr) in t.tracks.iter().enumerate() {
        if !tr.is_consistent() {
            out.push(format!("track {i} overlaps or starts before 0"));
        }
        let mut per_link: BTreeMap<Id, usize> = BTreeMap::new();
        for c in tr.clips() {
            if c.timeline().duration <= Time::ZERO {
                out.push(format!("track {i}: empty clip"));
            }
            if c.start < Time::ZERO {
                out.push(format!("track {i}: negative start"));
            }
            if let Some(h) = c.hold_frame {
                if h < Time::ZERO || c.media_duration.is_some_and(|m| h >= m) {
                    out.push(format!("track {i}: held frame outside the media"));
                }
            } else if !c.is_generator() && !c.is_still {
                if c.source.start < Time::ZERO {
                    out.push(format!("track {i}: source before the media start"));
                }
                if c.media_duration.is_some_and(|m| c.source.end() > m) {
                    out.push(format!("track {i}: source beyond the media end"));
                }
            }
            if let Some(l) = c.link {
                *per_link.entry(l).or_default() += 1;
            }
        }
        if per_link.values().any(|&n| n > 1) {
            out.push(format!("track {i}: a link group holds two clips on one track"));
        }
    }
    out
}

fn track_ids(t: &Timeline) -> Vec<Id> {
    t.tracks.iter().map(|x| x.id).collect()
}

/// One random verb on `t`; returns its name and the result so the caller can tell refusals from edits.
fn apply(
    op: usize,
    rng: &mut Lcg,
    t: &mut Timeline,
    c: &Clip,
    ids: &mut impl IdSource,
) -> (String, Result<(), EditError>) {
    let d = delta(rng, 40);
    let at = fd() * rng.int(200) as i64;
    let range = TimeRange::new(at, fd() * (1 + rng.int(40) as i64));
    let all = track_ids(t);
    let id = c.id;
    let name = format!("op {op} clip {:?} d {d:?} at {at:?}", id);
    let r = match op {
        0 => t.trim(id, ClipEdge::Tail, d).map(drop),
        1 => t.trim(id, ClipEdge::Head, d).map(drop),
        2 => t.roll(id, d).map(drop),
        3 => t.slip(id, d, SlipKeyframes::Stay).map(drop),
        4 => t.slide(id, d).map(drop),
        5 => t.move_clip(id, at, None, &BTreeMap::new(), None, ids).map(drop),
        6 => t.move_insert(id, at, None, ids),
        7 => t.ripple_delete(&[id]).map(drop),
        8 => t.ripple_trim(id, ClipEdge::Tail, d).map(drop),
        9 => t.ripple_trim(id, ClipEdge::Head, d).map(drop),
        10 => t.add_edit(at, None, ids).map(drop),
        11 => t.lift(range, &all, ids),
        12 => t.extract(range, &all, ids).map(drop),
        13 => t.join_through_edits(None).map(drop),
        14 => match t.clipboard(&BTreeSet::from([id])) {
            Some(cb) => t.paste(&cb, at, None, rng.chance(2), ids).map(drop),
            None => Err(EditError::ClipNotFound),
        },
        _ => {
            let track = t.tracks[rng.int(t.tracks.len())].id;
            t.close_gap(track, at, ids).map(drop)
        }
    };
    (name, r)
}

fn run(seed: u64) {
    let mut rng = Lcg(seed.wrapping_mul(7919));
    let mut ids = id_source(seed);
    let mut hist = History::new(start(seed, &mut ids), 50);
    assert!(problems(hist.current()).is_empty(), "seed {seed}: generated timeline invalid");
    let (mut applied, mut changed) = (0, 0);
    let mut log: Vec<String> = vec![];
    for step in 0..250 {
        let before = hist.current().clone();
        let clips: Vec<Clip> = before.tracks.iter().flat_map(|t| t.clips().to_vec()).collect();
        if clips.is_empty() {
            break;
        }
        let c = clips[rng.int(clips.len())].clone();
        let op = rng.int(16);
        let mut work = before.clone();
        let (name, res) = apply(op, &mut rng, &mut work, &c, &mut ids);
        log.push(format!("{step}: {name} -> {res:?}"));
        let tail = log[log.len().saturating_sub(6)..].join("\n");
        if let Ok(()) = res {
            {
                applied += 1;
                if work != before {
                    changed += 1;
                    hist.commit(&name, |s| *s = work.clone());
                    let after = hist.current().clone();
                    assert!(hist.undo(), "seed {seed}: nothing to undo after {name}");
                    assert!(*hist.current() == before, "seed {seed}: undo did not restore the snapshot after {name}");
                    assert!(hist.redo(), "seed {seed}: nothing to redo after {name}");
                    assert!(*hist.current() == after, "seed {seed}: redo did not re-apply {name}");
                }
            }
        }
        let p = problems(hist.current());
        assert!(p.is_empty(), "seed {seed} step {step} after {name}: {p:?}\n{tail}");
    }
    assert!(applied > 30 && changed > 20, "seed {seed}: the run did too little (applied {applied}, changed {changed})");
}

#[test]
fn random_edits_keep_the_timeline_valid_and_undo_exact() {
    for seed in 1..=40u64 {
        run(seed);
    }
}

/// An edit that is refused is atomic: the verbs work on a copy in Rust, so the original must equal the clone it started from.
#[test]
fn a_refused_edit_leaves_the_timeline_unchanged() {
    for seed in 1..=20u64 {
        let mut rng = Lcg(seed.wrapping_mul(31));
        let mut ids = id_source(seed);
        let mut t = start(seed, &mut ids);
        for _ in 0..150 {
            let clips: Vec<Clip> = t.tracks.iter().flat_map(|x| x.clips().to_vec()).collect();
            let Some(c) = clips.get(rng.int(clips.len().max(1))).cloned() else { break };
            let before = t.clone();
            let op = rng.int(16);
            let (name, res) = apply(op, &mut rng, &mut t, &c, &mut ids);
            if res.is_err() {
                assert!(t == before, "seed {seed}: refused {name} changed the timeline");
            }
            assert!(problems(&t).is_empty(), "seed {seed}: invalid after {name}: {:?}", problems(&t));
        }
    }
}

/// Conservation: a blade through every track and Join Cuts afterwards give back the same clips.
#[test]
fn split_then_join_cuts_restores_the_clips() {
    let shape = |t: &Timeline| -> Vec<Vec<[Time; 3]>> {
        t.tracks
            .iter()
            .map(|x| x.clips().iter().map(|c| [c.start, c.timeline().duration, c.source.start]).collect())
            .collect()
    };
    for seed in 1..=20u64 {
        let mut rng = Lcg(seed.wrapping_mul(31));
        let mut ids = id_source(seed);
        let original = start(seed, &mut ids);
        let mut t = original.clone();
        for _ in 0..(1 + rng.int(6)) {
            let at = fd() * rng.int(300) as i64;
            let _ = t.add_edit(at, None, &mut ids);
        }
        assert!(t.join_through_edits(None).is_ok());
        assert!(shape(&t) == shape(&original), "seed {seed}: split then join changed the clips");
    }
}

/// The class-sweep verbs (speed, reverse, extend edit, trim to playhead, split edit, unlink, nudge) on top of `apply`.
fn apply_more(rng: &mut Lcg, t: &mut Timeline, c: &Clip, ids: &mut impl IdSource) -> (String, Result<(), EditError>) {
    let d = delta(rng, 30);
    let at = fd() * rng.int(300) as i64;
    let edge = if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail };
    let flip = rng.chance(2);
    let pct = (25 + rng.int(300)) as f64;
    let all = track_ids(t);
    let id = c.id;
    let (name, r) = match rng.int(10) {
        0 => ("nudge", t.nudge(&BTreeSet::from([id]), d, ids).map(drop)),
        1 => ("rate stretch", t.rate_stretch(id, edge, d).map(drop)),
        2 => {
            let ch = SpeedChange { speed: Some(ClipSpeed::from_percent(pct)), ripple: flip, ..SpeedChange::default() };
            ("speed", t.apply_speed_change(&ch, id).map(drop))
        }
        3 => {
            let ch = SpeedChange { reversed: Some(true), ..SpeedChange::default() };
            ("reverse", t.apply_speed_change(&ch, id).map(drop))
        }
        4 => ("extend edit", t.extend_edit(id, edge, at).map(drop)),
        5 => {
            let mode = if flip { PlayheadTrimMode::Ripple } else { PlayheadTrimMode::Plain };
            ("trim to playhead", t.trim_to_playhead(edge, at, Some(&all), mode).map(drop))
        }
        6 => ("split selection", t.add_edit_for_selection(at, &BTreeSet::from([id]), ids).map(drop)),
        7 => {
            let side = if flip { SplitEditSide::Audio } else { SplitEditSide::Video };
            ("split edit", t.split_edit(c.timeline().end(), side, c.timeline().end() + d, None).map(drop))
        }
        8 => ("unlink", t.unlink(&BTreeSet::from([id]))),
        _ => {
            let n = fd() * (1 + rng.int(60) as i64);
            let ch = SpeedChange { duration: Some(n), ..SpeedChange::default() };
            ("set duration", t.apply_speed_change(&ch, id).map(drop))
        }
    };
    (name.to_string(), r)
}

/// Runs random verbs from both lists; `check(before, after, name)` runs after every applied one and returns problems.
pub(crate) fn sweep(
    seed: u64,
    start: Timeline,
    ids: &mut impl IdSource,
    pick: impl Fn(&mut Lcg, &Timeline) -> Option<Clip>,
    check: impl Fn(&Timeline, &Timeline, &str) -> Vec<String>,
) -> usize {
    let mut rng = Lcg(seed.wrapping_mul(7933));
    let mut tl = start.clone();
    let mut applied = 0;
    for step in 0..200 {
        if tl.tracks.iter().map(|x| x.clips().len()).sum::<usize>() > 60 {
            tl = start.clone();
        }
        let Some(c) = pick(&mut rng, &tl) else { break };
        let mut next = tl.clone();
        let (name, res) = if rng.chance(2) {
            let op = rng.int(16);
            apply(op, &mut rng, &mut next, &c, ids)
        } else {
            apply_more(&mut rng, &mut next, &c, ids)
        };
        if res.is_err() || next == tl {
            continue;
        }
        applied += 1;
        for t in next.tracks.iter_mut() {
            t.prune_transitions(start.format.frame_duration);
        }
        let mut p = problems(&next);
        p.extend(check(&tl, &next, &name));
        assert!(p.is_empty(), "seed {seed} step {step}: after {name}: {p:?}");
        tl = next;
    }
    applied
}

pub(crate) fn pick_any(rng: &mut Lcg, t: &Timeline) -> Option<Clip> {
    let all: Vec<&Clip> = t.tracks.iter().flat_map(|x| x.clips().iter()).collect();
    (!all.is_empty()).then(|| all[rng.int(all.len())].clone())
}

#[test]
fn reversed_clips_keep_their_source_inside_the_media_under_every_verb() {
    for seed in 201..=206u64 {
        let mut ids = id_source(seed);
        let mut start = start(seed, &mut ids);
        let mut rng = Lcg(seed.wrapping_mul(17));
        let clips: Vec<Id> = start.tracks.iter().flat_map(|x| x.clips().iter().map(|c| c.id)).collect();
        for id in clips {
            if rng.chance(2) {
                let ch = SpeedChange { reversed: Some(true), ..SpeedChange::default() };
                let _ = start.apply_speed_change(&ch, id);
            }
        }
        assert!(start.tracks.iter().any(|x| x.clips().iter().any(|c| c.reversed)));
        let applied = sweep(
            seed,
            start,
            &mut ids,
            |rng, t| {
                let all: Vec<&Clip> = t.tracks.iter().flat_map(|x| x.clips().iter()).collect();
                let rev: Vec<&Clip> = all.iter().copied().filter(|c| c.reversed).collect();
                let pool = if rev.is_empty() { all } else { rev };
                (!pool.is_empty()).then(|| pool[rng.int(pool.len())].clone())
            },
            |_, _, _| vec![],
        );
        assert!(applied > 33, "seed {seed}: the run did too little (applied {applied})");
    }
}

#[test]
fn locked_tracks_stay_identical_under_every_verb() {
    for seed in 201..=206u64 {
        let mut rng = Lcg(seed.wrapping_mul(29));
        let mut ids = id_source(seed);
        let mut start = start(seed, &mut ids);
        let n = start.tracks.len();
        let locked: BTreeSet<usize> = (0..1 + rng.int(2)).map(|_| rng.int(n)).collect();
        let locked_ids: Vec<Id> = locked.iter().map(|&i| start.tracks[i].id).collect();
        for &i in &locked {
            start.tracks[i].is_locked = true;
        }
        let applied = sweep(
            seed,
            start,
            &mut ids,
            |rng, t| {
                let open: Vec<&Clip> =
                    t.tracks.iter().filter(|x| !x.is_locked).flat_map(|x| x.clips().iter()).collect();
                let all: Vec<&Clip> = t.tracks.iter().flat_map(|x| x.clips().iter()).collect();
                let pool = if rng.chance(5) || open.is_empty() { all } else { open };
                (!pool.is_empty()).then(|| pool[rng.int(pool.len())].clone())
            },
            |before, after, name| {
                let mut out = vec![];
                for id in &locked_ids {
                    let (Some(a), Some(b)) =
                        (before.tracks.iter().find(|x| x.id == *id), after.tracks.iter().find(|x| x.id == *id))
                    else {
                        continue;
                    };
                    // Unlink clears an orphaned link id on a locked partner: bookkeeping only.
                    let strip = |t: &Track| -> Vec<Clip> {
                        t.clips()
                            .iter()
                            .cloned()
                            .map(|mut c| {
                                if name == "unlink" {
                                    c.link = None;
                                }
                                c
                            })
                            .collect()
                    };
                    if strip(a) != strip(b) || a.transitions != b.transitions {
                        out.push(format!("locked track {id:?} changed"));
                    }
                }
                out
            },
        );
        assert!(applied > 25, "seed {seed}: the run did too little (applied {applied})");
    }
}

#[test]
fn a_plain_run_keeps_every_invariant() {
    for seed in 301..=304u64 {
        let mut ids = id_source(seed);
        let s = start(seed, &mut ids);
        let applied = sweep(seed, s, &mut ids, pick_any, |_, _, _| vec![]);
        assert!(applied > 33, "seed {seed}: the run did too little (applied {applied})");
    }
}

/// Class 3 of EditClassSweepFuzzTests: transitions follow their clips under every verb; none points at a clip that is gone.
#[test]
fn transitions_never_dangle_under_every_verb() {
    use sq_core_effects::transition::{NewTransition, TimelineTransitions as _};
    use sq_core_model::{TransitionAlignment, TransitionKind};
    for seed in 201..=206u64 {
        let mut ids = id_source(seed);
        let mut s = start(seed, &mut ids);
        // Gaps between the generated clips are random (0..5 frames): touching pairs get a dissolve, every first clip a head fade.
        for ti in 0..s.tracks.len() {
            let track = s.tracks[ti].id;
            let clips: Vec<Clip> = s.tracks[ti].clips().to_vec();
            let mk = |out: Option<Id>, inc: Option<Id>| NewTransition {
                kind: TransitionKind::CrossDissolve,
                track,
                outgoing: out,
                incoming: inc,
                duration: fd() * 6,
                alignment: TransitionAlignment::Center,
                custom_before: Time::ZERO,
            };
            for w in clips.windows(2) {
                if w[0].timeline().end() == w[1].start {
                    let _ = s.add_transition(&mk(Some(w[0].id), Some(w[1].id)), &mut ids);
                }
            }
            if let Some(f) = clips.first() {
                let _ = s.add_transition(&mk(None, Some(f.id)), &mut ids);
            }
        }
        assert!(s.tracks.iter().any(|t| !t.transitions.is_empty()), "seed {seed}: no transition generated");
        let applied = sweep(
            seed,
            s,
            &mut ids,
            |rng, t| {
                let with_x: Vec<Clip> = t
                    .tracks
                    .iter()
                    .flat_map(|tr| {
                        tr.transitions
                            .iter()
                            .filter_map(|x| x.outgoing.or(x.incoming))
                            .filter_map(|c| tr.clip(c).cloned())
                    })
                    .collect();
                if !with_x.is_empty() && rng.chance(2) {
                    return Some(with_x[rng.int(with_x.len())].clone());
                }
                pick_any(rng, t)
            },
            |_, after, _| {
                let mut out = vec![];
                for (i, tr) in after.tracks.iter().enumerate() {
                    for x in &tr.transitions {
                        if [x.outgoing, x.incoming].into_iter().flatten().any(|c| tr.clip(c).is_none()) {
                            out.push(format!("track {i}: dangling transition"));
                        }
                    }
                }
                out
            },
        );
        assert!(applied > 33, "seed {seed}: the run did too little (applied {applied})");
    }
}
