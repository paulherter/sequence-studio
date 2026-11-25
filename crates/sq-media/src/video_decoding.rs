//! Port of `SQMedia/Sources/SQMedia/VideoDecoding.swift` (the variant without CoreVideo, which the Windows build uses).

use crate::demuxing::BoxFuture;
use crate::media_error::MediaError;
use sq_core_model::VideoTrackInfo;
use sq_core_time::{Id, Time};
use sq_frame::sqframe::{SQFrame, SQFramePixelFormat};
use std::ops::RangeInclusive;

/// One decoded frame: the neutral `SQFrame` (its presentation time is `pts`) plus the media and display duration.
#[derive(Clone)]
pub struct DecodedFrame {
    pub media: Id,
    pub duration: Time,
    pub frame: SQFrame,
}

impl DecodedFrame {
    pub fn new(media: Id, duration: Time, frame: SQFrame) -> DecodedFrame {
        DecodedFrame { media, duration, frame }
    }

    pub fn pts(&self) -> Time {
        self.frame.presentation_time
    }

    /// Bytes the frame holds, from its size and pixel format (GPU textures included: they count against the same budget).
    pub fn byte_cost(&self) -> usize {
        let px = self.frame.width * self.frame.height;
        match self.frame.pixel_format {
            SQFramePixelFormat::Nv12 | SQFramePixelFormat::Nv12FullRange => px * 3 / 2,
            SQFramePixelFormat::P010 | SQFramePixelFormat::P010FullRange => px * 3,
            SQFramePixelFormat::P210 | SQFramePixelFormat::P210FullRange => px * 4,
            SQFramePixelFormat::Bgra8 | SQFramePixelFormat::Rgba8 => px * 4,
            SQFramePixelFormat::Rgba16f | SQFramePixelFormat::Ayuv16 => px * 8,
            SQFramePixelFormat::Rgba32f => px * 16,
            SQFramePixelFormat::Other(_) => px * 4,
        }
    }
}

/// Called with each frame as soon as it is decoded (decode order, on any thread).
pub type FrameSink = Box<dyn Fn(DecodedFrame) + Send + Sync>;

/// Asked between pictures of a running decode: true = the caller does not want the rest any more.
pub type StopCheck = std::sync::Arc<dyn Fn() -> bool + Send + Sync>;

/// A decoder of one video track. Cancelling a decode = dropping its future (Swift: `Task` cancellation).
pub trait VideoDecoding: Send + Sync {
    fn info(&self) -> &VideoTrackInfo;
    fn is_hardware(&self) -> bool;

    /// The caller turned one decoded picture into pixels (`ok`) or could not (a failed GPU download). A hardware decoder
    /// that keeps failing reopens in software at its next decode. Default: ignored.
    fn report_download(&self, _ok: bool) {}

    /// Decodes presentation frames `range` and returns them in PTS order (entries with zero duration, which the edit
    /// list does not show, are left out). Continues from the previous call without
    /// reseeking when `range` starts right after the last decoded frame (forward playback).
    fn decode(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>>;

    /// Same as `decode`, and additionally hands each frame of `range` to `deliver` as soon as it is decoded (decode
    /// order, on any thread), so a caller can show the target of a long GOP before the job ends. The returned array
    /// holds only the frames that were not delivered early (carried over from a previous call, or a decoder without early
    /// delivery): a delivered frame belongs to the caller and is not held until the job ends (a long GOP of 4K frames).
    /// Default: nothing is delivered early.
    fn decode_deliver(
        &self,
        range: RangeInclusive<usize>,
        _deliver: FrameSink,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        self.decode(range)
    }

    /// As `decode_deliver`; frames of `range` before `needed_from` may be left out (a seek: a decoder that can skips
    /// pictures nothing references before the target, so the target arrives sooner). Default: ignores the hint.
    fn decode_needed_from(
        &self,
        range: RangeInclusive<usize>,
        _needed_from: Option<usize>,
        deliver: FrameSink,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        self.decode_deliver(range, deliver)
    }

    /// As `decode_needed_from`, and a decoder that can asks `stop` between pictures: once it says yes the decode ends
    /// early (Ok, with whatever was not delivered left out) and the decoder forgets its stream position, so the next
    /// call seeks. Default: runs to the end (a decoder that cannot stop).
    fn decode_until(
        &self,
        range: RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: FrameSink,
        _stop: StopCheck,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        self.decode_needed_from(range, needed_from, deliver)
    }

    fn invalidate(&self);
}

/// H.264 access units in AVCC form (length-prefixed NAL units).
pub enum H264NAL {}

impl H264NAL {
    /// True when the sample has at least one coded slice and no slice is used for reference (`nal_ref_idc` 0 on every
    /// slice NAL, types 1-5): no other picture depends on it, decoding can skip it. Anything malformed: false.
    pub fn is_disposable(bytes: &[u8], length_size: usize) -> bool {
        if !(1..=4).contains(&length_size) {
            return false;
        }
        let mut i = 0;
        let mut slices = 0;
        while i < bytes.len() {
            if bytes.len() - i < length_size + 1 {
                return false;
            }
            let mut len = 0usize;
            for k in 0..length_size {
                len = len << 8 | usize::from(bytes[i + k]);
            }
            let h = bytes[i + length_size];
            if len < 1 || bytes.len() - (i + length_size) < len {
                return false;
            }
            let ty = h & 0x1F;
            if (1..=5).contains(&ty) {
                if h & 0x60 != 0 {
                    return false;
                }
                slices += 1;
            }
            i += length_size + len;
        }
        slices > 0
    }
}

/// VT destination size divisor (Program monitor quality popup).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DecodeScale {
    Full,
    Half,
    Quarter,
}

impl DecodeScale {
    pub fn divisor(self) -> i64 {
        match self {
            DecodeScale::Full => 1,
            DecodeScale::Half => 2,
            DecodeScale::Quarter => 4,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_frame::sqframe::{SQFrameColorSpace, SQFrameStorage};
    use std::sync::Arc;

    struct NoStorage;
    impl SQFrameStorage for NoStorage {}

    /// AVCC sample of NAL units: each tuple is the NAL header byte and payload length.
    fn avcc(nals: &[(u8, usize)], length_size: usize) -> Vec<u8> {
        let mut out = Vec::new();
        for &(h, n) in nals {
            let len = n + 1;
            for k in (0..length_size).rev() {
                out.push(((len >> (8 * k)) & 0xFF) as u8);
            }
            out.push(h);
            out.extend(vec![0xAB; n]);
        }
        out
    }

    #[test]
    fn h264_disposable_needs_every_slice_unreferenced() {
        let check = |b: &[u8]| H264NAL::is_disposable(b, 4);
        // nal_ref_idc 0 slice (type 1): disposable; SEI (6) / AUD (9) around it do not matter.
        assert!(check(&avcc(&[(0x09, 1), (0x06, 5), (0x01, 40)], 4)));
        // Reference slice (nal_ref_idc 2, type 1) and IDR (0x65).
        assert!(!check(&avcc(&[(0x41, 40)], 4)));
        assert!(!check(&avcc(&[(0x65, 40)], 4)));
        // Two slices, one referenced: not disposable.
        assert!(!check(&avcc(&[(0x01, 20), (0x21, 20)], 4)));
        // No slice at all, empty, truncated length: never disposable (decode it).
        assert!(!check(&avcc(&[(0x06, 5)], 4)));
        assert!(!check(&[]));
        assert!(!check(&[0, 0, 0, 200, 0x01]));
        // 2-byte lengths.
        assert!(H264NAL::is_disposable(&avcc(&[(0x01, 300)], 2), 2));
        assert!(!H264NAL::is_disposable(&avcc(&[(0x01, 3)], 4), 5));
    }

    #[test]
    fn byte_cost_follows_the_pixel_format() {
        let frame = |f: SQFramePixelFormat| {
            let sq = SQFrame::new(8, 4, f, SQFrameColorSpace::Unspecified, Time::new(1, 30), Arc::new(NoStorage));
            DecodedFrame::new(Id::from_u128(1), Time::new(1, 30), sq)
        };
        assert_eq!(frame(SQFramePixelFormat::Nv12).byte_cost(), 48);
        assert_eq!(frame(SQFramePixelFormat::P010).byte_cost(), 96);
        assert_eq!(frame(SQFramePixelFormat::P210).byte_cost(), 128);
        assert_eq!(frame(SQFramePixelFormat::Bgra8).byte_cost(), 128);
        assert_eq!(frame(SQFramePixelFormat::Rgba16f).byte_cost(), 256);
        assert_eq!(frame(SQFramePixelFormat::Rgba32f).byte_cost(), 512);
        assert_eq!(frame(SQFramePixelFormat::Other(7)).byte_cost(), 128);
        assert_eq!(frame(SQFramePixelFormat::Nv12).pts(), Time::new(1, 30));
    }

    #[test]
    fn decode_scale_divisors() {
        assert_eq!([DecodeScale::Full, DecodeScale::Half, DecodeScale::Quarter].map(DecodeScale::divisor), [1, 2, 4]);
    }
}
