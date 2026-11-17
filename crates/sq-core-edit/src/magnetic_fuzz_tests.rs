// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagneticInvariantFuzzTests.swift, MagneticInvariantFuzzMoreVerbsTests.swift, MagneticBypassVerbsFuzzTests.swift
//
// Seeded random sequences of the Fast Cut (magnetic) verbs on a generated sequence (V1 main track with linked camera audio
// incl. J cuts, overlays on V2/V3, music on A2), with random Normal <-> Fast Cut switches, undo and redo in between.
// After every step: valid tracks (no overlap, nothing negative), every attachment valid and `derive_attachments` a no-op
// (Fast Cut), V1 gains no hole except through the spacer verbs, undo restores the exact snapshot and redo the post-op one, a
// mode switch moves no clip (tracks equal apart from attachments), a Normal-only run never stores an attachment.
// Also ported: followers follow (3) and content sync (4). shortcut: the linked-offset check (5) is not ported, it is covered by
// the focused unit tests in timeline_magnetic_*.rs; upgrade when a magnetic verb changes.

use crate::history::History;
use crate::timeline_edits::SlipKeyframes;
use crate::timeline_fuzz_tests::{Lcg, fd, problems};
use crate::timeline_magnetic_moves::MagneticGesturesExt as _;
use crate::timeline_magnetic_ops::MagneticOpsExt as _;
use crate::timeline_magnetic_verbs::MagneticVerbsExt as _;
use sq_core_model::{Clip, ClipEdge, EditError, SequenceFormat, Timeline, TimelineEditMode, Track, TrackKind};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn make(seed: u64, ids: &mut impl IdSource) -> Timeline {
    let mut rng = Lcg(seed.wrapping_mul(104_729));
    let mut tr = |k| Track::new(ids.next_id(), k);
    let (mut v1, mut a1) = (tr(TrackKind::Video), tr(TrackKind::Audio));
    let (mut v2, mut v3, mut a2) = (tr(TrackKind::Video), tr(TrackKind::Video), tr(TrackKind::Audio));
    let mut t = Time::ZERO;
    for i in 0..4 + rng.int(4) {
        let len = fd() * (10 + rng.int(50)) as i64;
        let (media, link) = (ids.next_id(), ids.next_id());
        let handle = fd() * (6 + rng.int(20)) as i64;
        let md = handle + len + fd() * (6 + rng.int(20)) as i64;
        let mut v = Clip::new(ids.next_id(), "v", media, TrackKind::Video, TimeRange::new(handle, len), t);
        v.media_duration = Some(md);
        v.link = Some(link);
        let k = fd() * (2 + rng.int(4)) as i64;
        let (mut a_start, mut a_src) = (t, v.source);
        if i % 2 == 1 {
            a_start = t - k;
            a_src = TimeRange::new(handle - k, len + k);
        }
        let mut a = Clip::new(ids.next_id(), "a", media, TrackKind::Audio, a_src, a_start);
        a.media_duration = Some(md);
        a.link = Some(link);
        let _ = v1.overwrite(v, ids);
        if i % 2 == 1
            && let Some(prev) = a1.clips().last().cloned()
            && prev.timeline().end() > a_start
        {
            let mut p = prev.clone();
            p.source = TimeRange::new(p.source.start, p.timeline().duration - (prev.timeline().end() - a_start));
            let rest: Vec<Clip> = a1.clips().iter().filter(|c| c.id != prev.id).cloned().collect();
            a1.set_clips(rest);
            let _ = a1.overwrite(p, ids);
        }
        let _ = a1.overwrite(a, ids);
        t += len;
    }
    let mut filler = |track: &mut Track, kind, count: usize, rng: &mut Lcg| {
        let mut at = fd() * rng.int(20) as i64;
        for _ in 0..count {
            let len = fd() * (8 + rng.int(40)) as i64;
            let h = fd() * rng.int(10) as i64;
            let mut c = Clip::new(ids.next_id(), "o", ids.next_id(), kind, TimeRange::new(h, len), at);
            c.media_duration = Some(h + len + fd() * rng.int(15) as i64);
            let _ = track.overwrite(c, ids);
            at += len + fd() * rng.int(30) as i64;
        }
    };
    let n = 2 + rng.int(3);
    filler(&mut v2, TrackKind::Video, n, &mut rng);
    let n = rng.int(3);
    filler(&mut v3, TrackKind::Video, n, &mut rng);
    let n = 1 + rng.int(3);
    filler(&mut a2, TrackKind::Audio, n, &mut rng);
    let mut tl = Timeline::new(ids.next_id(), "Magnetic", SequenceFormat::new(fd()), vec![v1, v2, v3, a1, a2]);
    tl.set_edit_mode(TimelineEditMode::Magnetic);
    tl
}

fn new_source(rng: &mut Lcg, ids: &mut impl IdSource) -> Vec<Clip> {
    let len = fd() * (1 + rng.int(40)) as i64;
    let h = fd() * rng.int(6) as i64;
    let md = h + len + fd() * rng.int(10) as i64;
    let m = ids.next_id();
    let mk = |ids: &mut dyn IdSource, kind| {
        let mut c = Clip::new(ids.next_id(), "n", m, kind, TimeRange::new(h, len), Time::ZERO);
        c.media_duration = Some(md);
        c
    };
    match rng.int(4) {
        0 => vec![mk(ids, TrackKind::Audio)],
        1 => {
            let l = ids.next_id();
            let (mut v, mut a) = (mk(ids, TrackKind::Video), mk(ids, TrackKind::Audio));
            v.link = Some(l);
            a.link = Some(l);
            vec![v, a]
        }
        _ => vec![mk(ids, TrackKind::Video)],
    }
}

pub(crate) fn holes(t: &Timeline) -> Time {
    let Some(mi) = t.main_track_index() else { return Time::ZERO };
    let (mut total, mut at) = (Time::ZERO, Time::ZERO);
    for c in t.tracks[mi].clips() {
        if c.start > at {
            total += c.start - at;
        }
        at = at.max(c.timeline().end());
    }
    total
}

fn hole_count(t: &Timeline) -> usize {
    let Some(mi) = t.main_track_index() else { return 0 };
    let c = t.tracks[mi].clips();
    usize::from(c.first().is_some_and(|f| f.start > Time::ZERO))
        + c.windows(2).filter(|w| w[0].timeline().end() < w[1].start).count()
}

pub(crate) fn attachment_problems(t: &Timeline) -> Vec<String> {
    let mut out = vec![];
    let mut d = t.clone();
    d.derive_attachments();
    if d != *t {
        out.push("derive_attachments is not a no-op".to_string());
    }
    let Some(mi) = t.main_track_index() else { return out };
    if t.tracks[mi].clips().is_empty() {
        return out;
    }
    for c in t.tracks.iter().flat_map(|x| x.clips()) {
        if t.is_attachable(c.id) {
            if c.attachment.is_none() {
                out.push(format!("attachable clip {:?} has no attachment", c.id));
            } else if !t.is_attachment_valid(c.id) {
                out.push(format!("attachment of {:?} invalid", c.id));
            }
        }
    }
    out
}

fn without_attachments(t: &Timeline) -> String {
    let mut c = t.clone();
    for tr in c.tracks.iter_mut() {
        tr.map_clips_keeping_timing(|x| {
            let mut y = x.clone();
            y.attachment = None;
            y
        });
    }
    serde_json::to_string(&c.tracks).expect("serialize")
}

/// Offset between every two members of a link group (Swift `EditInvariantFuzzTests.linkOffsets`), keyed by the id pair.
pub(crate) fn link_offsets(t: &Timeline) -> BTreeMap<(Id, Id), Time> {
    let mut groups: BTreeMap<Id, Vec<&Clip>> = BTreeMap::new();
    for c in t.tracks.iter().flat_map(|x| x.clips()) {
        if let Some(l) = c.link {
            groups.entry(l).or_default().push(c);
        }
    }
    let mut out = BTreeMap::new();
    for g in groups.values() {
        for x in g {
            for y in g.iter().filter(|y| x.id < y.id) {
                out.insert((x.id, y.id), y.start - x.start);
            }
        }
    }
    out
}

fn bytes(t: &Timeline) -> String {
    serde_json::to_string(t).expect("serialize")
}

/// One random verb; `spacer` verbs may open holes on V1. Returns the name.
fn apply(
    op: usize,
    rng: &mut Lcg,
    t: &mut Timeline,
    ids: &mut impl IdSource,
) -> (String, bool, bool, bool, Result<(), EditError>) {
    let all: Vec<Clip> = t.tracks.iter().flat_map(|x| x.clips().to_vec()).collect();
    let mi = t.main_track_index().expect("main");
    let main: Vec<Clip> = t.tracks[mi].clips().to_vec();
    let any = all[rng.int(all.len())].clone();
    let main_clip = main[rng.int(main.len())].clone();
    let off: Vec<&Clip> = all.iter().filter(|c| !main.iter().any(|m| m.id == c.id)).collect();
    let attached = if off.is_empty() { any.clone() } else { off[rng.int(off.len())].clone() };
    let end_frames = (t.main_track_end().frame_index(fd()).max(1)) as usize;
    let at = fd() * rng.int(end_frames + 20) as i64;
    let d = fd() * (rng.int(51) as i64 - 25);
    let keep = rng.chance(4);
    let tracks_all: Vec<Id> = t.tracks.iter().map(|x| x.id).collect();
    let some: Vec<Id> =
        if rng.chance(2) { tracks_all.clone() } else { tracks_all.iter().copied().filter(|_| rng.chance(2)).collect() };
    let range = TimeRange::new(at, fd() * (1 + rng.int(30)) as i64);
    let sel: BTreeSet<Id> = if rng.chance(2) {
        BTreeSet::from([any.id])
    } else {
        all.iter().filter(|_| rng.chance(8)).map(|c| c.id).collect()
    };
    let edge = if rng.chance(2) { ClipEdge::Head } else { ClipEdge::Tail };
    let mut spacer = false;
    let mut paste_attached = false;
    let r = match op {
        0 => t.append_to_main_track(&new_source(rng, ids), at, ids).map(drop),
        1 | 2 => t.insert_on_main_track(&new_source(rng, ids), at, ids).map(drop),
        3 => t.overwrite_on_main_track(&new_source(rng, ids), at, ids).map(drop),
        4 => {
            let b = rng.chance(2);
            t.attach(&new_source(rng, ids), at, b, ids).map(drop)
        }
        5 => {
            let kl = rng.chance(2);
            t.replace_on_main_track(main_clip.id, &new_source(rng, ids), kl, ids)
        }
        6 | 7 => t.magnetic_delete(&sel, keep, ids),
        8 => {
            spacer = true;
            t.replace_with_spacer(&sel, ids)
        }
        9 => t.delete_spacer(at, keep, ids).map(drop),
        10 => {
            spacer = true;
            t.insert_spacer(at, fd() * (1 + rng.int(20)) as i64, ids)
        }
        11 | 12 => t.magnetic_ripple_trim(main_clip.id, edge, d, ids).map(drop),
        13 => t.magnetic_ripple_trim(attached.id, edge, d, ids).map(drop),
        14 => t.magnetic_roll(any.id, d, ids).map(drop),
        15 => t.magnetic_slip(any.id, d, SlipKeyframes::Stay, ids).map(drop),
        16 => t.magnetic_slide(any.id, d, ids).map(drop),
        17 => t.magnetic_add_edit(at, &sel, ids).map(drop),
        18 => t.magnetic_add_edit_all(at, ids).map(drop),
        19 => {
            let s = if rng.chance(2) { None } else { Some(&sel) };
            t.magnetic_join(s, ids).map(drop)
        }
        20 | 21 => t.magnetic_rearrange(main_clip.id, at, keep, ids),
        22 => t.move_attached(attached.id, at, None, ids),
        23 => {
            let tr = tracks_all[rng.int(tracks_all.len())];
            t.move_attached(attached.id, at, Some(tr), ids)
        }
        24 => {
            spacer = true;
            t.lift_off_main_track(&sel, ids)
        }
        25 => {
            spacer = true;
            t.put_on_main_track(&sel, ids)
        }
        26 => {
            let tr = tracks_all[rng.int(tracks_all.len())];
            t.drag_off_main_track(main_clip.id, tr, at, keep, ids)
        }
        27 => {
            let o = rng.chance(2);
            spacer = o;
            t.drag_onto_main_track(attached.id, at, o, ids)
        }
        28 => t.set_attach_point(attached.id, at),
        29 | 30 => {
            let att = rng.chance(3);
            paste_attached = att;
            match t.magnetic_clipboard(&BTreeSet::from([main_clip.id])) {
                Some(cb) => t.magnetic_paste(&cb, at, att, ids).map(drop),
                None => Err(EditError::ClipNotFound),
            }
        }
        31 => t.magnetic_duplicate(&BTreeSet::from([main_clip.id]), ids).map(drop),
        32 => {
            if rng.chance(2) {
                t.magnetic_extract(range, &some, ids).map(drop)
            } else {
                spacer = true;
                t.magnetic_clear_range(range, &some, ids)
            }
        }
        _ => t.magnetic_insert_frame_hold(Some(main_clip.id), at, fd() * (1 + rng.int(20)) as i64, ids).map(drop),
    };
    // Verbs that carry the clips attached to a main clip along when it moves whole (invariant 3).
    let follow = match op {
        0..=2 | 11 | 12 => true,
        6 | 7 | 20 | 21 => !keep,
        _ => false,
    };
    // Invariant 4 (content sync) applies to the verbs that ripple V1 by themselves.
    let content = match op {
        0..=2 | 11 | 12 | 17..=19 => true,
        6 | 7 | 20 | 21 => !keep,
        29 | 30 => !paste_attached,
        _ => false,
    };
    (format!("op {op}"), spacer, follow, content, r)
}

/// Start, length and source of every clip (Swift `placed`).
pub(crate) fn placed(t: &Timeline) -> BTreeMap<Id, (Time, Time, TimeRange)> {
    t.tracks.iter().flat_map(|x| x.clips().iter()).map(|c| (c.id, (c.start, c.timeline().duration, c.source))).collect()
}

pub(crate) fn on_main(t: &Timeline, id: Id) -> bool {
    t.main_track_index().is_some_and(|mi| t.tracks[mi].clips().iter().any(|c| c.id == id))
}

/// Invariant 3, followers follow: a main clip that moved whole by `shift` takes every clip attached to it along (follow
/// verbs only). A follower that would start before 0, or that was trimmed by the same edit, is exempt.
fn followers_problems(before: &Timeline, after: &Timeline) -> Vec<String> {
    let (was, now) = (placed(before), placed(after));
    let mut out = Vec::new();
    let Some(mi) = before.main_track_index() else { return out };
    for x in before.tracks[mi].clips() {
        let (Some(b), Some(n)) = (was.get(&x.id), now.get(&x.id)) else { continue };
        if b.2 != n.2 || b.1 != n.1 || n.0 == b.0 || !on_main(after, x.id) {
            continue;
        }
        let shift = n.0 - b.0;
        for tr in before.tracks.iter().filter(|t| !t.is_locked) {
            for a in tr.clips().iter().filter(|a| a.attachment.as_ref().is_some_and(|at| at.host == x.id)) {
                let Some(na) = now.get(&a.id) else { continue };
                if on_main(after, a.id)
                    || a.start + shift < Time::ZERO
                    || na.1 != a.timeline().duration
                    || na.2 != a.source
                {
                    continue;
                }
                if na.0 - a.start != shift {
                    out.push(format!(
                        "clip {:?} attached to {:?} moved {:?} but its host moved {shift:?}",
                        a.id,
                        x.id,
                        na.0 - a.start
                    ));
                }
            }
        }
    }
    out
}

/// Media frame under timeline time `at` on V1 (constant speed material only; Swift `frameUnder`).
fn frame_under(t: &Timeline, at: Time) -> Option<(Id, Time)> {
    let mi = t.main_track_index()?;
    let c = t.tracks[mi].clips().iter().find(|c| c.timeline().contains(at))?;
    c.speed_keys.is_none().then(|| (c.media, c.source.start + (at - c.start)))
}

/// How many V1 clips show media frame `s` (Swift `cover`).
fn cover(t: &Timeline, media: Id, s: Time) -> usize {
    let Some(mi) = t.main_track_index() else { return 0 };
    t.tracks[mi].clips().iter().filter(|c| c.media == media && c.source.start <= s && s < c.source.end()).count()
}

/// Invariant 4, content sync: an attached clip kept its length and source keeps the media frame it sat over (when exactly
/// one V1 clip showed that frame before and after).
fn content_problems(before: &Timeline, after: &Timeline) -> Vec<String> {
    let mut out = Vec::new();
    for a in before.tracks.iter().flat_map(|x| x.clips().iter()) {
        let Some(at) = a.attachment.as_ref() else { continue };
        if !before.is_attachable(a.id) {
            continue;
        }
        let Some(na) = after.find(a.id).map(|m| m.clip) else { continue };
        let Some(nat) = na.attachment.as_ref() else { continue };
        if na.timeline().duration != a.timeline().duration
            || na.source != a.source
            || !after.is_attachable(a.id)
            || na.start <= Time::ZERO
        {
            continue;
        }
        let (t, t2) = (a.start + at.point, na.start + nat.point);
        let Some((m, s)) = frame_under(before, t) else { continue };
        if cover(before, m, s) != 1 || cover(after, m, s) != 1 {
            continue;
        }
        let Some((m2, s2)) = frame_under(after, t2) else { continue };
        if m != m2 || s != s2 {
            out.push(format!("attached {:?} lost its content frame ({s:?} -> {s2:?})", a.id));
        }
    }
    out
}

fn run(seed: u64, steps: usize) {
    let mut rng = Lcg(seed.wrapping_mul(7919));
    let mut ids = SequentialIds::default();
    for _ in 0..(seed % 5) * 1000 {
        ids.next_id();
    }
    let mut hist = History::new(make(seed, &mut ids), 50);
    let first = [problems(hist.current()), attachment_problems(hist.current())].concat();
    assert!(first.is_empty(), "seed {seed}: generated timeline invalid {first:?}");
    let (mut applied, mut log) = (0usize, Vec::<String>::new());
    for step in 0..steps {
        let t0 = hist.current().clone();
        let count: usize = t0.tracks.iter().map(|x| x.clips().len()).sum();
        let main_empty = t0.main_track_index().is_none_or(|mi| t0.tracks[mi].clips().is_empty());
        if count == 0 || count > 60 || t0.tracks.len() > 10 || main_empty {
            let mut f = make(seed + step as u64 + 9000, &mut ids);
            if !t0.is_fast_cut() {
                f.set_edit_mode(TimelineEditMode::Normal);
            }
            hist = History::new(f, 50);
            continue;
        }
        let op = rng.int(36);
        let tail = |log: &Vec<String>| log[log.len().saturating_sub(12)..].join(" | ");
        if op >= 35 {
            match rng.int(5) {
                2 => {
                    hist.undo();
                    log.push("undo".into());
                }
                3 => {
                    hist.redo();
                    log.push("redo".into());
                }
                _ => {
                    let m = if t0.is_fast_cut() { TimelineEditMode::Normal } else { TimelineEditMode::Magnetic };
                    let mut probe = hist.clone();
                    probe.commit("Switch mode", |t| t.set_edit_mode(m));
                    let after = probe.current().clone();
                    log.push(format!("{step}: switch mode"));
                    assert_eq!(
                        without_attachments(&after),
                        without_attachments(&t0),
                        "seed {seed}: mode switch moved clips\n{}",
                        tail(&log)
                    );
                    if m == TimelineEditMode::Magnetic {
                        let ap = attachment_problems(&after);
                        assert!(ap.is_empty(), "seed {seed}: after switching to Fast Cut: {ap:?}");
                    } else {
                        let mut same = t0.clone();
                        same.set_edit_mode(TimelineEditMode::Normal);
                        assert_eq!(
                            bytes(&after),
                            bytes(&same),
                            "seed {seed}: leaving Fast Cut changed more than the mode"
                        );
                    }
                    hist = probe;
                }
            }
        } else {
            let mut work = t0.clone();
            let (name, spacer, follow, content, res) = apply(op, &mut rng, &mut work, &mut ids);
            log.push(format!("{step}: {name} -> {res:?}"));
            if res.is_ok() && work != t0 {
                applied += 1;
                let mut probe = hist.clone();
                probe.commit(&name, |s| *s = work.clone());
                let after = probe.current().clone();
                let mut round = probe.clone();
                round.undo();
                assert!(
                    bytes(round.current()) == bytes(&t0),
                    "seed {seed}: undo did not restore after {name}\n{}",
                    tail(&log)
                );
                round.redo();
                assert!(bytes(round.current()) == bytes(&after), "seed {seed}: redo did not re-apply {name}");
                if t0.is_fast_cut() && after.is_fast_cut() && !spacer {
                    let trim_like = (11..=16).contains(&op);
                    let worse =
                        if trim_like { hole_count(&after) > hole_count(&t0) } else { holes(&after) > holes(&t0) };
                    assert!(!worse, "seed {seed}: V1 gained a hole after {name}\n{}", tail(&log));
                }
                if t0.is_fast_cut() && after.is_fast_cut() && follow {
                    let f = followers_problems(&t0, &after);
                    assert!(f.is_empty(), "seed {seed}: followers did not follow after {name}: {f:?}\n{}", tail(&log));
                }
                if t0.is_fast_cut() && after.is_fast_cut() && content {
                    let c = content_problems(&t0, &after);
                    assert!(c.is_empty(), "seed {seed}: content sync broke after {name}: {c:?}\n{}", tail(&log));
                }
                hist = probe;
            }
        }
        let p = problems(hist.current());
        assert!(p.is_empty(), "seed {seed} step {step}: {p:?}\n{}", tail(&log));
        if hist.current().is_fast_cut() {
            let ap = attachment_problems(hist.current());
            assert!(ap.is_empty(), "seed {seed} step {step}: {ap:?}\n{}", tail(&log));
        }
    }
    assert!(applied > steps / 8, "seed {seed}: the run did too little (applied {applied})");
}

#[test]
fn random_magnetic_ops_keep_every_invariant() {
    for seed in 201..=206u64 {
        run(seed, 300);
    }
}

/// Invariant 8: a sequence that never enters Fast Cut stores no attachment however the verbs run.
#[test]
fn a_normal_only_run_never_stores_an_attachment() {
    for seed in 201..=206u64 {
        let mut ids = SequentialIds::default();
        let mut rng = Lcg(seed.wrapping_mul(31));
        let mut tl = make(seed, &mut ids);
        for tr in tl.tracks.iter_mut() {
            tr.map_clips_keeping_timing(|x| {
                let mut y = x.clone();
                y.attachment = None;
                y
            });
        }
        tl.set_edit_mode(TimelineEditMode::Normal);
        for _ in 0..200 {
            let all: Vec<Clip> = tl.tracks.iter().flat_map(|x| x.clips().to_vec()).collect();
            if all.is_empty() || all.len() >= 60 {
                break;
            }
            let c = all[rng.int(all.len())].clone();
            let at = fd() * rng.int(300) as i64;
            let d = fd() * (rng.int(41) as i64 - 20);
            let len = fd() * (1 + rng.int(30)) as i64;
            let mut n = Clip::new(
                ids.next_id(),
                "n",
                ids.next_id(),
                TrackKind::Video,
                TimeRange::new(Time::ZERO, len),
                Time::ZERO,
            );
            n.media_duration = Some(len + fd() * 5);
            let sel = BTreeSet::from([c.id]);
            let _ = match rng.int(8) {
                0 => tl.insert_on_main_track(&[n], at, &mut ids).map(drop),
                1 => tl.overwrite_on_main_track(&[n], at, &mut ids).map(drop),
                2 => tl.attach(&[n], at, false, &mut ids).map(drop),
                3 => tl.magnetic_delete(&sel, false, &mut ids),
                4 => tl.magnetic_ripple_trim(c.id, ClipEdge::Tail, d, &mut ids).map(drop),
                5 => tl.magnetic_rearrange(c.id, at, false, &mut ids),
                6 => tl.magnetic_add_edit(at, &sel, &mut ids).map(drop),
                _ => tl.insert_spacer(at, len, &mut ids),
            };
            let s = bytes(&tl);
            assert!(
                !s.contains("\"attachment\"") && !s.contains("\"editMode\""),
                "seed {seed}: Normal-only run wrote a v67 key"
            );
            assert!(problems(&tl).is_empty(), "seed {seed}: {:?}", problems(&tl));
        }
    }
}
