// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+Speed.swift (set speed, set duration, refresh nested durations)

use crate::{Clip, ClipSpeed, EaseShape, EditError, SpeedKeys, SpeedSegment, Timeline};
use sq_core_time::{Id, Interpolation, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

impl Timeline {
    /// Brings the inner-duration limit (`media_duration`) of nested clips up to date: it is derived from the inner sequence
    /// at edit time, because a stored value goes stale when the inner sequence is edited. `inner` = the sequence's current
    /// duration.
    pub fn refresh_nested_durations(&mut self, inner: impl Fn(Id) -> Option<Time>) {
        for ti in 0..self.tracks.len() {
            for c in self.tracks[ti].clips().to_vec() {
                let Some(d) = c.sequence.and_then(&inner) else { continue };
                if Some(d) == c.media_duration {
                    continue;
                }
                let mut n = c;
                n.media_duration = Some(d);
                self.tracks[ti].replace(n);
            }
        }
    }

    /// Whole frames of `t` (nearest).
    fn nearest_frames(&self, t: Time) -> i64 {
        let fd = self.frame_duration();
        t.snapped(fd).frame_index(fd)
    }

    /// Sets the speed (and optionally direction / pitch handling) of a clip and its linked partners.
    ///
    /// The source range (in/out) is kept; the clip's timeline length becomes `source.duration / speed`, rounded to whole
    /// frames (the source range follows by at most half a frame). Start stays.
    /// - `ripple == false`: a clip that grows only grows into free space; where a neighbor is in the way, the clip is
    ///   truncated (shows less source) like Premiere. A clip that shrinks leaves a gap.
    /// - `ripple == true` (Ripple Edit, Shifting Trailing Clips): later clips on every ripple track shift by the change, like
    ///   a ripple trim; shortening closes only as far as nothing collides.
    /// - `holding_duration`: keeps the timeline length and changes the source range instead (the speed and duration fields
    ///   of Premiere's dialog unlinked): the clip shows more or less of its media, limited by the media.
    ///
    /// Returns the change of the clip's timeline duration.
    pub fn set_speed(
        &mut self,
        id: Id,
        speed: ClipSpeed,
        reversed: Option<bool>,
        keeps_pitch: Option<bool>,
        ripple: bool,
        holding_duration: bool,
    ) -> Result<Time, EditError> {
        let group = self.retime_group(id)?;
        let fd = self.frame_duration();
        let ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let mut involved: BTreeSet<usize> = group.iter().map(|m| m.track).collect();
        if ripple {
            involved.extend((0..self.tracks.len()).filter(|i| self.tracks[*i].follows_ripple()));
        }
        let primary = group[0].clip.clone();
        // Tracks without a member shift from the earliest member end (the edit point), not from the clicked clip's end: a
        // partner moved alone sits elsewhere, and later clips (and split-edit partners) behind the earliest end follow.
        let old_end = group.iter().map(|m| m.clip.timeline().end()).min().unwrap_or(primary.timeline().end());

        // Frame count per member: each keeps its own source range (a linked partner may be longer than the clip), limited by
        // its own media and neighbor.
        let mut lengths: BTreeMap<Id, Time> = BTreeMap::new();
        for m in &group {
            let mut c = m.clip.clone();
            if let Some(r) = reversed {
                c.reversed = r;
            }
            let basis = if holding_duration { c.duration() } else { speed.unscale(c.retime_span()) };
            let mut want = self.nearest_frames(basis).max(1);
            if let Some(k) = &c.speed_keys {
                want = self.nearest_frames(k.clamped_duration(fd * want, fd));
            }
            let per_frame = speed.scale(fd);
            // Media limits (the anchor end of the range stays, the other end moves). A remapped clip keeps the source it
            // visits, so only its length changes: no media limit. Less than one timeline frame of media left at this speed:
            // refuse rather than run past the media.
            if let Some(room) = media_frames(&c, per_frame) {
                if room < 1 {
                    return Err(EditError::InsufficientMedia);
                }
                want = want.min(room);
            }
            if !ripple {
                let next = self.tracks[m.track]
                    .clips()
                    .iter()
                    .filter(|x| !ids.contains(&x.id) && x.start >= c.timeline().end())
                    .map(|x| x.start)
                    .min();
                if let Some(next) = next {
                    want = want.min((next - c.start).frame_index(fd).max(1));
                }
            }
            lengths.insert(c.id, fd * want);
        }
        let length = |id: Id| lengths.get(&id).copied().ok_or(EditError::ClipNotFound);

        let mut work = self.tracks.clone();
        for m in &group {
            let new_duration = length(m.clip.id)?;
            let mut c = m.clip.clone();
            if let Some(r) = reversed {
                c.reversed = r;
            }
            if let Some(k) = keeps_pitch {
                c.keeps_pitch = k;
            }
            let flipped = c.reversed != m.clip.reversed;
            if let Some(keys) = c.speed_keys.clone() {
                // Remapped: the whole shape plays faster or slower; Reverse flips every segment.
                let mut scaled = keys.scaled(new_duration, fd);
                if flipped {
                    let end = scaled.end_position();
                    let segments = scaled
                        .segments
                        .iter()
                        .rev()
                        .map(|s| {
                            // An eased ramp played backwards is its curve rotated 180 degrees: out and in swap.
                            let ease = s.ease().map(|e| EaseShape::new(Interpolation::Bezier, e.r#in, e.out));
                            SpeedSegment::new(s.duration, s.to, Some(s.from), !s.reversed, ease)
                        })
                        .collect();
                    scaled = SpeedKeys::new(segments, end);
                }
                let fit = scaled.fitting(c.media_duration, fd).ok_or(EditError::Collision)?;
                c.set_speed_keys(Some(fit));
                c.rescale_keys(m.clip.duration(), new_duration, flipped);
                work[m.track].replace(c);
                continue;
            }
            c.speed = speed;
            let src_dur = speed.scale(new_duration);
            let end = c.source.end();
            let start = if c.reversed { end - src_dur } else { c.source.start };
            c.source = TimeRange::new(start, src_dur);
            c.rescale_keys(m.clip.duration(), new_duration, flipped);
            work[m.track].replace(c);
        }
        let change = length(primary.id)? - primary.duration();
        // Ripple: every track shifts by the same amount so trailing clips keep sync. Members of one group change in the same
        // direction; the largest growth (or the smallest shrink) is the one that collides with nothing.
        let mut shift_wanted = None;
        for m in &group {
            let d = length(m.clip.id)? - m.clip.duration();
            shift_wanted = Some(shift_wanted.map_or(d, |s: Time| s.max(d)));
        }
        let shift_wanted = shift_wanted.unwrap_or(change);
        if ripple && shift_wanted != Time::ZERO {
            let mut pivot: BTreeMap<usize, Time> = involved.iter().map(|i| (*i, old_end)).collect();
            let mut own: BTreeMap<usize, Time> = BTreeMap::new(); // several members on one track: the latest end
            for m in &group {
                let end = m.clip.timeline().end();
                let e = own.entry(m.track).or_insert(end);
                *e = (*e).max(end);
            }
            pivot.extend(own);
            // Split edits (J/L cuts): a straddling clip whose linked partner shifts moves with it, like a ripple trim.
            let pivot = Timeline::following_straddlers(&self.tracks, &pivot, &ids);
            let mut shift = shift_wanted;
            if shift < Time::ZERO {
                for i in &involved {
                    if let Some(room) = self.tracks[*i].left_room(pivot.get(i).copied().unwrap_or(old_end), &ids) {
                        shift = shift.max(-room);
                    }
                }
            }
            // The freed tail is not a delete: a caption in it stays and stops the ripple there, like a clip on another track.
            shift = self.limit_close_by_captions(old_end, shift);
            for i in &involved {
                work[*i].shift(pivot.get(i).copied().unwrap_or(old_end), shift, &ids);
            }
            if !work.iter().all(|t| t.is_consistent()) {
                return Err(EditError::Collision);
            }
            self.tracks = work;
            if shift < Time::ZERO {
                self.close_caption_span(TimeRange::new(old_end + shift, -shift));
            } else {
                self.open_caption_gap(old_end, shift);
            }
        } else {
            if !work.iter().all(|t| t.is_consistent()) {
                return Err(EditError::Collision);
            }
            self.tracks = work;
        }
        Ok(change)
    }

    /// Sets the clip's timeline duration (frame-snapped, at least one frame); the speed becomes `source.duration /
    /// duration` (clamped to 1 % ... 10000 %). Same options as `set_speed`.
    pub fn set_duration(
        &mut self,
        id: Id,
        duration: Time,
        reversed: Option<bool>,
        keeps_pitch: Option<bool>,
        ripple: bool,
    ) -> Result<Time, EditError> {
        let c: Clip = self.find(id).ok_or(EditError::ClipNotFound)?.clip;
        let d = self.nearest_frames(duration).max(1);
        let target = self.frame_duration() * d;
        let speed = ClipSpeed::from_source_over(c.retime_span(), target);
        self.set_speed(id, speed, reversed, keeps_pitch, ripple, false)
    }
}

/// Whole timeline frames of media the clip can show at `per_frame` source time per frame, from its anchored edge (source end
/// when reversed, source start forward). `None` = no limit (remapped clip, or unknown media length).
#[doc(hidden)]
pub fn media_frames(c: &Clip, per_frame: Time) -> Option<i64> {
    if c.speed_keys.is_some() {
        return None;
    }
    if c.reversed {
        return Some(c.source.end().frame_index(per_frame)); // start' = end - dur >= 0
    }
    c.media_duration.map(|m| (m - c.source.start).frame_index(per_frame))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SequenceFormat, Track, TrackKind};

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn pct(p: f64) -> ClipSpeed {
        ClipSpeed::from_percent(p)
    }

    /// A clip of `frames` frames of source starting at source frame `from`, media 3000 frames long.
    fn clip(start: i64, from: i64, frames: i64, kind: TrackKind, link: Option<u128>) -> Clip {
        thread_local!(static NEXT: std::cell::Cell<u128> = const { std::cell::Cell::new(100) });
        let n = NEXT.with(|c| {
            c.set(c.get() + 1);
            c.get()
        });
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(n + 5000),
            kind,
            TimeRange::new(f(from), f(frames)),
            f(start),
        );
        c.link = link.map(Id::from_u128);
        c.media_duration = Some(f(3000));
        c
    }

    fn v(start: i64, from: i64, frames: i64) -> Clip {
        clip(start, from, frames, TrackKind::Video, None)
    }

    fn timeline(tracks: Vec<(TrackKind, Vec<Clip>)>) -> Timeline {
        let tracks = tracks
            .into_iter()
            .enumerate()
            .map(|(i, (kind, clips))| {
                let mut t = Track::new(Id::from_u128(9000 + i as u128), kind);
                t.set_clips(clips);
                t
            })
            .collect();
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    fn first(tl: &Timeline, track: usize, i: usize) -> Clip {
        tl.tracks[track].clips()[i].clone()
    }

    fn set(tl: &mut Timeline, id: Id, speed: ClipSpeed, ripple: bool) -> Result<Time, EditError> {
        tl.set_speed(id, speed, None, None, ripple, false)
    }

    #[test]
    fn double_speed_halves_the_length_and_keeps_in_out() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(10, 20, 60)])]);
        let id = first(&tl, 0, 0).id;
        assert_eq!(set(&mut tl, id, pct(200.0), false), Ok(f(-30)));
        let c = first(&tl, 0, 0);
        assert_eq!((c.duration(), c.start, c.source), (f(30), f(10), TimeRange::new(f(20), f(60))));
    }

    #[test]
    fn non_integer_ratios_round_the_length_to_frames() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(0, 0, 30)])]);
        let id = first(&tl, 0, 0).id;
        assert!(set(&mut tl, id, pct(33.33), false).is_ok());
        let c = first(&tl, 0, 0);
        assert_eq!(c.duration(), f(90)); // 30 / 0.3333 = 90.009 frames
        assert_eq!((c.speed, c.source.duration), (pct(33.33), pct(33.33).scale(f(90))));
        assert!(set(&mut tl, id, pct(250.0), false).is_ok());
        let c = first(&tl, 0, 0);
        assert_eq!((c.duration().frame_index(Time::new(1, 30)), c.duration()), (12, f(12)));
    }

    #[test]
    fn set_duration_computes_the_speed_and_clamps_it_to_the_range() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(0, 0, 90)])]);
        let id = first(&tl, 0, 0).id;
        assert!(tl.set_duration(id, f(45), None, None, false).is_ok());
        let c = first(&tl, 0, 0);
        assert_eq!((c.speed, c.duration(), c.source.duration), (pct(200.0), f(45), f(90)));
        let mut big = timeline(vec![(TrackKind::Video, vec![v(0, 0, 3000)])]);
        let id = first(&big, 0, 0).id;
        assert!(big.set_duration(id, f(3), None, None, false).is_ok()); // would be 100000 %
        assert_eq!(first(&big, 0, 0).speed, ClipSpeed::MAXIMUM);
    }

    fn captions(items: &[(i64, i64)]) -> crate::CaptionTrack {
        let list: Vec<_> = items
            .iter()
            .enumerate()
            .map(|(n, (a, b))| serde_json::json!({"id": Id::from_u128(100 + n as u128), "lines": ["c"], "range": {"start": {"value": a, "timescale": 30}, "duration": {"value": b - a, "timescale": 30}}}))
            .collect();
        serde_json::from_value(serde_json::json!({"id": Id::from_u128(1), "items": list}))
            .unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn a_ripple_speed_up_keeps_a_caption_in_the_freed_tail_and_stops_there() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(0, 0, 60), v(60, 500, 30)])]);
        tl.caption_tracks = vec![captions(&[(40, 50), (70, 80)])];
        let before = tl.clone();
        let id = first(&tl, 0, 0).id;
        assert!(tl.set_speed(id, pct(200.0), None, None, true, false).is_ok()); // 60 -> 30 frames, 30 would close
        let ranges: Vec<TimeRange> = tl.caption_tracks[0].items().iter().map(|i| i.range).collect();
        assert_eq!(ranges[0], TimeRange::from_end(f(40), f(50)), "the caption in the freed tail is not dropped");
        assert_eq!(first(&tl, 0, 0).duration(), f(30));
        assert_eq!(first(&tl, 0, 1).start, f(50), "the ripple closed only the 10 frames after the caption");
        assert_eq!(ranges[1], TimeRange::from_end(f(60), f(70)), "a later caption rides the ripple");
        let undone = before.clone(); // undo = the snapshot taken before the edit
        assert_eq!(undone, before);
        assert_ne!(tl, before);
    }

    #[test]
    fn a_ripple_speed_up_closes_fully_when_no_caption_is_in_the_freed_tail() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(0, 0, 60), v(60, 500, 30)])]);
        tl.caption_tracks = vec![captions(&[(5, 20), (70, 80)])];
        let id = first(&tl, 0, 0).id;
        assert!(tl.set_speed(id, pct(200.0), None, None, true, false).is_ok());
        assert_eq!(first(&tl, 0, 1).start, f(30));
        let ranges: Vec<TimeRange> = tl.caption_tracks[0].items().iter().map(|i| i.range).collect();
        assert_eq!(ranges, [TimeRange::from_end(f(5), f(20)), TimeRange::from_end(f(40), f(50))]);
    }

    #[test]
    fn without_ripple_a_clip_only_grows_into_free_space_and_shortening_leaves_a_gap() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(0, 0, 30), v(50, 500, 30)])]);
        let id = first(&tl, 0, 0).id;
        assert!(set(&mut tl, id, pct(50.0), false).is_ok()); // wants 60 frames, 50 are free
        let (a, b) = (first(&tl, 0, 0), first(&tl, 0, 1));
        assert_eq!((a.duration(), a.source.duration, b.start), (f(50), f(25), f(50))); // truncated: shows less source
        let mut gap = timeline(vec![(TrackKind::Video, vec![v(0, 0, 60), v(60, 500, 30)])]);
        let id = first(&gap, 0, 0).id;
        assert!(set(&mut gap, id, pct(200.0), false).is_ok());
        assert_eq!((first(&gap, 0, 1).start, first(&gap, 0, 0).duration()), (f(60), f(30)));
    }

    #[test]
    fn ripple_shifts_trailing_clips_on_all_sync_tracks() {
        let mut tl = timeline(vec![
            (TrackKind::Video, vec![v(0, 0, 60), v(60, 500, 30)]),
            (TrackKind::Video, vec![v(70, 0, 20)]),
        ]);
        let id = first(&tl, 0, 0).id;
        assert!(set(&mut tl, id, pct(50.0), true).is_ok()); // +60 frames
        assert_eq!(first(&tl, 0, 0).duration(), f(120));
        assert_eq!((first(&tl, 0, 1).start, first(&tl, 1, 0).start), (f(120), f(130)));
        assert!(set(&mut tl, id, pct(200.0), true).is_ok()); // back, -90 frames
        assert_eq!((first(&tl, 0, 1).start, first(&tl, 1, 0).start), (f(30), f(40)));
    }

    #[test]
    fn a_ripple_speed_change_moves_the_in_out_range_and_markers_like_a_trim() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(0, 0, 60), v(60, 500, 30)])]);
        tl.in_out = Some(TimeRange::from_end(f(70), f(80)));
        let id = first(&tl, 0, 0).id;
        assert!(set(&mut tl, id, pct(200.0), true).is_ok()); // -30 frames
        assert_eq!(tl.in_out, Some(TimeRange::from_end(f(40), f(50))));
    }

    #[test]
    fn a_linked_pair_changes_together() {
        let mut tl = timeline(vec![
            (TrackKind::Video, vec![clip(0, 0, 60, TrackKind::Video, Some(7))]),
            (TrackKind::Audio, vec![clip(0, 0, 60, TrackKind::Audio, Some(7))]),
        ]);
        let id = first(&tl, 0, 0).id;
        assert!(tl.set_speed(id, pct(200.0), Some(true), Some(false), false, false).is_ok());
        for t in 0..2 {
            let c = first(&tl, t, 0);
            assert!(c.speed == pct(200.0) && c.reversed && !c.keeps_pitch && c.duration() == f(30));
        }
    }

    #[test]
    fn reverse_only_keeps_range_and_length() {
        let mut tl = timeline(vec![(TrackKind::Video, vec![v(4, 10, 40)])]);
        let id = first(&tl, 0, 0).id;
        assert_eq!(tl.set_speed(id, ClipSpeed::NORMAL, Some(true), None, false, false), Ok(Time::ZERO));
        let c = first(&tl, 0, 0);
        assert!(c.reversed && c.source == TimeRange::new(f(10), f(40)) && c.start == f(4));
        assert!(tl.set_speed(id, ClipSpeed::NORMAL, Some(false), None, false, false).is_ok());
        assert!(!first(&tl, 0, 0).reversed);
    }

    #[test]
    fn slowing_beyond_the_media_end_stays_inside_the_media() {
        let mut c = v(0, 0, 30);
        c.media_duration = Some(f(30));
        let mut tl = timeline(vec![(TrackKind::Video, vec![c])]);
        let id = first(&tl, 0, 0).id;
        assert!(set(&mut tl, id, pct(70.0), false).is_ok());
        assert!(first(&tl, 0, 0).source.end() <= f(30));
    }

    #[test]
    fn stills_locked_tracks_and_unknown_clips_are_refused() {
        let mut still = v(0, 0, 30);
        still.is_still = true;
        let mut tl = timeline(vec![(TrackKind::Video, vec![still])]);
        let id = first(&tl, 0, 0).id;
        assert_eq!(set(&mut tl, id, pct(200.0), false), Err(EditError::SpeedUnsupported));
        let mut locked = timeline(vec![(TrackKind::Video, vec![v(0, 0, 30)])]);
        locked.tracks[0].is_locked = true;
        let id = first(&locked, 0, 0).id;
        assert_eq!(set(&mut locked, id, pct(200.0), false), Err(EditError::TrackLocked));
        assert_eq!(set(&mut locked, Id::from_u128(1), pct(200.0), false), Err(EditError::ClipNotFound));
    }

    #[test]
    fn nested_durations_follow_the_inner_sequence() {
        let mut nested = v(0, 0, 30);
        nested.sequence = Some(Id::from_u128(77));
        let mut tl = timeline(vec![(TrackKind::Video, vec![nested, v(40, 0, 10)])]);
        tl.refresh_nested_durations(|s| (s == Id::from_u128(77)).then_some(f(45)));
        assert_eq!((first(&tl, 0, 0).media_duration, first(&tl, 0, 1).media_duration), (Some(f(45)), Some(f(3000))));
    }
}
