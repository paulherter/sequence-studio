//! Which FFmpeg video encoders `Encoder::open` tries, in order. Pure so the fallback chain is testable without FFmpeg
//! (the PC runs the tests with a fake availability probe).
//!
//! The release builds use an LGPL FFmpeg: no libx264 / libx265. Hardware encoders come first, per system: VideoToolbox
//! on a Mac; NVENC, AMF, Quick Sync, Media Foundation on Windows; VA-API on Linux. Software last: H.264 falls back to
//! OpenH264, HEVC to Kvazaar (both 8-bit, no multi-pass). There is no MPEG-4 Part 2 stand-in: a computer without an
//! encoder for the chosen codec fails the export ("no HEVC encoder"), it never writes another codec under that name.

/// The operating system family that decides which hardware encoders exist.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Apple,
    Windows,
    Linux,
}

impl Platform {
    /// The system this build runs on.
    pub const fn current() -> Platform {
        if cfg!(target_vendor = "apple") {
            Platform::Apple
        } else if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Linux
        }
    }
}

/// Encoder names in try order, with the number of hardware names at the front (those get a test frame first).
#[derive(Debug, PartialEq, Eq)]
pub struct Candidates {
    pub names: Vec<&'static str>,
    pub hardware: usize,
}

/// The candidates for one kind of file on `platform`; `hardware` = the user allows hardware encoders.
pub fn candidates(hevc: bool, prores: bool, gif: bool, hardware: bool, platform: Platform) -> Candidates {
    let hw: &[&'static str] = match (prores || gif, hardware, platform, hevc) {
        // ProRes: the Mac's hardware encoder first (as AVFoundation); `prores_ks` when VideoToolbox refuses or is absent.
        (_, true, Platform::Apple, _) if prores => &["prores_videotoolbox"],
        (true, ..) | (_, false, ..) => &[],
        (_, _, Platform::Apple, false) => &["h264_videotoolbox"],
        (_, _, Platform::Apple, true) => &["hevc_videotoolbox"],
        // NVENC first: it is the only one that honors every option; AMF and Quick Sync follow; Media Foundation is the
        // vendor-neutral last resort (which MFT answers depends on the driver).
        (_, _, Platform::Windows, false) => &["h264_nvenc", "h264_amf", "h264_qsv", "h264_mf"],
        (_, _, Platform::Windows, true) => &["hevc_nvenc", "hevc_amf", "hevc_qsv", "hevc_mf"],
        (_, _, Platform::Linux, false) => &["h264_vaapi"],
        (_, _, Platform::Linux, true) => &["hevc_vaapi"],
    };
    let sw: &[&'static str] = if gif {
        &["gif"]
    } else if prores {
        &["prores_ks"]
    } else if hevc {
        &["libx265", "libkvazaar"]
    } else {
        &["libx264", "libopenh264"]
    };
    Candidates { names: hw.iter().chain(sw).copied().collect(), hardware: hw.len() }
}

/// The first candidate `available` accepts (what the shim does with `avcodec_find_encoder_by_name`).
pub fn first_available(c: &Candidates, available: impl Fn(&str) -> bool) -> Option<&'static str> {
    c.names.iter().copied().find(|n| available(n))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_computer_without_any_listed_encoder_gets_none_never_mpeg4() {
        // The user picked H.264 or HEVC: a file of another codec under that name is wrong, so the list ends there and
        // the export fails with "no encoder" (`first_available` answers `None`).
        for platform in [Platform::Apple, Platform::Windows, Platform::Linux] {
            for hevc in [false, true] {
                let c = candidates(hevc, false, false, true, platform);
                assert!(!c.names.contains(&"mpeg4"), "{platform:?} hevc {hevc}: {:?}", c.names);
                assert_eq!(first_available(&c, |n| n == "mpeg4"), None);
            }
        }
    }

    #[test]
    fn lgpl_mac_prefers_videotoolbox_then_gpl_software() {
        let c = candidates(false, false, false, true, Platform::Apple);
        assert_eq!(c.names, ["h264_videotoolbox", "libx264", "libopenh264"]);
        assert_eq!(first_available(&c, |n| n != "h264_videotoolbox" && n != "libx264"), Some("libopenh264"));
    }

    #[test]
    fn windows_tries_nvenc_then_amf_then_quick_sync_then_media_foundation() {
        let h264 = candidates(false, false, false, true, Platform::Windows);
        assert_eq!(h264.names[..4], ["h264_nvenc", "h264_amf", "h264_qsv", "h264_mf"]);
        assert_eq!(h264.hardware, 4);
        let hevc = candidates(true, false, false, true, Platform::Windows);
        assert_eq!(hevc.names[..4], ["hevc_nvenc", "hevc_amf", "hevc_qsv", "hevc_mf"]);
        // A machine with only the Media Foundation encoder gets it, not software.
        assert_eq!(first_available(&hevc, |n| n == "hevc_mf" || n == "libkvazaar"), Some("hevc_mf"));
    }

    #[test]
    fn linux_tries_vaapi_before_the_software_encoders() {
        let h264 = candidates(false, false, false, true, Platform::Linux);
        assert_eq!(h264.names, ["h264_vaapi", "libx264", "libopenh264"]);
        assert_eq!(h264.hardware, 1);
        let hevc = candidates(true, false, false, true, Platform::Linux);
        assert_eq!(hevc.names, ["hevc_vaapi", "libx265", "libkvazaar"]);
    }

    #[test]
    fn hevc_software_prefers_kvazaar_and_h264_prefers_openh264() {
        let hevc = candidates(true, false, false, false, Platform::Linux);
        assert_eq!(first_available(&hevc, |n| n == "libkvazaar" || n == "gif"), Some("libkvazaar"));
        let h264 = candidates(false, false, false, false, Platform::Windows);
        assert_eq!(first_available(&h264, |n| n == "libopenh264" || n == "gif"), Some("libopenh264"));
    }

    #[test]
    fn no_candidate_is_a_gpl_encoder_except_the_two_that_an_lgpl_build_leaves_out() {
        // libx264 / libx265 stay listed for builds that have them; an LGPL build simply does not offer them. Nothing
        // else GPL-only may ever be added.
        for platform in [Platform::Apple, Platform::Windows, Platform::Linux] {
            for hevc in [false, true] {
                for name in candidates(hevc, false, false, true, platform).names {
                    assert!(!name.contains("x264") || name == "libx264", "{name}");
                    assert!(!name.contains("x265") || name == "libx265", "{name}");
                    assert!(!name.contains("xvid") && !name.contains("fdk"), "{name}");
                }
            }
        }
    }

    #[test]
    fn software_only_export_skips_hardware_and_prores_and_gif_have_their_own_encoder() {
        assert_eq!(candidates(true, false, false, false, Platform::Apple).names, ["libx265", "libkvazaar"]);
        let pro = Candidates { names: vec!["prores_ks"], hardware: 0 };
        assert_eq!(candidates(false, true, false, false, Platform::Apple), pro);
        assert_eq!(candidates(false, true, false, true, Platform::Windows), pro);
        assert_eq!(candidates(false, false, true, true, Platform::Windows).names, ["gif"]);
    }

    #[test]
    fn mac_prores_tries_videotoolbox_first_then_prores_ks() {
        let c = candidates(false, true, false, true, Platform::Apple);
        assert_eq!(c, Candidates { names: vec!["prores_videotoolbox", "prores_ks"], hardware: 1 });
        assert_eq!(first_available(&c, |n| n == "prores_ks"), Some("prores_ks"));
        assert_eq!(first_available(&c, |_| true), Some("prores_videotoolbox"));
    }

    #[test]
    fn nothing_available_means_no_encoder() {
        assert_eq!(first_available(&candidates(false, false, false, true, Platform::Windows), |_| false), None);
    }
}
