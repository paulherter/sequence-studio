// Swift: ProxyPolicy.swift (the async prober is a blocking trait; `AVSourceSeekProber` is `seek_prober::FfmpegSeekProber`)
//! Decides whether a source needs an automatic proxy: only sources that seek slowly (long-GOP).

use crate::model::ProxyKind;
use crate::proxy_queue::{ProxyJobPriority, ProxyQueue};
use crate::proxy_transcoding::ProxyTranscodeError;
use crate::seek_prober::FfmpegSeekProber;
use sq_core_time::{IdSource, Timestamp};
use std::path::Path;

/// What we know about how a source seeks. Produced by a `SourceSeekProbing` implementation.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SourceSeekInfo {
    /// Video codec FourCC, e.g. "avc1", "hvc1", "apcn".
    pub codec_four_cc: String,
    /// Largest distance (in frames, decode order) between two sync samples in the scanned window.
    /// `None` if unknown (then only the codec decides).
    pub max_sync_distance: Option<i64>,
    /// How many frames were scanned.
    pub scanned_frames: i64,
}

impl SourceSeekInfo {
    /// The window the Mac sample-cursor walk reads.
    pub const DEFAULT_MAX_SAMPLES: usize = 600;

    /// Info with nothing scanned.
    pub fn new(codec_four_cc: &str, max_sync_distance: Option<i64>) -> SourceSeekInfo {
        SourceSeekInfo { codec_four_cc: codec_four_cc.to_string(), max_sync_distance, scanned_frames: 0 }
    }

    /// The facts of a demuxer's sample index: `sync_flags` are the samples' sync flags in order; the first `max_samples`
    /// are read, as the Mac sample-cursor walk. Without a second sync sample the gap is the samples after the last one.
    pub fn from_sync_flags(
        codec_four_cc: &str,
        sync_flags: impl IntoIterator<Item = bool>,
        max_samples: usize,
    ) -> SourceSeekInfo {
        let (mut count, mut last_sync, mut max_gap) = (0i64, None::<i64>, 0i64);
        for is_sync in sync_flags.into_iter().take(max_samples) {
            if is_sync {
                if let Some(l) = last_sync {
                    max_gap = max_gap.max(count - l);
                }
                last_sync = Some(count);
            }
            count += 1;
        }
        if max_gap == 0 && count > 1 {
            max_gap = count - last_sync.unwrap_or(0);
        }
        SourceSeekInfo {
            codec_four_cc: codec_four_cc.to_string(),
            max_sync_distance: if count > 1 { Some(max_gap) } else { None },
            scanned_frames: count,
        }
    }

    /// The QuickTime FourCC `ProxyPolicy` knows for an FFmpeg codec name (any ProRes counts as 422: all are intra);
    /// unknown names pass through.
    pub fn four_cc_for_ffmpeg_codec(name: &str) -> String {
        match name {
            "h264" => "avc1",
            "hevc" => "hvc1",
            "av1" => "av01",
            "vp9" => "vp09",
            "vp8" => "vp08",
            "mpeg2video" => "mp2v",
            "mpeg4" => "mp4v",
            "prores" => "apcn",
            "dnxhd" => "AVdn",
            "mjpeg" => "jpeg",
            "cfhd" => "CFHD",
            "v210" => "v210",
            "rawvideo" => "raw ",
            other => other,
        }
        .to_string()
    }
}

/// Reads how a source seeks.
pub trait SourceSeekProbing: Send + Sync {
    /// The seek facts of the file at `url`.
    fn probe(&self, url: &Path) -> Result<SourceSeekInfo, ProxyTranscodeError>;
}

/// The system's prober: the FFmpeg one every system shares.
pub fn platform_seek_prober() -> Box<dyn SourceSeekProbing> {
    Box::new(FfmpegSeekProber::default())
}

/// Why no proxy is made.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SkipReason {
    /// The codec has only intra frames.
    IntraOnlyCodec,
    /// Syncs are close enough.
    ShortGOP {
        /// The largest distance found.
        max_distance: i64,
    },
    /// Nothing known about the GOP.
    Unknown,
    /// Proxy mode off.
    Disabled,
    /// Long-GOP but light enough to scrub on this machine (Auto).
    LightSource,
    /// Interlaced with Deinterlace off: playback shows the stored fields, and a proxy has none.
    KeepsFields,
}

/// The policy's verdict.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProxyDecision {
    /// Make a proxy of this kind.
    NeedsProxy(ProxyKind),
    /// Make none.
    Skip(SkipReason),
}

impl ProxyDecision {
    /// A proxy is wanted.
    pub fn needs_proxy(&self) -> bool {
        matches!(self, ProxyDecision::NeedsProxy(_))
    }
}

/// Decides whether a source needs an automatic proxy: only sources that seek slowly (long-GOP).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProxyPolicy {
    /// Sources whose largest sync-sample distance exceeds this many frames are long-GOP.
    pub max_sync_distance: i64,
    /// Kind produced automatically.
    pub auto_kind: ProxyKind,
}

impl Default for ProxyPolicy {
    fn default() -> ProxyPolicy {
        ProxyPolicy { max_sync_distance: 8, auto_kind: ProxyKind::ProxyHalf }
    }
}

impl ProxyPolicy {
    /// Intra-only codecs: ProRes (all), DNxHD/HR, MJPEG, Cineform, Apple Intermediate, uncompressed.
    pub const INTRA_CODECS: [&'static str; 19] = [
        "apcn", "apch", "apcs", "apco", "ap4h", "ap4x", "aprn", "aprh", "AVdn", "AVdh", "mjpa", "mjpb", "jpeg", "CFHD",
        "icod", "v210", "2vuy", "yuv2", "raw ",
    ];

    /// The verdict for a source.
    pub fn decide(&self, info: &SourceSeekInfo) -> ProxyDecision {
        if Self::INTRA_CODECS.contains(&info.codec_four_cc.as_str()) {
            return ProxyDecision::Skip(SkipReason::IntraOnlyCodec);
        }
        let Some(d) = info.max_sync_distance else { return ProxyDecision::Skip(SkipReason::Unknown) };
        if d > self.max_sync_distance {
            ProxyDecision::NeedsProxy(self.auto_kind)
        } else {
            ProxyDecision::Skip(SkipReason::ShortGOP { max_distance: d })
        }
    }
}

/// Connects import to the queue: evaluates the policy and enqueues a low-priority proxy job if needed.
pub struct ProxyAutoGenerator {
    prober: Box<dyn SourceSeekProbing>,
    policy: ProxyPolicy,
}

impl ProxyAutoGenerator {
    /// A generator with the platform prober and the default policy.
    pub fn new() -> ProxyAutoGenerator {
        Self::with(platform_seek_prober(), ProxyPolicy::default())
    }

    /// A generator with its own prober and policy.
    pub fn with(prober: Box<dyn SourceSeekProbing>, policy: ProxyPolicy) -> ProxyAutoGenerator {
        ProxyAutoGenerator { prober, policy }
    }

    /// Call when a source has been imported. Returns the decision; a job is enqueued (background priority) on
    /// `NeedsProxy`. Probe failures mean no proxy (never blocks import). The queue is passed in, not owned.
    pub fn source_imported(
        &self,
        queue: &mut ProxyQueue,
        url: &Path,
        ids: &mut dyn IdSource,
        now: Timestamp,
    ) -> ProxyDecision {
        let Ok(info) = self.prober.probe(url) else { return ProxyDecision::Skip(SkipReason::Unknown) };
        let decision = self.policy.decide(&info);
        if let ProxyDecision::NeedsProxy(kind) = decision {
            queue.enqueue(url, kind, ProxyJobPriority::Background, ProxyQueue::UNRANKED, ids, now).ok();
        }
        decision
    }
}

impl Default for ProxyAutoGenerator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::test_support::*;
    use crate::proxy_cache::ProxyCache;
    use sq_core_time::SequentialIds;
    use std::collections::HashMap;
    use std::sync::Arc;

    struct FakeProber(HashMap<String, SourceSeekInfo>);

    impl SourceSeekProbing for FakeProber {
        fn probe(&self, url: &Path) -> Result<SourceSeekInfo, ProxyTranscodeError> {
            let name = url.file_name().unwrap().to_string_lossy().into_owned();
            self.0.get(&name).cloned().ok_or(ProxyTranscodeError::NoVideoTrack)
        }
    }

    fn info(codec: &str, d: Option<i64>) -> SourceSeekInfo {
        SourceSeekInfo::new(codec, d)
    }

    #[test]
    fn long_gop_needs_half_proxy() {
        let policy = ProxyPolicy::default();
        assert_eq!(policy.decide(&info("avc1", Some(15))), ProxyDecision::NeedsProxy(ProxyKind::ProxyHalf));
        assert!(policy.decide(&info("hvc1", Some(9))).needs_proxy());
    }

    #[test]
    fn short_gop_at_threshold_is_skipped() {
        let policy = ProxyPolicy::default();
        assert_eq!(
            policy.decide(&info("avc1", Some(8))),
            ProxyDecision::Skip(SkipReason::ShortGOP { max_distance: 8 })
        );
        assert_eq!(
            policy.decide(&info("avc1", Some(1))),
            ProxyDecision::Skip(SkipReason::ShortGOP { max_distance: 1 })
        );
    }

    #[test]
    fn intra_codecs_never_even_with_huge_distance() {
        for c in ["apcn", "apco", "ap4h", "AVdh", "mjpa"] {
            assert_eq!(
                ProxyPolicy::default().decide(&info(c, Some(500))),
                ProxyDecision::Skip(SkipReason::IntraOnlyCodec)
            );
        }
    }

    #[test]
    fn unknown_gop_is_skipped() {
        assert_eq!(ProxyPolicy::default().decide(&info("avc1", None)), ProxyDecision::Skip(SkipReason::Unknown));
    }

    #[test]
    fn custom_threshold() {
        let policy = ProxyPolicy { max_sync_distance: 30, ..ProxyPolicy::default() };
        assert!(!policy.decide(&info("avc1", Some(15))).needs_proxy());
    }

    #[test]
    fn auto_generator_enqueues_only_long_gop_at_background_priority() {
        let dir = TempDir::new();
        let (long, intra, broken) = (dir.join("long.mp4"), dir.join("intra.mov"), dir.join("broken.mp4"));
        for (i, p) in [&long, &intra, &broken].into_iter().enumerate() {
            write_file(p, 500, i as u8 + 1);
        }
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let mut queue = ProxyQueue::new(cache, 1);
        let prober = FakeProber(HashMap::from([
            ("long.mp4".to_string(), info("avc1", Some(30))),
            ("intra.mov".to_string(), info("apcn", Some(1))),
        ]));
        let gen_ = ProxyAutoGenerator::with(Box::new(prober), ProxyPolicy::default());
        let (mut ids, now) = (SequentialIds::default(), Timestamp::from_unix_seconds(1.0));
        assert_eq!(
            gen_.source_imported(&mut queue, &long, &mut ids, now),
            ProxyDecision::NeedsProxy(ProxyKind::ProxyHalf)
        );
        assert_eq!(
            gen_.source_imported(&mut queue, &intra, &mut ids, now),
            ProxyDecision::Skip(SkipReason::IntraOnlyCodec)
        );
        assert_eq!(gen_.source_imported(&mut queue, &broken, &mut ids, now), ProxyDecision::Skip(SkipReason::Unknown));
        let jobs = queue.all_jobs();
        assert_eq!(jobs.len(), 1);
        assert!(
            jobs[0].kind == ProxyKind::ProxyHalf
                && jobs[0].priority == ProxyJobPriority::Background
                && jobs[0].source == long
        );
    }

    /// The seek facts from a demuxer's sample index: the same gaps the Mac sample-cursor walk finds.
    #[test]
    fn largest_gap_between_sync_samples() {
        let flags = (0..100).map(|i| i % 25 == 0 || i == 60);
        let info = SourceSeekInfo::from_sync_flags("avc1", flags, SourceSeekInfo::DEFAULT_MAX_SAMPLES);
        assert!(info.max_sync_distance == Some(25) && info.scanned_frames == 100);
        assert_eq!(ProxyPolicy::default().decide(&info), ProxyDecision::NeedsProxy(ProxyKind::ProxyHalf));
    }

    #[test]
    fn one_sync_sample_counts_the_window_and_only_the_window_is_read() {
        let w = SourceSeekInfo::DEFAULT_MAX_SAMPLES;
        let flags = |n: usize| std::iter::once(true).chain(std::iter::repeat_n(false, n));
        assert_eq!(SourceSeekInfo::from_sync_flags("hvc1", flags(999), w).max_sync_distance, Some(600));
        assert_eq!(SourceSeekInfo::from_sync_flags("hvc1", flags(9), w).max_sync_distance, Some(10));
        assert_eq!(SourceSeekInfo::from_sync_flags("hvc1", [true], w).max_sync_distance, None);
        assert_eq!(SourceSeekInfo::from_sync_flags("avc1", [true; 50], w).max_sync_distance, Some(1));
    }

    #[test]
    fn ffmpeg_codec_names_map_to_the_four_ccs_the_policy_knows() {
        assert_eq!(SourceSeekInfo::four_cc_for_ffmpeg_codec("h264"), "avc1");
        assert_eq!(SourceSeekInfo::four_cc_for_ffmpeg_codec("hevc"), "hvc1");
        for intra in ["prores", "dnxhd", "mjpeg", "cfhd", "v210", "rawvideo"] {
            assert!(
                ProxyPolicy::INTRA_CODECS.contains(&SourceSeekInfo::four_cc_for_ffmpeg_codec(intra).as_str()),
                "{intra}"
            );
        }
        assert_eq!(SourceSeekInfo::four_cc_for_ffmpeg_codec("vp9"), "vp09");
        assert_eq!(SourceSeekInfo::four_cc_for_ffmpeg_codec("something"), "something");
    }
}
