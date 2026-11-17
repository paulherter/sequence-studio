//! Other systems: no VideoToolbox. `VtVideoDecoder::new` always fails so callers fall back to FFmpeg; the workspace still builds.

use crate::codec::StreamRange;
use sq_core_model::VideoTrackInfo;
use sq_core_time::Id;
use sq_gpu::gpu::Gpu;
use sq_media::demuxing::{BoxFuture, Demuxing};
use sq_media::media_error::MediaError;
use sq_media::video_decoding::{DecodedFrame, VideoDecoding};
use std::ops::RangeInclusive;
use std::sync::Arc;

/// Placeholder with the Mac decoder's constructor; it cannot be built.
pub struct VtVideoDecoder {
    info: VideoTrackInfo,
}

impl VtVideoDecoder {
    pub fn new(
        _demuxer: Arc<dyn Demuxing>,
        _info: VideoTrackInfo,
        _media: Id,
        _gpu: Arc<Gpu>,
        _range: StreamRange,
    ) -> Result<VtVideoDecoder, MediaError> {
        Err(MediaError::UnsupportedCodec("VideoToolbox is not available on this system".to_string()))
    }

    pub fn with_deinterlace(self, _order: sq_core_model::FieldOrder) -> Result<VtVideoDecoder, MediaError> {
        Err(MediaError::UnsupportedCodec("VideoToolbox is not available on this system".to_string()))
    }
}

impl VideoDecoding for VtVideoDecoder {
    fn info(&self) -> &VideoTrackInfo {
        &self.info
    }

    fn is_hardware(&self) -> bool {
        false
    }

    fn decode(&self, _range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async {
            Err(MediaError::UnsupportedCodec("VideoToolbox is not available on this system".to_string()))
        })
    }

    fn invalidate(&self) {}
}
