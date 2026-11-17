//! What the video encoder of THIS computer cannot do, as the export sheet shows it. The facts come from the encoder
//! probe of `sq_media_ffmpeg::encode` (run once per session in the background); this module turns the export settings
//! into the options asked for and the missing ones into plain words. Pure: tests feed a fake probe.

use super::delivery::DeliveryCheck;
use super::settings::{ExportSettings, VideoCodec, VideoProfile};
use sq_media_ffmpeg::encode::{Wish, cached, missing};
// Re-exported for `ExportDialogModel::set_probe_state`, which lets a test play a computer with other encoders.
pub use sq_media_ffmpeg::encode::{Probe, ProbeKind, ProbeState, caps_of};

/// The options an encoder can lack (re-exported for the sheet).
pub use sq_media_ffmpeg::encode::Missing;

/// The encoder this computer uses for an export and the options of that export it cannot honor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncoderSupport {
    /// "VA-API (hardware)", "OpenH264 (software)", ...; empty when no encoder opens for this file (`has_encoder`).
    pub label: String,
    pub hardware: bool,
    pub missing: Vec<Missing>,
}

/// The sheet's words for an FFmpeg encoder name.
pub fn encoder_label(name: &str) -> String {
    let (what, hardware) = match name {
        n if n.ends_with("_vaapi") => ("VA-API", true),
        n if n.ends_with("_nvenc") => ("NVIDIA NVENC", true),
        n if n.ends_with("_amf") => ("AMD AMF", true),
        n if n.ends_with("_qsv") => ("Intel Quick Sync", true),
        n if n.ends_with("_mf") => ("Windows Media Foundation", true),
        n if n.ends_with("_videotoolbox") => ("VideoToolbox", true),
        "libopenh264" => ("OpenH264", false),
        "libkvazaar" => ("Kvazaar", false),
        "libx264" => ("x264", false),
        "libx265" => ("x265", false),
        other => (other, false),
    };
    format!("{what} ({})", if hardware { "hardware" } else { "software" })
}

fn missing_text(m: Missing) -> &'static str {
    match m {
        Missing::Encoder => "an encoder for this format",
        Missing::TenBit => "10-bit",
        Missing::BFrames => "B-frames",
        Missing::ConstantBitrate => "constant bitrate",
        Missing::ConstantQuality => "constant quality",
        Missing::MultiPass => "multi-pass",
        Missing::Profile => "H.264 profile",
    }
}

/// What `s` asks of an H.264 / HEVC encoder beyond an average bitrate.
pub fn wish_of(s: &ExportSettings) -> Wish {
    let v = &s.video;
    Wish {
        ten_bit: v.codec == VideoCodec::Hevc
            && (v.profile == VideoProfile::Main10 || s.applied_hdr_delivery().is_some()),
        // Baseline has no B-frames: the file is written without them, which is what the profile asks for.
        b_frames: v.allows_frame_reordering && !(v.codec == VideoCodec::H264 && v.profile == VideoProfile::Baseline),
        profile: v.codec == VideoCodec::H264
            && matches!(v.profile, VideoProfile::Baseline | VideoProfile::Main | VideoProfile::High),
        cbr: v.uses_constant_bitrate(),
        constant_quality: v.uses_constant_quality(),
        multi_pass: s.uses_multi_pass(),
    }
}

/// What the refused export says when no encoder of the chosen codec (or depth) opens: what is missing, what to pick.
pub fn no_encoder_message(s: &ExportSettings) -> String {
    let (what, instead) = match (s.video.codec, wish_of(s).ten_bit) {
        (VideoCodec::Hevc, true) => {
            ("10-bit HEVC (Main 10 or HDR)", "Turn on hardware encoding, or choose HEVC Main, H.264 or ProRes instead.")
        }
        (VideoCodec::Hevc, false) => ("HEVC", "Choose H.264 or ProRes instead."),
        _ => ("H.264", "Choose HEVC or ProRes instead."),
    };
    format!("This computer has no {what} encoder, so this file cannot be exported. {instead}")
}

/// The probe that answers for `s`: the codec, the depth and whether hardware may be tried (not above its size limit).
pub fn probe_kind_of(s: &ExportSettings) -> ProbeKind {
    let v = &s.video;
    ProbeKind {
        hevc: v.codec == VideoCodec::Hevc,
        ten_bit: wish_of(s).ten_bit,
        hardware: v.hardware_encoding && v.width.max(v.height) <= DeliveryCheck::hardware_size_limit(v.codec),
    }
}

impl EncoderSupport {
    /// For an H.264 / HEVC video export once the probe has answered; `None` before that, for ProRes, audio-only files and
    /// frame output (their encoders have no such limits to show).
    pub fn of(s: &ExportSettings) -> Option<EncoderSupport> {
        Self::of_with(s, cached)
    }

    /// `of` with the probe's answers supplied by `state` (the sheet model injects them, so a test can play any computer).
    pub fn of_with(s: &ExportSettings, state: impl FnOnce(ProbeKind) -> ProbeState) -> Option<EncoderSupport> {
        if s.audio_only.is_some() || s.frame_output.is_some() || s.video.codec.is_pro_res() {
            return None;
        }
        match state(probe_kind_of(s)) {
            ProbeState::Pending => None,
            ProbeState::NoEncoder => Some(EncoderSupport::none(s)),
            ProbeState::Found(p) => Some(EncoderSupport::from_probe(s, &p)),
        }
    }

    /// No encoder opens for `s`: a 10-bit wish lacks 10-bit (the codec itself may still work in 8-bit), anything else lacks
    /// the encoder. The export is refused either way; the sheet shows the choice as not available.
    pub fn none(s: &ExportSettings) -> EncoderSupport {
        let missing = if wish_of(s).ten_bit { vec![Missing::TenBit] } else { vec![Missing::Encoder] };
        EncoderSupport { label: String::new(), hardware: false, missing }
    }

    /// Whether an encoder opened (false: the export of this file is refused).
    pub fn has_encoder(&self) -> bool {
        !self.label.is_empty()
    }
    /// The support of the probed encoder for `s`.
    pub fn from_probe(s: &ExportSettings, probe: &Probe) -> EncoderSupport {
        EncoderSupport {
            label: encoder_label(&probe.name),
            hardware: probe.caps.hardware,
            missing: missing(&probe.caps, &wish_of(s)),
        }
    }

    /// Whether the encoder honors `option`.
    pub fn can(&self, option: Missing) -> bool {
        !self.missing.contains(&option)
    }

    /// The note line under the sheet's options: the encoder and what it cannot do.
    pub fn note(&self) -> String {
        if !self.has_encoder() {
            return if self.can(Missing::TenBit) {
                "This computer has no encoder for this format: the export will not run.".to_string()
            } else {
                "This computer has no 10-bit HEVC encoder: Main 10 and HDR are not available and the export will not run."
                    .to_string()
            };
        }
        let mut text = format!("Encoder: {}.", self.label);
        if !self.missing.is_empty() {
            let list: Vec<&str> = self.missing.iter().map(|m| missing_text(*m)).collect();
            text.push_str(&format!(" Not available on this computer: {}.", list.join(", ")));
        }
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::preset::ExportPreset;
    use crate::core::settings::VideoProfile;
    use sq_media_ffmpeg::encode::caps_of;

    fn probe(name: &str) -> Probe {
        Probe { name: name.to_string(), caps: caps_of(name) }
    }

    fn hevc10() -> ExportSettings {
        let mut s = ExportPreset::MATCH_SOURCE.settings();
        s.video.codec = VideoCodec::Hevc;
        s.video.profile = VideoProfile::Main10;
        s
    }

    #[test]
    fn the_wish_follows_the_settings() {
        let mut s = hevc10();
        let w = wish_of(&s);
        assert!(w.ten_bit && w.b_frames && !w.cbr && !w.constant_quality);
        s.video.codec = VideoCodec::H264;
        s.video.allows_frame_reordering = false;
        s.video.set_constant_quality(Some(0.7));
        let w = wish_of(&s);
        assert!(!w.ten_bit && !w.b_frames && w.constant_quality);
    }

    #[test]
    fn an_h264_profile_is_wished_only_for_baseline_main_and_high_and_baseline_wishes_no_b_frames() {
        let mut s = ExportPreset::MATCH_SOURCE.settings();
        s.video.codec = VideoCodec::H264;
        for (profile, wished) in [
            (VideoProfile::Automatic, false),
            (VideoProfile::Baseline, true),
            (VideoProfile::Main, true),
            (VideoProfile::High, true),
        ] {
            s.video.profile = profile;
            assert_eq!(wish_of(&s).profile, wished, "{profile:?}");
        }
        s.video.profile = VideoProfile::Baseline;
        s.video.allows_frame_reordering = true;
        assert!(!wish_of(&s).b_frames, "a Baseline file has no B-frames, so none is missing");
        s.video.profile = VideoProfile::High;
        assert!(wish_of(&s).b_frames);
        s.video.codec = VideoCodec::Hevc;
        s.video.profile = VideoProfile::Main;
        assert!(!wish_of(&s).profile, "HEVC Main is the encoder's own default");
        s.video.codec = VideoCodec::H264;
        s.video.profile = VideoProfile::High;
        let lost = EncoderSupport::from_probe(&s, &probe("libkvazaar"));
        assert!(lost.missing.contains(&Missing::Profile));
        assert!(lost.note().contains("H.264 profile"));
        assert!(EncoderSupport::from_probe(&s, &probe("libx264")).can(Missing::Profile));
    }

    #[test]
    fn a_software_fallback_lists_what_a_10_bit_hevc_export_loses() {
        let support = EncoderSupport::from_probe(&hevc10(), &probe("libkvazaar"));
        assert_eq!(support.missing, [Missing::TenBit]);
        assert!(!support.hardware);
        assert_eq!(support.note(), "Encoder: Kvazaar (software). Not available on this computer: 10-bit.");
    }

    #[test]
    fn a_hardware_encoder_with_everything_has_no_missing_list() {
        let support = EncoderSupport::from_probe(&hevc10(), &probe("hevc_vaapi"));
        assert!(support.hardware && support.missing.is_empty() && support.can(Missing::TenBit));
        assert_eq!(support.note(), "Encoder: VA-API (hardware).");
    }

    #[test]
    fn openh264_cannot_do_b_frames_and_kvazaar_cannot_do_constant_bitrate() {
        let mut s = ExportPreset::MATCH_SOURCE.settings();
        s.video.codec = VideoCodec::H264;
        assert!(!EncoderSupport::from_probe(&s, &probe("libopenh264")).can(Missing::BFrames));
        s.video.set_bitrate_kind(crate::core::settings::BitrateKind::Cbr);
        let kvazaar = EncoderSupport::from_probe(&s, &probe("libkvazaar"));
        assert!(!kvazaar.can(Missing::ConstantBitrate) && kvazaar.can(Missing::BFrames));
    }

    #[test]
    fn without_any_encoder_the_choice_is_not_available_and_the_message_names_the_way_out() {
        // Main 10 with no 10-bit encoder: HEVC itself may still work, so only the depth is missing.
        let s = hevc10();
        let none = EncoderSupport::none(&s);
        assert!(!none.has_encoder() && !none.can(Missing::TenBit) && none.can(Missing::Encoder));
        assert!(none.note().contains("no 10-bit HEVC encoder"));
        let msg = no_encoder_message(&s);
        assert!(msg.contains("10-bit HEVC") && msg.contains("hardware encoding") && msg.contains("H.264"), "{msg}");
        // Plain H.264 / HEVC: the whole format is missing; the message never offers MPEG-4.
        let mut h = ExportPreset::MATCH_SOURCE.settings();
        h.video.codec = VideoCodec::H264;
        let none = EncoderSupport::none(&h);
        assert!(!none.can(Missing::Encoder) && none.can(Missing::TenBit));
        assert!(no_encoder_message(&h).contains("no H.264 encoder"));
        h.video.codec = VideoCodec::Hevc;
        h.video.profile = VideoProfile::Main;
        assert!(no_encoder_message(&h).contains("no HEVC encoder") && !no_encoder_message(&h).contains("MPEG"));
    }

    #[test]
    fn a_measured_probe_without_b_frames_removes_them_for_a_capable_encoder() {
        let mut p = probe("hevc_vaapi");
        p.caps.b_frames = false;
        let support = EncoderSupport::from_probe(&hevc10(), &p);
        assert_eq!(support.missing, [Missing::BFrames]);
        let mut s = hevc10();
        s.video.allows_frame_reordering = false;
        assert!(EncoderSupport::from_probe(&s, &p).missing.is_empty());
    }

    #[test]
    fn hardware_is_not_tried_above_its_size_limit_or_when_switched_off() {
        let mut s = hevc10();
        assert!(probe_kind_of(&s).hardware);
        s.video.hardware_encoding = false;
        assert!(!probe_kind_of(&s).hardware);
        s.video.hardware_encoding = true;
        s.video.codec = VideoCodec::H264;
        s.video.width = 7680;
        s.video.height = 4320;
        assert!(!probe_kind_of(&s).hardware);
    }

    #[test]
    fn labels_say_hardware_or_software() {
        assert_eq!(encoder_label("h264_nvenc"), "NVIDIA NVENC (hardware)");
        assert_eq!(encoder_label("hevc_mf"), "Windows Media Foundation (hardware)");
        assert_eq!(encoder_label("libopenh264"), "OpenH264 (software)");
        assert_eq!(encoder_label("something"), "something (software)");
    }

    #[test]
    fn prores_and_audio_only_have_no_support_note() {
        let mut s = ExportPreset::MATCH_SOURCE.settings();
        s.video.codec = VideoCodec::ProRes422;
        assert_eq!(EncoderSupport::of(&s), None);
    }

    #[test]
    fn main_10_without_hardware_finds_no_encoder_but_with_hardware_it_does() {
        let mut s = hevc10();
        s.video.hardware_encoding = false;
        // The Windows VM: the probe of 10-bit HEVC with hardware off found nothing.
        let vm = |k: ProbeKind| match (k.hevc && k.ten_bit, k.hardware) {
            (true, false) => ProbeState::NoEncoder,
            _ => ProbeState::Found(probe("hevc_mf")),
        };
        let off = EncoderSupport::of_with(&s, vm).expect("the probe answered");
        assert!(!off.has_encoder() && !off.can(Missing::TenBit));
        s.video.hardware_encoding = true;
        let on = EncoderSupport::of_with(&s, vm).expect("the probe answered");
        assert!(on.has_encoder() && on.can(Missing::TenBit));
        // Before the probe ran nothing is restricted.
        assert!(EncoderSupport::of_with(&s, |_| ProbeState::Pending).is_none());
    }
}
