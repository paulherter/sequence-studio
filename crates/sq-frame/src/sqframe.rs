// Swift: SQFrame.swift
//! One video frame handed across crate boundaries (decoder -> playback -> render).

use sq_core_time::Time;
use std::any::Any;
use std::sync::Arc;

/// Pixel layout of a frame's storage. Platform codes without a neutral name travel as `Other` (CoreVideo FourCC on the
/// Mac, e.g. Apple's lossless-compressed `&8v0`), so wrapping never fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SQFramePixelFormat {
    /// 8-bit B, G, R, A, one plane.
    Bgra8,
    /// 8-bit R, G, B, A, one plane.
    Rgba8,
    /// 8-bit 4:2:0 YCbCr, Y plane + interleaved CbCr plane, video range.
    Nv12,
    /// 8-bit 4:2:0 YCbCr, two planes, full range.
    Nv12FullRange,
    /// 10-bit 4:2:0 YCbCr in 16-bit words, two planes, video range.
    P010,
    /// 10-bit 4:2:0 YCbCr in 16-bit words, two planes, full range.
    P010FullRange,
    /// 10-bit 4:2:2 YCbCr in 16-bit words, two planes, video range.
    P210,
    /// 10-bit 4:2:2 YCbCr in 16-bit words, two planes, full range (Sony XAVC S-I S-Log3).
    P210FullRange,
    /// 16-bit float R, G, B, A, one plane.
    Rgba16f,
    /// 32-bit float R, G, B, A, one plane.
    Rgba32f,
    /// 16-bit A, Y, Cb, Cr 4:4:4, one plane (ProRes 4444 decode).
    Ayuv16,
    /// A platform format code without a neutral case.
    Other(u32),
}

impl SQFramePixelFormat {
    /// Number of planes; `None` for `Other` (only the platform knows).
    pub fn plane_count(self) -> Option<usize> {
        match self {
            Self::Nv12 | Self::Nv12FullRange | Self::P010 | Self::P010FullRange | Self::P210 | Self::P210FullRange => {
                Some(2)
            }
            Self::Bgra8 | Self::Rgba8 | Self::Rgba16f | Self::Rgba32f | Self::Ayuv16 => Some(1),
            Self::Other(_) => None,
        }
    }

    /// Whether the format stores YCbCr rather than RGB.
    pub fn is_ycbcr(self) -> bool {
        match self {
            Self::Nv12
            | Self::Nv12FullRange
            | Self::P010
            | Self::P010FullRange
            | Self::P210
            | Self::P210FullRange
            | Self::Ayuv16 => true,
            Self::Bgra8 | Self::Rgba8 | Self::Rgba16f | Self::Rgba32f | Self::Other(_) => false,
        }
    }

    /// Full-range (0...max) YCbCr; RGB formats are always full range.
    pub fn is_full_range(self) -> bool {
        !matches!(self, Self::Nv12 | Self::P010 | Self::P210)
    }

    /// Significant bits per component; `None` for `Other`.
    pub fn bits_per_component(self) -> Option<u32> {
        match self {
            Self::Bgra8 | Self::Rgba8 | Self::Nv12 | Self::Nv12FullRange => Some(8),
            Self::P010 | Self::P010FullRange | Self::P210 | Self::P210FullRange => Some(10),
            Self::Rgba16f | Self::Ayuv16 => Some(16),
            Self::Rgba32f => Some(32),
            Self::Other(_) => None,
        }
    }
}

/// Color space a frame's pixels are encoded in (primaries + transfer).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SQFrameColorSpace {
    /// Not tagged: the reader decides (on the Mac the buffer attachments and the track's `VideoTrackInfo` decide).
    Unspecified,
    /// Rec. 601.
    Rec601,
    /// Rec. 709.
    Rec709,
    /// sRGB.
    SRGB,
    /// Display P3.
    DisplayP3,
    /// Rec. 2020.
    Rec2020,
    /// Rec. 2020 primaries, PQ transfer.
    Rec2020PQ,
    /// Rec. 2020 primaries, HLG transfer.
    Rec2020HLG,
    /// Linear light, Rec.709 primaries (the compositor's working space, text rasters).
    LinearRec709,
}

/// The platform object that holds a frame's pixels: a CVPixelBuffer on the Mac, a D3D12 texture or an FFmpeg frame on
/// Windows. Opaque to everything outside the platform layer; immutable once wrapped.
pub trait SQFrameStorage: Any + Send + Sync {}

/// One video frame handed across crate boundaries (decoder -> playback -> render). A value: clones share the storage,
/// nothing is copied pixel-wise.
#[derive(Clone)]
pub struct SQFrame {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// Pixel layout.
    pub pixel_format: SQFramePixelFormat,
    /// Color space the pixels are encoded in.
    pub color_space: SQFrameColorSpace,
    /// When the frame is shown.
    pub presentation_time: Time,
    storage: Arc<dyn SQFrameStorage>,
}

impl SQFrame {
    /// A frame over `storage`; `Unspecified` color and time zero are the Swift defaults.
    pub fn new(
        width: usize,
        height: usize,
        pixel_format: SQFramePixelFormat,
        color_space: SQFrameColorSpace,
        presentation_time: Time,
        storage: Arc<dyn SQFrameStorage>,
    ) -> SQFrame {
        SQFrame { width, height, pixel_format, color_space, presentation_time, storage }
    }

    /// The platform storage (`let storage`).
    pub fn storage(&self) -> &Arc<dyn SQFrameStorage> {
        &self.storage
    }

    /// The storage as `T`, `None` when the platform stored something else (Swift `storage as? T`).
    pub fn storage_as<T: SQFrameStorage>(&self) -> Option<&T> {
        let any: &dyn Any = &*self.storage;
        any.downcast_ref::<T>()
    }

    /// The same pixels at another presentation time.
    pub fn with_presentation_time(&self, t: Time) -> SQFrame {
        let mut f = self.clone();
        f.presentation_time = t;
        f
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A platform-free storage for the portable tests.
    struct TestStorage {
        tag: i64,
    }
    impl SQFrameStorage for TestStorage {}

    fn storage(tag: i64) -> Arc<TestStorage> {
        Arc::new(TestStorage { tag })
    }

    #[test]
    fn holds_size_format_color_time_and_storage() {
        let s = storage(7);
        let f = SQFrame::new(
            1920,
            1080,
            SQFramePixelFormat::Nv12,
            SQFrameColorSpace::Rec709,
            Time::new(1001, 30000),
            Arc::clone(&s) as Arc<dyn SQFrameStorage>,
        );
        assert!(f.width == 1920 && f.height == 1080);
        assert_eq!(f.pixel_format, SQFramePixelFormat::Nv12);
        assert_eq!(f.color_space, SQFrameColorSpace::Rec709);
        assert_eq!(f.presentation_time, Time::new(1001, 30000));
        assert!(f.storage_as::<TestStorage>().is_some_and(|t| std::ptr::eq(t, Arc::as_ptr(&s)) && t.tag == 7));
    }

    #[test]
    fn defaults_are_unspecified_color_and_time_zero() {
        let f = SQFrame::new(2, 2, SQFramePixelFormat::Bgra8, SQFrameColorSpace::Unspecified, Time::ZERO, storage(0));
        assert_eq!(f.color_space, SQFrameColorSpace::Unspecified);
        assert_eq!(f.presentation_time, Time::ZERO);
    }

    #[test]
    fn copies_share_the_same_storage() {
        let s = storage(1);
        let a = SQFrame::new(
            4,
            4,
            SQFramePixelFormat::Rgba16f,
            SQFrameColorSpace::Unspecified,
            Time::ZERO,
            Arc::clone(&s) as Arc<dyn SQFrameStorage>,
        );
        let mut b = a.clone();
        b.color_space = SQFrameColorSpace::LinearRec709;
        assert!(b.storage_as::<TestStorage>().is_some_and(|t| std::ptr::eq(t, Arc::as_ptr(&s))));
        assert_eq!(a.color_space, SQFrameColorSpace::Unspecified);
    }

    #[test]
    fn retiming_keeps_pixels() {
        let s = storage(2);
        let a = SQFrame::new(
            8,
            6,
            SQFramePixelFormat::P010,
            SQFrameColorSpace::Unspecified,
            Time::new(1, 25),
            Arc::clone(&s) as Arc<dyn SQFrameStorage>,
        );
        let b = a.with_presentation_time(Time::new(2, 25));
        assert_eq!(b.presentation_time, Time::new(2, 25));
        assert!(b.width == 8 && b.height == 6 && b.pixel_format == SQFramePixelFormat::P010);
        assert!(b.storage_as::<TestStorage>().is_some_and(|t| std::ptr::eq(t, Arc::as_ptr(&s))));
    }

    #[test]
    fn pixel_format_traits() {
        use SQFramePixelFormat as F;
        assert!(F::Nv12.plane_count() == Some(2) && F::Nv12.is_ycbcr());
        assert!(F::P010FullRange.plane_count() == Some(2) && F::P010FullRange.is_full_range());
        assert!(!F::Nv12.is_full_range());
        assert!(F::P210FullRange.is_full_range() && !F::P210.is_full_range());
        assert!(F::P210FullRange.plane_count() == Some(2) && F::P210FullRange.bits_per_component() == Some(10));
        assert!(F::Bgra8.plane_count() == Some(1) && !F::Bgra8.is_ycbcr());
        assert!(F::Rgba16f.plane_count() == Some(1) && !F::Rgba16f.is_ycbcr());
        assert!(F::P010.bits_per_component() == Some(10) && F::Nv12.bits_per_component() == Some(8));
        assert!(F::Rgba16f.bits_per_component() == Some(16) && F::Rgba32f.bits_per_component() == Some(32));
        assert_eq!(F::Other(0x2676_7630).plane_count(), None);
    }
}
