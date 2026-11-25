// Swift: ProxyOrdering.swift
//! Order of automatic proxy jobs.

use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use std::cmp::Ordering;
use std::collections::BTreeMap;

/// Where a media is used on the timeline: its clips' `[start, end)` spans.
pub type Uses = BTreeMap<Id, Vec<(Time, Time)>>;

/// Order of automatic proxy jobs: media the active timeline uses come before bin-only media, then by the earliest
/// timeline position of a clip, then by the bin order (stable).
pub struct ProxyOrdering;

impl ProxyOrdering {
    /// Earliest clip start per media ID in `timeline` (`None` = no active timeline: everything is bin-only).
    pub fn first_use(timeline: Option<&Timeline>) -> BTreeMap<Id, Time> {
        let mut out: BTreeMap<Id, Time> = BTreeMap::new();
        for track in timeline.map(|t| t.tracks.as_slice()).unwrap_or_default() {
            for clip in track.clips() {
                if out.get(&clip.media).is_none_or(|first| clip.start < *first) {
                    out.insert(clip.media, clip.start);
                }
            }
        }
        out
    }

    /// A running job whose source is at least this far (timeline seconds) from the playhead may be dropped for a near one.
    pub const FAR_SECONDS: i64 = 120;
    /// A waiting job counts as "near" (worth dropping a far running job for) within this many timeline seconds.
    pub const NEAR_SECONDS: i64 = 10;
    /// A running job past this progress is always finished: dropping it would waste more than it gains.
    pub const KEEP_PROGRESS: f64 = 0.5;

    /// Every clip span per media ID in `timeline`.
    pub fn uses(timeline: Option<&Timeline>) -> Uses {
        let mut out = Uses::new();
        for track in timeline.map(|t| t.tracks.as_slice()).unwrap_or_default() {
            for clip in track.clips() {
                let span = clip.timeline();
                out.entry(clip.media).or_default().push((span.start, span.end()));
            }
        }
        out
    }

    /// Timeline distance from `playhead` to the nearest clip of `media`: zero under the playhead, `None` when the
    /// timeline does not use it.
    pub fn distance(uses: &Uses, media: Id, playhead: Time) -> Option<Time> {
        uses.get(&media)?
            .iter()
            .map(|&(start, end)| {
                if playhead < start {
                    start - playhead
                } else if playhead >= end {
                    playhead - end
                } else {
                    Time::ZERO
                }
            })
            .min()
    }

    /// `ids` nearest to `playhead` first (distance to the nearest clip), ties: bigger source (`sizes`, bytes) first, then
    /// bin order; media the timeline does not use come last in bin order.
    pub fn sorted_near(ids: &[Id], uses: &Uses, playhead: Time, sizes: &BTreeMap<Id, i64>) -> Vec<Id> {
        let mut indexed: Vec<(usize, Id, Option<Time>)> =
            ids.iter().copied().enumerate().map(|(i, id)| (i, id, Self::distance(uses, id, playhead))).collect();
        indexed.sort_by(|a, b| match (a.2, b.2) {
            (Some(x), Some(y)) => {
                let (sa, sb) = (sizes.get(&a.1).copied().unwrap_or(0), sizes.get(&b.1).copied().unwrap_or(0));
                x.cmp(&y).then(sb.cmp(&sa)).then(a.0.cmp(&b.0))
            }
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => a.0.cmp(&b.0),
        });
        indexed.into_iter().map(|(_, id, _)| id).collect()
    }

    /// Whether a running job (source at `running`, `progress` done) is dropped so a waiting one (at `waiting`) can run:
    /// only when the running source is far from the playhead, the waiting one is near it and the running job is under
    /// half done. A source the timeline does not use counts as far.
    pub fn should_preempt(running: Option<Time>, progress: f64, waiting: Option<Time>) -> bool {
        let far = running.is_none_or(|d| d >= Time::new(Self::FAR_SECONDS, 1));
        let near = waiting.is_some_and(|d| d <= Time::new(Self::NEAR_SECONDS, 1));
        far && near && progress < Self::KEEP_PROGRESS
    }

    /// `ids` sorted timeline-first; media without a use keep their relative (bin) order at the end.
    pub fn sorted(ids: &[Id], first_use: &BTreeMap<Id, Time>) -> Vec<Id> {
        let mut indexed: Vec<(usize, Id)> = ids.iter().copied().enumerate().collect();
        indexed.sort_by(|a, b| match (first_use.get(&a.1), first_use.get(&b.1)) {
            (Some(x), Some(y)) => x.cmp(y).then(a.0.cmp(&b.0)),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => a.0.cmp(&b.0),
        });
        indexed.into_iter().map(|(_, id)| id).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::TimeRange;

    fn clip(media: Id, at: i64) -> Clip {
        let source = TimeRange::new(Time::ZERO, Time::new(10, 1));
        Clip::new(Id::fixed(900 + at as u64), "c", media, TrackKind::Video, source, Time::new(at, 1))
    }

    fn track(n: u64, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::fixed(n), TrackKind::Video);
        t.set_clips(clips);
        t
    }

    #[test]
    fn first_use_is_the_earliest_clip_start_across_tracks() {
        let (a, b) = (Id::fixed(1), Id::fixed(2));
        let tracks = vec![track(10, vec![clip(a, 50), clip(b, 0)]), track(11, vec![clip(a, 20)])];
        let t = Timeline::new(Id::fixed(5), "T", SequenceFormat::new(Time::new(1, 30)), tracks);
        let use_ = ProxyOrdering::first_use(Some(&t));
        assert_eq!(use_[&a], Time::new(20, 1));
        assert_eq!(use_[&b], Time::new(0, 1));
        assert!(ProxyOrdering::first_use(None).is_empty());
    }

    #[test]
    fn timeline_media_first_then_bin_only_in_bin_order() {
        let (bin1, late, early, bin2) = (Id::fixed(1), Id::fixed(2), Id::fixed(3), Id::fixed(4));
        let use_ = BTreeMap::from([(late, Time::new(30, 1)), (early, Time::new(5, 1))]);
        assert_eq!(ProxyOrdering::sorted(&[bin1, late, early, bin2], &use_), vec![early, late, bin1, bin2]);
    }

    #[test]
    fn equal_position_keeps_bin_order() {
        let (a, b) = (Id::fixed(1), Id::fixed(2));
        let use_ = BTreeMap::from([(a, Time::ZERO), (b, Time::ZERO)]);
        assert_eq!(ProxyOrdering::sorted(&[a, b], &use_), vec![a, b]);
    }

    fn uses_of(items: &[(Id, i64, i64)]) -> Uses {
        let mut u = Uses::new();
        for &(m, a, b) in items {
            u.entry(m).or_default().push((Time::new(a, 1), Time::new(b, 1)));
        }
        u
    }

    #[test]
    fn playhead_near_b_ranks_b_first_and_moving_it_reranks() {
        let (a, b, c) = (Id::fixed(1), Id::fixed(2), Id::fixed(3));
        let u = uses_of(&[(a, 0, 10), (b, 100, 110), (c, 300, 310)]);
        let none = BTreeMap::new();
        let ids = [a, b, c];
        assert_eq!(ProxyOrdering::sorted_near(&ids, &u, Time::new(105, 1), &none), vec![b, a, c]);
        assert_eq!(ProxyOrdering::sorted_near(&ids, &u, Time::new(305, 1), &none), vec![c, b, a]);
        assert_eq!(ProxyOrdering::sorted_near(&ids, &u, Time::ZERO, &none), vec![a, b, c]);
    }

    #[test]
    fn under_the_playhead_is_distance_zero_and_bigger_source_wins_ties() {
        let (small, big, unused) = (Id::fixed(1), Id::fixed(2), Id::fixed(3));
        let u = uses_of(&[(small, 0, 50), (big, 20, 40)]);
        let sizes = BTreeMap::from([(small, 10), (big, 3_500_000_000)]);
        let t = Time::new(30, 1);
        assert_eq!(ProxyOrdering::distance(&u, big, t), Some(Time::ZERO));
        assert_eq!(ProxyOrdering::distance(&u, unused, t), None);
        assert_eq!(ProxyOrdering::sorted_near(&[unused, small, big], &u, t, &sizes), vec![big, small, unused]);
    }

    #[test]
    fn a_running_job_is_dropped_only_when_far_unfinished_and_a_near_one_waits() {
        let s = |n| Some(Time::new(n, 1));
        assert!(ProxyOrdering::should_preempt(s(600), 0.1, s(0)));
        assert!(ProxyOrdering::should_preempt(None, 0.1, s(5)));
        assert!(!ProxyOrdering::should_preempt(s(30), 0.1, s(0)), "the running source is near too");
        assert!(!ProxyOrdering::should_preempt(s(600), 0.8, s(0)), "nearly done: finish it");
        assert!(!ProxyOrdering::should_preempt(s(600), 0.1, s(60)), "the waiting one is not near");
        assert!(!ProxyOrdering::should_preempt(s(600), 0.1, None));
    }
}
