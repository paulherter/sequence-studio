//! The data `MXFDemuxer` derives from a parsed MXF file (Swift `MXFDemuxer.Built`), cached per file by `MxfFile`.
//! The AVFoundation demuxer itself is Apple-only and not ported; the FFmpeg demuxer of `sq-media-ffmpeg` serves MXF.

use crate::demuxing::DemuxedFormat;
use crate::sample_index::SampleIndex;
use sq_core_time::Time;

/// Timing of one sample (Swift `CMSampleTimingInfo`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SampleTiming {
    /// Duration of the sample.
    pub duration: Time,
    /// Presentation time.
    pub presentation: Time,
    /// Decode time.
    pub decode: Time,
}

/// What a demuxer derives from the file: built once per parsed file.
#[derive(Clone, Debug)]
pub struct Built {
    /// Sample table.
    pub index: SampleIndex,
    /// Stream format.
    pub format: DemuxedFormat,
    /// Every sample is a sync sample.
    pub is_intra_only: bool,
    /// The codec is H.264.
    pub is_h264: bool,
    /// Timing per sample.
    pub times: Vec<SampleTiming>,
    /// Sync flag per sample.
    pub sync: Vec<bool>,
}
