// Swift: DeliveryAdvice.swift, DeliveryCheck.swift

use super::platform_spec::PlatformSpec;
use super::preset::{ExportPreset, PresetKind};
use super::settings::{ExportSettings, VideoCodec};
use sq_core_edit::cut_check::CutCheckPlatform;
use sq_core_model::DeliveryPlatform;
use sq_core_time::Time;

/// Frame rates YouTube lists as supported (fps).
const YOUTUBE_RATES: [f64; 6] = [24.0, 25.0, 30.0, 48.0, 50.0, 60.0];

fn is_youtube_rate(fps: f64) -> bool {
    YOUTUBE_RATES.iter().any(|r| (r - fps).abs() < 0.05 || (r * 1000.0 / 1001.0 - fps).abs() < 0.05)
}

fn seconds_of(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

/// C `printf("%.3g")`.
fn format_g3(v: f64) -> String {
    if v == 0.0 || !v.is_finite() {
        return if v == 0.0 { "0".to_string() } else { v.to_string() };
    }
    let sci = format!("{v:.2e}");
    let (mant, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let trim = |s: String| if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s };
    if !(-4..3).contains(&exp) {
        return format!("{}e{}{:02}", trim(mant.to_string()), if exp < 0 { '-' } else { '+' }, exp.abs());
    }
    trim(format!("{:.*}", (2 - exp).max(0) as usize, v))
}

/// Soft findings about an export that never block it (the hard upload limits live in `DeliveryLimits`). Plain English
/// lines for the Export sheet.
pub struct DeliveryAdvice;

/// The ProRes encoder hint: hardware on the Mac, software elsewhere.
fn prores_text() -> &'static str {
    if cfg!(target_vendor = "apple") {
        "ProRes uses the Mac's hardware encoder when available, otherwise software."
    } else {
        "ProRes is encoded in software on every system."
    }
}

impl DeliveryAdvice {
    /// Soft length limit of a platform preset (Shorts 3 min, Reels 90 s); `None` = none.
    pub fn soft_duration_limit(preset: &ExportPreset) -> Option<Time> {
        let p = preset.platform.filter(|_| preset.kind == PresetKind::Social)?;
        PlatformSpec::bundled().entry(p.raw_value())?.soft_duration_seconds.map(|s| Time::new(s, 1))
    }

    /// The length warning for `duration` under `preset`, `None` when it fits or the preset has no soft limit.
    pub fn length_warning(preset: &ExportPreset, duration: Time, preset_name: &str) -> Option<String> {
        let lim = Self::soft_duration_limit(preset).filter(|l| duration > *l)?;
        let seconds = seconds_of(lim).round() as i64;
        let actual = seconds_of(duration).round() as i64;
        Some(format!("{preset_name} usually accepts at most {seconds} seconds; this export is {actual} seconds."))
    }

    /// Notes about delivery settings: odd frame rate for YouTube, audio not at 48 kHz.
    pub fn settings_notes(s: &ExportSettings, preset: &ExportPreset) -> Vec<String> {
        let mut out = Vec::new();
        if s.audio_only.is_some() || s.frame_output.is_some() {
            return out;
        }
        let fd = s.video.frame_duration;
        if fd.value() > 0
            && matches!(preset.kind, PresetKind::Youtube1080 | PresetKind::Youtube1440 | PresetKind::Youtube4K)
        {
            let fps = fd.timescale() as f64 / fd.value() as f64;
            if !is_youtube_rate(fps) {
                out.push(format!(
                    "YouTube lists 24, 25, 30, 48, 50 and 60 fps; {} fps may be re-encoded or look uneven.",
                    Self::format_rate(fps)
                ));
            }
        }
        let a = s.effective_audio();
        if a.enabled && a.sample_rate != 48_000 {
            out.push(format!(
                "Audio is {} kHz; video delivery expects 48 kHz.",
                Self::format_rate(a.sample_rate as f64 / 1000.0)
            ));
        }
        out
    }

    /// An odd stored sequence size is written one pixel smaller (codecs need even sizes); say so.
    pub fn odd_size_note(width: i64, height: i64) -> Option<String> {
        if width <= 0 || height <= 0 || (width % 2 == 0 && height % 2 == 0) {
            return None;
        }
        Some(format!(
            "The sequence is {width}x{height}; the file is written at {}x{} because video needs even sizes.",
            width & !1,
            height & !1
        ))
    }

    /// Whole numbers without a decimal point, other rates with three significant digits.
    pub fn format_rate(v: f64) -> String {
        if v == v.round() { format!("{}", v as i64) } else { format_g3(v) }
    }
}

/// How serious a delivery issue is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliverySeverity {
    /// For information.
    Info,
    /// Worth a look.
    Warning,
}

/// One chip of the Export sheet.
#[derive(Clone, Debug, PartialEq)]
pub struct DeliveryIssue {
    /// Stable key: vfr, interlaced, zone, fps, audioRate, length.
    pub id: &'static str,
    /// How serious.
    pub severity: DeliverySeverity,
    /// Short text for a chip (one line).
    pub text: String,
}

/// What the used source media looks like (probed at import).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct SourceTraits {
    /// A source has a variable frame rate.
    pub has_variable_frame_rate: bool,
    /// A source is interlaced.
    pub has_interlaced: bool,
    /// Captions whose box reaches into the delivery platform's UI zone (counted by the app from the caption layout).
    pub captions_in_zone: usize,
}

/// Which encoder runs and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncoderHint {
    /// Hardware encoder.
    pub is_hardware: bool,
    /// Why this encoder runs (and, for software, which setting forced it).
    pub reason: String,
}

/// The platform's UI zone (`None`: feed posts, YouTube).
pub fn safe_zone_platform(p: DeliveryPlatform) -> Option<CutCheckPlatform> {
    match p {
        DeliveryPlatform::Tiktok => Some(CutCheckPlatform::Tiktok),
        DeliveryPlatform::Reels => Some(CutCheckPlatform::Reels),
        DeliveryPlatform::Shorts => Some(CutCheckPlatform::Shorts),
        DeliveryPlatform::SocialFeed | DeliveryPlatform::Youtube => None,
    }
}

/// Pure delivery checks of an export: what the Export sheet shows as chips, plus the encoder hint. Soft findings only.
pub struct DeliveryCheck;

impl DeliveryCheck {
    /// The chips for `settings`.
    pub fn issues(
        s: &ExportSettings,
        preset: &ExportPreset,
        duration: Time,
        source: SourceTraits,
        platform: Option<DeliveryPlatform>,
    ) -> Vec<DeliveryIssue> {
        let warn = |id, text: String| DeliveryIssue { id, severity: DeliverySeverity::Warning, text };
        if s.audio_only.is_some() || s.frame_output.is_some() {
            return Vec::new();
        }
        let mut out = Vec::new();
        if source.has_variable_frame_rate {
            out.push(warn("vfr", "Variable frame rate source".to_string()));
        }
        if source.has_interlaced {
            out.push(warn("interlaced", "Interlaced source".to_string()));
        }
        if let (true, Some(zp)) = (source.captions_in_zone > 0, platform.and_then(safe_zone_platform)) {
            let n = source.captions_in_zone;
            out.push(warn(
                "zone",
                format!("{n} {} in the {} UI zone", if n == 1 { "caption sits" } else { "captions sit" }, zp.title()),
            ));
        }
        let fd = s.video.frame_duration;
        if fd.value() > 0 {
            let fps = fd.timescale() as f64 / fd.value() as f64;
            if !is_youtube_rate(fps) {
                out.push(warn("fps", format!("{} fps is not a YouTube rate", DeliveryAdvice::format_rate(fps))));
            }
        }
        let a = s.effective_audio();
        if a.enabled && a.sample_rate != 48_000 {
            out.push(warn(
                "audioRate",
                format!("Audio {} kHz, not 48", DeliveryAdvice::format_rate(a.sample_rate as f64 / 1000.0)),
            ));
        }
        let secs = seconds_of(duration);
        let whole = |t: Time| seconds_of(t).round() as i64;
        if let Some(lim) = DeliveryAdvice::soft_duration_limit(preset).filter(|l| duration > *l) {
            let name = preset.platform.map_or("platform", |p| p.display_name());
            out.push(warn("length", format!("Over {} s: {name} may cut it", whole(lim))));
        } else if preset.kind == PresetKind::XPost
            && let Some(hard) = preset.limits().map(|l| l.max_duration)
            && duration <= hard
            && secs > 0.9 * seconds_of(hard)
        {
            out.push(warn("length", format!("Close to X's {} s limit", whole(hard))));
        }
        out
    }

    /// Largest side in pixels the hardware encoders of `codec` take.
    pub fn hardware_size_limit(codec: VideoCodec) -> i64 {
        if codec == VideoCodec::H264 { 4096 } else { 8192 }
    }

    /// Which encoder will run for video and why. `None` for audio-only and frame-output exports.
    pub fn encoder(s: &ExportSettings) -> Option<EncoderHint> {
        if s.audio_only.is_some() || s.frame_output.is_some() {
            return None;
        }
        let hint = |is_hardware, reason: String| Some(EncoderHint { is_hardware, reason });
        if s.video.codec.is_pro_res() {
            return hint(cfg!(target_vendor = "apple") && s.video.hardware_encoding, prores_text().to_string());
        }
        if !s.video.hardware_encoding {
            return hint(false, "Software encoder: hardware encoding is off in the video settings.".to_string());
        }
        // Hardware H.264 stops at 4096 px on every vendor (VideoToolbox, NVENC, AMF, Quick Sync); hardware HEVC reaches
        // 8192 px. The swift app answers 4096 for both; the exact limit of one machine is still the encoder's to say.
        let limit = Self::hardware_size_limit(s.video.codec);
        if s.video.width.max(s.video.height) > limit {
            return hint(
                false,
                format!(
                    "Software encoder: {}x{} is above the {} px hardware limit.",
                    s.video.width, s.video.height, limit
                ),
            );
        }
        hint(
            true,
            "Uses the hardware encoder; it falls back to software when this computer has none for this size."
                .to_string(),
        )
    }
}
