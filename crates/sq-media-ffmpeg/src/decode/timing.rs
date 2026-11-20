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
    /// The container's edit list does not present this sample (FFmpeg's discard flag); it stays for decoding.
    pub hidden: bool,
}

/// The `SampleIndex` of an FFmpeg-demuxed video stream, and the way back from a decoded picture's pts to its frame.
pub struct FrameTable {
    pub index: SampleIndex,
    pub time_base: TimeBase,
    /// Pts of the first presented frame: the index starts at 0 there (a negative stream start, an MP4 edit list, puts the
    /// samples before it in the file; they are hidden, not frames of the clip).
    pub origin_ticks: i64,
    presentation_of_ticks: HashMap<i64, usize>,
    /// (pts, dts, duration) per decode ordinal on the table's clock; a hidden sample sits at the nearest presented time with
    /// zero duration, so a sample reader and the index tell the same story.
    times: Vec<(Time, Time, Time)>,
}

impl FrameTable {
    pub fn new(packets: &[PacketTiming], time_base: TimeBase) -> FrameTable {
        let shown = || packets.iter().filter(|p| !p.hidden);
        // Without any presented sample nothing is hidden (a broken edit list must not empty the clip).
        let any_shown = shown().next().is_some();
        let hidden_of = |p: &PacketTiming| p.hidden && any_shown;
        let source: Vec<&PacketTiming> = if any_shown { shown().collect() } else { packets.iter().collect() };
        let origin = source.iter().map(|p| p.pts).min().unwrap_or(0);
        let end = source.iter().map(|p| p.pts + p.duration.max(0)).max().unwrap_or(0);
        let make = |ordinal: usize, p: &PacketTiming| {
            let hidden = hidden_of(p);
            let pts = if hidden { p.pts.clamp(origin, end) } else { p.pts };
            Entry {
                pts: time_base.time(pts - origin),
                dts: time_base.time(p.dts - origin),
                duration: if hidden { Time::ZERO } else { time_base.time(p.duration.max(0)) },
                is_sync: p.is_key,
                decode_ordinal: ordinal as i64,
            }
        };
        let times = packets
            .iter()
            .enumerate()
            .map(|(o, p)| {
                let e = make(o, p);
                (e.pts, e.dts, e.duration)
            })
            .collect();
        // Hidden samples (an edit list cuts them out) are no frames: frame 0 is the first presented picture. They stay
        // in the decode plan, since a presented frame may reference them and the decoder may never output them (leading
        // pictures of a cut GOP).
        let (hidden, shown): (Vec<_>, Vec<_>) =
            packets.iter().enumerate().map(|(o, p)| (hidden_of(p), make(o, p))).partition(|(h, _)| *h);
        let index = SampleIndex::with_hidden(
            shown.into_iter().map(|(_, e)| e).collect(),
            hidden.into_iter().map(|(_, e)| e).collect(),
        );
        let mut map = HashMap::new();
        for (i, e) in index.entries().iter().enumerate() {
            // The decoder reports the sample's own pts.
            let key = packets[e.decode_ordinal as usize].pts;
            if e.duration > Time::ZERO || !map.contains_key(&key) {
                map.insert(key, i);
            }
        }
        FrameTable { index, time_base, origin_ticks: origin, presentation_of_ticks: map, times }
    }

    /// (pts, dts, duration) of the sample with decode ordinal `ordinal`, as the index tells it.
    pub fn sample_times(&self, ordinal: usize) -> Option<(Time, Time, Time)> {
        self.times.get(ordinal).copied()
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
        PacketTiming { pts, dts, duration, is_key, hidden: false }
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

    /// An MP4 cut between key frames (`ffmpeg -ss .. -c copy`): the edit list hides the samples before time 0, among them two
    /// leading B pictures whose references are not in the file, so the decoder never outputs them. The clip starts at the
    /// first presented sample; the hidden ones stay in the table with zero duration and nobody waits for them.
    #[test]
    fn samples_hidden_by_an_edit_list_do_not_start_the_clip() {
        let h = |pts, dts, key| PacketTiming { pts, dts, duration: 1001, is_key: key, hidden: true };
        let packets = vec![
            h(-3003, -6006, true),
            h(-5005, -5005, false),
            h(-4004, -4004, false),
            pk(0, -3003, 1001, false),
            h(-2002, -2002, false),
            h(-1001, -1001, false),
            pk(1001, 0, 1001, false),
        ];
        let table = FrameTable::new(&packets, TimeBase::new(1, 30_000).unwrap());
        assert_eq!(table.origin_ticks, 0);
        let e = table.index.entries();
        assert_eq!(table.index.count(), 2);
        // Hidden samples are no frames: only the two presented pictures are numbered.
        assert_eq!(e.iter().map(|x| x.decode_ordinal).collect::<Vec<_>>(), vec![3, 6]);
        assert_eq!(table.index.frame_at(Time::ZERO), Some(0));
        assert_eq!(table.index.sync_decode_ordinal(0), 0); // frame 0 decodes from the hidden key frame
        // The decoder reports each sample's own pts; a hidden picture is not looked up.
        assert_eq!(table.presentation_index(1001), Some(1));
        assert_eq!(table.presentation_index(-3003), None);
        // The sample reader agrees: hidden samples sit at the nearest presented time with no duration.
        let t30 = TimeBase::new(1, 30_000).unwrap();
        assert_eq!(table.sample_times(0), Some((Time::ZERO, t30.time(-6006), Time::ZERO)));
        assert_eq!(table.sample_times(6).map(|t| t.2), Some(t30.time(1001)));
    }

    /// A cut in the middle of the stream: the hidden sample is neither a frame nor a lookup target.
    #[test]
    fn a_sample_hidden_mid_stream_is_never_looked_up() {
        let hid = PacketTiming { pts: 500, dts: 500, duration: 500, is_key: false, hidden: true };
        let packets = vec![pk(0, 0, 500, true), hid, pk(1001, 1001, 500, false)];
        let table = FrameTable::new(&packets, TimeBase::new(1, 1000).unwrap());
        assert_eq!(table.index.count(), 2);
        for ms in [0, 400, 500, 700, 1000, 1001, 1400] {
            let i = table.index.frame_at(Time::new(ms, 1000)).expect("a frame");
            assert!(table.index.entries()[i].duration > Time::ZERO, "{ms} ms");
        }
        assert_eq!(table.index.frame_at(Time::new(700, 1000)), Some(0));
        assert_eq!(table.sample_times(1).map(|t| t.2), Some(Time::ZERO));
    }

    /// Without an edit list the table is the plain one: every sample a frame, pts shifted to 0, times as the entries.
    #[test]
    fn a_stream_without_hidden_samples_keeps_its_table() {
        let table = FrameTable::new(&reordered_packets(), tb());
        for (o, p) in reordered_packets().iter().enumerate() {
            assert_eq!(table.sample_times(o), Some((tb().time(p.pts - 1024), tb().time(p.dts - 1024), tb().time(512))));
        }
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
