// Swift: ProxyOrdering.swift
//! Order of automatic proxy jobs.

use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use std::cmp::Ordering;
use std::collections::BTreeMap;

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
}
