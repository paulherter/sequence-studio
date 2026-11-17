// SPDX-License-Identifier: GPL-3.0-or-later
//! Which source frames of a clip the next playback ticks show, for the Magic matte look-ahead: the coming timeline
//! times go through the same evaluation a tick uses, so a reversed clip, a clip speed, a speed ramp and reverse or fast
//! playback prepare the frames that are shown next (Swift: MatteLookAhead.swift).

use sq_core_edit::layer_time_path::LayerTimePath;
use sq_core_edit::playback::PlaybackRate;
use sq_core_effects::evaluation::{LayerRequest, SequenceResolver};
use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use sq_media::sample_index::SampleIndex;
use std::collections::{BTreeMap, BTreeSet};

/// The timeline times of the next `count` different frames after grid time `t` at playback `rate` (one tick per
/// sequence frame: the clock moves `rate` frames per tick; a slow rate shows a frame several ticks long). Times before
/// the sequence start are left out.
pub fn times(t: Time, frame: Time, rate: PlaybackRate, count: usize) -> Vec<Time> {
    if count == 0 || rate.is_paused() {
        return Vec::new();
    }
    let num = i64::from(rate.num()).abs();
    let den = i64::from(rate.den().max(1));
    let mut out = Vec::new();
    let mut last = 0i64;
    let mut k = 1i64;
    while out.len() < count && k <= count as i64 * den {
        let frames = k * num / den;
        k += 1;
        if frames == last {
            continue;
        }
        last = frames;
        let at = if rate.is_reverse() { t - frame * frames } else { t + frame * frames };
        if at.is_negative() {
            break;
        }
        out.push(at);
    }
    out
}

fn push_once(out: &mut BTreeMap<Id, Vec<Time>>, clip: Id, s: Time) {
    let v = out.entry(clip).or_default();
    if !v.contains(&s) {
        v.push(s);
    }
}

/// Per clip in `clips`: the source times its layers ask for at the coming timeline times, in playing order.
pub fn source_times(
    t: Time,
    frame: Time,
    rate: PlaybackRate,
    count: usize,
    clips: &BTreeSet<Id>,
    layers: &dyn Fn(Time) -> Vec<LayerRequest>,
) -> BTreeMap<Id, Vec<Time>> {
    let mut out = BTreeMap::new();
    if clips.is_empty() {
        return out;
    }
    for at in times(t, frame, rate, count) {
        for r in layers(at) {
            if clips.contains(&r.clip) {
                push_once(&mut out, r.clip, r.source_time);
            }
        }
    }
    out
}

/// The same answer for the clips of `requests` (the tick's layers at `t`) that show a Magic matte, without evaluating
/// the timeline again per coming time: each such layer's source time comes from its clips' own time mappings
/// (`LayerTimePath`). `layers` is asked only for a time one of them cannot answer.
#[allow(clippy::too_many_arguments)] // shortcut: one call site per tick, a params struct when a third caller appears
pub fn source_times_from_requests(
    t: Time,
    frame: Time,
    rate: PlaybackRate,
    count: usize,
    requests: &[LayerRequest],
    timeline: &Timeline,
    sequences: SequenceResolver,
    layers: &mut dyn FnMut(Time) -> Vec<LayerRequest>,
) -> BTreeMap<Id, Vec<Time>> {
    let masked: Vec<&LayerRequest> =
        requests.iter().filter(|r| r.effects.magic_mattes().iter().any(|m| !m.must_cover)).collect();
    let mut out = BTreeMap::new();
    if masked.is_empty() {
        return out;
    }
    let coming = times(t, frame, rate, count);
    if coming.is_empty() {
        return out;
    }
    let clips: BTreeSet<Id> = masked.iter().map(|r| r.clip).collect();
    let mut paths: Vec<(Id, LayerTimePath)> = Vec::new();
    for r in &masked {
        match LayerTimePath::new(r, t, timeline, sequences) {
            Some(p) => paths.push((r.clip, p)),
            None => break,
        }
    }
    let known = paths.len() == masked.len();
    for at in coming {
        let mut derived: Vec<(Id, Time)> = Vec::new();
        if known {
            for (clip, p) in &paths {
                match p.source_time(at) {
                    Some(s) => derived.push((*clip, s)),
                    None => break,
                }
            }
        }
        if !known || derived.len() < paths.len() {
            derived =
                layers(at).into_iter().filter(|r| clips.contains(&r.clip)).map(|r| (r.clip, r.source_time)).collect();
        }
        for (clip, s) in derived {
            push_once(&mut out, clip, s);
        }
    }
    out
}

/// The source frames (seconds, as the store keys them) that show the coming source times `times`, in playing order,
/// each once and without the frame shown now (`shown`).
pub fn frames(times: &[Time], shown: i64, index: &SampleIndex) -> Vec<f64> {
    if index.count() == 0 {
        return Vec::new();
    }
    let last = index.count() as i64 - 1;
    let mut seen: BTreeSet<i64> = BTreeSet::from([shown]);
    let mut out = Vec::new();
    for &t in times {
        // Clamped like `MediaSource::frame_index`: past the end the last frame, before the start the first.
        let f = index.frame_at(t).map_or(if t > Time::ZERO { last } else { 0 }, |i| i as i64).clamp(0, last);
        if !seen.insert(f) {
            continue;
        }
        let pts = index.entries()[f as usize].pts;
        out.push(pts.value() as f64 / pts.timescale().max(1) as f64);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_media::sample_index::Entry;

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn index(frames: i64) -> SampleIndex {
        SampleIndex::new(
            (0..frames)
                .map(|i| Entry {
                    pts: fd() * i,
                    dts: fd() * i,
                    duration: fd(),
                    is_sync: i % 15 == 0,
                    decode_ordinal: i,
                })
                .collect(),
        )
    }

    /// Source frame numbers prepared at timeline frame `at` for a clip that maps timeline time to source time
    /// `speed * t` (forward) or `end - speed * t` (reversed), like the Swift tests' 20 s clip.
    fn ahead(at: i64, rate: PlaybackRate, speed: i64, reversed: bool) -> (i64, Vec<i64>) {
        let idx = index(600);
        let map = move |t: Time| if reversed { Time::new(20, 1) - fd() - t * speed } else { t * speed };
        let t = fd() * at;
        let shown = idx.frame_at(map(t)).unwrap() as i64;
        let ts: Vec<Time> = times(t, fd(), rate, 4).into_iter().map(map).collect();
        (shown, frames(&ts, shown, &idx).iter().map(|s| (s * 30.0).round() as i64).collect())
    }

    #[test]
    fn a_plain_clip_prepares_the_next_four_frames() {
        assert_eq!(ahead(10, PlaybackRate::FORWARD, 1, false), (10, vec![11, 12, 13, 14]));
    }

    #[test]
    fn a_reversed_clip_prepares_the_frames_before_the_shown_one() {
        let (shown, coming) = ahead(10, PlaybackRate::FORWARD, 1, true);
        assert!(shown > 500);
        assert_eq!(coming, (1..=4).map(|k| shown - k).collect::<Vec<_>>());
    }

    #[test]
    fn a_fast_clip_prepares_every_second_or_sixth_frame() {
        assert_eq!(ahead(10, PlaybackRate::FORWARD, 2, false), (20, vec![22, 24, 26, 28]));
        assert_eq!(ahead(10, PlaybackRate::FORWARD, 6, false), (60, vec![66, 72, 78, 84]));
    }

    #[test]
    fn reverse_playback_prepares_the_frames_before() {
        assert_eq!(ahead(10, PlaybackRate::REVERSE, 1, false), (10, vec![9, 8, 7, 6]));
        // Near the sequence start nothing before it is asked for.
        assert_eq!(ahead(2, PlaybackRate::REVERSE, 1, false).1, vec![1, 0]);
    }

    #[test]
    fn fast_and_slow_playback_step_with_the_clock() {
        assert_eq!(ahead(10, PlaybackRate::whole(2), 1, false).1, vec![12, 14, 16, 18]);
        assert_eq!(ahead(20, PlaybackRate::whole(-4), 1, false).1, vec![16, 12, 8, 4]);
        // Half rate: each frame shows two ticks long, the next four different frames are prepared.
        assert_eq!(ahead(10, PlaybackRate::new(1, 2), 1, false).1, vec![11, 12, 13, 14]);
        assert!(times(fd() * 10, fd(), PlaybackRate::ZERO, 4).is_empty());
    }
}
