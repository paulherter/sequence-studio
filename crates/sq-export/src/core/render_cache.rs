//! The export side of the preview render cache (Swift `RenderCacheSegmentWriter`): a segment is written to an
//! intra-coded ProRes 422 LT .mov at the sequence's size, without audio and caption burn-in, through the same render
//! path as an export. These are the settings of that file, the "working space" part of the segment key, and the rule
//! for when an export may read cached segments. The writer itself is `FfmpegExportEncoder` over the frame source of the
//! app (`sequence-studio/src/export.rs`, `write_cache_segment`).

use super::settings::{ColorSettings, ExportSettings, RangeSelection, VideoCodec};
use sq_core_model::{PixelAspect, SequenceFormat};
use sq_core_time::TimeRange;

/// The compositor's working space (working-linear, Rec.709 primaries, 1.0 = reference white).
/// shortcut: a constant, since the compositor has one fixed working space; becomes the project's choice when it has one.
pub const COMPOSITOR_WORKING_SPACE: &str = "linear-rec709-ref100";

/// The settings of the cache file of `range` of a sequence with `format`.
pub fn segment_settings(format: &SequenceFormat, range: TimeRange) -> ExportSettings {
    let mut s = ExportSettings::default();
    s.video.codec = VideoCodec::ProRes422LT;
    s.video.width = format.width;
    s.video.height = format.height;
    s.video.frame_duration = format.frame_duration;
    s.video.set_pixel_aspect(format.pixel_aspect_store.unwrap_or_else(PixelAspect::square));
    s.audio.enabled = false;
    s.range = RangeSelection::InOut(range);
    s
}

/// The working space part of the segment key: the compositor's space plus everything of the cache file's own encoding
/// the picture depends on (codec, bit depth, pixel format, output color, HDR handling). A change to any of them gives
/// every segment a new key, so no file of the old pipeline is read again.
pub fn working_space(format: &SequenceFormat) -> String {
    let s = segment_settings(format, TimeRange::new(sq_core_time::Time::ZERO, format.frame_duration));
    let c = s.color;
    [
        COMPOSITOR_WORKING_SPACE.to_string(),
        s.video.codec.raw_value().to_string(),
        format!("{}bit", s.video.bit_depth()),
        format!("{:?}", s.source_pixel_format()),
        format!("{:?}-{:?}-{:?}", c.primaries, c.transfer, c.matrix),
        s.hdr_to_sdr.map_or("sdr".to_string(), |h| format!("{h:?}")),
        s.hdr_delivery.map_or("-".to_string(), |h| format!("{h:?}")),
    ]
    .join("/")
}

/// Whether an export with `settings` may read cached segments instead of compositing them, picture for picture the same
/// as playback with the cache: only when it renders the sequence's own frames (size, rate, pixel shape, no format
/// variant) into a picture the cache file holds (Rec.709 SDR, no alpha, no HDR handling) and the delivery is not of a
/// higher quality than the cache's ProRes 422 LT (a ProRes 422 / HQ / 4444 master or an image sequence renders fresh).
pub fn may_reuse(settings: &ExportSettings, format: &SequenceFormat) -> bool {
    let v = &settings.video;
    let same_picture = v.width == format.width
        && v.height == format.height
        && v.frame_duration == format.frame_duration
        && v.pixel_aspect() == format.pixel_aspect_store.unwrap_or_else(PixelAspect::square);
    let plain = settings.variant.is_none()
        && settings.frame_output.is_none()
        && settings.audio_only.is_none()
        && !v.preserves_alpha
        && settings.hdr_to_sdr.is_none()
        && settings.hdr_delivery.is_none()
        && settings.color == ColorSettings::REC709;
    same_picture
        && plain
        && matches!(v.codec, VideoCodec::H264 | VideoCodec::Hevc | VideoCodec::ProRes422LT | VideoCodec::ProRes422Proxy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn format() -> SequenceFormat {
        let mut f = SequenceFormat::new(Time::new(1, 25));
        (f.width, f.height) = (1920, 1080);
        f
    }

    #[test]
    fn a_cache_file_is_prores_lt_without_audio_at_the_sequence_size() {
        let s = segment_settings(&format(), TimeRange::new(Time::ZERO, Time::seconds(2)));
        assert_eq!(s.video.codec, VideoCodec::ProRes422LT);
        assert_eq!((s.video.width, s.video.height, s.video.frame_duration), (1920, 1080, Time::new(1, 25)));
        assert!(!s.audio.enabled);
        assert_eq!(s.range, RangeSelection::InOut(TimeRange::new(Time::ZERO, Time::seconds(2))));
        assert!(working_space(&format()).starts_with("linear-rec709-ref100/prores422LT/"));
    }

    #[test]
    fn only_a_plain_same_size_delivery_reuses_cached_segments() {
        let f = format();
        let mut s = segment_settings(&f, TimeRange::new(Time::ZERO, Time::seconds(1)));
        assert!(may_reuse(&s, &f));
        s.video.codec = VideoCodec::H264;
        assert!(may_reuse(&s, &f));
        s.video.codec = VideoCodec::ProRes422HQ;
        assert!(!may_reuse(&s, &f), "a better master renders fresh");
        s.video.codec = VideoCodec::Hevc;
        s.video.width = 1280;
        assert!(!may_reuse(&s, &f), "another size renders fresh");
    }
}
