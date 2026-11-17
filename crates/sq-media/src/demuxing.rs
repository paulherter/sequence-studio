//! Port of `SQMedia/Sources/SQMedia/Demuxing.swift` (the CoreMedia-less variant the Windows build uses).

use crate::media_error::MediaError;
use crate::sample_index::SampleIndex;
use sq_core_time::Time;
use std::future::Future;
use std::ops::RangeInclusive;
use std::pin::Pin;

/// A boxed future: what an `async` method of a dyn-compatible trait returns.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Compressed sample (one access unit, decode order): the bytes plus timing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DemuxedSample {
    pub data: Vec<u8>,
    pub pts: Time,
    pub dts: Time,
    pub duration: Time,
    pub is_sync: bool,
}

/// Stream format: codec name (FFmpeg's, e.g. "h264", "hevc"), coded size and the codec configuration record
/// (avcC / hvcC payload, FFmpeg "extradata").
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DemuxedFormat {
    pub codec: String,
    pub width: i64,
    pub height: i64,
    pub extradata: Vec<u8>,
}

impl DemuxedFormat {
    pub fn new(codec: &str, width: i64, height: i64, extradata: Vec<u8>) -> DemuxedFormat {
        DemuxedFormat { codec: codec.to_string(), width, height, extradata }
    }
}

pub trait Demuxing: Send + Sync {
    fn index(&self) -> &SampleIndex;

    /// The stream's own sync flags. `index` may present more frames as sync than the codec has (QuickTime Animation:
    /// every frame is random access, its decoder restores state itself); decoders that rebuild state from the real key
    /// frames read this. Default: `index`.
    fn coded_index(&self) -> &SampleIndex {
        self.index()
    }

    fn format_description(&self) -> &DemuxedFormat;

    /// Clockwise quarter turns (0, 90, 180, 270 degrees) the decoded picture needs to be upright (track preferred transform).
    fn rotation(&self) -> i64 {
        0
    }

    /// Compressed samples needed to decode presentation frames `range`, in decode order (from the GOP's sync sample).
    fn samples_for(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DemuxedSample>, MediaError>>;

    /// The samples of `samples_for(range)` from decode ordinal `from_decode_ordinal` on (a decoder continuing a GOP
    /// already submitted the ones before it). Default: reads the whole run and drops the head.
    fn samples_from(
        &self,
        range: RangeInclusive<usize>,
        from_decode_ordinal: i64,
    ) -> BoxFuture<'_, Result<Vec<DemuxedSample>, MediaError>> {
        Box::pin(async move {
            let skip = from_decode_ordinal - self.index().sync_decode_ordinal(*range.start());
            let mut all = self.samples_for(range).await?;
            if skip > 0 {
                all.drain(..usize::try_from(skip).unwrap_or(usize::MAX).min(all.len()));
            }
            Ok(all)
        })
    }

    /// A streaming reader for the same samples as `samples_from`; `None` = the demuxer only reads whole runs.
    fn sample_reader(
        &self,
        _range: RangeInclusive<usize>,
        _from_decode_ordinal: i64,
    ) -> Result<Option<Box<dyn SampleReading>>, MediaError> {
        Ok(None)
    }
}

/// Compressed samples of one decode run, read one at a time in decode order (synchronous, blocking file reads), so a
/// decoder can submit the first sample while the rest are still being read (PLAYBACK-PERF "Seek: exact frame sooner").
pub trait SampleReading {
    /// Samples left to read.
    fn count(&self) -> usize;
    /// The next sample (decode order). Fails when the file ends early.
    fn next(&mut self) -> Result<DemuxedSample, MediaError>;
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::sample_index::Entry;
    use std::task::{Context, Poll, Waker};

    /// Runs a future that never waits on anything but itself.
    pub(crate) fn block_on<T>(fut: impl Future<Output = T>) -> T {
        let mut fut = std::pin::pin!(fut);
        let mut cx = Context::from_waker(Waker::noop());
        loop {
            if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
                return v;
            }
        }
    }

    /// Frames 0...5 in decode order = presentation order, a sync sample every third frame.
    pub(crate) struct FakeDemuxer {
        index: SampleIndex,
        format: DemuxedFormat,
    }

    impl FakeDemuxer {
        pub(crate) fn new(frames: i64) -> FakeDemuxer {
            let entries = (0..frames)
                .map(|i| Entry {
                    pts: Time::new(i, 30),
                    dts: Time::new(i, 30),
                    duration: Time::new(1, 30),
                    is_sync: i % 3 == 0,
                    decode_ordinal: i,
                })
                .collect();
            FakeDemuxer { index: SampleIndex::new(entries), format: DemuxedFormat::new("h264", 64, 48, vec![1, 2]) }
        }
    }

    impl Demuxing for FakeDemuxer {
        fn index(&self) -> &SampleIndex {
            &self.index
        }
        fn format_description(&self) -> &DemuxedFormat {
            &self.format
        }
        fn samples_for(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DemuxedSample>, MediaError>> {
            Box::pin(async move {
                let start = self.index.sync_decode_ordinal(*range.start());
                let end = *range.end() as i64;
                Ok((start..=end)
                    .map(|o| DemuxedSample {
                        data: vec![o as u8],
                        pts: Time::new(o, 30),
                        dts: Time::new(o, 30),
                        duration: Time::new(1, 30),
                        is_sync: o % 3 == 0,
                    })
                    .collect())
            })
        }
    }

    fn ordinals(s: &[DemuxedSample]) -> Vec<u8> {
        s.iter().map(|x| x.data[0]).collect()
    }

    #[test]
    fn defaults_read_the_index_and_no_rotation() {
        let d = FakeDemuxer::new(6);
        assert_eq!(d.rotation(), 0);
        assert_eq!(d.coded_index().count(), 6);
        assert_eq!(d.format_description().codec, "h264");
        assert!(d.sample_reader(0..=1, 0).unwrap().is_none());
    }

    #[test]
    fn continued_read_drops_the_samples_already_submitted() {
        let d = FakeDemuxer::new(6);
        // Frame 4 starts in the GOP of sync sample 3.
        assert_eq!(ordinals(&block_on(d.samples_for(4..=4)).unwrap()), vec![3, 4]);
        assert_eq!(ordinals(&block_on(d.samples_from(4..=4, 3)).unwrap()), vec![3, 4]);
        assert_eq!(ordinals(&block_on(d.samples_from(4..=4, 4)).unwrap()), vec![4]);
        assert_eq!(ordinals(&block_on(d.samples_from(4..=4, 9)).unwrap()), Vec::<u8>::new());
        assert_eq!(ordinals(&block_on(d.samples_from(4..=4, 0)).unwrap()), vec![3, 4]);
    }
}
