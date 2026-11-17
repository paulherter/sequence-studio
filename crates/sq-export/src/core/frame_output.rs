// Swift: FrameStillFormat.swift, FrameOutputNaming.swift (ImageSequenceNaming, GIFTiming), FrameOutput (ExportSettings.swift)

use super::queue::sanitize;
use super::serde_util::Wrap;
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::Time;

/// The formats of Export Frame. The working picture is premultiplied linear rgba16Float; every format but EXR applies
/// the BT.709 transfer curve like the viewer does, EXR keeps the linear values.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FrameStillFormat {
    /// 8-bit PNG, opaque.
    Png,
    /// 8-bit PNG with straight alpha.
    PngAlpha,
    /// JPEG.
    Jpeg,
    /// 16-bit TIFF, opaque.
    Tiff16,
    /// 16-bit TIFF with straight alpha.
    Tiff16Alpha,
    /// Half-float OpenEXR, linear.
    Exr,
}

impl FrameStillFormat {
    /// Every format, in menu order.
    pub const ALL: [FrameStillFormat; 6] = [
        FrameStillFormat::Png,
        FrameStillFormat::PngAlpha,
        FrameStillFormat::Jpeg,
        FrameStillFormat::Tiff16,
        FrameStillFormat::Tiff16Alpha,
        FrameStillFormat::Exr,
    ];

    /// Shown name.
    pub fn display_name(self) -> &'static str {
        match self {
            FrameStillFormat::Png => "PNG",
            FrameStillFormat::PngAlpha => "PNG (with alpha)",
            FrameStillFormat::Jpeg => "JPEG",
            FrameStillFormat::Tiff16 => "TIFF (16-bit)",
            FrameStillFormat::Tiff16Alpha => "TIFF (16-bit, with alpha)",
            FrameStillFormat::Exr => "EXR (half float, linear)",
        }
    }

    /// File extension.
    pub fn file_extension(self) -> &'static str {
        match self {
            FrameStillFormat::Png | FrameStillFormat::PngAlpha => "png",
            FrameStillFormat::Jpeg => "jpg",
            FrameStillFormat::Tiff16 | FrameStillFormat::Tiff16Alpha => "tiff",
            FrameStillFormat::Exr => "exr",
        }
    }

    /// Whether the format stores alpha.
    pub fn keeps_alpha(self) -> bool {
        matches!(self, FrameStillFormat::PngAlpha | FrameStillFormat::Tiff16Alpha | FrameStillFormat::Exr)
    }

    /// The FFmpeg-based writer handles every format (png, mjpeg, tiff, exr encoders).
    pub fn is_supported(self) -> bool {
        true
    }

    /// The formats this machine can write.
    pub fn available() -> Vec<FrameStillFormat> {
        FrameStillFormat::ALL.into_iter().filter(|f| f.is_supported()).collect()
    }
}

/// Output that is not one video file: an animated GIF, or a folder of numbered still images (one per frame).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FrameOutput {
    /// Animated GIF.
    Gif,
    /// Numbered images, one per frame.
    Sequence(FrameStillFormat),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum FrameOutputRepr {
    Gif {},
    Sequence(Wrap<FrameStillFormat>),
}

impl Serialize for FrameOutput {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            FrameOutput::Gif => FrameOutputRepr::Gif {},
            FrameOutput::Sequence(f) => FrameOutputRepr::Sequence(Wrap { v: *f }),
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for FrameOutput {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match FrameOutputRepr::deserialize(d)? {
            FrameOutputRepr::Gif {} => FrameOutput::Gif,
            FrameOutputRepr::Sequence(w) => FrameOutput::Sequence(w.v),
        })
    }
}

impl FrameOutput {
    /// Shown name.
    pub fn display_name(self) -> String {
        match self {
            FrameOutput::Gif => "Animated GIF".to_string(),
            FrameOutput::Sequence(f) => format!("Image sequence \u{B7} {}", f.display_name()),
        }
    }
}

/// Numbered file names of an image sequence.
pub struct ImageSequenceNaming;

impl ImageSequenceNaming {
    /// Digits of the frame number: at least 4, more when the last number needs them.
    pub fn digits(start_number: i64, count: i64) -> usize {
        (start_number + count.max(1) - 1).max(0).to_string().len().max(4)
    }

    /// "Shot_0007.png": the name is made file-system safe, the number is zero padded.
    pub fn file_name(stem: &str, number: i64, digits: usize, ext: &str) -> String {
        format!("{}_{:0>digits$}.{ext}", sanitize(stem), number.max(0))
    }

    /// Every file name of a sequence of `count` frames numbered from `start_number`.
    pub fn file_names(stem: &str, start_number: i64, count: i64, ext: &str) -> Vec<String> {
        let d = Self::digits(start_number, count);
        (0..count.max(0)).map(|i| Self::file_name(stem, start_number + i, d, ext)).collect()
    }
}

/// GIF stores each frame delay in whole centiseconds. A constant round(100 / fps) would play 24 fps four percent fast;
/// frame i instead spans round(i * 100 / fps) to round((i + 1) * 100 / fps), so delays alternate (4, 4, 5 at 24 fps)
/// and their sum is the duration (to half a centisecond).
pub struct GifTiming;

impl GifTiming {
    /// Delay of each frame in centiseconds.
    pub fn delays_centiseconds(frame_duration: Time, frame_count: usize) -> Vec<i64> {
        if frame_duration.value() <= 0 || frame_duration.timescale() <= 0 || frame_count == 0 {
            return Vec::new();
        }
        let (v, t) = (i128::from(frame_duration.value()), i128::from(frame_duration.timescale()));
        // round(i * 100 * v / t), half up, in integers.
        let boundary = |i: usize| ((2 * i as i128 * 100 * v + t) / (2 * t)) as i64;
        (0..frame_count).map(|i| boundary(i + 1) - boundary(i)).collect()
    }
}
