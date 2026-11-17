// Swift: LiveDuckingIndex.swift
//! Live ducking decisions of one timeline revision, built once off the audio thread, so a mix block does no walk over
//! every clip: the dialogue candidates sorted by start (binary search per block) and the set of clips the duck acts on.
//! Answers exactly `LiveDucking::dialogue_ranges_pauses` and `LiveDucking::ducks` for the timeline it was built from; any
//! change of the timeline (edit, undo, mute, solo, role, opt-out) needs a new index.

use crate::live_ducking::{DialogueSilenceProvider, LiveDucking};
use sq_core_model::{Clip, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq)]
struct Entry {
    range: TimeRange,
    track: usize,
    clip: usize,
}

/// The duck index of one timeline revision.
#[derive(Clone, Debug, PartialEq)]
pub struct LiveDuckingIndex {
    /// Dialogue-role, enabled, non-generator clips on audible audio tracks still in live ducking, sorted by start.
    entries: Vec<Entry>,
    /// `max_end[i]`: the latest end among `entries[0..=i]` (non-decreasing, so the first entry that can reach a window is
    /// found by binary search).
    max_end: Vec<Time>,
    /// Top-level clips live ducking acts on (`LiveDucking::ducks`).
    ducked: BTreeSet<Id>,
}

impl LiveDuckingIndex {
    /// Builds the index of `t`.
    pub fn new(t: &Timeline) -> LiveDuckingIndex {
        let mut e: Vec<Entry> = Vec::new();
        let solo = t.tracks.iter().any(|tr| tr.kind == TrackKind::Audio && !tr.is_muted && tr.is_solo);
        for (ti, track) in t.tracks.iter().enumerate() {
            if track.kind != TrackKind::Audio
                || track.is_muted
                || (solo && !track.is_solo)
                || track.is_excluded_from_live_ducking()
            {
                continue;
            }
            let role = track.audio_role;
            for (i, c) in track.clips().iter().enumerate() {
                if c.audio_tag.or(role) == Some(sq_core_model::AudioTag::Dialogue) && c.is_enabled && !c.is_generator()
                {
                    e.push(Entry { range: c.timeline(), track: ti, clip: i });
                }
            }
        }
        e.sort_by_key(|x| x.range.start);
        let mut m: Vec<Time> = Vec::with_capacity(e.len());
        for x in &e {
            m.push(m.last().map_or(x.range.end(), |l| (*l).max(x.range.end())));
        }
        LiveDuckingIndex { entries: e, max_end: m, ducked: LiveDucking::ducked_clip_ids(t) }
    }

    /// Whether live ducking acts on the top-level clip `id` (same as `LiveDucking::ducks(clip, its track)`).
    pub fn ducks(&self, id: Id) -> bool {
        self.ducked.contains(&id)
    }

    /// `LiveDucking::dialogue_ranges_pauses(t, window, pauses)` into `out` (replaced; its capacity is kept). `t` must be
    /// the timeline this index was built from.
    pub fn dialogue_ranges(
        &self,
        t: &Timeline,
        window: &TimeRange,
        pauses: impl Fn(&Clip, &Track) -> Option<Vec<TimeRange>>,
        out: &mut Vec<TimeRange>,
    ) {
        out.clear();
        if self.entries.is_empty() {
            return;
        }
        // First entry whose running max end reaches the window; entries from the first start past the window end are out.
        let lo = self.max_end.partition_point(|m| *m < window.start);
        let mut sorted = true;
        for e in &self.entries[lo..] {
            if e.range.start > window.end() {
                break;
            }
            if e.range.end() < window.start {
                continue;
            }
            let track = &t.tracks[e.track];
            let clip = &track.clips()[e.clip];
            match pauses(clip, track) {
                Some(s) if !s.is_empty() => {
                    let before = out.len();
                    append_active_ranges(&e.range, &s, out);
                    if before > 0 && out.len() > before && out[before].start < out[before - 1].start {
                        sorted = false;
                    }
                }
                _ => {
                    if out.last().is_some_and(|last| e.range.start < last.start) {
                        sorted = false;
                    }
                    out.push(e.range);
                }
            }
        }
        merge_in_place(out, sorted);
    }

    /// Same with the pauses from a silence provider (`None` = every clip ducks over its whole length).
    pub fn dialogue_ranges_silences(
        &self,
        t: &Timeline,
        window: &TimeRange,
        silences: Option<&dyn DialogueSilenceProvider>,
        out: &mut Vec<TimeRange>,
    ) {
        self.dialogue_ranges(t, window, |c, track| silences.and_then(|s| s.silences(c, track.volume_db)), out);
    }
}

/// `LiveDucking::active_ranges` appended to `out`.
fn append_active_ranges(clip: &TimeRange, silences: &[TimeRange], out: &mut Vec<TimeRange>) {
    let is_sorted = silences.windows(2).all(|w| w[1].start >= w[0].start);
    let mut owned;
    let s: &[TimeRange] = if is_sorted {
        silences
    } else {
        owned = silences.to_vec();
        owned.sort_by_key(|r| r.start);
        &owned
    };
    let mut cursor = clip.start;
    for p in s {
        let (a, b) = (p.start.max(clip.start), p.end().min(clip.end()));
        if b <= a {
            continue;
        }
        if a > cursor {
            out.push(TimeRange::new(cursor, a - cursor));
        }
        cursor = cursor.max(b);
    }
    if clip.end() > cursor {
        out.push(TimeRange::new(cursor, clip.end() - cursor));
    }
}

/// The merge of `dialogue_ranges`, in place: empty ranges dropped, touching or overlapping ones joined, sorted by start.
/// `sorted`: the input is already sorted by start (skips the sort).
fn merge_in_place(a: &mut Vec<TimeRange>, sorted: bool) {
    if a.is_empty() {
        return;
    }
    if !sorted {
        a.sort_by_key(|r| r.start);
    }
    let mut w = 0;
    for k in 0..a.len() {
        if a[k].is_empty() {
            continue;
        }
        let r = a[k];
        if w > 0 && r.start <= a[w - 1].end() {
            let last = a[w - 1];
            a[w - 1] = TimeRange::new(last.start, last.end().max(r.end()) - last.start);
        } else {
            a[w] = r;
            w += 1;
        }
    }
    a.truncate(w);
}

impl LiveDucking {
    /// `expanded` into `out` (replaced, capacity kept). Input sorted by start (as `dialogue_ranges` returns).
    pub fn expanded_into(&self, ranges: &[TimeRange], out: &mut Vec<TimeRange>) {
        out.clear();
        out.extend(self.expanded(ranges));
    }

    /// `gain` over ranges already passed through `expanded` (once per block instead of once per gain chunk).
    pub fn gain_expanded(&self, time: Time, expanded_ranges: &[TimeRange]) -> f32 {
        if self.is_off() {
            return 1.0;
        }
        self.raw_gain(time, expanded_ranges)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::{clip, timeline, track};
    use crate::live_ducking::DuckTimingExt;
    use sq_core_model::{AudioTag, DuckTiming};

    fn mixed_clips() -> Vec<Vec<Clip>> {
        let mut out = Vec::new();
        for k in 0..6_i64 {
            let mut clips: Vec<Clip> = (0..40_i64)
                .map(|i| {
                    let tag = if (i + k) % 5 == 0 {
                        Some(AudioTag::Dialogue)
                    } else if (i + k) % 7 == 0 {
                        Some(AudioTag::Music)
                    } else {
                        None
                    };
                    clip(i * 5 + k, 3 + (i + k) % 4, tag)
                })
                .collect();
            clips[3].is_enabled = false;
            clips[5].duck_key_ids = vec![Id::from_u128(5000 + k as u128)];
            if k == 5 {
                let mut g = clip(217, 4, Some(AudioTag::Dialogue));
                g.id = Id::from_u128(9_000_001);
                g.generator = Some(sq_core_model::GeneratorRef {
                    kind: "solid".to_string(),
                    payload: vec![0, 0, 0],
                    payload_version: 1,
                });
                clips.push(g);
            }
            out.push(clips);
        }
        out
    }

    fn build(clips: &[Vec<Clip>]) -> Timeline {
        let tracks = clips
            .iter()
            .enumerate()
            .map(|(k, c)| {
                let role = if k < 2 {
                    Some(AudioTag::Dialogue)
                } else if k < 4 {
                    Some(AudioTag::Music)
                } else {
                    None
                };
                track(k as u128 + 1, role, c.clone())
            })
            .collect();
        timeline(tracks)
    }

    fn windows() -> Vec<TimeRange> {
        let mut w = vec![TimeRange::new(Time::new(-5, 1), Time::new(500, 1))];
        for s in (-3..215).step_by(2) {
            w.push(TimeRange::new(Time::new(s, 1), Time::new(1, 100)));
            w.push(TimeRange::new(Time::new(s * 3 + 1, 3), Time::new(7, 2)));
        }
        w
    }

    /// Pauses for some clips (the second second of every clip whose start is a multiple of 3), none for the rest.
    fn pauses(c: &Clip, _t: &Track) -> Option<Vec<TimeRange>> {
        (c.start.value() % 3 == 0).then(|| vec![TimeRange::new(c.start + Time::new(1, 1), Time::new(1, 2))])
    }

    fn expect_same(t: &Timeline, idx: &LiveDuckingIndex) {
        let mut buf = Vec::new();
        for w in windows() {
            idx.dialogue_ranges(t, &w, pauses, &mut buf);
            assert_eq!(buf, LiveDucking::dialogue_ranges_pauses(t, Some(&w), pauses));
            idx.dialogue_ranges(t, &w, |_, _| None, &mut buf);
            assert_eq!(buf, LiveDucking::dialogue_ranges(t, Some(&w), None));
        }
        for tr in &t.tracks {
            for c in tr.clips() {
                assert_eq!(idx.ducks(c.id), LiveDucking::ducks(c, tr));
            }
        }
    }

    #[test]
    fn matches_the_walk() {
        let t = build(&mixed_clips());
        expect_same(&t, &LiveDuckingIndex::new(&t));
    }

    #[test]
    fn empty_and_video_only_timelines() {
        let empty = timeline(vec![]);
        expect_same(&empty, &LiveDuckingIndex::new(&empty));
        let mut v = sq_core_model::Track::new(Id::from_u128(1), TrackKind::Video);
        v.set_clips(vec![clip(0, 5, Some(AudioTag::Dialogue))]);
        let video = timeline(vec![v]);
        expect_same(&video, &LiveDuckingIndex::new(&video));
    }

    /// Every timeline change the feeder sees rebuilds the index; each rebuilt index matches the walk again, and the old
    /// one (built before the change) would not have.
    #[test]
    fn follows_edits_undo_mute_solo_and_roles() {
        let clips = mixed_clips();
        let base = build(&clips);
        let with = |f: &dyn Fn(&mut Vec<Vec<Clip>>)| {
            let mut c = clips.clone();
            f(&mut c);
            build(&c)
        };
        let mut changes: Vec<(&str, Timeline)> = vec![
            ("move", with(&|c| c[0][10].start = Time::new(300, 1))),
            ("clip tag", with(&|c| c[3][1].audio_tag = Some(AudioTag::Dialogue))),
            ("disable", with(&|c| c[0][0].is_enabled = false)),
            ("music tag off", with(&|c| c[2][1].audio_tag = Some(AudioTag::Sfx))),
        ];
        let mut muted = base.clone();
        muted.tracks[0].is_muted = true;
        changes.push(("mute", muted));
        let mut solo = base.clone();
        solo.tracks[2].is_solo = true;
        changes.push(("solo", solo));
        let mut role = base.clone();
        role.tracks[2].audio_role = Some(AudioTag::Dialogue);
        changes.push(("track role", role));
        let mut excl = base.clone();
        excl.tracks[1].set_excluded_from_live_ducking(true);
        changes.push(("exclude", excl));
        let old = LiveDuckingIndex::new(&base);
        for (name, t) in &changes {
            expect_same(t, &LiveDuckingIndex::new(t));
            let mut stale = false;
            let mut buf = Vec::new();
            for w in windows() {
                old.dialogue_ranges(t, &w, |_, _| None, &mut buf);
                if buf != LiveDucking::dialogue_ranges(t, Some(&w), None) {
                    stale = true;
                    break;
                }
            }
            for tr in &t.tracks {
                for c in tr.clips() {
                    stale |= old.ducks(c.id) != LiveDucking::ducks(c, tr);
                }
            }
            assert!(stale, "{name}: the change must be visible to a rebuilt index only");
        }
        // Undo = the earlier snapshot again: an index of it equals the first one.
        expect_same(&base, &LiveDuckingIndex::new(&base));
        assert_eq!(LiveDuckingIndex::new(&base), old);
    }

    /// The expanded ranges into a buffer and the gain over them equal the allocating API (bit for bit).
    #[test]
    fn expanded_into_buffer_and_gain_match() {
        let ranges = LiveDucking::dialogue_ranges_pauses(&build(&mixed_clips()), None, pauses);
        for timing in [DuckTiming::classic(), DuckTiming::resolve(), DuckTiming::speech()] {
            let d = LiveDucking::with_timing(12.0, timing);
            let mut buf = Vec::new();
            d.expanded_into(&ranges, &mut buf);
            assert_eq!(buf, d.expanded(&ranges));
            for k in 0..2000_i64 {
                let t = Time::new(k * 211, 1000);
                assert_eq!(d.gain_expanded(t, &buf), d.gain(t, &ranges));
            }
        }
    }
}
