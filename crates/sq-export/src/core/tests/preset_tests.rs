// Swift: PresetTests.swift, QualityStepTests.swift, InstagramPresetTests.swift, DeliveryTargetPresetTests.swift

use super::{fmt, target};
use crate::core::*;
use sq_core_model::DeliveryPlatform;
use sq_core_time::Time;
use std::collections::HashSet;

#[test]
fn all_social_presets_are_valid_nine_sixteen_rec709() {
    assert_eq!(ExportPreset::social().len(), 6);
    for p in ExportPreset::social() {
        let s = p.settings();
        assert!(s.validate().is_empty(), "{}", p.id());
        assert!(s.video.width == 1080 && s.video.height == 1920);
        assert_eq!(s.video.frame_duration, Time::new(1, 30));
        assert_eq!(s.color, ColorSettings::REC709);
    }
}

#[test]
fn platforms_and_codecs() {
    for platform in SocialPlatform::ALL {
        assert_eq!(ExportPreset::social_preset(platform, VideoCodec::H264).settings().video.codec, VideoCodec::H264);
        assert_eq!(ExportPreset::social_preset(platform, VideoCodec::Hevc).settings().video.codec, VideoCodec::Hevc);
    }
    let ids: HashSet<String> = ExportPreset::social().iter().map(ExportPreset::id).collect();
    assert_eq!(ids.len(), 6);
    assert_eq!(ExportPreset::DEFAULT.id(), "tiktok-h264");
}

#[test]
fn hevc_uses_lower_bitrate_than_h264() {
    for platform in SocialPlatform::ALL {
        let a =
            ExportPreset::social_preset(platform, VideoCodec::H264).settings().video.bitrate.average_bits_per_second();
        let b =
            ExportPreset::social_preset(platform, VideoCodec::Hevc).settings().video.bitrate.average_bits_per_second();
        assert!(b < a);
    }
}

#[test]
fn default_is_tiktok_h264() {
    assert_eq!(ExportPreset::DEFAULT.platform, Some(SocialPlatform::Tiktok));
    assert_eq!(ExportPreset::DEFAULT.settings().video.codec, VideoCodec::H264);
    assert_eq!(ExportPreset::DEFAULT.settings(), ExportPreset::social_default_settings());
}

/// A preset bitrate between the steps matches none (the dialog opened with no Quality segment lit); the nearest step does.
#[test]
fn a_bitrate_between_the_steps_has_a_nearest_quality_step() {
    let mut v = video(VideoCodec::H264);
    v.apply_quality(QualityStep::Standard);
    let on_step = v.bitrate.average_bits_per_second();
    v.bitrate = BitrateMode::Average(on_step * 13 / 10);
    assert_eq!(v.quality_step(), None, "30 % off Standard is no step");
    assert_eq!(v.nearest_quality_step(), Some(QualityStep::Standard));
    v.bitrate = BitrateMode::Average(on_step * 4);
    assert_eq!(v.nearest_quality_step(), Some(QualityStep::High));
    v.bitrate = BitrateMode::Average(on_step / 4);
    assert_eq!(v.nearest_quality_step(), Some(QualityStep::Smaller));
}

fn video(codec: VideoCodec) -> VideoSettings {
    let mut v = VideoSettings::default();
    v.codec = codec;
    v.width = 1920;
    v.height = 1080;
    v.frame_duration = Time::new(1, 30);
    v
}

#[test]
fn standard_matches_default_bitrate() {
    let mut v = video(VideoCodec::H264);
    v.apply_quality(QualityStep::Standard);
    assert_eq!(v.bitrate.average_bits_per_second(), (1920.0 * 1080.0 * 30.0 * 0.18) as i64);
    assert_eq!(v.quality_step(), Some(QualityStep::Standard));
}

#[test]
fn steps_order_and_hevc_is_smaller() {
    let (mut h, mut e) = (video(VideoCodec::H264), video(VideoCodec::Hevc));
    h.apply_quality(QualityStep::Smaller);
    let hs = h.bitrate.average_bits_per_second();
    h.apply_quality(QualityStep::High);
    let hh = h.bitrate.average_bits_per_second();
    e.apply_quality(QualityStep::High);
    assert!(hs < hh);
    assert!(e.bitrate.average_bits_per_second() < hh);
    assert_eq!(h.quality_step(), Some(QualityStep::High));
}

#[test]
fn custom_and_pro_res_have_no_step() {
    let mut v = video(VideoCodec::H264);
    v.bitrate = BitrateMode::Average(7_000_000);
    assert_eq!(v.quality_step(), None);
    let mut p = video(VideoCodec::ProRes422);
    p.apply_quality(QualityStep::High);
    assert_eq!(p.quality_step(), None);
}

#[test]
fn maximum_keeps_ratio() {
    let mut v = video(VideoCodec::H264);
    v.bitrate = BitrateMode::AverageAndMax { average: 10_000_000, max: 15_000_000 };
    v.apply_quality(QualityStep::High);
    assert_eq!(v.bitrate.max_bits_per_second(), Some(v.bitrate.average_bits_per_second() * 3 / 2));
}

#[test]
fn feed_and_stories_sizes() {
    let size = |p: ExportPreset| {
        let s = p.settings();
        (s.video.width, s.video.height)
    };
    assert_eq!(size(ExportPreset::FEED_PORTRAIT), (1080, 1350));
    assert_eq!(size(ExportPreset::FEED_SQUARE), (1080, 1080));
    assert_eq!(size(ExportPreset::STORIES), (1080, 1920));
}

#[test]
fn instagram_presets_are_valid_h264_rec709_thirty_fps() {
    for p in [ExportPreset::FEED_PORTRAIT, ExportPreset::FEED_SQUARE, ExportPreset::STORIES] {
        let s = p.settings();
        assert!(s.validate().is_empty(), "{}", p.id());
        assert_eq!(s.video.codec, VideoCodec::H264);
        assert_eq!(s.color, ColorSettings::REC709);
        assert_eq!(s.video.frame_duration, Time::new(1, 30));
    }
}

#[test]
fn presets_keep_their_size_whatever_the_sequence_is() {
    let s = ExportPreset::FEED_PORTRAIT.settings_matching(Some(&fmt(1920, 1080)));
    assert!(s.video.width == 1080 && s.video.height == 1350);
}

#[test]
fn listed_with_unique_ids_and_names() {
    let all = ExportPreset::all();
    assert_eq!(all.iter().map(ExportPreset::id).collect::<HashSet<_>>().len(), all.len());
    assert_eq!(all.iter().map(ExportPreset::name).collect::<HashSet<_>>().len(), all.len());
    for p in [ExportPreset::FEED_PORTRAIT, ExportPreset::FEED_SQUARE, ExportPreset::STORIES] {
        assert!(all.contains(&p));
    }
    assert!(ExportPreset::STORIES.name().contains("Stories"));
}

#[test]
fn youtube_1440_table() {
    let s = ExportPreset::YOUTUBE_1440.settings();
    assert!(s.video.width == 2560 && s.video.height == 1440);
    assert_eq!(s.video.bitrate.average_bits_per_second(), 16_000_000);
    assert!(s.validate().is_empty());
}

#[test]
fn youtube_default_follows_frame_width() {
    let t = target(DeliveryPlatform::Youtube);
    let p = |w, h| ExportPreset::default_preset(Some(&fmt(w, h)), Some(&t));
    assert_eq!(p(1920, 1080), ExportPreset::YOUTUBE_1080);
    assert_eq!(p(2560, 1440), ExportPreset::YOUTUBE_1440);
    assert_eq!(p(3840, 2160), ExportPreset::YOUTUBE_4K);
}

#[test]
fn x_and_facebook_are_present_valid_and_unique() {
    for p in [ExportPreset::X_POST, ExportPreset::FACEBOOK] {
        assert!(ExportPreset::all().contains(&p));
        assert!(p.settings().validate().is_empty());
        assert_eq!(p.settings().video.codec, VideoCodec::H264);
    }
    assert_eq!(ExportPreset::X_POST.limits().map(|l| l.max_duration), Some(Time::new(140, 1)));
    assert_eq!(ExportPreset::FACEBOOK.limits(), None);
}

#[test]
fn platform_maps_to_preset() {
    let vertical = fmt(1080, 1920);
    let d = |f: &sq_core_model::SequenceFormat, p| ExportPreset::default_preset(Some(f), Some(&target(p)));
    assert_eq!(
        d(&vertical, DeliveryPlatform::Tiktok),
        ExportPreset::social_preset(SocialPlatform::Tiktok, VideoCodec::H264)
    );
    assert_eq!(
        d(&vertical, DeliveryPlatform::Reels),
        ExportPreset::social_preset(SocialPlatform::Reels, VideoCodec::H264)
    );
    assert_eq!(
        d(&vertical, DeliveryPlatform::Shorts),
        ExportPreset::social_preset(SocialPlatform::Shorts, VideoCodec::H264)
    );
    let (hd, uhd) = (fmt(1920, 1080), fmt(3840, 2160));
    assert_eq!(d(&hd, DeliveryPlatform::Youtube), ExportPreset::YOUTUBE_1080);
    assert_eq!(d(&uhd, DeliveryPlatform::Youtube), ExportPreset::YOUTUBE_4K);
    let (portrait, square) = (fmt(1080, 1350), fmt(1080, 1080));
    assert_eq!(d(&portrait, DeliveryPlatform::SocialFeed), ExportPreset::FEED_PORTRAIT);
    assert_eq!(d(&square, DeliveryPlatform::SocialFeed), ExportPreset::FEED_SQUARE);
    assert_eq!(ExportPreset::default_preset(Some(&hd), None), ExportPreset::MATCH_SOURCE);
}

#[test]
fn tiktok_sequence_gives_vertical_settings_with_loudness() {
    let f = fmt(1080, 1920);
    let t = target(DeliveryPlatform::Tiktok);
    let s = ExportPreset::default_preset(Some(&f), Some(&t)).settings_matching_target(Some(&f), Some(&t));
    assert!(s.video.width == 1080 && s.video.height == 1920);
    assert_eq!(s.audio.loudness, Some(LoudnessNormalization::new(-14.0, -1.0)));
}

/// A delivery preset of another aspect never changes the sequence's size: the sheet opens at the sequence's own size.
#[test]
fn a_delivery_target_of_another_aspect_keeps_the_sequence_size() {
    for (w, h, platform) in [
        (1080, 1920, DeliveryPlatform::Youtube),
        (1080, 1350, DeliveryPlatform::Youtube),
        (1920, 1080, DeliveryPlatform::Tiktok),
        (1920, 1080, DeliveryPlatform::Shorts),
        (1080, 1080, DeliveryPlatform::Youtube),
    ] {
        let (f, t) = (fmt(w, h), target(platform));
        let s = ExportPreset::default_preset(Some(&f), Some(&t)).settings_matching_target(Some(&f), Some(&t));
        assert_eq!((s.video.width, s.video.height), (w, h), "{platform:?} on {w}x{h}");
        assert!(s.audio.loudness.is_some(), "the target's loudness stays");
    }
    // The same aspect keeps the preset's own size.
    let (f, t) = (fmt(1920, 1080), target(DeliveryPlatform::Youtube));
    let s = ExportPreset::default_preset(Some(&f), Some(&t)).settings_matching_target(Some(&f), Some(&t));
    assert_eq!((s.video.width, s.video.height), (1920, 1080));
}

#[test]
fn no_target_means_no_loudness() {
    let f = fmt(1920, 1080);
    assert_eq!(ExportPreset::YOUTUBE_1080.settings_matching_target(Some(&f), None).audio.loudness, None);
}

#[test]
fn match_source_follows_the_sequence_size_rate_and_scales_bitrate() {
    let mut f = fmt(1921, 1081);
    f.frame_duration = Time::new(1, 60);
    let s = ExportPreset::MATCH_SOURCE.settings_matching(Some(&f));
    assert!(s.video.width == 1920 && s.video.height == 1080);
    // 1920 * 1080 * 60 * 0.18 = 22_394_880
    assert_eq!(s.video.bitrate, BitrateMode::Average(22_394_880));
    assert_eq!(s.video.keyframe_interval, 120);
    // 120 fps social sequences stay at the preset's 30 fps; youtube above 30 fps gets 1.5x
    f.frame_duration = Time::new(1, 120);
    assert_eq!(ExportPreset::DEFAULT.settings_matching(Some(&f)).video.frame_duration, Time::new(1, 30));
    f.frame_duration = Time::new(1, 60);
    let y = ExportPreset::YOUTUBE_1080.settings_matching(Some(&f));
    assert_eq!(y.video.bitrate, BitrateMode::AverageAndMax { average: 18_000_000, max: 27_000_000 });
}

#[test]
fn loudness_per_preset() {
    assert_eq!(ExportPreset::PRORES.loudness().target_lufs, -23.0);
    assert_eq!(ExportPreset::DEFAULT.loudness(), LoudnessNormalization::new(-14.0, -1.0));
}

#[test]
fn a_remembered_quality_step_returns_on_the_preset_and_never_on_custom() {
    let s = ExportPreset::YOUTUBE_1080.settings();
    let p = ExportPreferences::new(&ExportPreset::YOUTUBE_1080.id(), &s, false)
        .with_quality_step(Some(QualityStep::Smaller));
    let back = ExportPreferences::decode(p.encoded().as_deref()).unwrap();
    assert_eq!(back.quality_step, Some(QualityStep::Smaller));
    let mut target = ExportPreset::YOUTUBE_1080.settings();
    back.apply(&mut target, LoudnessNormalization::new(-16.0, -1.0));
    assert_eq!(target.video.quality_step(), Some(QualityStep::Smaller));
    let custom = ExportPreferences::new(ExportPreferences::CUSTOM_PRESET_ID, &s, false)
        .with_quality_step(Some(QualityStep::High));
    assert_eq!(custom.quality_step, None);
}

#[test]
fn preferences_round_trip_and_apply() {
    let mut s = ExportPreset::DEFAULT.settings();
    s.captions = CaptionMode::SidecarVtt;
    s.audio.loudness = Some(LoudnessNormalization::default());
    s.video.width = 640;
    let p = ExportPreferences::new(ExportPreferences::CUSTOM_PRESET_ID, &s, true);
    let back = ExportPreferences::decode(p.encoded().as_deref()).unwrap();
    assert_eq!(back, p);
    assert!(back.preset().is_none());
    let mut target = ExportPreset::DEFAULT.settings();
    back.apply(&mut target, LoudnessNormalization::new(-16.0, -1.0));
    assert!(target.video.width == 640 && target.captions == CaptionMode::SidecarVtt);
    assert_eq!(target.audio.loudness, Some(LoudnessNormalization::new(-16.0, -1.0)));
    // A damaged value never stops the dialog from opening.
    let damaged =
        ExportPreferences::decode(Some(br#"{"presetID": 5, "captions": "x", "audioEnabled": false}"#)).unwrap();
    assert_eq!(damaged.preset_id, "tiktok-h264");
    assert!(damaged.captions == CaptionMode::None && !damaged.audio_enabled);
    assert_eq!(damaged.preset(), Some(ExportPreset::DEFAULT));
    assert!(ExportPreferences::decode(Some(b"not json")).is_none());
}
