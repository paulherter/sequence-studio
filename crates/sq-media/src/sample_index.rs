// Swift: SampleIndex.swift
//! Presentation-ordered frame table of one video track. Pure value, built once per media.

use sq_core_time::Time;
use std::ops::RangeInclusive;

/// One frame of the table.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Entry {
    pub pts: Time,
    pub dts: Time,
    pub duration: Time,
    pub is_sync: bool,
    pub decode_ordinal: i64,
}

/// Presentation-ordered frame table of one video track.
#[derive(Clone, Debug)]
pub struct SampleIndex {
    /// Sorted by pts; pts 0 = first presented frame (edit-list / start offset removed). Samples the edit list does not
    /// present have zero duration (pts = the cut point); they stay in the table because later frames may reference them.
    entries: Vec<Entry>,
    /// decodeOrdinal -> presentation index.
    presentation_index_of_ordinal: Vec<usize>,
    /// Decode ordinals of sync samples, ascending.
    sync_ordinals: Vec<i64>,
}

impl SampleIndex {
    /// `raw` may come in any order; pts and dts are shifted so the smallest pts becomes 0.
    /// `decode_ordinal`s must be the contiguous range 0..count.
    pub fn new(raw: Vec<Entry>) -> SampleIndex {
        let origin = raw.iter().map(|e| e.pts).min().unwrap_or(Time::ZERO);
        let mut e: Vec<Entry> = raw
            .into_iter()
            .map(|mut x| {
                x.pts -= origin;
                x.dts -= origin;
                x
            })
            .collect();
        // Equal pts: zero-duration entries (samples an edit list cuts out, kept for decoding) sort first, so
        // `frame_at` picks the frame that is actually shown there.
        e.sort_by(|a, b| {
            a.pts
                .cmp(&b.pts)
                .then_with(|| (b.duration == Time::ZERO).cmp(&(a.duration == Time::ZERO)))
                .then_with(|| a.decode_ordinal.cmp(&b.decode_ordinal))
        });
        let mut inv = vec![0usize; e.len()];
        for (i, x) in e.iter().enumerate() {
            if let Ok(o) = usize::try_from(x.decode_ordinal)
                && o < e.len()
            {
                inv[o] = i;
            }
        }
        let mut sync_ordinals: Vec<i64> = e.iter().filter(|x| x.is_sync).map(|x| x.decode_ordinal).collect();
        sync_ordinals.sort();
        SampleIndex { entries: e, presentation_index_of_ordinal: inv, sync_ordinals }
    }

    /// The frames, sorted by pts.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Number of frames.
    pub fn count(&self) -> usize {
        self.entries.len()
    }

    /// End of the last frame.
    pub fn duration(&self) -> Time {
        self.entries.iter().map(|x| x.pts + x.duration).max().unwrap_or(Time::ZERO)
    }

    /// Index of the frame with pts <= t < next pts (VFR-safe); None before the first frame or at/after the end.
    pub fn frame_at(&self, t: Time) -> Option<usize> {
        let last = self.entries.last()?;
        if t < Time::ZERO || t >= last.pts + last.duration {
            return None;
        }
        // first index with pts > t
        let lo = self.entries.partition_point(|x| x.pts <= t);
        lo.checked_sub(1)
    }

    /// Decode ordinal of the sync sample that starts the GOP of decode ordinal `o`.
    fn sync_ordinal_at_or_spanning(&self, o: i64) -> i64 {
        let lo = self.sync_ordinals.partition_point(|&s| s <= o);
        if lo > 0 { self.sync_ordinals[lo - 1] } else { 0 }
    }

    /// Decode ordinal of the sync sample to start decoding from for presentation frame `index`.
    pub fn sync_decode_ordinal(&self, index: usize) -> i64 {
        self.sync_ordinal_at_or_spanning(self.entries[index].decode_ordinal)
    }

    /// Decode ordinal a decoder must have run from (without a flush since) for frame `index` to come out whole: the sync
    /// sample of `fresh_decode_start`. A session that started later (at an open GOP's sync sample) lacks the references of
    /// that GOP's leading pictures, and decoding them anyway gives a picture built on missing references.
    pub fn reference_start_ordinal(&self, index: usize) -> i64 {
        self.sync_decode_ordinal(self.fresh_decode_start(index))
    }

    /// Presentation index of the sync sample a fresh decode for frame `index` starts at (its GOP's, one GOP earlier for a
    /// leading picture): decoding from there to `index` yields every frame in between on the way.
    pub fn decode_start_index(&self, index: usize) -> usize {
        usize::try_from(self.reference_start_ordinal(index))
            .ok()
            .and_then(|o| self.presentation_index_of_ordinal.get(o).copied())
            .unwrap_or(0)
            .min(index)
    }

    /// Presentation index a fresh decode (after a flush) starts from so that frame `index` comes out. Open-GOP streams
    /// (HEVC CRA, x265's default) put leading pictures after the sync sample in decode order but before it in
    /// presentation; they reference the previous GOP, and a decoder that starts at that sync sample drops them. For such
    /// a frame the start steps back one GOP (until the frame is not a leading picture of the start's GOP).
    pub fn fresh_decode_start(&self, index: usize) -> usize {
        let mut lo = index;
        while lo > 0 {
            // lo == 0: no earlier GOP (clip start)
            let sync = self.presentation_index_of_ordinal[self.sync_decode_ordinal(lo) as usize];
            if lo >= sync {
                break;
            }
            lo = self.previous_sync(lo); // strictly decreasing: terminates
        }
        lo
    }

    /// Presentation indices of the frames that belong to the GOP (sync sample up to the next one in decode order).
    pub fn gop(&self, index: usize) -> RangeInclusive<usize> {
        let s = self.sync_decode_ordinal(index);
        let lo = self.sync_ordinals.partition_point(|&x| x <= s);
        let end = if lo < self.sync_ordinals.len() { self.sync_ordinals[lo] } else { self.entries.len() as i64 };
        let (mut mn, mut mx) = (usize::MAX, usize::MIN);
        for o in s..(s + 1).max(end) {
            if let Some(&p) = usize::try_from(o).ok().and_then(|o| self.presentation_index_of_ordinal.get(o)) {
                mn = mn.min(p);
                mx = mx.max(p);
            }
        }
        mn..=mx
    }

    /// Presentation index of the nearest sync frame strictly before `index` (0 when there is none).
    pub fn previous_sync(&self, index: usize) -> usize {
        let mut i = index.min(self.entries.len());
        while i > 0 {
            i -= 1;
            if self.entries[i].is_sync {
                return i;
            }
        }
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds entries from a presentation-order list of decode ordinals (Swift shuffles; the sort makes order irrelevant,
    /// so a fixed reversal stands in for it).
    fn make_index(pts: &[i64], dec: &[i64], sync: &[i64], offset: i64) -> SampleIndex {
        let scale = 30;
        let mut es: Vec<Entry> = pts
            .iter()
            .zip(dec)
            .map(|(&p, &d)| Entry {
                pts: Time::new(p + offset, scale),
                dts: Time::new(d + offset - 2, scale),
                duration: Time::new(1, scale),
                is_sync: sync.contains(&d),
                decode_ordinal: d,
            })
            .collect();
        es.reverse();
        SampleIndex::new(es)
    }

    // Presentation 0..11, two closed GOPs of 6. GOP A presentation 0...5 decode ordinals: 0:0 1:2 2:3 3:1 4:5 5:4;
    // GOP B presentation 6...11 ordinals +6.
    const PRES_DEC: [i64; 12] = [0, 2, 3, 1, 5, 4, 6, 8, 9, 7, 11, 10];

    fn range12() -> Vec<i64> {
        (0..12).collect()
    }

    #[test]
    fn normalises_first_presented_frame_to_zero_and_sorts() {
        let idx = make_index(&range12(), &PRES_DEC, &[0, 6], 100);
        assert_eq!(idx.entries().first().map(|e| e.pts), Some(Time::ZERO));
        assert!(idx.entries().windows(2).all(|w| w[0].pts < w[1].pts));
        assert_eq!(idx.entries().iter().map(|e| e.decode_ordinal).collect::<Vec<_>>(), PRES_DEC.to_vec());
        assert_eq!(idx.duration(), Time::new(12, 30));
    }

    #[test]
    fn frame_lookup_outside_range_is_none() {
        let idx = make_index(&range12(), &PRES_DEC, &[0, 6], 0);
        assert_eq!(idx.frame_at(Time::new(-1, 30)), None);
        assert_eq!(idx.frame_at(Time::new(12, 30)), None);
        assert_eq!(idx.frame_at(Time::new(5, 1)), None);
        assert_eq!(idx.frame_at(Time::ZERO), Some(0));
        assert_eq!(idx.frame_at(Time::new(11, 30)), Some(11));
        assert_eq!(idx.frame_at(Time::new(3, 30)), Some(3));
        assert_eq!(idx.frame_at(Time::new(3, 30) + Time::new(1, 60)), Some(3));
    }

    #[test]
    fn frame_lookup_is_vfr_safe() {
        // pts in 1/60: 0, 2, 3, 7, 8, 12 with durations to next.
        let p: [i64; 6] = [0, 2, 3, 7, 8, 12];
        let es: Vec<Entry> = p
            .iter()
            .enumerate()
            .map(|(i, &v)| Entry {
                pts: Time::new(v, 60),
                dts: Time::new(v, 60),
                duration: Time::new(p.get(i + 1).copied().unwrap_or(14) - v, 60),
                is_sync: i == 0,
                decode_ordinal: i as i64,
            })
            .collect();
        let idx = SampleIndex::new(es);
        assert_eq!(idx.frame_at(Time::new(1, 60)), Some(0));
        assert_eq!(idx.frame_at(Time::new(2, 60)), Some(1));
        assert_eq!(idx.frame_at(Time::new(6, 60)), Some(2));
        assert_eq!(idx.frame_at(Time::new(7, 60)), Some(3));
        assert_eq!(idx.frame_at(Time::new(13, 60)), Some(5));
        assert_eq!(idx.frame_at(Time::new(14, 60)), None);
    }

    #[test]
    fn gop_ranges_with_b_frame_reorder() {
        let idx = make_index(&range12(), &PRES_DEC, &[0, 6], 0);
        for i in 0..6 {
            assert_eq!(idx.gop(i), 0..=5);
        }
        for i in 6..12 {
            assert_eq!(idx.gop(i), 6..=11);
        }
        assert_eq!(idx.sync_decode_ordinal(4), 0);
        assert_eq!(idx.sync_decode_ordinal(9), 6);
    }

    /// Open GOP (x265 CRA): the CRA at presentation 8 is decoded before the leading pictures 6 and 7, which reference GOP A.
    #[test]
    fn fresh_decode_start_steps_back_for_leading_pictures_of_an_open_gop() {
        let idx = make_index(&range12(), &[0, 2, 3, 1, 5, 4, 7, 8, 6, 10, 11, 9], &[0, 6], 0);
        assert_eq!(idx.sync_decode_ordinal(7), 6); // the CRA's GOP in decode order
        assert_eq!(idx.fresh_decode_start(6), 0); // leading pictures: start at GOP A
        assert_eq!(idx.fresh_decode_start(7), 0);
        assert_eq!(idx.fresh_decode_start(8), 8); // the CRA and the frames after it: unchanged (their GOP's sync)
        assert_eq!(idx.fresh_decode_start(11), 11);
        assert_eq!(idx.sync_decode_ordinal(11), 6);
        assert_eq!(idx.fresh_decode_start(5), 5);
        assert_eq!(idx.fresh_decode_start(0), 0);
        // The sync sample a decode starts at: the CRA (8) for its trailing pictures, GOP A's for the leading ones.
        assert_eq!((idx.decode_start_index(11), idx.decode_start_index(7), idx.decode_start_index(5)), (8, 0, 0));
        // Closed GOPs never step back.
        let closed = make_index(&range12(), &PRES_DEC, &[0, 6], 0);
        assert!((0..12).all(|i| closed.fresh_decode_start(i) == i));
    }

    #[test]
    fn previous_sync() {
        let idx = make_index(&range12(), &PRES_DEC, &[0, 6], 0);
        assert_eq!(idx.previous_sync(0), 0);
        assert_eq!(idx.previous_sync(5), 0);
        assert_eq!(idx.previous_sync(6), 0);
        assert_eq!(idx.previous_sync(7), 6);
        assert_eq!(idx.previous_sync(11), 6);
    }

    #[test]
    fn single_gop_and_empty() {
        let one = make_index(&[0, 1, 2], &[0, 2, 1], &[0], 0);
        assert_eq!(one.gop(2), 0..=2);
        assert_eq!(SampleIndex::new(vec![]).frame_at(Time::ZERO), None);
    }
}
