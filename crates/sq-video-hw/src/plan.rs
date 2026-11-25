//! Decode-order planning over a `SampleIndex` (pure): where to start, which frames are wanted, how to step back.
//! Same rules as the FFmpeg decoder's `DecodePlan` (sq-media-ffmpeg), kept here so this crate does not depend on it.

use sq_core_time::Time;
use sq_media::sample_index::SampleIndex;
use std::collections::HashSet;
use std::ops::RangeInclusive;

/// Frames past the requested range that are sent too, so the decoder's reorder buffer releases the last wanted frame
/// without a flush (and forward playback continues without a seek).
pub const LOOKAHEAD: usize = 4;

/// Where the session continues after the previous call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub next_ordinal: i64,
    pub last_presented: usize,
    /// Ordinal the session started at (its last flush): frames whose references lie before it need a seek.
    pub origin: i64,
}

/// Presentation index of every decode ordinal (a hidden sample: the first presented frame after it). One slot per packet
/// of the file, hidden ones included: sized by the frame count it lost the last decode ordinals of a clip with a
/// stream copy's preroll, so the pictures of its last frames never reached a caller.
pub fn ordinal_map(index: &SampleIndex) -> Vec<usize> {
    (0..index.ordinal_count()).map(|o| index.presentation_index_of_decode_ordinal(o).unwrap_or(0)).collect()
}

/// First ordinal to send for `range`, and whether the session must drop its state first (a seek).
pub fn start(
    range: &RangeInclusive<usize>,
    index: &SampleIndex,
    cursor: Option<Cursor>,
    carried: &HashSet<usize>,
) -> (i64, bool) {
    let fresh = index.reference_start_ordinal(*range.start());
    if let Some(c) = cursor
        && range.clone().all(|i| carried.contains(&i) || index.reference_start_ordinal(i) >= c.origin)
    {
        if *range.start() == c.last_presented + 1 {
            return (c.next_ordinal, false);
        }
        if fresh <= c.next_ordinal
            && range.clone().all(|i| index.entries()[i].decode_ordinal >= c.next_ordinal || carried.contains(&i))
        {
            return (c.next_ordinal, false);
        }
    }
    (fresh, true)
}

/// The frames the caller gets back: zero-duration entries (hidden by the edit list) and frames before `needed_from` stay out.
pub fn wanted(range: &RangeInclusive<usize>, index: &SampleIndex, needed_from: Option<usize>) -> HashSet<usize> {
    let from = needed_from.unwrap_or(0);
    range.clone().filter(|i| *i >= from && index.entries()[*i].duration > Time::ZERO).collect()
}

/// Last presentation index whose samples are sent: `LOOKAHEAD` frames past the range.
pub fn extended_end(range_end: usize, count: usize) -> usize {
    (range_end + LOOKAHEAD).min(count.saturating_sub(1))
}

/// The decode ordinal one GOP before the start `start()` would pick for a seek to `range_start`; `None` at the clip start.
/// The retry for B-frame streams whose landed keyframe lies after the target (G1: HEVC, 3 of 10 first seeks).
pub fn step_back(index: &SampleIndex, range_start: usize) -> Option<i64> {
    let map = ordinal_map(index);
    let sync = index.sync_decode_ordinal(index.fresh_decode_start(range_start));
    let sync_index = *map.get(usize::try_from(sync).ok()?)?;
    if sync_index == 0 {
        return None;
    }
    let earlier = index.previous_sync(sync_index);
    let ordinal = index.entries()[earlier].decode_ordinal;
    (ordinal < sync).then_some(ordinal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_media::sample_index::Entry;

    /// Two closed GOPs `I P B B` at 30 fps: presentation 0..7, decode ordinals 0 2 3 1 | 4 6 7 5.
    fn index() -> SampleIndex {
        let dec = [0i64, 2, 3, 1, 4, 6, 7, 5];
        SampleIndex::new(
            dec.iter()
                .enumerate()
                .map(|(p, &d)| Entry {
                    pts: Time::new(p as i64, 30),
                    dts: Time::new(d, 30),
                    duration: Time::new(1, 30),
                    is_sync: d == 0 || d == 4,
                    decode_ordinal: d,
                })
                .collect(),
        )
    }

    #[test]
    fn seek_starts_at_the_sync_sample_and_flushes() {
        let ix = index();
        assert_eq!(start(&(2..=3), &ix, None, &HashSet::new()), (0, true));
        assert_eq!(start(&(5..=5), &ix, None, &HashSet::new()), (4, true));
        // Behind what was sent: a seek.
        let c = Some(Cursor { next_ordinal: 6, last_presented: 5, origin: 0 });
        assert_eq!(start(&(1..=1), &ix, c, &HashSet::new()), (0, true));
    }

    #[test]
    fn forward_playback_continues_without_a_flush() {
        let ix = index();
        let c = Some(Cursor { next_ordinal: 3, last_presented: 1, origin: 0 });
        assert_eq!(start(&(2..=3), &ix, c, &HashSet::new()), (3, false));
    }

    /// Open GOP as the Sony XAVC files write it (`B B I` per GOP, the I's leading B-frames reference the GOP before):
    /// presentation 0..8, decode order I2 B0 B1 P5 B3 B4 | I8 B6 B7. A session that started at the second I lacks the
    /// references of B6 and B7: asking for them must seek one GOP back, not continue into garbage (C2177 frame 118).
    #[test]
    fn leading_pictures_after_a_start_at_their_gop_seek_back() {
        let order: [usize; 9] = [2, 0, 1, 5, 3, 4, 8, 6, 7]; // presentation frame of each decode ordinal
        let mut entries: Vec<Entry> = (0..9)
            .map(|p| Entry {
                pts: Time::new(p as i64, 30),
                dts: Time::ZERO,
                duration: Time::new(1, 30),
                is_sync: false,
                decode_ordinal: 0,
            })
            .collect();
        for (o, &p) in order.iter().enumerate() {
            entries[p].decode_ordinal = o as i64;
            entries[p].dts = Time::new(o as i64, 30);
            entries[p].is_sync = o == 0 || o == 6;
        }
        let ix = SampleIndex::new(entries);
        // Started fresh at I8 (ordinal 6), returned frame 8, next to send is B6 (ordinal 7).
        let at_i8 = Some(Cursor { next_ordinal: 7, last_presented: 8, origin: 6 });
        for f in [6, 7] {
            assert_eq!(start(&(f..=f), &ix, at_i8, &HashSet::new()), (0, true), "frame {f}");
        }
        // A carried picture is whole already; the I's own GOP continues.
        assert_eq!(start(&(6..=6), &ix, at_i8, &HashSet::from([6])), (7, false));
        // A session that ran from the clip start holds the references: B6 continues.
        let from_start = Some(Cursor { next_ordinal: 7, last_presented: 5, origin: 0 });
        assert_eq!(start(&(6..=7), &ix, from_start, &HashSet::new()), (7, false));
    }

    #[test]
    fn wanted_skips_hidden_and_early_frames() {
        let mut raw: Vec<Entry> = index().entries().to_vec();
        raw[2].duration = Time::ZERO;
        let ix = SampleIndex::new(raw);
        let mut got: Vec<usize> = wanted(&(0..=4), &ix, Some(1)).into_iter().collect();
        got.sort();
        assert_eq!(got, vec![1, 3, 4]);
    }

    #[test]
    fn step_back_goes_one_gop_earlier() {
        let ix = index();
        assert_eq!(step_back(&ix, 5), Some(0));
        assert_eq!(step_back(&ix, 2), None);
        assert_eq!(ordinal_map(&ix), vec![0, 3, 1, 2, 4, 7, 5, 6]);
    }

    /// 6 packets, the first two hidden preroll (an edit list), then frames 0..4 in decode order 2 0 1 4 3 (a B pair at the
    /// end): the map has a slot for every ordinal, so the last two ordinals still name the last frames.
    #[test]
    fn the_ordinal_map_covers_the_packets_after_hidden_preroll() {
        let e = |pts: i64, o: i64, sync: bool| Entry {
            pts: Time::new(pts, 30),
            dts: Time::new(o, 30),
            duration: Time::new(1, 30),
            is_sync: sync,
            decode_ordinal: o,
        };
        let shown = vec![e(2, 3, false), e(0, 2, true), e(1, 4, false), e(4, 5, false), e(3, 6, false)];
        let hidden = vec![e(-2, 0, true), e(-1, 1, false)];
        let ix = SampleIndex::with_hidden(shown, hidden);
        assert_eq!((ix.count(), ix.ordinal_count()), (5, 7));
        let map = ordinal_map(&ix);
        assert_eq!(map.len(), 7);
        assert_eq!(&map[5..], &[4, 3], "the last two packets are the last two frames");
        assert!(ix.is_hidden_ordinal(0) && !ix.is_hidden_ordinal(5));
    }

    #[test]
    fn lookahead_stops_at_the_last_frame() {
        assert_eq!(extended_end(2, 100), 2 + LOOKAHEAD);
        assert_eq!(extended_end(98, 100), 99);
    }
}
