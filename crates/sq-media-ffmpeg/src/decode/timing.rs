use sq_core_time::Time;
use sq_media::sample_index::{Entry, SampleIndex};
use std::collections::{HashMap, HashSet};
use std::ops::RangeInclusive;

/// An FFmpeg stream time base (seconds per tick = num / den) and exact conversions to rational `Time`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TimeBase {
    num: i64,
    den: i64,
}

impl TimeBase {
    /// Both parts must be positive (a stream without a time base cannot be indexed).
    pub fn new(num: i64, den: i64) -> Option<TimeBase> {
        (num > 0 && den > 0).then_some(TimeBase { num, den })
    }

    pub fn time(self, ticks: i64) -> Time {
        Time::reducing(i128::from(ticks) * i128::from(self.num), i128::from(self.den))
    }

    /// Ticks nearest to `t` (half away from zero); exact when `t` lies on the tick grid.
    pub fn ticks(self, t: Time) -> i64 {
        let n = i128::from(t.value()) * i128::from(self.den);
        let d = i128::from(t.timescale()) * i128::from(self.num);
        let (q, r) = (n / d, n % d);
        let ticks = if 2 * r.abs() >= d.abs() { if n < 0 { q - 1 } else { q + 1 } } else { q };
        i64::try_from(ticks).unwrap_or(if ticks < 0 { i64::MIN } else { i64::MAX })
    }
}

/// One demuxed packet as the index pass reports it (stream ticks, decode order).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PacketTiming {
    pub pts: i64,
    pub dts: i64,
    pub duration: i64,
    pub is_key: bool,
}

/// The `SampleIndex` of an FFmpeg-demuxed video stream, and the way back from a decoded picture's pts to its frame.
pub struct FrameTable {
    pub index: SampleIndex,
    pub time_base: TimeBase,
    /// Smallest pts: the index starts at 0 there.
    pub origin_ticks: i64,
    presentation_of_ticks: HashMap<i64, usize>,
}

impl FrameTable {
    pub fn new(packets: &[PacketTiming], time_base: TimeBase) -> FrameTable {
        let origin = packets.iter().map(|p| p.pts).min().unwrap_or(0);
        let entries = packets
            .iter()
            .enumerate()
            .map(|(ordinal, p)| Entry {
                pts: time_base.time(p.pts - origin),
                dts: time_base.time(p.dts - origin),
                duration: time_base.time(p.duration.max(0)),
                is_sync: p.is_key,
                decode_ordinal: ordinal as i64,
            })
            .collect();
        let index = SampleIndex::new(entries);
        let mut map = HashMap::new();
        for (i, e) in index.entries().iter().enumerate() {
            let key = time_base.ticks(e.pts) + origin;
            if e.duration > Time::ZERO || !map.contains_key(&key) {
                map.insert(key, i);
            }
        }
        FrameTable { index, time_base, origin_ticks: origin, presentation_of_ticks: map }
    }

    /// Presentation index of a decoded picture's pts (stream ticks); `None` when no packet had that pts.
    pub fn presentation_index(&self, ticks: i64) -> Option<usize> {
        self.presentation_of_ticks.get(&ticks).copied()
    }
}

/// Where the decoder continues after the previous call.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct DecodeCursor {
    /// Next decode ordinal to send.
    pub next_ordinal: i64,
    /// Last presentation index the previous call returned.
    pub last_presented: usize,
    /// Ordinal the decoder started at (its last flush): frames whose references lie before it need a seek.
    pub origin: i64,
}

/// Decode-order planning for `VideoDecoding::decode` over a `SampleIndex` (pure).
pub enum DecodePlan {}

impl DecodePlan {
    /// First ordinal to send for `range`, and whether the decoder must drop its state first (a seek). Forward playback
    /// (`range` starts right after the previous call's last frame) continues without flushing, and so does a short jump
    /// ahead whose frames are all still to be sent (or `carried`) when a seek would not start later (the Mac
    /// `VideoDecoder.plan`). A seek to a leading picture of an open GOP starts one GOP earlier
    /// (`SampleIndex::fresh_decode_start`): FFmpeg drops the RASL pictures of a CRA it starts at.
    pub fn start(
        range: &RangeInclusive<usize>,
        index: &SampleIndex,
        cursor: Option<DecodeCursor>,
        carried: &HashSet<usize>,
    ) -> (i64, bool) {
        let fresh = index.reference_start_ordinal(*range.start());
        // A decoder that started after a frame's references (at an open GOP's sync sample) cannot continue to it.
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

    /// The frames of `range` the caller expects back (zero-duration entries the edit list hides are left out).
    pub fn wanted(range: &RangeInclusive<usize>, index: &SampleIndex) -> HashSet<usize> {
        range.clone().filter(|i| index.entries()[*i].duration > Time::ZERO).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tb() -> TimeBase {
        TimeBase::new(1, 15_360).unwrap()
    }

    fn pk(pts: i64, dts: i64, duration: i64, is_key: bool) -> PacketTiming {
        PacketTiming { pts, dts, duration, is_key }
    }

    #[test]
    fn ticks_round_trip_exactly() {
        for ticks in [0, 1, 512, 15_360, 1_234_567, -512] {
            assert_eq!(tb().ticks(tb().time(ticks)), ticks);
        }
        assert_eq!(tb().time(512), Time::new(1, 30));
        assert_eq!(TimeBase::new(1001, 30_000).map(|t| t.time(3)), Some(Time::new(3003, 30_000)));
        assert!(TimeBase::new(0, 1).is_none());
    }

    #[test]
    fn off_grid_time_rounds_to_nearest_tick() {
        assert_eq!(tb().ticks(Time::new(1, 61_440)), 0); // a quarter tick
        assert_eq!(tb().ticks(Time::new(1, 30_720)), 1); // half a tick rounds up
        assert_eq!(tb().ticks(Time::new(-1, 30_720)), -1); // and away from zero below it
    }

    /// I P B B, as a B-frame encoder writes it: decode order differs from presentation order, pts starts at 1024.
    fn reordered_packets() -> Vec<PacketTiming> {
        vec![
            pk(1024, 0, 512, true),
            pk(2560, 512, 512, false),
            pk(1536, 1024, 512, false),
            pk(2048, 1536, 512, false),
            pk(3072, 2048, 512, true),
            pk(3584, 2560, 512, false),
        ]
    }

    fn start(range: RangeInclusive<usize>, index: &SampleIndex, cursor: Option<DecodeCursor>) -> (i64, bool) {
        DecodePlan::start(&range, index, cursor, &HashSet::new())
    }

    fn cursor(next_ordinal: i64, last_presented: usize) -> Option<DecodeCursor> {
        Some(DecodeCursor { next_ordinal, last_presented, origin: 0 })
    }

    #[test]
    fn frame_table_maps_decoded_pts_to_presentation_order() {
        let table = FrameTable::new(&reordered_packets(), tb());
        let e = table.index.entries();
        assert_eq!(table.index.count(), 6);
        assert_eq!(e.iter().map(|x| x.decode_ordinal).collect::<Vec<_>>(), vec![0, 2, 3, 1, 4, 5]);
        assert_eq!(e[0].pts, Time::ZERO);
        assert_eq!(e[3].pts, Time::new(3, 30));
        assert_eq!(table.presentation_index(2560), Some(3));
        assert_eq!(table.presentation_index(1024), Some(0));
        assert_eq!(table.presentation_index(999), None);
        assert_eq!(table.time_base.ticks(e[3].pts) + table.origin_ticks, 2560);
    }

    #[test]
    fn seek_starts_at_the_sync_sample_and_flushes() {
        let table = FrameTable::new(&reordered_packets(), tb());
        assert_eq!(start(2..=3, &table.index, None), (0, true));
        // Behind the frames already sent (presentation 1 is decode ordinal 2): a seek.
        assert_eq!(start(1..=1, &table.index, cursor(4, 3)), (0, true));
        // Far ahead (the GOP at ordinal 4 while the decoder is still at ordinal 1): a seek, not decoding the gap.
        assert_eq!(start(5..=5, &table.index, cursor(1, 0)), (4, true));
    }

    /// x265 open GOP: the CRA (presentation 8) is sent before its leading pictures 6 and 7. A seek to one of them starts
    /// at the previous GOP's sync sample, since FFmpeg drops the RASL pictures of a CRA it starts at.
    #[test]
    fn seek_to_a_leading_picture_starts_one_gop_earlier() {
        let order: [i64; 12] = [0, 3, 1, 2, 5, 4, 8, 6, 7, 11, 9, 10]; // presentation frame of each decode ordinal
        let packets: Vec<_> =
            order.iter().enumerate().map(|(o, f)| pk(1024 + f * 512, o as i64 * 512, 512, o == 0 || o == 6)).collect();
        let index = FrameTable::new(&packets, tb()).index;
        for f in [6, 7] {
            assert_eq!(start(f..=f, &index, None), (0, true));
        }
        assert_eq!(start(8..=8, &index, None).0, 6);
        assert_eq!(start(9..=10, &index, None).0, 6);
        assert_eq!(start(3..=7, &index, None).0, 0);
        // GOP A sent (ordinals 0-5, last frame returned 5) and frame 6 skipped: 7 continues at the CRA instead of
        // decoding GOP A again.
        assert_eq!(start(7..=7, &index, cursor(6, 5)), (6, false));
        // Started fresh at the CRA (ordinal 6) and returned 8: its leading pictures lack their references, so 6 and 7 seek
        // one GOP back instead of continuing into pictures built on missing references (H.264 open GOP, C2177).
        let at_cra = Some(DecodeCursor { next_ordinal: 7, last_presented: 8, origin: 6 });
        for f in [6, 7] {
            assert_eq!(start(f..=f, &index, at_cra), (0, true));
        }
    }

    /// A jump ahead whose frames are all still to be sent (or carried over) continues, as the Mac decoder's plan does.
    #[test]
    fn short_jump_ahead_continues_without_flush() {
        let table = FrameTable::new(&reordered_packets(), tb());
        assert_eq!(start(5..=5, &table.index, cursor(4, 1)), (4, false));
        // Presentation 2 (ordinal 3) was already sent: only a carried picture lets the call continue.
        let c = cursor(4, 0);
        assert!(start(2..=5, &table.index, c).1);
        assert!(!DecodePlan::start(&(2..=5), &table.index, c, &HashSet::from([1, 2, 3])).1);
    }

    #[test]
    fn forward_playback_continues_without_flush() {
        let table = FrameTable::new(&reordered_packets(), tb());
        assert_eq!(start(4..=5, &table.index, cursor(4, 3)), (4, false));
    }

    #[test]
    fn wanted_skips_hidden_frames() {
        let mut packets = reordered_packets();
        packets[2].duration = 0;
        let table = FrameTable::new(&packets, tb());
        let hidden = table.index.entries().iter().position(|e| e.duration == Time::ZERO);
        let wanted = DecodePlan::wanted(&(0..=5), &table.index);
        assert!(hidden.is_some_and(|h| !wanted.contains(&h)));
        assert_eq!(wanted.len(), 5);
    }
}
