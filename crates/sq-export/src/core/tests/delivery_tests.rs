// Swift: DeliveryAdviceTests.swift, DeliveryCheckTests.swift, PlatformSpecSoftLimitTests.swift,
// StemMetadataSpecTests.swift (platform spec)

use crate::core::*;
use sq_core_model::DeliveryPlatform;
use sq_core_time::Time;

fn soc(p: SocialPlatform) -> ExportPreset {
    ExportPreset::social_preset(p, VideoCodec::H264)
}

#[test]
fn soft_limits_come_from_the_bundled_spec() {
    let spec = PlatformSpec::bundled();
    assert_eq!(spec.entry("shorts").unwrap().soft_duration_seconds, Some(180));
    assert_eq!(spec.entry("reels").unwrap().soft_duration_seconds, Some(90));
    assert_eq!(spec.entry("tiktok").unwrap().soft_duration_seconds, None);
    assert_eq!(DeliveryAdvice::soft_duration_limit(&soc(SocialPlatform::Shorts)), Some(Time::new(180, 1)));
    assert_eq!(DeliveryAdvice::soft_duration_limit(&soc(SocialPlatform::Reels)), Some(Time::new(90, 1)));
    assert_eq!(DeliveryAdvice::soft_duration_limit(&soc(SocialPlatform::Tiktok)), None);
}

#[test]
fn platform_spec_bundled() {
    let p = PlatformSpec::bundled();
    assert_eq!(p.platforms.len(), 3);
    assert_eq!(p.entry("shorts").unwrap().max_duration_seconds, 180);
    assert_eq!(p.entry("shorts").unwrap().loudness_lufs, Some(-14.0));
    assert_eq!(p.entry("tiktok").unwrap().loudness_lufs, None);
    assert!(p.platforms.iter().all(|e| e.source.starts_with("https://") && e.verified.len() == 10));
}

#[test]
fn shorts_and_reels_length_warn() {
    let (shorts, reels) = (soc(SocialPlatform::Shorts), soc(SocialPlatform::Reels));
    assert!(DeliveryAdvice::length_warning(&shorts, Time::new(179, 1), "Shorts").is_none());
    assert_eq!(
        DeliveryAdvice::length_warning(&shorts, Time::new(200, 1), "Shorts").as_deref(),
        Some("Shorts usually accepts at most 180 seconds; this export is 200 seconds.")
    );
    assert!(DeliveryAdvice::length_warning(&reels, Time::new(95, 1), "Reels").is_some());
    assert!(DeliveryAdvice::length_warning(&soc(SocialPlatform::Tiktok), Time::new(600, 1), "T").is_none());
}

#[test]
fn youtube_rate_and_audio_notes() {
    let mut s = ExportPreset::YOUTUBE_1080.settings();
    s.video.frame_duration = Time::new(1, 30);
    s.audio.sample_rate = 48_000;
    let notes = |s: &ExportSettings| DeliveryAdvice::settings_notes(s, &ExportPreset::YOUTUBE_1080);
    assert!(notes(&s).is_empty());
    s.video.frame_duration = Time::new(1001, 24000);
    assert!(notes(&s).is_empty());
    s.video.frame_duration = Time::new(1, 120);
    assert_eq!(notes(&s), ["YouTube lists 24, 25, 30, 48, 50 and 60 fps; 120 fps may be re-encoded or look uneven."]);
    s.video.frame_duration = Time::new(1, 30);
    s.audio.sample_rate = 44_100;
    assert_eq!(notes(&s), ["Audio is 44.1 kHz; video delivery expects 48 kHz."]);
}

#[test]
fn format_rate_matches_printf_g3() {
    assert_eq!(DeliveryAdvice::format_rate(30.0), "30");
    assert_eq!(DeliveryAdvice::format_rate(23.976), "24");
    assert_eq!(DeliveryAdvice::format_rate(29.97), "30");
    assert_eq!(DeliveryAdvice::format_rate(59.94), "59.9");
    assert_eq!(DeliveryAdvice::format_rate(44.1), "44.1");
    assert_eq!(DeliveryAdvice::format_rate(0.5), "0.5");
    assert_eq!(DeliveryAdvice::format_rate(1234.5), "1.23e+03");
    assert_eq!(DeliveryAdvice::format_rate(0.00001234), "1.23e-05");
}

#[test]
fn odd_size_note_names_the_even_size() {
    assert!(DeliveryAdvice::odd_size_note(1921, 1080).unwrap().contains("1920x1080"));
    assert!(DeliveryAdvice::odd_size_note(1920, 1080).is_none());
}

fn ids(i: &[DeliveryIssue]) -> Vec<&'static str> {
    i.iter().map(|x| x.id).collect()
}

fn issues(s: &ExportSettings, p: &ExportPreset, secs: i64, src: SourceTraits) -> Vec<DeliveryIssue> {
    DeliveryCheck::issues(s, p, Time::new(secs, 1), src, None)
}

#[test]
fn clean_export_has_no_issues() {
    let mut s = ExportPreset::YOUTUBE_1080.settings();
    s.video.frame_duration = Time::new(1, 30);
    s.audio.sample_rate = 48_000;
    assert!(issues(&s, &ExportPreset::YOUTUBE_1080, 60, SourceTraits::default()).is_empty());
}

#[test]
fn source_traits_raise_vfr_and_interlaced() {
    let s = ExportPreset::YOUTUBE_1080.settings();
    let src = SourceTraits { has_variable_frame_rate: true, has_interlaced: true, captions_in_zone: 0 };
    let i = issues(&s, &ExportPreset::YOUTUBE_1080, 60, src);
    assert_eq!(ids(&i), ["vfr", "interlaced"]);
    assert!(i.iter().all(|x| x.severity == DeliverySeverity::Warning && !x.text.is_empty()));
}

#[test]
fn captions_in_platform_zone_warn() {
    let s = ExportPreset::YOUTUBE_1080.settings();
    let run = |n, p: Option<DeliveryPlatform>| {
        DeliveryCheck::issues(
            &s,
            &ExportPreset::YOUTUBE_1080,
            Time::new(10, 1),
            SourceTraits { captions_in_zone: n, ..Default::default() },
            p,
        )
    };
    let w = run(2, Some(DeliveryPlatform::Tiktok));
    assert!(ids(&w) == ["zone"] && w[0].severity == DeliverySeverity::Warning);
    assert_eq!(w[0].text, "2 captions sit in the TikTok UI zone");
    assert_eq!(run(1, Some(DeliveryPlatform::Reels))[0].text, "1 caption sits in the Reels UI zone");
    assert!(run(0, Some(DeliveryPlatform::Tiktok)).is_empty());
    assert!(run(2, Some(DeliveryPlatform::Youtube)).is_empty() && run(2, None).is_empty());
}

#[test]
fn frame_rate_and_audio_rate_issues() {
    let mut s = ExportPreset::YOUTUBE_1080.settings();
    s.video.frame_duration = Time::new(1, 120);
    s.audio.sample_rate = 44_100;
    let i = issues(&s, &ExportPreset::YOUTUBE_1080, 10, SourceTraits::default());
    assert_eq!(ids(&i), ["fps", "audioRate"]);
    assert_eq!(i[0].text, "120 fps is not a YouTube rate");
    assert_eq!(i[1].text, "Audio 44.1 kHz, not 48");
}

#[test]
fn platform_length_warnings() {
    let reels = soc(SocialPlatform::Reels);
    let s = reels.settings();
    assert!(ids(&issues(&s, &reels, 120, SourceTraits::default())).contains(&"length"));
    assert_eq!(issues(&s, &reels, 120, SourceTraits::default())[0].text, "Over 90 s: Instagram Reels may cut it");
    assert!(!ids(&issues(&s, &reels, 60, SourceTraits::default())).contains(&"length"));
    let x = ExportPreset::X_POST;
    assert!(ids(&issues(&x.settings(), &x, 130, SourceTraits::default())).contains(&"length"));
    assert!(!ids(&issues(&x.settings(), &x, 60, SourceTraits::default())).contains(&"length"));
    assert!(!ids(&issues(&x.settings(), &x, 141, SourceTraits::default())).contains(&"length"));
}

#[test]
fn audio_only_and_frame_output_have_no_issues() {
    let s = ExportPreset::AUDIO_WAV.settings();
    assert!(
        issues(&s, &ExportPreset::AUDIO_WAV, 600, SourceTraits { has_interlaced: true, ..Default::default() })
            .is_empty()
    );
    assert!(DeliveryCheck::encoder(&s).is_none());
}

#[test]
fn encoder_hint() {
    let mut s = ExportPreset::MATCH_SOURCE.settings();
    s.video.hardware_encoding = true;
    s.video.width = 1920;
    s.video.height = 1080;
    assert!(DeliveryCheck::encoder(&s).unwrap().is_hardware);
    s.video.hardware_encoding = false;
    let off = DeliveryCheck::encoder(&s).unwrap();
    assert!(!off.is_hardware && off.reason.contains("hardware encoding is off"));
    s.video.hardware_encoding = true;
    s.video.codec = VideoCodec::H264;
    s.video.width = 7680;
    s.video.height = 4320;
    assert!(!DeliveryCheck::encoder(&s).unwrap().is_hardware);
    s.video.codec = VideoCodec::ProRes422;
    assert!(DeliveryCheck::encoder(&s).unwrap().reason.contains("ProRes"));
}

#[test]
fn hardware_size_limit_is_per_codec() {
    let mut s = ExportPreset::MATCH_SOURCE.settings();
    s.video.hardware_encoding = true;
    s.video.width = 7680;
    s.video.height = 4320;
    s.video.codec = VideoCodec::Hevc;
    assert!(DeliveryCheck::encoder(&s).unwrap().is_hardware, "8K HEVC stays on the hardware encoder");
    s.video.width = 8704;
    let big = DeliveryCheck::encoder(&s).unwrap();
    assert!(!big.is_hardware && big.reason.contains("8192 px"), "{}", big.reason);
    s.video.codec = VideoCodec::H264;
    s.video.width = 4097;
    assert!(DeliveryCheck::encoder(&s).unwrap().reason.contains("4096 px"));
    assert_eq!(DeliveryCheck::hardware_size_limit(VideoCodec::H264), 4096);
}
