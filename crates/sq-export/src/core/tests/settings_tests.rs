// Swift: SettingsTests.swift, plus the JSON shapes Swift's Codable writes.

use crate::core::*;
use serde_json::json;
use sq_core_time::{Time, TimeRange};

#[test]
fn defaults_are_nine_sixteen_h264_rec709() {
    let s = ExportSettings::default();
    assert_eq!(s.video.codec, VideoCodec::H264);
    assert!(s.video.width == 1080 && s.video.height == 1920);
    assert_eq!(s.video.frame_duration, Time::new(1, 30));
    assert_eq!(s.color, ColorSettings::REC709);
    assert!(s.audio.codec == AudioCodec::Aac && s.audio.sample_rate == 48_000 && s.audio.channels == 2);
    assert_eq!(s.captions, CaptionMode::None);
    assert_eq!(s.range, RangeSelection::EntireSequence);
    assert!(s.validate().is_empty());
}

#[test]
fn codable_round_trip() {
    let mut s = ExportSettings::default();
    s.video.codec = VideoCodec::Hevc;
    s.video.bitrate = BitrateMode::AverageAndMax { average: 8_000_000, max: 12_000_000 };
    s.audio.loudness = Some(LoudnessNormalization::new(-16.0, -2.0));
    s.captions = CaptionMode::SidecarSrt;
    s.range = RangeSelection::InOut(TimeRange::new(Time::new(1, 1), Time::new(5, 1)));
    let back: ExportSettings = serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap();
    assert_eq!(back, s);
}

#[test]
fn validation_finds_problems() {
    let mut s = ExportSettings::default();
    s.video.width = 1081;
    s.video.height = 0;
    s.video.bitrate = BitrateMode::Average(0);
    s.video.keyframe_interval = 0;
    s.audio.channels = 0;
    s.audio.sample_rate = 0;
    let issues = s.validate();
    assert!(issues.contains(&ExportSettingsIssue::OddDimensions));
    assert!(issues.contains(&ExportSettingsIssue::NonPositiveBitrate));
    assert!(issues.contains(&ExportSettingsIssue::InvalidKeyframeInterval));
    assert!(issues.contains(&ExportSettingsIssue::InvalidAudio));
}

#[test]
fn max_below_average_is_invalid() {
    let mut s = ExportSettings::default();
    s.video.bitrate = BitrateMode::AverageAndMax { average: 10_000_000, max: 5_000_000 };
    assert!(s.validate().contains(&ExportSettingsIssue::NonPositiveBitrate));
}

#[test]
fn size_estimate() {
    let mut s = ExportSettings::default();
    s.video.bitrate = BitrateMode::Average(8_000_000);
    s.audio.bitrate = 128_000;
    // 10 s => (8_000_000 + 128_000) * 10 / 8 bytes
    assert_eq!(s.estimated_file_size(Time::new(10, 1)), 10_160_000);
    s.audio.enabled = false;
    assert_eq!(s.estimated_file_size(Time::new(10, 1)), 10_000_000);
    assert_eq!(s.estimated_file_size(Time::new(1, 3)), 333_333);
}

/// Each ProRes profile has its own rate (147 / 220 / 330 Mbit/s at 1080p29.97).
#[test]
fn pro_res_profiles_have_own_rates() {
    let mut s = ExportSettings::pro_res_422_hq_master();
    s.video.width = 1920;
    s.video.height = 1080;
    s.video.frame_duration = Time::new(1001, 30000);
    s.video.codec = VideoCodec::ProRes422;
    assert_eq!(s.estimated_video_bits_per_second(), 147_000_000);
    s.video.codec = VideoCodec::ProRes422HQ;
    assert_eq!(s.estimated_video_bits_per_second(), 220_000_000);
    s.video.codec = VideoCodec::ProRes4444;
    assert_eq!(s.estimated_video_bits_per_second(), 330_000_000);
}

/// ProRes ignores the (12 Mbit/s default) bitrate field; 1080p29.97 HQ is about 220 Mbit/s plus 24-bit PCM.
#[test]
fn pro_res_size_estimate() {
    let mut s = ExportSettings::pro_res_422_hq_master();
    s.video.frame_duration = Time::new(1001, 30000);
    // 10 s: 220 Mbit/s video = 275_000_000 bytes, PCM 48k*2*24 = 2_304_000 bit/s = 2_880_000 bytes
    assert_eq!(s.estimated_file_size(Time::new(10, 1)), 275_000_000 + 2_880_000);
    s.audio.enabled = false;
    s.video.width = 3840;
    s.video.height = 2160;
    assert_eq!(s.estimated_file_size(Time::new(10, 1)), 1_100_000_000);
}

/// The JSON Swift's synthesized Codable writes for enums with associated values, and the tolerant reading.
#[test]
fn json_matches_swift_codable() {
    let mut s = ExportSettings::default();
    s.video.bitrate = BitrateMode::Average(12_000_000);
    s.range = RangeSelection::InOut(TimeRange::new(Time::new(1, 1), Time::new(5, 1)));
    s.frame_output = Some(FrameOutput::Sequence(FrameStillFormat::PngAlpha));
    s.hdr_to_sdr = Some(HdrToSdr::new(1.0, false));
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(v["video"]["bitrate"], json!({"average": {"_0": 12_000_000}}));
    assert_eq!(
        v["range"],
        json!({"inOut": {"_0": {"start": {"value": 1, "timescale": 1}, "duration": {"value": 5, "timescale": 1}}}})
    );
    assert_eq!(v["frameOutput"], json!({"sequence": {"_0": "pngAlpha"}}));
    assert_eq!(v["hdrToSDR"], json!({"exposureStops": 1.0, "compressesGamut": false}));
    assert_eq!(v["captions"], json!("none"));
    assert_eq!(v["color"], json!({"primaries": "itu709", "transfer": "itu709", "matrix": "itu709"}));
    // Optional keys that are unset are absent, like Swift's encodeIfPresent.
    for k in
        ["variant", "coverImage", "damagedFrames", "speed", "multiPassStore", "audioOnly", "metadata", "hdrDelivery"]
    {
        assert!(v.get(k).is_none(), "{k}");
    }
    assert!(v["video"].get("constantBitrate").is_none() && v["video"].get("pixelAspect").is_none());
    assert_eq!(serde_json::to_value(ExportSettings::default().range).unwrap(), json!({"entireSequence": {}}));
    assert_eq!(serde_json::to_value(FrameOutput::Gif).unwrap(), json!({"gif": {}}));
    let back: ExportSettings = serde_json::from_value(v).unwrap();
    assert_eq!(back, s);
}

#[test]
fn stored_optionals_appear_only_when_set() {
    let mut s = ExportSettings::default();
    s.video.set_bitrate_kind(BitrateKind::Cbr);
    s.set_encoder_speed(EncoderSpeed::Fast);
    s.set_multi_pass(true);
    s.continue_on_damaged_frames = true;
    s.video.set_constant_quality(Some(2.0));
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(v["video"]["constantBitrate"], json!(true));
    assert_eq!(v["video"]["constantQuality"], json!(1.0));
    assert_eq!(v["speed"], json!("fast"));
    assert_eq!(v["multiPassStore"], json!(true));
    assert_eq!(v["damagedFrames"], json!(true));
    let back: ExportSettings = serde_json::from_value(v).unwrap();
    assert!(
        back.video.bitrate_kind() == BitrateKind::Cbr
            && back.encoder_speed() == EncoderSpeed::Fast
            && back.multi_pass()
    );
    // Constant quality beats CBR; ProRes has neither.
    assert!(!back.video.uses_constant_bitrate() && back.video.uses_constant_quality());
    let mut p = back.clone();
    p.video.codec = VideoCodec::ProRes422;
    assert!(p.video.constant_quality().is_none() && !p.video.uses_constant_bitrate());
}

#[test]
fn old_settings_decode_with_defaults() {
    let v = json!({"video": {"codec": "hevc", "width": 1920, "height": 1080, "bitrate": {"average": {"_0": 9000000}}}});
    let s: ExportSettings = serde_json::from_value(v).unwrap();
    assert!(s.video.allows_frame_reordering && s.video.hardware_encoding);
    assert_eq!(s.video.bitrate, BitrateMode::Average(9_000_000));
    assert_eq!(s.video.frame_duration, Time::new(1, 30));
}

#[test]
fn legacy_loudness_target_maps_to_loudness() {
    let a: AudioSettings = serde_json::from_value(json!({"loudnessTarget": -16})).unwrap();
    assert_eq!(a.loudness, Some(LoudnessNormalization::new(-16.0, -1.0)));
    assert_eq!(a.loudness_target(), Some(-16));
    let enc = serde_json::to_value(&a).unwrap();
    assert!(enc.get("loudnessTarget").is_none() && enc["loudness"]["targetLUFS"] == json!(-16.0));
    let mut b = AudioSettings { loudness: Some(LoudnessNormalization::new(-14.0, -3.0)), ..Default::default() };
    b.set_loudness_target(Some(-18));
    assert_eq!(b.loudness, Some(LoudnessNormalization::new(-18.0, -3.0)));
    b.set_loudness_target(None);
    assert_eq!(b.loudness, None);
}

#[test]
fn square_pixel_aspect_is_not_stored_and_a_broken_one_reads_as_square() {
    let mut v = VideoSettings::default();
    v.set_pixel_aspect(sq_core_model::PixelAspect::new(2, 1).unwrap());
    let j = serde_json::to_value(&v).unwrap();
    assert_eq!(j["pixelAspect"], json!({"num": 2, "den": 1}));
    v.set_pixel_aspect(sq_core_model::PixelAspect::square());
    assert!(serde_json::to_value(&v).unwrap().get("pixelAspect").is_none());
    let broken: VideoSettings = serde_json::from_value(json!({"pixelAspect": {"num": 9, "den": 1}})).unwrap();
    assert!(broken.pixel_aspect().is_square());
}

#[test]
fn file_extension_pixel_format_and_delivery() {
    let mut s = ExportSettings::default();
    assert_eq!((s.file_extension(), s.source_pixel_format()), ("mp4", ExportPixelFormat::Yuv420v));
    s.video.codec = VideoCodec::Hevc;
    s.video.profile = VideoProfile::Main10;
    assert_eq!(s.source_pixel_format(), ExportPixelFormat::Yuv420v10);
    s.video.profile = VideoProfile::Main;
    s.hdr_delivery = Some(HdrDelivery::default());
    assert_eq!(s.source_pixel_format(), ExportPixelFormat::Yuv420v10);
    s.video.codec = VideoCodec::H264;
    assert!(s.applied_hdr_delivery().is_none());
    s.video.codec = VideoCodec::ProRes4444;
    assert_eq!((s.file_extension(), s.source_pixel_format()), ("mov", ExportPixelFormat::Ayuv4444));
    s.video.preserves_alpha = true;
    assert_eq!(s.source_pixel_format(), ExportPixelFormat::Ayuv4444Alpha);
    s.frame_output = Some(FrameOutput::Gif);
    assert_eq!((s.file_extension(), s.source_pixel_format()), ("gif", ExportPixelFormat::Bgra8));
    s.frame_output = Some(FrameOutput::Sequence(FrameStillFormat::Exr));
    assert_eq!((s.file_extension(), s.source_pixel_format()), ("", ExportPixelFormat::RgbaHalf));
    let mut a = ExportSettings::default();
    a.audio_only = Some(AudioFileFormat::Flac);
    a.captions = CaptionMode::BurnIn;
    a.cover_image = Some(CoverImageFormat::Png);
    let d = a.for_delivery();
    assert!(d.captions == CaptionMode::None && d.cover_image.is_none());
    assert_eq!((a.file_extension(), a.effective_audio().codec), ("flac", AudioCodec::Pcm));
    assert!(ExportPixelFormat::Yuv420v.needs_even_size() && !ExportPixelFormat::Bgra8.needs_even_size());
}

#[test]
fn multi_pass_needs_software_bitrate_video() {
    let mut s = ExportPreset::BEST_AT_SIZE.settings();
    assert!(s.uses_multi_pass());
    s.video.hardware_encoding = true;
    assert!(!s.uses_multi_pass());
    s.video.hardware_encoding = false;
    s.video.set_bitrate_kind(BitrateKind::Cbr);
    assert!(!s.uses_multi_pass());
    assert_eq!(EncoderSpeed::suggested(8 << 30), Some(EncoderSpeed::Balanced));
    assert_eq!(EncoderSpeed::suggested(16 << 30), None);
}
