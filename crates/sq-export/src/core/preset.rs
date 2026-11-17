// Swift: ExportPreset.swift, QualityStep.swift, ExportPreferences.swift

use super::frame_output::{FrameOutput, FrameStillFormat};
use super::settings::{
    AudioFileFormat, AudioSettings, BitrateMode, CaptionMode, CoverImageFormat, ExportSettings, LoudnessNormalization,
    VideoCodec, VideoProfile, VideoSettings,
};
use serde::{Deserialize, Serialize};
use sq_core_model::{DeliveryPlatform, DeliveryTarget, SequenceFormat};
use sq_core_time::Time;

/// Platforms with their own vertical presets.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SocialPlatform {
    /// TikTok.
    Tiktok,
    /// Instagram Reels.
    Reels,
    /// YouTube Shorts.
    Shorts,
}

impl SocialPlatform {
    /// Every platform.
    pub const ALL: [SocialPlatform; 3] = [SocialPlatform::Tiktok, SocialPlatform::Reels, SocialPlatform::Shorts];

    /// Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            SocialPlatform::Tiktok => "tiktok",
            SocialPlatform::Reels => "reels",
            SocialPlatform::Shorts => "shorts",
        }
    }

    /// Shown name.
    pub fn display_name(self) -> &'static str {
        match self {
            SocialPlatform::Tiktok => "TikTok",
            SocialPlatform::Reels => "Instagram Reels",
            SocialPlatform::Shorts => "YouTube Shorts",
        }
    }
}

/// What a preset is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PresetKind {
    /// Sequence size and rate, high bitrate H.264.
    MatchSource,
    /// YouTube 1080p.
    Youtube1080,
    /// YouTube 1440p.
    Youtube1440,
    /// YouTube 4K.
    Youtube4K,
    /// A vertical platform preset.
    Social,
    /// ProRes 422 HQ master.
    ProRes,
    /// X (Twitter) 1080p, H.264.
    XPost,
    /// Facebook 1080p, H.264.
    Facebook,
    /// HEVC Main 10 at the sequence's size and rate.
    Hevc10,
    /// H.264 at the average bitrate in several passes by the software encoder.
    BestAtSize,
    /// ProRes 422 master.
    ProRes422,
    /// ProRes 4444 master.
    ProRes4444,
    /// Instagram feed 4:5.
    FeedPortrait,
    /// Instagram feed 1:1.
    FeedSquare,
    /// Instagram Stories 9:16.
    Stories,
    /// Audio only: M4A (AAC 256 kbit/s).
    AudioM4A,
    /// Audio only: WAV (24-bit PCM).
    AudioWav,
    /// Audio only: lossless FLAC (24-bit).
    AudioFlac,
    /// Animated GIF.
    Gif,
    /// Folder of numbered PNG images (with alpha).
    ImageSequence,
}

impl PresetKind {
    /// Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            PresetKind::MatchSource => "matchSource",
            PresetKind::Youtube1080 => "youtube1080",
            PresetKind::Youtube1440 => "youtube1440",
            PresetKind::Youtube4K => "youtube4K",
            PresetKind::Social => "social",
            PresetKind::ProRes => "proRes",
            PresetKind::XPost => "xPost",
            PresetKind::Facebook => "facebook",
            PresetKind::Hevc10 => "hevc10",
            PresetKind::BestAtSize => "bestAtSize",
            PresetKind::ProRes422 => "proRes422",
            PresetKind::ProRes4444 => "proRes4444",
            PresetKind::FeedPortrait => "feedPortrait",
            PresetKind::FeedSquare => "feedSquare",
            PresetKind::Stories => "stories",
            PresetKind::AudioM4A => "audioM4A",
            PresetKind::AudioWav => "audioWAV",
            PresetKind::AudioFlac => "audioFLAC",
            PresetKind::Gif => "gif",
            PresetKind::ImageSequence => "imageSequence",
        }
    }
}

/// Upload limits of a platform: the Export sheet blocks a job that would exceed them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct DeliveryLimits {
    /// Longest accepted duration.
    pub max_duration: Time,
    /// Largest accepted file.
    pub max_file_bytes: i64,
}

/// One entry of the Export sheet's preset menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ExportPreset {
    /// What it is for.
    pub kind: PresetKind,
    /// Only for `Social` presets.
    pub platform: Option<SocialPlatform>,
    /// Codec.
    pub codec: VideoCodec,
}

impl ExportPreset {
    /// A platform preset.
    pub fn social_preset(platform: SocialPlatform, codec: VideoCodec) -> ExportPreset {
        ExportPreset { kind: PresetKind::Social, platform: Some(platform), codec }
    }

    /// Match Source, High bitrate (H.264).
    pub const MATCH_SOURCE: ExportPreset =
        ExportPreset { kind: PresetKind::MatchSource, platform: None, codec: VideoCodec::H264 };
    /// YouTube 1080p Full HD.
    pub const YOUTUBE_1080: ExportPreset =
        ExportPreset { kind: PresetKind::Youtube1080, platform: None, codec: VideoCodec::H264 };
    /// YouTube 1440p QHD.
    pub const YOUTUBE_1440: ExportPreset =
        ExportPreset { kind: PresetKind::Youtube1440, platform: None, codec: VideoCodec::H264 };
    /// YouTube 4K Ultra HD.
    pub const YOUTUBE_4K: ExportPreset =
        ExportPreset { kind: PresetKind::Youtube4K, platform: None, codec: VideoCodec::H264 };
    /// X (Twitter) 1080p.
    pub const X_POST: ExportPreset = ExportPreset { kind: PresetKind::XPost, platform: None, codec: VideoCodec::H264 };
    /// Facebook 1080p.
    pub const FACEBOOK: ExportPreset =
        ExportPreset { kind: PresetKind::Facebook, platform: None, codec: VideoCodec::H264 };
    /// ProRes 422 HQ master.
    pub const PRORES: ExportPreset =
        ExportPreset { kind: PresetKind::ProRes, platform: None, codec: VideoCodec::ProRes422HQ };
    /// ProRes 422 master.
    pub const PRORES_422: ExportPreset =
        ExportPreset { kind: PresetKind::ProRes422, platform: None, codec: VideoCodec::ProRes422 };
    /// ProRes 4444 master.
    pub const PRORES_4444: ExportPreset =
        ExportPreset { kind: PresetKind::ProRes4444, platform: None, codec: VideoCodec::ProRes4444 };
    /// HEVC 10-bit.
    pub const HEVC_10: ExportPreset =
        ExportPreset { kind: PresetKind::Hevc10, platform: None, codec: VideoCodec::Hevc };
    /// Best quality at size (multi-pass).
    pub const BEST_AT_SIZE: ExportPreset =
        ExportPreset { kind: PresetKind::BestAtSize, platform: None, codec: VideoCodec::H264 };
    /// Instagram feed 4:5.
    pub const FEED_PORTRAIT: ExportPreset =
        ExportPreset { kind: PresetKind::FeedPortrait, platform: None, codec: VideoCodec::H264 };
    /// Instagram feed 1:1.
    pub const FEED_SQUARE: ExportPreset =
        ExportPreset { kind: PresetKind::FeedSquare, platform: None, codec: VideoCodec::H264 };
    /// Instagram Stories.
    pub const STORIES: ExportPreset =
        ExportPreset { kind: PresetKind::Stories, platform: None, codec: VideoCodec::H264 };
    /// Audio only M4A.
    pub const AUDIO_M4A: ExportPreset =
        ExportPreset { kind: PresetKind::AudioM4A, platform: None, codec: VideoCodec::H264 };
    /// Audio only WAV.
    pub const AUDIO_WAV: ExportPreset =
        ExportPreset { kind: PresetKind::AudioWav, platform: None, codec: VideoCodec::H264 };
    /// Audio only FLAC.
    pub const AUDIO_FLAC: ExportPreset =
        ExportPreset { kind: PresetKind::AudioFlac, platform: None, codec: VideoCodec::H264 };
    /// Animated GIF.
    pub const GIF: ExportPreset = ExportPreset { kind: PresetKind::Gif, platform: None, codec: VideoCodec::H264 };
    /// Image sequence.
    pub const IMAGE_SEQUENCE: ExportPreset =
        ExportPreset { kind: PresetKind::ImageSequence, platform: None, codec: VideoCodec::H264 };
    /// TikTok 9:16 H.264.
    pub const DEFAULT: ExportPreset =
        ExportPreset { kind: PresetKind::Social, platform: Some(SocialPlatform::Tiktok), codec: VideoCodec::H264 };

    /// Stable id: the kind's raw value, `<platform>-<codec>` for social presets.
    pub fn id(&self) -> String {
        match self.kind {
            PresetKind::Social => {
                format!("{}-{}", self.platform.map_or("social", SocialPlatform::raw_value), self.codec.raw_value())
            }
            k => k.raw_value().to_string(),
        }
    }

    /// Menu name.
    pub fn name(&self) -> String {
        match self.kind {
            PresetKind::MatchSource => "Match Source \u{2013} High bitrate (H.264)".into(),
            PresetKind::Youtube1080 => "YouTube 1080p Full HD".into(),
            PresetKind::Youtube1440 => "YouTube 1440p QHD".into(),
            PresetKind::Youtube4K => "YouTube 4K Ultra HD".into(),
            PresetKind::XPost => "X (Twitter) 1080p (H.264)".into(),
            PresetKind::Facebook => "Facebook 1080p (H.264)".into(),
            PresetKind::ProRes => "ProRes 422 HQ (master)".into(),
            PresetKind::ProRes422 => "ProRes 422 (master)".into(),
            PresetKind::ProRes4444 => "ProRes 4444 (master)".into(),
            PresetKind::Hevc10 => "Match Source \u{2013} HEVC 10-bit".into(),
            PresetKind::BestAtSize => "Best quality at size \u{2013} H.264 (multi-pass)".into(),
            PresetKind::FeedPortrait => "Instagram Feed 4:5 1080\u{D7}1350 (H.264)".into(),
            PresetKind::FeedSquare => "Instagram Feed 1:1 1080\u{D7}1080 (H.264)".into(),
            PresetKind::Stories => "Instagram Stories 1080\u{D7}1920 (H.264)".into(),
            PresetKind::Social => {
                format!(
                    "{} 1080\u{D7}1920 ({})",
                    self.platform.map_or("Vertical", SocialPlatform::display_name),
                    self.codec.display_name()
                )
            }
            PresetKind::AudioM4A => "Audio only \u{2013} M4A (AAC)".into(),
            PresetKind::AudioWav => "Audio only \u{2013} WAV (24-bit PCM)".into(),
            PresetKind::AudioFlac => "Audio only \u{2013} FLAC (lossless)".into(),
            PresetKind::Gif => "Animated GIF".into(),
            PresetKind::ImageSequence => "Image sequence (PNG)".into(),
        }
    }

    /// The mixed audio only, no picture.
    pub fn is_audio_only(&self) -> bool {
        matches!(self.kind, PresetKind::AudioM4A | PresetKind::AudioWav | PresetKind::AudioFlac)
    }

    /// TikTok / Reels / Shorts, H.264 and HEVC.
    pub fn social() -> Vec<ExportPreset> {
        SocialPlatform::ALL
            .into_iter()
            .flat_map(|p| [VideoCodec::H264, VideoCodec::Hevc].map(|c| ExportPreset::social_preset(p, c)))
            .collect()
    }

    /// Everything the Export sheet offers, in menu order.
    pub fn all() -> Vec<ExportPreset> {
        let mut v = vec![
            Self::MATCH_SOURCE,
            Self::HEVC_10,
            Self::BEST_AT_SIZE,
            Self::YOUTUBE_1080,
            Self::YOUTUBE_1440,
            Self::YOUTUBE_4K,
            Self::X_POST,
            Self::FACEBOOK,
        ];
        v.extend(Self::social());
        v.extend([
            Self::FEED_PORTRAIT,
            Self::FEED_SQUARE,
            Self::STORIES,
            Self::PRORES,
            Self::PRORES_422,
            Self::PRORES_4444,
            Self::AUDIO_M4A,
            Self::AUDIO_WAV,
            Self::AUDIO_FLAC,
            Self::GIF,
            Self::IMAGE_SEQUENCE,
        ]);
        v
    }

    /// The preset a sequence exports with by default: its target platform's (TikTok/Reels/Shorts, YouTube 1080p, 1440p or
    /// 4K by frame width), 4:5 or 1:1 for feed posts (by the sequence's shape), Match Source when it has no target.
    pub fn default_preset(format: Option<&SequenceFormat>, target: Option<&DeliveryTarget>) -> ExportPreset {
        let Some(target) = target else { return Self::MATCH_SOURCE };
        match target.platform {
            DeliveryPlatform::Tiktok => Self::social_preset(SocialPlatform::Tiktok, VideoCodec::H264),
            DeliveryPlatform::Reels => Self::social_preset(SocialPlatform::Reels, VideoCodec::H264),
            DeliveryPlatform::Shorts => Self::social_preset(SocialPlatform::Shorts, VideoCodec::H264),
            DeliveryPlatform::Youtube => {
                let w = format.map_or(0, |f| f.width);
                if w >= 3840 {
                    Self::YOUTUBE_4K
                } else if w >= 2560 {
                    Self::YOUTUBE_1440
                } else {
                    Self::YOUTUBE_1080
                }
            }
            DeliveryPlatform::SocialFeed => {
                if format.is_some_and(|f| f.width == f.height) {
                    Self::FEED_SQUARE
                } else {
                    Self::FEED_PORTRAIT
                }
            }
        }
    }

    /// `settings_matching` for a sheet that opens or resets, plus the delivery target's loudness normalization (LUFS and
    /// true-peak ceiling). A preset of another shape than the sequence (YouTube on a vertical sequence, TikTok on a
    /// horizontal one) never changes the sequence's size, with or without a delivery target.
    pub fn settings_matching_target(
        &self,
        format: Option<&SequenceFormat>,
        target: Option<&DeliveryTarget>,
    ) -> ExportSettings {
        let mut s = self.settings_matching(format);
        if let Some(f) = format.filter(|f| f.is_valid()) {
            let (a, b) =
                (i128::from(s.video.width) * i128::from(f.height), i128::from(s.video.height) * i128::from(f.width));
            if (a - b).abs() * 100 > a.max(b) {
                s.video.width = f.width & !1;
                s.video.height = f.height & !1;
                s.video.set_pixel_aspect(f.pixel_aspect());
            }
        }
        if let Some(t) = target {
            s.audio.loudness = Some(LoudnessNormalization::new(t.target_lufs, t.true_peak_db));
        }
        s
    }

    /// Settings with the sequence's frame size / rate where the preset follows the source (Match Source: size and rate,
    /// ProRes: size and rate, YouTube: rate; social presets keep 1080x1920 and the sequence rate between 23.976 and 60
    /// fps, else 30).
    pub fn settings_matching(&self, format: Option<&SequenceFormat>) -> ExportSettings {
        let mut s = self.settings();
        let Some(f) = format.filter(|f| f.is_valid()) else { return s };
        let fps = f.frame_duration.timescale() as f64 / f.frame_duration.value() as f64;
        match self.kind {
            PresetKind::MatchSource
            | PresetKind::Hevc10
            | PresetKind::BestAtSize
            | PresetKind::ProRes
            | PresetKind::ProRes422
            | PresetKind::ProRes4444
            | PresetKind::ImageSequence => {
                s.video.width = f.width & !1;
                s.video.height = f.height & !1;
                s.video.frame_duration = f.frame_duration;
                s.video.set_pixel_aspect(f.pixel_aspect()); // stored size plus the file's pixel aspect (pasp)
                if matches!(self.kind, PresetKind::MatchSource | PresetKind::Hevc10 | PresetKind::BestAtSize) {
                    // Bits per pixel per frame; HEVC needs about 30 % less than H.264 for the same quality.
                    let bpp = if self.kind == PresetKind::Hevc10 { 0.12 } else { 0.18 };
                    let bps = (s.video.width * s.video.height) as f64 * fps * bpp;
                    let avg = bps.clamp(6_000_000.0, 80_000_000.0) as i64;
                    // No data rate limit: a 1.5x cap cost hard clips 3-4 VMAF.
                    s.video.bitrate = BitrateMode::Average(avg);
                    s.video.keyframe_interval = ((fps.round() as i64) * 2).max(1);
                }
            }
            PresetKind::Youtube1080
            | PresetKind::Youtube1440
            | PresetKind::Youtube4K
            | PresetKind::XPost
            | PresetKind::Facebook => {
                s.video.frame_duration = f.frame_duration;
                if fps > 30.0 {
                    let b = s.video.bitrate.average_bits_per_second() * 3 / 2;
                    s.video.bitrate = BitrateMode::AverageAndMax { average: b, max: b * 3 / 2 };
                }
                s.video.keyframe_interval = ((fps.round() as i64) * 2).max(1);
            }
            PresetKind::AudioM4A | PresetKind::AudioWav | PresetKind::AudioFlac | PresetKind::Gif => {}
            PresetKind::Social | PresetKind::FeedPortrait | PresetKind::FeedSquare | PresetKind::Stories => {
                // The sequence rate is kept when a platform accepts it (23.976 to 60 fps); anything else (120 fps, odd
                // rates) stays at the preset's 30 fps.
                if (23.9..=60.1).contains(&fps) {
                    s.video.frame_duration = f.frame_duration;
                }
            }
        }
        s
    }

    /// Preset defaults: 1080x1920 30 fps for social, 1080p / 2160p 30 fps for YouTube, Rec.709 1-1-1, AAC 48 kHz stereo.
    pub fn settings(&self) -> ExportSettings {
        let mut s = ExportSettings::default();
        s.video.codec = self.codec;
        s.audio.bitrate = 192_000;
        let v = &mut s.video;
        let fd30 = Time::new(1, 30);
        match self.kind {
            PresetKind::Gif | PresetKind::ImageSequence => {
                s.frame_output = Some(if self.kind == PresetKind::Gif {
                    FrameOutput::Gif
                } else {
                    FrameOutput::Sequence(FrameStillFormat::PngAlpha)
                });
                v.width = 1080;
                v.height = 1080;
                v.frame_duration = if self.kind == PresetKind::Gif { Time::new(1, 15) } else { fd30 };
                s.audio.enabled = false;
                s.captions = CaptionMode::None;
            }
            PresetKind::AudioM4A | PresetKind::AudioWav | PresetKind::AudioFlac => {
                s.audio_only = Some(match self.kind {
                    PresetKind::AudioM4A => AudioFileFormat::M4a,
                    PresetKind::AudioFlac => AudioFileFormat::Flac,
                    _ => AudioFileFormat::Wav,
                });
                s.audio.codec = if self.kind == PresetKind::AudioM4A {
                    super::settings::AudioCodec::Aac
                } else {
                    super::settings::AudioCodec::Pcm
                };
                s.audio.bitrate = 256_000;
                s.audio.pcm_bit_depth = 24;
                s.captions = CaptionMode::None;
            }
            PresetKind::ProRes => return ExportSettings::pro_res_422_hq_master(),
            PresetKind::ProRes422 | PresetKind::ProRes4444 => {
                let mut m = ExportSettings::pro_res_422_hq_master();
                m.video.codec = self.codec;
                return m;
            }
            PresetKind::Hevc10 => {
                v.width = 1920;
                v.height = 1080;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::Average(14_000_000);
                v.keyframe_interval = 60;
                v.profile = VideoProfile::Main10;
                s.audio.bitrate = 320_000;
            }
            PresetKind::BestAtSize => {
                v.width = 1920;
                v.height = 1080;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::Average(20_000_000);
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
                s.audio.bitrate = 320_000;
                v.hardware_encoding = false; // multi-pass runs on the software encoder only (see `uses_multi_pass`)
                v.allows_frame_reordering = false;
                s.set_multi_pass(true);
            }
            PresetKind::MatchSource => {
                v.width = 1920;
                v.height = 1080;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::Average(20_000_000);
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
                s.audio.bitrate = 320_000;
            }
            PresetKind::Youtube1080 => {
                v.width = 1920;
                v.height = 1080;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::AverageAndMax { average: 12_000_000, max: 18_000_000 };
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
                s.audio.bitrate = 320_000; // AAC stereo at 48 kHz tops out at 320 kbit/s: more fails with "Cannot Encode Media"
            }
            PresetKind::Youtube1440 => {
                // YouTube's recommended SDR upload bitrates: 16 Mbit/s at 24-30 fps (raised 1.5x above 30 fps).
                v.width = 2560;
                v.height = 1440;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::AverageAndMax { average: 16_000_000, max: 24_000_000 };
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
                s.audio.bitrate = 320_000;
            }
            PresetKind::XPost => {
                // X accepts H.264 High, AAC, up to 1920x1200 at 60 fps and 25 Mbit/s; limits in `limits`.
                v.width = 1920;
                v.height = 1080;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::AverageAndMax { average: 10_000_000, max: 15_000_000 };
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
            }
            PresetKind::Facebook => {
                // Facebook's recommendation: H.264 progressive, AAC stereo, 30 fps; 1080p at about 8 Mbit/s.
                v.width = 1920;
                v.height = 1080;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::AverageAndMax { average: 8_000_000, max: 12_000_000 };
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
            }
            PresetKind::Youtube4K => {
                v.width = 3840;
                v.height = 2160;
                v.frame_duration = fd30;
                v.bitrate = BitrateMode::AverageAndMax { average: 45_000_000, max: 68_000_000 };
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
                s.audio.bitrate = 320_000;
            }
            PresetKind::FeedPortrait | PresetKind::FeedSquare | PresetKind::Stories => {
                v.width = 1080;
                v.height = match self.kind {
                    PresetKind::FeedPortrait => 1350,
                    PresetKind::FeedSquare => 1080,
                    _ => 1920,
                };
                v.frame_duration = fd30;
                let avg = if self.kind == PresetKind::Stories { 8_000_000 } else { 10_000_000 };
                v.bitrate = BitrateMode::AverageAndMax { average: avg, max: avg * 3 / 2 };
                v.keyframe_interval = 60;
                v.profile = VideoProfile::High;
            }
            PresetKind::Social => {
                v.width = 1080;
                v.height = 1920;
                v.frame_duration = fd30;
                let avg = match (self.platform.unwrap_or(SocialPlatform::Tiktok), self.codec) {
                    (SocialPlatform::Tiktok, VideoCodec::H264) => 12_000_000,
                    (SocialPlatform::Reels, VideoCodec::H264) => 10_000_000,
                    (SocialPlatform::Shorts, VideoCodec::H264) => 14_000_000,
                    (SocialPlatform::Tiktok, VideoCodec::Hevc) => 8_000_000,
                    (SocialPlatform::Reels, VideoCodec::Hevc) => 7_000_000,
                    (SocialPlatform::Shorts, VideoCodec::Hevc) => 10_000_000,
                    _ => 12_000_000,
                };
                v.bitrate = BitrateMode::AverageAndMax { average: avg, max: avg * 3 / 2 };
                v.keyframe_interval = 60;
                v.profile = if self.codec == VideoCodec::H264 { VideoProfile::High } else { VideoProfile::Main };
            }
        }
        s
    }

    /// Hard limits of the platform this preset targets (`None` = none the dialog checks).
    pub fn limits(&self) -> Option<DeliveryLimits> {
        (self.kind == PresetKind::XPost)
            .then(|| DeliveryLimits { max_duration: Time::new(140, 1), max_file_bytes: 512 * 1_000_000 })
    }

    /// Loudness target the Export sheet offers with this preset (normalization itself stays an opt-in per export).
    /// TikTok, Instagram Reels, YouTube and YouTube Shorts play at about -14 LUFS; the ProRes master follows EBU R128
    /// (-23 LUFS). True-peak ceiling is -1 dBTP everywhere.
    pub fn loudness(&self) -> LoudnessNormalization {
        match self.kind {
            PresetKind::ProRes | PresetKind::ProRes422 | PresetKind::ProRes4444 => {
                LoudnessNormalization::new(-23.0, -1.0)
            }
            _ => LoudnessNormalization::new(-14.0, -1.0),
        }
    }

    /// Default = TikTok 9:16 H.264 settings.
    pub fn social_default_settings() -> ExportSettings {
        Self::DEFAULT.settings()
    }
}

/// Quality steps for the H.264 / HEVC target bitrate, as bits per pixel per frame: Standard is the Match Source default,
/// nothing wasted; Smaller file and High quality are the measured ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QualityStep {
    /// Smaller file.
    Smaller,
    /// Standard.
    Standard,
    /// High quality.
    High,
}

impl QualityStep {
    /// Every step, in order.
    pub const ALL: [QualityStep; 3] = [QualityStep::Smaller, QualityStep::Standard, QualityStep::High];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            QualityStep::Smaller => "Smaller file",
            QualityStep::Standard => "Standard",
            QualityStep::High => "High quality",
        }
    }

    /// Bits per pixel per frame; HEVC needs about 30 % less than H.264 for the same picture. `None` for ProRes.
    pub fn bits_per_pixel(self, codec: VideoCodec) -> Option<f64> {
        match (codec, self) {
            (VideoCodec::H264, QualityStep::Smaller) => Some(0.09),
            (VideoCodec::H264, QualityStep::Standard) => Some(0.18),
            (VideoCodec::H264, QualityStep::High) => Some(0.35),
            (VideoCodec::Hevc, QualityStep::Smaller) => Some(0.055),
            (VideoCodec::Hevc, QualityStep::Standard) => Some(0.12),
            (VideoCodec::Hevc, QualityStep::High) => Some(0.235),
            _ => None,
        }
    }
}

impl VideoSettings {
    fn pixels_per_second(&self) -> f64 {
        (self.width * self.height) as f64 * self.frame_duration.timescale() as f64
            / self.frame_duration.value().max(1) as f64
    }

    /// The step the current target bitrate sits on (within 8 %), `None` for a custom value or ProRes.
    pub fn quality_step(&self) -> Option<QualityStep> {
        let px = self.pixels_per_second();
        if px <= 0.0 {
            return None;
        }
        let bpp = self.bitrate.average_bits_per_second() as f64 / px;
        QualityStep::ALL
            .into_iter()
            .find(|step| step.bits_per_pixel(self.codec).is_some_and(|t| (bpp - t).abs() <= 0.08 * t))
    }

    /// The step whose bitrate is closest to the current target (in the log domain, so 2x too high is as far as 2x too low),
    /// `None` for ProRes. The dialog highlights it when the preset's own bitrate sits on no step, so one is always on.
    pub fn nearest_quality_step(&self) -> Option<QualityStep> {
        let px = self.pixels_per_second();
        if px <= 0.0 {
            return None;
        }
        let bpp = (self.bitrate.average_bits_per_second() as f64 / px).max(1e-9);
        QualityStep::ALL
            .into_iter()
            .filter_map(|step| step.bits_per_pixel(self.codec).map(|t| (step, (bpp / t).ln().abs())))
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(step, _)| step)
    }

    /// Sets the target bitrate for the step at the current size and rate. A stored maximum keeps its ratio to the target.
    pub fn apply_quality(&mut self, step: QualityStep) {
        let Some(bpp) = step.bits_per_pixel(self.codec) else { return };
        let avg = (self.pixels_per_second() * bpp).clamp(500_000.0, 400_000_000.0) as i64;
        self.bitrate = match self.bitrate.max_bits_per_second() {
            Some(old_max) => {
                let ratio = old_max as f64 / self.bitrate.average_bits_per_second().max(1) as f64;
                BitrateMode::AverageAndMax { average: avg, max: avg.max((avg as f64 * ratio) as i64) }
            }
            None => BitrateMode::Average(avg),
        };
    }
}

/// A sequence's frame size and delivery platform: what decides the preset a sheet starts with.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SequenceShape {
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
    /// The delivery platform, if the sequence has one.
    pub platform: Option<DeliveryPlatform>,
}

impl SequenceShape {
    /// The shape of a sequence; `None` without a frame format.
    pub fn of(format: Option<&SequenceFormat>, target: Option<&DeliveryTarget>) -> Option<SequenceShape> {
        format.map(|f| SequenceShape { width: f.width, height: f.height, platform: target.map(|t| t.platform) })
    }
}

/// What the export dialog remembers between exports (stored by the app as JSON): the last preset and the per-export
/// choices a preset does not own. Absent or damaged keys decode to the defaults, so an older or damaged value never
/// stops the dialog from opening.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "serde_json::Value")]
pub struct ExportPreferences {
    /// Id of the last preset.
    #[serde(rename = "presetID")]
    pub preset_id: String,
    /// Captions.
    pub captions: CaptionMode,
    /// Cover image.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_image: Option<CoverImageFormat>,
    /// Continue on damaged frames.
    pub continue_on_damaged_frames: bool,
    /// Audio on.
    pub audio_enabled: bool,
    /// Normalize loudness.
    pub normalize_loudness: bool,
    /// Export all format variants.
    pub export_all_formats: bool,
    /// The quality step picked on a preset: the preset keeps its name and this step goes back on its bitrate. Unset while
    /// the bitrate is the preset's own, and never kept for "Custom" (its whole video part is stored instead).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quality_step: Option<QualityStep>,
    /// The shape of the sequence the picks were made on. On a sequence of the same shape and target they win over the
    /// preset its delivery target would choose; on another one the target's preset applies as before.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sequence_shape: Option<SequenceShape>,
    /// Hand-edited video settings; only kept while the preset is "Custom".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_video: Option<VideoSettings>,
    /// Hand-edited audio settings; only kept while the preset is "Custom".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_audio: Option<AudioSettings>,
}

impl From<serde_json::Value> for ExportPreferences {
    fn from(v: serde_json::Value) -> ExportPreferences {
        fn get<T: serde::de::DeserializeOwned>(v: &serde_json::Value, k: &str) -> Option<T> {
            v.get(k).and_then(|x| serde_json::from_value(x.clone()).ok())
        }
        ExportPreferences {
            preset_id: get(&v, "presetID").unwrap_or_else(|| ExportPreset::DEFAULT.id()),
            captions: get(&v, "captions").unwrap_or(CaptionMode::None),
            cover_image: get(&v, "coverImage"),
            continue_on_damaged_frames: get(&v, "continueOnDamagedFrames").unwrap_or(false),
            audio_enabled: get(&v, "audioEnabled").unwrap_or(true),
            normalize_loudness: get(&v, "normalizeLoudness").unwrap_or(false),
            export_all_formats: get(&v, "exportAllFormats").unwrap_or(false),
            quality_step: get(&v, "qualityStep"),
            sequence_shape: get(&v, "sequenceShape"),
            custom_video: get(&v, "customVideo"),
            custom_audio: get(&v, "customAudio"),
        }
    }
}

impl ExportPreferences {
    /// The id of the hand-edited "Custom" entry.
    pub const CUSTOM_PRESET_ID: &'static str = "custom";

    /// What the dialog keeps of `settings` under `preset_id`.
    pub fn new(preset_id: &str, settings: &ExportSettings, export_all_formats: bool) -> ExportPreferences {
        let custom = preset_id == Self::CUSTOM_PRESET_ID;
        ExportPreferences {
            preset_id: preset_id.to_string(),
            captions: settings.captions,
            cover_image: settings.cover_image,
            continue_on_damaged_frames: settings.continue_on_damaged_frames,
            audio_enabled: settings.audio.enabled,
            normalize_loudness: settings.audio.loudness.is_some(),
            export_all_formats,
            quality_step: None,
            sequence_shape: None,
            custom_video: custom.then(|| settings.video.clone()),
            custom_audio: custom.then(|| settings.audio.clone()),
        }
    }

    /// Remembers the quality step picked on a preset (ignored for "Custom", which keeps its own bitrate).
    pub fn with_quality_step(mut self, step: Option<QualityStep>) -> ExportPreferences {
        self.quality_step = step.filter(|_| self.preset_id != Self::CUSTOM_PRESET_ID);
        self
    }

    /// Remembers the sequence the picks were made on (see [`ExportPreferences::sequence_shape`]).
    pub fn with_sequence_shape(mut self, shape: Option<SequenceShape>) -> ExportPreferences {
        self.sequence_shape = shape;
        self
    }

    /// The preset this restores (`None` for "Custom" or a preset that no longer exists).
    pub fn preset(&self) -> Option<ExportPreset> {
        ExportPreset::all().into_iter().find(|p| p.id() == self.preset_id)
    }

    /// Puts the remembered choices on `settings`, which hold the preset's values. `loudness` is the target a normalized
    /// export uses here (the sequence's delivery target or the preset's platform target).
    pub fn apply(&self, settings: &mut ExportSettings, loudness: LoudnessNormalization) {
        if self.preset_id == Self::CUSTOM_PRESET_ID
            && let Some(v) = &self.custom_video
        {
            settings.video = v.clone();
            if let Some(a) = &self.custom_audio {
                settings.audio = a.clone();
            }
        } else if let Some(step) = self.quality_step {
            settings.video.apply_quality(step);
        }
        settings.captions = self.captions;
        settings.cover_image = self.cover_image;
        settings.continue_on_damaged_frames = self.continue_on_damaged_frames;
        settings.audio.enabled = self.audio_enabled;
        settings.audio.loudness = self.normalize_loudness.then_some(loudness);
    }

    /// JSON bytes the app stores.
    pub fn encoded(&self) -> Option<Vec<u8>> {
        serde_json::to_vec(self).ok()
    }

    /// Reads stored bytes; `None` when there are none or they are not JSON.
    pub fn decode(data: Option<&[u8]>) -> Option<ExportPreferences> {
        data.and_then(|d| serde_json::from_slice(d).ok())
    }
}
