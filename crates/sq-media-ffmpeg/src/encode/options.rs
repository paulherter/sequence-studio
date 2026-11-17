//! The private options each video encoder gets for the export's rate control, speed and B-frame choices. Pure, so the
//! mapping is tested without any encoder or GPU. The C++ shim applies them to the codec context (`av_opt_set` with
//! `AV_OPT_SEARCH_CHILDREN`: codec-level keys such as `flags` and private ones such as `rc` alike); the generic fields
//! (`bit_rate`, `rc_max_rate`, `gop_size`, `max_b_frames`) stay in `vendor/encode.cpp`.
//!
//! An encoder that refuses an option is opened again without the options (see `openVideoAny`), so a wrong key costs
//! the rate-control mode, never the export.

/// The H.264 profile the export sheet chose. HEVC has none of these (Main 10 is a bit depth, `EncodeConfig::ten_bit`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum H264Profile {
    /// The encoder decides.
    #[default]
    Automatic,
    Baseline,
    Main,
    High,
}

impl H264Profile {
    /// The number the C config carries: 0 = the encoder decides, 1 Baseline, 2 Main, 3 High.
    pub fn code(self) -> i32 {
        match self {
            H264Profile::Automatic => 0,
            H264Profile::Baseline => 1,
            H264Profile::Main => 2,
            H264Profile::High => 3,
        }
    }

    /// Baseline has no B-frames (the standard's rule; the shim opens such a file without them).
    pub fn allows_b_frames(self) -> bool {
        self != H264Profile::Baseline
    }
}

/// What the export asks of an H.264 / HEVC encoder.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VideoRequest {
    pub hevc: bool,
    /// H.264 only; HEVC and `Automatic` leave the encoder's own choice.
    pub profile: H264Profile,
    /// 0 = a target bitrate; else constant quality 0.05...1.
    pub quality: f64,
    /// Constant bitrate (only with a bitrate target).
    pub cbr: bool,
    /// 0 = Quality, 1 = Balanced, 2 = Fast.
    pub speed: i32,
    /// B-frames wanted; 0 = none.
    pub b_frames: i32,
}

/// The quantizer that matches a constant-quality value: 14 at 1.0 down to 43 at 0.05 (the CRF scale of the software
/// encoders, which the AMF constant-QP branch in `encode.cpp` uses as well).
pub fn quantizer(quality: f64) -> i32 {
    let q = quality.clamp(0.05, 1.0);
    (14.0 + (1.0 - q) * 30.0 + 0.5) as i32
}

type Options = Vec<(&'static str, String)>;

fn pairs<const N: usize>(list: [(&'static str, &str); N]) -> Options {
    list.into_iter().map(|(k, v)| (k, v.to_string())).collect()
}

/// The value of an encoder's own `profile` option for an H.264 request, by the words that encoder knows (`None` when the
/// encoder decides or has no such option). VA-API and AMF only name the constrained Baseline, which is the one the
/// hardware can write; the shim sets the codec-level profile as well for the encoders that read only that
/// (Media Foundation, and VA-API / AMF / QSV beside their option).
fn profile_option(name: &str, r: &VideoRequest) -> Option<&'static str> {
    if r.hevc {
        return None;
    }
    let (baseline, main, high) = if name.ends_with("_vaapi") || name.ends_with("_amf") || name == "libopenh264" {
        ("constrained_baseline", "main", "high")
    } else if name.ends_with("_nvenc") || name.ends_with("_qsv") || name.ends_with("_videotoolbox") || name == "libx264"
    {
        ("baseline", "main", "high")
    } else {
        return None;
    };
    match r.profile {
        H264Profile::Automatic => None,
        H264Profile::Baseline => Some(baseline),
        H264Profile::Main => Some(main),
        H264Profile::High => Some(high),
    }
}

/// The options of the encoder `name` for `r`; empty for encoders that need none (and for names not known here).
pub fn private_options(name: &str, r: &VideoRequest) -> Options {
    let mut o = rate_options(name, r);
    if let Some(profile) = profile_option(name, r) {
        o.push(("profile", profile.to_string()));
    }
    o
}

/// The rate control, speed and B-frame options of `private_options`.
fn rate_options(name: &str, r: &VideoRequest) -> Options {
    let cq = r.quality > 0.0;
    let qp = quantizer(r.quality).to_string();
    let pick = |quality: &'static str, balanced: &'static str, fast: &'static str| match r.speed {
        0 => quality,
        1 => balanced,
        _ => fast,
    };
    if name.ends_with("_vaapi") {
        // The driver picks the mode itself without `rc_mode`; name it, so CBR is CBR and a cap means VBR.
        let mut o = pairs([(
            "rc_mode",
            if cq {
                "CQP"
            } else if r.cbr {
                "CBR"
            } else {
                "VBR"
            },
        )]);
        if cq {
            o.push(("qp", qp));
        }
        o
    } else if name.ends_with("_nvenc") {
        let mut o = pairs([(
            "rc",
            if cq {
                "constqp"
            } else if r.cbr {
                "cbr"
            } else {
                "vbr"
            },
        )]);
        if cq {
            o.push(("qp", qp));
        }
        o.push(("preset", pick("p6", "p4", "p2").to_string()));
        if r.speed == 0 {
            o.push(("tune", "hq".to_string()));
        }
        o
    } else if name.ends_with("_amf") {
        // Constant quality (rc=cqp) is set in `encode.cpp`; the other modes are named here.
        let mut o = Vec::new();
        if !cq {
            o.push(("rc", if r.cbr { "cbr" } else { "vbr_peak" }.to_string()));
        }
        o.push(("quality", pick("quality", "balanced", "speed").to_string()));
        o
    } else if name.ends_with("_qsv") {
        let mut o = pairs([("preset", pick("slow", "medium", "veryfast"))]);
        if cq {
            // QSCALE with a global quality is the constant-QP mode of Quick Sync.
            o.push(("flags", "+qscale".to_string()));
            o.push(("global_quality", qp));
        }
        o
    } else if name.ends_with("_mf") {
        if cq {
            // MF's quality is 0...100 (higher is better), our 0.05...1 times 100.
            pairs([
                ("rate_control", "quality"),
                ("quality", &format!("{}", (r.quality.clamp(0.05, 1.0) * 100.0).round() as i32)),
            ])
        } else {
            pairs([("rate_control", if r.cbr { "cbr" } else { "pc_vbr" })])
        }
    } else if name == "libkvazaar" {
        // One `kvazaar-params` value, the preset first (a preset resets the parameters after it). Its GOP of 8 is
        // hierarchical B-frames; 0 means I and P pictures only.
        let mut p = vec![
            format!("preset={}", pick("medium", "fast", "ultrafast")),
            format!("gop={}", if r.b_frames > 0 { 8 } else { 0 }),
        ];
        if cq {
            p.push(format!("qp={qp}"));
        }
        pairs([("kvazaar-params", &p.join(","))])
    } else {
        Vec::new()
    }
}

/// The `name<TAB>key<TAB>value` lines the shim reads, for every name that has options.
pub fn option_lines(names: &[&str], r: &VideoRequest) -> String {
    let mut out = String::new();
    for name in names {
        for (key, value) in private_options(name, r) {
            out.push_str(&format!("{name}\t{key}\t{value}\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> VideoRequest {
        VideoRequest { hevc: false, profile: H264Profile::Automatic, quality: 0.0, cbr: false, speed: 0, b_frames: 2 }
    }

    fn get(o: &Options, key: &str) -> Option<String> {
        o.iter().find(|(k, _)| *k == key).map(|(_, v)| v.clone())
    }

    #[test]
    fn the_quantizer_runs_from_14_at_best_to_43_at_the_lowest_quality() {
        assert_eq!(quantizer(1.0), 14);
        assert_eq!(quantizer(0.05), 43);
        assert_eq!(quantizer(0.6), 26);
        assert_eq!(quantizer(0.0), 43);
        assert_eq!(quantizer(7.0), 14);
    }

    #[test]
    fn vaapi_names_cbr_vbr_and_constant_quality() {
        let vbr = private_options("h264_vaapi", &request());
        assert_eq!(get(&vbr, "rc_mode").as_deref(), Some("VBR"));
        assert_eq!(get(&vbr, "qp"), None);
        let cbr = private_options("hevc_vaapi", &VideoRequest { cbr: true, ..request() });
        assert_eq!(get(&cbr, "rc_mode").as_deref(), Some("CBR"));
        let cq = private_options("h264_vaapi", &VideoRequest { quality: 1.0, ..request() });
        assert_eq!((get(&cq, "rc_mode").as_deref(), get(&cq, "qp").as_deref()), (Some("CQP"), Some("14")));
    }

    #[test]
    fn nvenc_maps_rate_control_and_the_speed_choice_to_a_preset() {
        let quality = private_options("hevc_nvenc", &request());
        assert_eq!((get(&quality, "rc").as_deref(), get(&quality, "preset").as_deref()), (Some("vbr"), Some("p6")));
        assert_eq!(get(&quality, "tune").as_deref(), Some("hq"));
        let fast = private_options("h264_nvenc", &VideoRequest { speed: 2, cbr: true, ..request() });
        assert_eq!((get(&fast, "rc").as_deref(), get(&fast, "preset").as_deref()), (Some("cbr"), Some("p2")));
        assert_eq!(get(&fast, "tune"), None);
        let cq = private_options("h264_nvenc", &VideoRequest { quality: 0.05, ..request() });
        assert_eq!((get(&cq, "rc").as_deref(), get(&cq, "qp").as_deref()), (Some("constqp"), Some("43")));
    }

    #[test]
    fn amf_leaves_constant_quality_to_the_shim_and_names_the_other_modes() {
        let vbr = private_options("h264_amf", &request());
        assert_eq!(get(&vbr, "rc").as_deref(), Some("vbr_peak"));
        assert_eq!(get(&vbr, "quality").as_deref(), Some("quality"));
        let cbr = private_options("hevc_amf", &VideoRequest { cbr: true, speed: 1, ..request() });
        assert_eq!((get(&cbr, "rc").as_deref(), get(&cbr, "quality").as_deref()), (Some("cbr"), Some("balanced")));
        let cq = private_options("h264_amf", &VideoRequest { quality: 0.5, ..request() });
        assert_eq!(get(&cq, "rc"), None);
    }

    #[test]
    fn quick_sync_uses_qscale_for_constant_quality_and_a_preset_for_speed() {
        let cq = private_options("hevc_qsv", &VideoRequest { quality: 0.6, speed: 2, ..request() });
        assert_eq!(get(&cq, "flags").as_deref(), Some("+qscale"));
        assert_eq!(
            (get(&cq, "global_quality").as_deref(), get(&cq, "preset").as_deref()),
            (Some("26"), Some("veryfast"))
        );
        assert_eq!(get(&private_options("h264_qsv", &request()), "flags"), None);
    }

    #[test]
    fn media_foundation_names_its_rate_control() {
        assert_eq!(get(&private_options("h264_mf", &request()), "rate_control").as_deref(), Some("pc_vbr"));
        assert_eq!(
            get(&private_options("h264_mf", &VideoRequest { cbr: true, ..request() }), "rate_control").as_deref(),
            Some("cbr")
        );
        let cq = private_options("hevc_mf", &VideoRequest { quality: 0.8, ..request() });
        assert_eq!(
            (get(&cq, "rate_control").as_deref(), get(&cq, "quality").as_deref()),
            (Some("quality"), Some("80"))
        );
    }

    #[test]
    fn kvazaar_gets_one_parameter_list_with_the_preset_first() {
        let o = private_options("libkvazaar", &request());
        assert_eq!(get(&o, "kvazaar-params").as_deref(), Some("preset=medium,gop=8"));
        let none = private_options("libkvazaar", &VideoRequest { b_frames: 0, speed: 2, quality: 1.0, ..request() });
        assert_eq!(get(&none, "kvazaar-params").as_deref(), Some("preset=ultrafast,gop=0,qp=14"));
    }

    #[test]
    fn encoders_without_options_and_unknown_names_get_none() {
        for name in ["libopenh264", "mpeg4", "libx264", "libx265", "h264_videotoolbox", "nonsense"] {
            assert!(private_options(name, &request()).is_empty(), "{name}");
        }
    }

    #[test]
    fn the_lines_for_the_shim_name_their_encoder_and_carry_no_separator_inside_a_value() {
        let r = VideoRequest { hevc: true, ..request() };
        let lines = option_lines(&["hevc_vaapi", "libx265", "libkvazaar"], &r);
        assert!(lines.contains("hevc_vaapi\trc_mode\tVBR\n"));
        assert!(lines.contains("libkvazaar\tkvazaar-params\tpreset=medium,gop=8\n"));
        assert!(!lines.contains("libx265"));
        for line in lines.lines() {
            assert_eq!(line.split('\t').count(), 3, "{line}");
        }
    }

    fn profile_of(name: &str, profile: H264Profile) -> Option<String> {
        get(&private_options(name, &VideoRequest { profile, ..request() }), "profile")
    }

    #[test]
    fn every_h264_encoder_that_takes_a_profile_gets_the_sheets_choice_in_its_own_words() {
        use H264Profile::{Baseline, High, Main};
        let cases = [
            ("h264_vaapi", ["constrained_baseline", "main", "high"]),
            ("h264_amf", ["constrained_baseline", "main", "high"]),
            ("libopenh264", ["constrained_baseline", "main", "high"]),
            ("h264_nvenc", ["baseline", "main", "high"]),
            ("h264_qsv", ["baseline", "main", "high"]),
            ("h264_videotoolbox", ["baseline", "main", "high"]),
            ("libx264", ["baseline", "main", "high"]),
        ];
        for (name, words) in cases {
            for (profile, word) in [Baseline, Main, High].into_iter().zip(words) {
                assert_eq!(profile_of(name, profile).as_deref(), Some(word), "{name} {profile:?}");
            }
        }
    }

    #[test]
    fn automatic_hevc_and_encoders_without_the_option_get_no_profile_option() {
        for name in ["h264_vaapi", "h264_amf", "h264_nvenc", "h264_qsv", "h264_videotoolbox", "libx264", "libopenh264"]
        {
            assert_eq!(profile_of(name, H264Profile::Automatic), None, "{name}");
        }
        // HEVC: Main 10 is a bit depth, never a profile option of the H.264 kind.
        for name in ["hevc_vaapi", "hevc_amf", "hevc_nvenc", "libx265"] {
            let r = VideoRequest { hevc: true, profile: H264Profile::High, ..request() };
            assert_eq!(get(&private_options(name, &r), "profile"), None, "{name}");
        }
        // Media Foundation reads the codec-level profile only (the shim sets it); MPEG-4 and Kvazaar have none.
        for name in ["h264_mf", "mpeg4", "libkvazaar", "nonsense"] {
            assert_eq!(profile_of(name, H264Profile::High), None, "{name}");
        }
    }

    #[test]
    fn the_profile_never_disturbs_the_rate_control_options() {
        let plain = private_options("h264_nvenc", &request());
        let high = private_options("h264_nvenc", &VideoRequest { profile: H264Profile::High, ..request() });
        assert_eq!(&high[..plain.len()], &plain[..]);
        assert_eq!(high.len(), plain.len() + 1);
    }

    #[test]
    fn the_profile_codes_and_the_baseline_rule() {
        let codes: Vec<i32> = [H264Profile::Automatic, H264Profile::Baseline, H264Profile::Main, H264Profile::High]
            .map(H264Profile::code)
            .to_vec();
        assert_eq!(codes, [0, 1, 2, 3]);
        assert!(!H264Profile::Baseline.allows_b_frames());
        assert!(H264Profile::Main.allows_b_frames() && H264Profile::Automatic.allows_b_frames());
    }
}
