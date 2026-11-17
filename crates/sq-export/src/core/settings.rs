// Swift: ExportSettings.swift, ExportPixelFormat.swift

use super::frame_output::FrameOutput;
use super::hdr::{HdrDelivery, HdrToSdr};
use super::metadata::ExportMetadata;
use super::serde_util::{Wrap, is_false, lenient};
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_model::PixelAspect;
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

/// Video codec of a file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum VideoCodec {
    /// H.264.
    #[serde(rename = "h264")]
    H264,
    /// HEVC.
    #[serde(rename = "hevc")]
    Hevc,
    /// ProRes 422 HQ ('apch').
    #[serde(rename = "prores422HQ")]
    ProRes422HQ,
    /// ProRes 422 ('apcn').
    #[serde(rename = "prores422")]
    ProRes422,
    /// ProRes 4444 ('ap4h').
    #[serde(rename = "prores4444")]
    ProRes4444,
    /// ProRes 422 LT.
    #[serde(rename = "prores422LT")]
    ProRes422LT,
    /// ProRes 422 Proxy.
    #[serde(rename = "prores422Proxy")]
    ProRes422Proxy,
}

impl VideoCodec {
    /// Every codec, in declaration order.
    pub const ALL: [VideoCodec; 7] = [
        VideoCodec::H264,
        VideoCodec::Hevc,
        VideoCodec::ProRes422HQ,
        VideoCodec::ProRes422,
        VideoCodec::ProRes4444,
        VideoCodec::ProRes422LT,
        VideoCodec::ProRes422Proxy,
    ];

    /// Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            VideoCodec::H264 => "h264",
            VideoCodec::Hevc => "hevc",
            VideoCodec::ProRes422HQ => "prores422HQ",
            VideoCodec::ProRes422 => "prores422",
            VideoCodec::ProRes4444 => "prores4444",
            VideoCodec::ProRes422LT => "prores422LT",
            VideoCodec::ProRes422Proxy => "prores422Proxy",
        }
    }

    /// Intra-frame mastering codecs: bitrate, profile and keyframe interval do not apply.
    pub fn is_mastering(self) -> bool {
        self.is_pro_res()
    }

    /// Any ProRes flavor.
    pub fn is_pro_res(self) -> bool {
        !matches!(self, VideoCodec::H264 | VideoCodec::Hevc)
    }

    /// Shown name.
    pub fn display_name(self) -> &'static str {
        match self {
            VideoCodec::H264 => "H.264",
            VideoCodec::Hevc => "HEVC",
            VideoCodec::ProRes422HQ => "ProRes 422 HQ",
            VideoCodec::ProRes422 => "ProRes 422",
            VideoCodec::ProRes422LT => "ProRes 422 LT",
            VideoCodec::ProRes422Proxy => "ProRes 422 Proxy",
            VideoCodec::ProRes4444 => "ProRes 4444",
        }
    }
}

/// Encoder speed of H.264 / HEVC (ProRes ignores it): a per-machine preference, not part of a preset's look.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EncoderSpeed {
    /// The encoder's own defaults.
    Quality,
    /// Offline transcode the user waits for.
    Balanced,
    /// Balanced plus no B-frames and one reference frame.
    Fast,
}

impl EncoderSpeed {
    /// Every speed.
    pub const ALL: [EncoderSpeed; 3] = [EncoderSpeed::Quality, EncoderSpeed::Balanced, EncoderSpeed::Fast];

    /// Shown name.
    pub fn display_name(self) -> &'static str {
        match self {
            EncoderSpeed::Quality => "Quality",
            EncoderSpeed::Balanced => "Balanced",
            EncoderSpeed::Fast => "Fast",
        }
    }

    /// The speed to suggest (never apply) for a machine with this much memory: Balanced at 8 GB or less.
    pub fn suggested(physical_memory: u64) -> Option<EncoderSpeed> {
        (physical_memory <= 8 << 30).then_some(EncoderSpeed::Balanced)
    }
}

/// H.264 / HEVC profile.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VideoProfile {
    /// The encoder decides.
    Automatic,
    /// Baseline.
    Baseline,
    /// Main.
    Main,
    /// High.
    High,
    /// HEVC Main 10.
    Main10,
}

/// Target bitrate: an average, or an average with a data-rate cap.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BitrateMode {
    /// Average bits per second.
    Average(i64),
    /// Average and maximum bits per second.
    AverageAndMax {
        /// Average.
        average: i64,
        /// Cap.
        max: i64,
    },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum BitrateRepr {
    Average(Wrap<i64>),
    AverageAndMax { average: i64, max: i64 },
}

impl From<BitrateRepr> for BitrateMode {
    fn from(r: BitrateRepr) -> BitrateMode {
        match r {
            BitrateRepr::Average(w) => BitrateMode::Average(w.v),
            BitrateRepr::AverageAndMax { average, max } => BitrateMode::AverageAndMax { average, max },
        }
    }
}

impl From<BitrateMode> for BitrateRepr {
    fn from(m: BitrateMode) -> BitrateRepr {
        match m {
            BitrateMode::Average(v) => BitrateRepr::Average(Wrap { v }),
            BitrateMode::AverageAndMax { average, max } => BitrateRepr::AverageAndMax { average, max },
        }
    }
}

impl Serialize for BitrateMode {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        BitrateRepr::from(*self).serialize(s)
    }
}

impl<'de> Deserialize<'de> for BitrateMode {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        BitrateRepr::deserialize(d).map(BitrateMode::from)
    }
}

impl BitrateMode {
    /// The average, whichever case.
    pub fn average_bits_per_second(self) -> i64 {
        match self {
            BitrateMode::Average(a) | BitrateMode::AverageAndMax { average: a, .. } => a,
        }
    }

    /// The cap, when there is one.
    pub fn max_bits_per_second(self) -> Option<i64> {
        match self {
            BitrateMode::Average(_) => None,
            BitrateMode::AverageAndMax { max, .. } => Some(max),
        }
    }
}

/// How the encoder spends the target bitrate (H.264 / HEVC).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BitrateKind {
    /// Single-pass average target, optionally capped.
    Vbr,
    /// Constant bitrate for broadcast delivery.
    Cbr,
}

impl BitrateKind {
    /// Both kinds.
    pub const ALL: [BitrateKind; 2] = [BitrateKind::Vbr, BitrateKind::Cbr];

    /// Segmented-control title.
    pub fn title(self) -> &'static str {
        match self {
            BitrateKind::Vbr => "VBR",
            BitrateKind::Cbr => "CBR",
        }
    }

    /// Tooltip line of the mode.
    pub fn help(self) -> &'static str {
        match self {
            BitrateKind::Vbr => {
                "VBR: the bitrate follows the picture around Target, busy scenes get more. Maximum caps it."
            }
            BitrateKind::Cbr => "CBR: the bitrate stays at Target the whole time, for broadcast delivery.",
        }
    }

    /// Target applies to every mode; Maximum only to VBR.
    pub fn shows_maximum(self) -> bool {
        self != BitrateKind::Cbr
    }

    /// The modes a codec offers: none for the intra-frame mastering codecs.
    pub fn available(codec: VideoCodec) -> Vec<BitrateKind> {
        if codec.is_mastering() { Vec::new() } else { BitrateKind::ALL.to_vec() }
    }
}

fn square_aspect_is_absent<'de, D: Deserializer<'de>>(d: D) -> Result<Option<PixelAspect>, D::Error> {
    Ok(lenient::<D, PixelAspect>(d)?.filter(|a| !a.is_square()))
}

fn true_or_absent<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(d)?.unwrap_or(false))
}

/// Picture settings of an export.
///
/// Reading is tolerant: a key that is absent keeps its default (B-frames on), so settings and presets written before
/// a key existed decode unchanged.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct VideoSettings {
    /// Codec.
    pub codec: VideoCodec,
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
    /// Duration of one frame.
    pub frame_duration: Time,
    /// Profile.
    pub profile: VideoProfile,
    /// Target bitrate.
    pub bitrate: BitrateMode,
    /// Stored flag (key absent for VBR) so older files decode as VBR; use `bitrate_kind`.
    #[serde(rename = "constantBitrate", skip_serializing_if = "is_false", deserialize_with = "true_or_absent")]
    constant_bitrate: bool,
    #[serde(rename = "constantQuality", skip_serializing_if = "Option::is_none")]
    constant_quality_store: Option<f64>,
    /// Max frames between keyframes.
    pub keyframe_interval: i64,
    /// Prefer the hardware encoder.
    pub hardware_encoding: bool,
    /// B-frames (frame reordering) for H.264 / HEVC; ignored for Baseline and intra-only codecs.
    pub allows_frame_reordering: bool,
    /// ProRes 4444 only: write the compositor's coverage into the alpha channel.
    pub preserves_alpha: bool,
    #[serde(
        rename = "pixelAspect",
        skip_serializing_if = "Option::is_none",
        deserialize_with = "square_aspect_is_absent"
    )]
    pixel_aspect_store: Option<PixelAspect>,
}

impl Default for VideoSettings {
    fn default() -> VideoSettings {
        VideoSettings {
            codec: VideoCodec::H264,
            width: 1080,
            height: 1920,
            frame_duration: Time::new(1, 30),
            profile: VideoProfile::Automatic,
            bitrate: BitrateMode::Average(12_000_000),
            constant_bitrate: false,
            constant_quality_store: None,
            keyframe_interval: 60,
            hardware_encoding: true,
            allows_frame_reordering: true,
            preserves_alpha: false,
            pixel_aspect_store: None,
        }
    }
}

impl VideoSettings {
    /// VBR or CBR. A stored Maximum is kept while CBR is on and applies again in VBR.
    pub fn bitrate_kind(&self) -> BitrateKind {
        if self.constant_bitrate { BitrateKind::Cbr } else { BitrateKind::Vbr }
    }

    /// Sets VBR or CBR.
    pub fn set_bitrate_kind(&mut self, kind: BitrateKind) {
        self.constant_bitrate = kind == BitrateKind::Cbr;
    }

    /// Whether the encoder runs at constant bitrate: CBR on a codec that has rate control.
    pub fn uses_constant_bitrate(&self) -> bool {
        self.bitrate_kind() == BitrateKind::Cbr && !self.codec.is_mastering() && self.constant_quality_store.is_none()
    }

    /// Constant quality (0...1) instead of a target bitrate; ignored for ProRes.
    pub fn constant_quality(&self) -> Option<f64> {
        if self.codec.is_mastering() { None } else { self.constant_quality_store }
    }

    /// Sets the constant quality, clamped to 0.05...1.
    pub fn set_constant_quality(&mut self, q: Option<f64>) {
        self.constant_quality_store = q.map(|q| q.clamp(0.05, 1.0));
    }

    /// Whether the file size follows the picture instead of a bitrate.
    pub fn uses_constant_quality(&self) -> bool {
        self.constant_quality().is_some()
    }

    /// Shape of one stored pixel (square when unset).
    pub fn pixel_aspect(&self) -> PixelAspect {
        self.pixel_aspect_store.unwrap_or_else(PixelAspect::square)
    }

    /// Sets the pixel aspect; square is stored as absent.
    pub fn set_pixel_aspect(&mut self, a: PixelAspect) {
        self.pixel_aspect_store = if a.is_square() { None } else { Some(a) };
    }

    /// Bits per component of the encoded picture: 10 for HEVC Main 10 and ProRes 422, 12 for ProRes 4444, else 8.
    pub fn bit_depth(&self) -> i64 {
        if self.codec.is_pro_res() {
            return if self.codec == VideoCodec::ProRes4444 { 12 } else { 10 };
        }
        if self.codec == VideoCodec::Hevc && self.profile == VideoProfile::Main10 { 10 } else { 8 }
    }
}

/// Primaries tag.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ColorPrimaries {
    /// ITU-R BT.709.
    #[serde(rename = "itu709")]
    Itu709,
}

/// Transfer tag.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ColorTransfer {
    /// ITU-R BT.709.
    #[serde(rename = "itu709")]
    Itu709,
}

/// Matrix tag.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ColorMatrix {
    /// ITU-R BT.709.
    #[serde(rename = "itu709")]
    Itu709,
}

/// Output is always Rec.709, tagged 1-1-1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ColorSettings {
    /// Primaries.
    pub primaries: ColorPrimaries,
    /// Transfer.
    pub transfer: ColorTransfer,
    /// Matrix.
    pub matrix: ColorMatrix,
}

impl ColorSettings {
    /// Rec.709 tagged 1-1-1.
    pub const REC709: ColorSettings = ColorSettings {
        primaries: ColorPrimaries::Itu709,
        transfer: ColorTransfer::Itu709,
        matrix: ColorMatrix::Itu709,
    };
}

impl Default for ColorSettings {
    fn default() -> ColorSettings {
        ColorSettings::REC709
    }
}

/// Audio codec; `Pcm` = uncompressed little-endian integer PCM for mastering.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioCodec {
    /// AAC.
    Aac,
    /// PCM.
    Pcm,
}

/// Two-pass loudness normalization: one linear gain = target - measured integrated loudness, limited so the resulting
/// true peak stays at or below the ceiling.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct LoudnessNormalization {
    /// Target integrated loudness in LUFS.
    #[serde(rename = "targetLUFS")]
    pub target_lufs: f64,
    /// Maximum true peak after gain in dBTP.
    #[serde(rename = "truePeakCeilingDB")]
    pub true_peak_ceiling_db: f64,
}

impl Default for LoudnessNormalization {
    fn default() -> LoudnessNormalization {
        LoudnessNormalization { target_lufs: -14.0, true_peak_ceiling_db: -1.0 }
    }
}

impl LoudnessNormalization {
    /// Target and ceiling.
    pub fn new(target_lufs: f64, true_peak_ceiling_db: f64) -> LoudnessNormalization {
        LoudnessNormalization { target_lufs, true_peak_ceiling_db }
    }
}

/// Audio settings of an export.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "AudioSettingsWire")]
pub struct AudioSettings {
    /// Audio on.
    pub enabled: bool,
    /// Codec.
    pub codec: AudioCodec,
    /// Sample rate in Hz.
    pub sample_rate: i64,
    /// Channel count.
    pub channels: i64,
    /// AAC bits per second.
    pub bitrate: i64,
    /// PCM only: 16, 24 or 32.
    pub pcm_bit_depth: i64,
    /// `None` = no normalization.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loudness: Option<LoudnessNormalization>,
}

/// Tolerant reading: missing keys keep defaults; the legacy `loudnessTarget` (whole LUFS) maps to `loudness`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AudioSettingsWire {
    enabled: bool,
    codec: AudioCodec,
    sample_rate: i64,
    channels: i64,
    bitrate: i64,
    pcm_bit_depth: i64,
    loudness: Option<LoudnessNormalization>,
    loudness_target: Option<i64>,
}

impl Default for AudioSettingsWire {
    fn default() -> AudioSettingsWire {
        let d = AudioSettings::default();
        AudioSettingsWire {
            enabled: d.enabled,
            codec: d.codec,
            sample_rate: d.sample_rate,
            channels: d.channels,
            bitrate: d.bitrate,
            pcm_bit_depth: d.pcm_bit_depth,
            loudness: None,
            loudness_target: None,
        }
    }
}

impl From<AudioSettingsWire> for AudioSettings {
    fn from(w: AudioSettingsWire) -> AudioSettings {
        let loudness = w.loudness.or_else(|| {
            w.loudness_target.map(|t| LoudnessNormalization { target_lufs: t as f64, ..Default::default() })
        });
        AudioSettings {
            enabled: w.enabled,
            codec: w.codec,
            sample_rate: w.sample_rate,
            channels: w.channels,
            bitrate: w.bitrate,
            pcm_bit_depth: w.pcm_bit_depth,
            loudness,
        }
    }
}

impl Default for AudioSettings {
    fn default() -> AudioSettings {
        AudioSettings {
            enabled: true,
            codec: AudioCodec::Aac,
            sample_rate: 48_000,
            channels: 2,
            bitrate: 192_000,
            pcm_bit_depth: 24,
            loudness: None,
        }
    }
}

impl AudioSettings {
    /// `loudness` as a whole-LUFS target (not encoded).
    pub fn loudness_target(&self) -> Option<i64> {
        self.loudness.map(|l| l.target_lufs.round() as i64)
    }

    /// Sets the whole-LUFS target; an existing ceiling is kept.
    pub fn set_loudness_target(&mut self, target: Option<i64>) {
        let ceiling =
            self.loudness.map_or(LoudnessNormalization::default().true_peak_ceiling_db, |l| l.true_peak_ceiling_db);
        self.loudness = target.map(|t| LoudnessNormalization { target_lufs: t as f64, true_peak_ceiling_db: ceiling });
    }
}

/// "Also save cover image": a still of the cover frame written next to the video.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CoverImageFormat {
    /// PNG.
    Png,
    /// JPEG.
    Jpg,
}

impl CoverImageFormat {
    /// Both formats.
    pub const ALL: [CoverImageFormat; 2] = [CoverImageFormat::Png, CoverImageFormat::Jpg];

    /// File extension.
    pub fn file_extension(self) -> &'static str {
        match self {
            CoverImageFormat::Png => "png",
            CoverImageFormat::Jpg => "jpg",
        }
    }
}

/// Audio-only delivery: the file holds the mixed audio and no picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioFileFormat {
    /// AAC in an MPEG-4 audio file.
    M4a,
    /// Uncompressed little-endian integer PCM in a WAVE file.
    Wav,
    /// Lossless FLAC (16 or 24 bit).
    Flac,
}

impl AudioFileFormat {
    /// Every format.
    pub const ALL: [AudioFileFormat; 3] = [AudioFileFormat::M4a, AudioFileFormat::Wav, AudioFileFormat::Flac];

    /// File extension.
    pub fn file_extension(self) -> &'static str {
        match self {
            AudioFileFormat::M4a => "m4a",
            AudioFileFormat::Wav => "wav",
            AudioFileFormat::Flac => "flac",
        }
    }

    /// The codec the format carries.
    pub fn codec(self) -> AudioCodec {
        if self == AudioFileFormat::M4a { AudioCodec::Aac } else { AudioCodec::Pcm }
    }

    /// Shown name.
    pub fn display_name(self) -> &'static str {
        match self {
            AudioFileFormat::M4a => "M4A (AAC)",
            AudioFileFormat::Wav => "WAV (PCM)",
            AudioFileFormat::Flac => "FLAC (lossless)",
        }
    }
}

/// Captions in the export.
///
/// The sidecar writers (SRT, VTT, ITT) live in `formats`; the queue reaches them through `SidecarWriting`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CaptionMode {
    /// None.
    #[serde(rename = "none")]
    None,
    /// Burned into the picture.
    #[serde(rename = "burnIn")]
    BurnIn,
    /// SubRip sidecar.
    #[serde(rename = "sidecarSRT")]
    SidecarSrt,
    /// WebVTT sidecar.
    #[serde(rename = "sidecarVTT")]
    SidecarVtt,
    /// iTunes timed text sidecar.
    #[serde(rename = "sidecarITT")]
    SidecarItt,
}

impl CaptionMode {
    /// Extension of the sidecar file (`None` = no sidecar).
    pub fn sidecar_extension(self) -> Option<&'static str> {
        match self {
            CaptionMode::SidecarSrt => Some("srt"),
            CaptionMode::SidecarVtt => Some("vtt"),
            CaptionMode::SidecarItt => Some("itt"),
            CaptionMode::None | CaptionMode::BurnIn => None,
        }
    }
}

/// Which part of the sequence is exported.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RangeSelection {
    /// All of it.
    EntireSequence,
    /// A range.
    InOut(TimeRange),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum RangeRepr {
    EntireSequence {},
    InOut(Wrap<TimeRange>),
}

impl Serialize for RangeSelection {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            RangeSelection::EntireSequence => RangeRepr::EntireSequence {},
            RangeSelection::InOut(r) => RangeRepr::InOut(Wrap { v: *r }),
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for RangeSelection {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match RangeRepr::deserialize(d)? {
            RangeRepr::EntireSequence {} => RangeSelection::EntireSequence,
            RangeRepr::InOut(w) => RangeSelection::InOut(w.v),
        })
    }
}

/// What is wrong with a settings value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ExportSettingsIssue {
    /// Width or height is not a positive even number.
    OddDimensions,
    /// Bitrate is not positive, or the maximum is below the average.
    NonPositiveBitrate,
    /// Keyframe interval is not positive.
    InvalidKeyframeInterval,
    /// Frame duration is not positive.
    InvalidFrameDuration,
    /// Audio settings are unusable.
    InvalidAudio,
}

/// Everything one export needs to know.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ExportSettings {
    /// Picture settings.
    pub video: VideoSettings,
    /// Color tags.
    pub color: ColorSettings,
    /// Audio settings.
    pub audio: AudioSettings,
    /// Captions.
    pub captions: CaptionMode,
    /// Range.
    pub range: RangeSelection,
    /// The sequence's format variant to render (`None` = the sequence's own format).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variant: Option<Id>,
    /// Also save the cover frame as a still next to the video.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_image: Option<CoverImageFormat>,
    /// Sequence time of the cover frame; `None` = the first exported frame.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_time: Option<Time>,
    /// A source frame that cannot be decoded is drawn as the damaged placeholder instead of stopping the export.
    #[serde(rename = "damagedFrames", skip_serializing_if = "is_false", deserialize_with = "true_or_absent")]
    pub continue_on_damaged_frames: bool,
    #[serde(rename = "speed", skip_serializing_if = "Option::is_none")]
    speed: Option<EncoderSpeed>,
    #[serde(rename = "multiPassStore", skip_serializing_if = "is_false", deserialize_with = "true_or_absent")]
    multi_pass: bool,
    /// Audio-only export (no picture); `None` = a video file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_only: Option<AudioFileFormat>,
    /// GIF or numbered image sequence instead of a video file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_output: Option<FrameOutput>,
    /// Title, comment, creation date and chapters written into the file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<ExportMetadata>,
    /// HDR to SDR trim for this export.
    #[serde(rename = "hdrToSDR", skip_serializing_if = "Option::is_none")]
    pub hdr_to_sdr: Option<HdrToSdr>,
    /// HDR delivery tags with MDCV/CLLI metadata; HEVC only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hdr_delivery: Option<HdrDelivery>,
}

impl Default for ExportSettings {
    fn default() -> ExportSettings {
        ExportSettings {
            video: VideoSettings::default(),
            color: ColorSettings::REC709,
            audio: AudioSettings::default(),
            captions: CaptionMode::None,
            range: RangeSelection::EntireSequence,
            variant: None,
            cover_image: None,
            cover_time: None,
            continue_on_damaged_frames: false,
            speed: None,
            multi_pass: false,
            audio_only: None,
            frame_output: None,
            metadata: None,
            hdr_to_sdr: None,
            hdr_delivery: None,
        }
    }
}

/// ProRes 422 HQ reference rate: 220 Mbit/s at 1920x1080, 29.97 fps (Apple's published target).
const PRORES_422_HQ_REFERENCE_BPS: i128 = 220_000_000;

/// Apple's published target rates at 1920x1080, 29.97 fps, per profile.
fn pro_res_reference_bits_per_second(codec: VideoCodec) -> i128 {
    match codec {
        VideoCodec::ProRes422 => 147_000_000,
        VideoCodec::ProRes422LT => 102_000_000,
        VideoCodec::ProRes422Proxy => 45_000_000,
        VideoCodec::ProRes4444 => 330_000_000,
        _ => PRORES_422_HQ_REFERENCE_BPS,
    }
}

impl ExportSettings {
    /// H.264 / HEVC encoder speed; Quality by default.
    pub fn encoder_speed(&self) -> EncoderSpeed {
        self.speed.unwrap_or(EncoderSpeed::Quality)
    }

    /// Sets the encoder speed; Quality is stored as absent.
    pub fn set_encoder_speed(&mut self, s: EncoderSpeed) {
        self.speed = (s != EncoderSpeed::Quality).then_some(s);
    }

    /// "Best quality at size": several encoder passes at the average bitrate.
    pub fn multi_pass(&self) -> bool {
        self.multi_pass
    }

    /// Sets multi-pass.
    pub fn set_multi_pass(&mut self, on: bool) {
        self.multi_pass = on;
    }

    /// Whether the export runs multi-pass: only a bitrate target has a size to hold (not CBR, not constant quality,
    /// not ProRes), and only the software encoder does it.
    pub fn uses_multi_pass(&self) -> bool {
        self.multi_pass
            && !self.video.hardware_encoding
            && !self.video.codec.is_mastering()
            && !self.video.uses_constant_bitrate()
            && !self.video.uses_constant_quality()
            && self.audio_only.is_none()
            && self.frame_output.is_none()
    }

    /// The audio settings the writer uses: an audio-only file's format decides the codec.
    pub fn effective_audio(&self) -> AudioSettings {
        let mut a = self.audio.clone();
        if let Some(f) = self.audio_only {
            a.codec = f.codec();
        }
        a
    }

    /// Settings with what an audio-only file cannot carry switched off (burned-in captions, cover image).
    pub fn for_delivery(&self) -> ExportSettings {
        if self.audio_only.is_none() && self.frame_output.is_none() {
            return self.clone();
        }
        let mut s = self.clone();
        if s.captions == CaptionMode::BurnIn {
            s.captions = CaptionMode::None;
        }
        s.cover_image = None;
        s.cover_time = None;
        s
    }

    /// Every problem with the settings (empty = valid).
    pub fn validate(&self) -> BTreeSet<ExportSettingsIssue> {
        use ExportSettingsIssue::*;
        let v = &self.video;
        let mut r = BTreeSet::new();
        if self.audio_only.is_some() {
            if !self.audio.enabled {
                r.insert(InvalidAudio);
            }
        } else if self.frame_output.is_some() {
            // Pictures have no chroma subsampling: any positive size, no bitrate, no keyframes, no audio.
            if v.width <= 0 || v.height <= 0 {
                r.insert(OddDimensions);
            }
        } else if v.width <= 0 || v.height <= 0 || v.width % 2 != 0 || v.height % 2 != 0 {
            r.insert(OddDimensions);
        }
        if self.audio_only.is_none() && self.frame_output.is_none() && !v.codec.is_mastering() {
            if v.bitrate.average_bits_per_second() <= 0 {
                r.insert(NonPositiveBitrate);
            }
            if v.bitrate.max_bits_per_second().is_some_and(|m| m < v.bitrate.average_bits_per_second()) {
                r.insert(NonPositiveBitrate);
            }
            if v.keyframe_interval <= 0 {
                r.insert(InvalidKeyframeInterval);
            }
        }
        if self.audio_only.is_none() && v.frame_duration.value() <= 0 {
            r.insert(InvalidFrameDuration);
        }
        let a = self.effective_audio();
        if self.frame_output.is_some() {
            return r;
        }
        if a.enabled
            && (a.channels <= 0
                || a.sample_rate <= 0
                || (a.codec == AudioCodec::Aac && a.bitrate <= 0)
                || (a.codec == AudioCodec::Pcm && ![16, 24, 32].contains(&a.pcm_bit_depth))
                || (self.audio_only == Some(AudioFileFormat::Flac) && ![16, 24].contains(&a.pcm_bit_depth)))
        {
            r.insert(InvalidAudio);
        }
        r
    }

    /// Estimated video bitrate in bits per second. Mastering codecs have no bitrate setting, so ProRes is derived
    /// from its reference rate scaled by pixels and frame rate.
    pub fn estimated_video_bits_per_second(&self) -> i64 {
        let v = &self.video;
        if self.audio_only.is_some() || self.frame_output.is_some() {
            return 0;
        }
        if !v.codec.is_mastering() {
            return v.bitrate.average_bits_per_second();
        }
        if v.frame_duration.value() <= 0 || v.width <= 0 || v.height <= 0 {
            return 0;
        }
        // ref * (w*h / (1920*1080)) * (fps / (30000/1001))
        let num = pro_res_reference_bits_per_second(v.codec)
            * i128::from(v.width)
            * i128::from(v.height)
            * i128::from(v.frame_duration.timescale())
            * 1001;
        let den = i128::from(1920 * 1080) * i128::from(v.frame_duration.value()) * 30000;
        (num / den) as i64
    }

    /// Audio bits per second: PCM from its format, AAC from its bitrate, FLAC about 60 percent of PCM.
    pub fn estimated_audio_bits_per_second(&self) -> i64 {
        let audio = self.effective_audio();
        if !audio.enabled || self.frame_output.is_some() {
            return 0;
        }
        if self.audio_only == Some(AudioFileFormat::Flac) {
            return audio.sample_rate * audio.channels * audio.pcm_bit_depth * 6 / 10;
        }
        if audio.codec == AudioCodec::Pcm {
            return audio.sample_rate * audio.channels * audio.pcm_bit_depth;
        }
        audio.bitrate
    }

    /// Rough output size in bytes: (video + audio bitrate) * duration / 8, truncated.
    pub fn estimated_file_size(&self, duration: Time) -> i64 {
        let bps = i128::from(self.estimated_video_bits_per_second() + self.estimated_audio_bits_per_second());
        ((bps * i128::from(duration.value())) / (8 * i128::from(duration.timescale()))) as i64
    }

    /// Container file extension: MOV for mastering codecs, MP4 otherwise, "gif", or "" for a folder of stills.
    pub fn file_extension(&self) -> &'static str {
        match self.frame_output {
            Some(FrameOutput::Gif) => "gif",
            Some(FrameOutput::Sequence(_)) => "",
            None => match self.audio_only {
                Some(f) => f.file_extension(),
                None if self.video.codec.is_mastering() => "mov",
                None => "mp4",
            },
        }
    }

    /// The HDR delivery tags when they apply: HEVC video only (needs 10 bits); ProRes, H.264, pictures and audio stay SDR.
    pub fn applied_hdr_delivery(&self) -> Option<HdrDelivery> {
        if self.video.codec == VideoCodec::Hevc && self.audio_only.is_none() && self.frame_output.is_none() {
            self.hdr_delivery
        } else {
            None
        }
    }

    /// Pixel format the frame source renders for this codec, so no 8-bit BGRA step sits in front of a 10-bit encoder.
    pub fn source_pixel_format(&self) -> ExportPixelFormat {
        match self.frame_output {
            Some(FrameOutput::Sequence(_)) => return ExportPixelFormat::RgbaHalf,
            Some(FrameOutput::Gif) => return ExportPixelFormat::Bgra8,
            None => {}
        }
        match self.video.codec {
            VideoCodec::H264 => ExportPixelFormat::Yuv420v,
            VideoCodec::Hevc => {
                if self.video.profile == VideoProfile::Main10 || self.applied_hdr_delivery().is_some() {
                    ExportPixelFormat::Yuv420v10
                } else {
                    ExportPixelFormat::Yuv420v
                }
            }
            VideoCodec::ProRes422HQ | VideoCodec::ProRes422 | VideoCodec::ProRes422LT | VideoCodec::ProRes422Proxy => {
                ExportPixelFormat::Yuv422v10
            }
            VideoCodec::ProRes4444 => {
                if self.video.preserves_alpha {
                    ExportPixelFormat::Ayuv4444Alpha
                } else {
                    ExportPixelFormat::Ayuv4444
                }
            }
        }
    }

    /// "ProRes 422 HQ master": ProRes 422 HQ in MOV, Rec.709 1-1-1, 24-bit 48 kHz stereo PCM. Size and frame rate are
    /// meant to be set from the sequence.
    pub fn pro_res_422_hq_master() -> ExportSettings {
        let mut s = ExportSettings::default();
        s.video.codec = VideoCodec::ProRes422HQ;
        s.video.width = 1920;
        s.video.height = 1080;
        s.video.frame_duration = Time::new(1, 30);
        s.video.profile = VideoProfile::Automatic;
        s.video.hardware_encoding = true;
        s.color = ColorSettings::REC709;
        s.audio.codec = AudioCodec::Pcm;
        s.audio.pcm_bit_depth = 24;
        s.audio.sample_rate = 48_000;
        s.audio.channels = 2;
        s
    }
}

/// Output pixel format of the export render.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ExportPixelFormat {
    /// BGRA 8-bit.
    Bgra8,
    /// 4:2:0 8-bit.
    Yuv420v,
    /// 4:2:0 10-bit (HEVC Main 10).
    Yuv420v10,
    /// 4:2:2 10-bit (ProRes 422).
    Yuv422v10,
    /// 4:4:4:4 AYpCbCr 16-bit, opaque (ProRes 4444).
    Ayuv4444,
    /// 4:4:4:4 16-bit, rendered over transparent with straight color and the coverage in alpha.
    Ayuv4444Alpha,
    /// Premultiplied linear rgba16Float over transparent: the working picture as is (image sequences).
    RgbaHalf,
}

impl ExportPixelFormat {
    /// Chroma subsampled horizontally: width and height must be even.
    pub fn needs_even_size(self) -> bool {
        matches!(self, ExportPixelFormat::Yuv420v | ExportPixelFormat::Yuv420v10 | ExportPixelFormat::Yuv422v10)
    }
}
