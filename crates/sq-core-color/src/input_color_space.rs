// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: InputColorSpace.swift
//! Camera input color spaces. The stored value is always a `ColorSpaceID` (per clip `ClipFootageColor.source`, per
//! project `Project.inputColorSpace`); `InputColorProfile` is the camera / Log / SDR-HDR view of it for the UI.

use sq_core_model::{ColorSpaceID, MediaInfo, MediaRef, Project};

/// Log, HDR flags, names and the resolution order of [`ColorSpaceID`].
pub trait ColorSpaceIdExt: Sized {
    /// Every color space in declaration order (Swift `allCases`).
    const ALL: [Self; 23];
    /// Camera log encoding (needs the conversion to look normal).
    fn is_log(&self) -> bool;
    /// HDR delivery encoding (HLG or PQ).
    fn is_hdr(&self) -> bool;
    /// Name shown in the UI.
    fn display_name(self) -> &'static str;
    /// The stored text of the space (Swift `rawValue`).
    fn raw_value(self) -> &'static str;
    /// The source color space a clip is rendered with: the clip's own override, else a real detection of the media
    /// (Sony XML S-Log3, HLG/PQ/Apple Log tags, or a file tagged Rec.709), else the project default, else Rec.709.
    /// Only untagged video that detected as Rec.709 takes the project default (Panasonic/DJI log files carry no
    /// color tags); tagged Rec.709 (iPhone SDR, screen recordings, ProRes overlays) keeps Rec.709.
    /// `tagged`: the file has a color primaries or transfer tag (`MediaInfo::has_color_tags`).
    fn effective(
        clip: Option<ColorSpaceID>,
        detected: Option<ColorSpaceID>,
        tagged: bool,
        project_default: Option<ColorSpaceID>,
    ) -> ColorSpaceID;
}

impl ColorSpaceIdExt for ColorSpaceID {
    const ALL: [ColorSpaceID; 23] = [
        ColorSpaceID::Rec709,
        ColorSpaceID::SLog3SGamut3Cine,
        ColorSpaceID::HlgBT2020,
        ColorSpaceID::PqBT2020,
        ColorSpaceID::VLogVGamut,
        ColorSpaceID::AppleLog,
        ColorSpaceID::DLogDGamut,
        ColorSpaceID::CanonLogCinemaGamut,
        ColorSpaceID::CanonLogBT2020,
        ColorSpaceID::CanonLogBT709,
        ColorSpaceID::CanonLog2CinemaGamut,
        ColorSpaceID::CanonLog2BT2020,
        ColorSpaceID::CanonLog2BT709,
        ColorSpaceID::CanonLog3CinemaGamut,
        ColorSpaceID::CanonLog3BT2020,
        ColorSpaceID::CanonLog3BT709,
        ColorSpaceID::LogC3WideGamut3,
        ColorSpaceID::LogC4WideGamut4,
        ColorSpaceID::Log3G10RedWideGamut,
        ColorSpaceID::BmdFilmGen5WideGamut,
        ColorSpaceID::NLogBT2020,
        ColorSpaceID::FLog2FGamutC,
        ColorSpaceID::AcesCCTAP1,
    ];

    fn is_log(&self) -> bool {
        !matches!(*self, ColorSpaceID::Rec709 | ColorSpaceID::HlgBT2020 | ColorSpaceID::PqBT2020)
    }

    fn is_hdr(&self) -> bool {
        *self == ColorSpaceID::HlgBT2020 || *self == ColorSpaceID::PqBT2020
    }

    fn display_name(self) -> &'static str {
        match self {
            ColorSpaceID::Rec709 => "Rec. 709",
            ColorSpaceID::SLog3SGamut3Cine => "S-Log3 / S-Gamut3.Cine",
            ColorSpaceID::HlgBT2020 => "HLG / Rec. 2020",
            ColorSpaceID::PqBT2020 => "PQ (HDR10) / Rec. 2020",
            ColorSpaceID::VLogVGamut => "V-Log / V-Gamut",
            ColorSpaceID::AppleLog => "Apple Log / Rec. 2020",
            ColorSpaceID::DLogDGamut => "D-Log / D-Gamut",
            ColorSpaceID::CanonLogCinemaGamut => "Canon Log / Cinema Gamut",
            ColorSpaceID::CanonLogBT2020 => "Canon Log / Rec. 2020",
            ColorSpaceID::CanonLogBT709 => "Canon Log / Rec. 709",
            ColorSpaceID::CanonLog2CinemaGamut => "Canon Log 2 / Cinema Gamut",
            ColorSpaceID::CanonLog2BT2020 => "Canon Log 2 / Rec. 2020",
            ColorSpaceID::CanonLog2BT709 => "Canon Log 2 / Rec. 709",
            ColorSpaceID::CanonLog3CinemaGamut => "Canon Log 3 / Cinema Gamut",
            ColorSpaceID::CanonLog3BT2020 => "Canon Log 3 / Rec. 2020",
            ColorSpaceID::CanonLog3BT709 => "Canon Log 3 / Rec. 709",
            ColorSpaceID::LogC3WideGamut3 => "LogC3 / ARRI Wide Gamut 3",
            ColorSpaceID::LogC4WideGamut4 => "LogC4 / ARRI Wide Gamut 4",
            ColorSpaceID::Log3G10RedWideGamut => "Log3G10 / REDWideGamutRGB",
            ColorSpaceID::BmdFilmGen5WideGamut => "Blackmagic Film Gen 5 / Wide Gamut",
            ColorSpaceID::NLogBT2020 => "N-Log / Rec. 2020",
            ColorSpaceID::FLog2FGamutC => "F-Log2 / F-Gamut C",
            ColorSpaceID::AcesCCTAP1 => "ACEScct / AP1",
        }
    }

    fn raw_value(self) -> &'static str {
        match self {
            ColorSpaceID::Rec709 => "rec709",
            ColorSpaceID::SLog3SGamut3Cine => "sLog3SGamut3Cine",
            ColorSpaceID::HlgBT2020 => "hlgBT2020",
            ColorSpaceID::PqBT2020 => "pqBT2020",
            ColorSpaceID::VLogVGamut => "vLogVGamut",
            ColorSpaceID::AppleLog => "appleLog",
            ColorSpaceID::DLogDGamut => "dLogDGamut",
            ColorSpaceID::CanonLogCinemaGamut => "canonLogCinemaGamut",
            ColorSpaceID::CanonLogBT2020 => "canonLogBT2020",
            ColorSpaceID::CanonLogBT709 => "canonLogBT709",
            ColorSpaceID::CanonLog2CinemaGamut => "canonLog2CinemaGamut",
            ColorSpaceID::CanonLog2BT2020 => "canonLog2BT2020",
            ColorSpaceID::CanonLog2BT709 => "canonLog2BT709",
            ColorSpaceID::CanonLog3CinemaGamut => "canonLog3CinemaGamut",
            ColorSpaceID::CanonLog3BT2020 => "canonLog3BT2020",
            ColorSpaceID::CanonLog3BT709 => "canonLog3BT709",
            ColorSpaceID::LogC3WideGamut3 => "logC3WideGamut3",
            ColorSpaceID::LogC4WideGamut4 => "logC4WideGamut4",
            ColorSpaceID::Log3G10RedWideGamut => "log3G10RedWideGamut",
            ColorSpaceID::BmdFilmGen5WideGamut => "bmdFilmGen5WideGamut",
            ColorSpaceID::NLogBT2020 => "nLogBT2020",
            ColorSpaceID::FLog2FGamutC => "fLog2FGamutC",
            ColorSpaceID::AcesCCTAP1 => "acesCCTAP1",
        }
    }

    fn effective(
        clip: Option<ColorSpaceID>,
        detected: Option<ColorSpaceID>,
        tagged: bool,
        project_default: Option<ColorSpaceID>,
    ) -> ColorSpaceID {
        if let Some(clip) = clip {
            return clip;
        }
        if let Some(detected) = detected
            && (detected != ColorSpaceID::Rec709 || tagged)
        {
            return detected;
        }
        project_default.or(detected).unwrap_or(ColorSpaceID::Rec709)
    }
}

/// Camera brands the input picker offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CameraMake {
    /// Sony.
    Sony,
    /// iPhone.
    IPhone,
    /// GoPro.
    GoPro,
    /// DJI.
    Dji,
    /// Panasonic.
    Panasonic,
    /// Canon.
    Canon,
    /// Any other camera.
    Other,
    /// ARRI.
    Arri,
    /// RED.
    Red,
    /// Blackmagic.
    Blackmagic,
    /// Nikon.
    Nikon,
    /// Fujifilm.
    Fujifilm,
    /// ACES.
    Aces,
}

impl CameraMake {
    /// Every brand in declaration order (Swift `allCases`).
    pub const ALL: [CameraMake; 13] = [
        CameraMake::Sony,
        CameraMake::IPhone,
        CameraMake::GoPro,
        CameraMake::Dji,
        CameraMake::Panasonic,
        CameraMake::Canon,
        CameraMake::Other,
        CameraMake::Arri,
        CameraMake::Red,
        CameraMake::Blackmagic,
        CameraMake::Nikon,
        CameraMake::Fujifilm,
        CameraMake::Aces,
    ];

    /// The stored text (Swift `rawValue`).
    pub fn raw_value(self) -> &'static str {
        match self {
            CameraMake::Sony => "sony",
            CameraMake::IPhone => "iPhone",
            CameraMake::GoPro => "goPro",
            CameraMake::Dji => "dji",
            CameraMake::Panasonic => "panasonic",
            CameraMake::Canon => "canon",
            CameraMake::Other => "other",
            CameraMake::Arri => "arri",
            CameraMake::Red => "red",
            CameraMake::Blackmagic => "blackmagic",
            CameraMake::Nikon => "nikon",
            CameraMake::Fujifilm => "fujifilm",
            CameraMake::Aces => "aces",
        }
    }

    /// Name shown in the UI.
    pub fn display_name(self) -> &'static str {
        match self {
            CameraMake::Sony => "Sony",
            CameraMake::IPhone => "iPhone",
            CameraMake::GoPro => "GoPro",
            CameraMake::Dji => "DJI",
            CameraMake::Panasonic => "Panasonic",
            CameraMake::Canon => "Canon",
            CameraMake::Other => "Other",
            CameraMake::Arri => "ARRI",
            CameraMake::Red => "RED",
            CameraMake::Blackmagic => "Blackmagic",
            CameraMake::Nikon => "Nikon",
            CameraMake::Fujifilm => "Fujifilm",
            CameraMake::Aces => "ACES",
        }
    }
}

/// SDR or one of the two HDR encodings.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum DynamicRange {
    /// Standard dynamic range.
    #[default]
    Sdr,
    /// Hybrid log-gamma.
    Hlg,
    /// PQ (HDR10).
    Pq,
}

/// Camera + Log on/off + SDR/HDR, resolved to a color space. Log wins over the dynamic range.
///
/// shortcut: no serde coding, because no saved type holds a profile (the picker state is derived from the stored
/// `ColorSpaceID`); add it when a profile is stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct InputColorProfile {
    /// The camera brand.
    pub camera: CameraMake,
    /// Log encoding on.
    pub log: bool,
    /// SDR or HDR encoding (ignored while `log` is on).
    pub range: DynamicRange,
    /// Which of the camera's log curves / color spaces, for a camera with several (Canon); `None` = its default
    /// (`log_space`). Ignored when it is not one of `log_spaces(camera)`.
    pub log_variant: Option<ColorSpaceID>,
}

impl InputColorProfile {
    /// A profile with the given camera, Log switch and range, no variant.
    pub fn new(camera: CameraMake, log: bool, range: DynamicRange) -> InputColorProfile {
        InputColorProfile { camera, log, range, log_variant: None }
    }

    /// The camera's log curve (its default one when it has several); `None` when there is none we can convert (GoPro
    /// GP-Log has no published curve). Canon: Canon Log 3 / Cinema Gamut, the pairing Canon recommends for grading.
    pub fn log_space(camera: CameraMake) -> Option<ColorSpaceID> {
        match camera {
            CameraMake::Sony => Some(ColorSpaceID::SLog3SGamut3Cine),
            CameraMake::IPhone => Some(ColorSpaceID::AppleLog),
            CameraMake::Dji => Some(ColorSpaceID::DLogDGamut),
            CameraMake::Panasonic => Some(ColorSpaceID::VLogVGamut),
            CameraMake::Canon => Some(ColorSpaceID::CanonLog3CinemaGamut),
            CameraMake::Arri => Some(ColorSpaceID::LogC3WideGamut3),
            CameraMake::Red => Some(ColorSpaceID::Log3G10RedWideGamut),
            CameraMake::Blackmagic => Some(ColorSpaceID::BmdFilmGen5WideGamut),
            CameraMake::Nikon => Some(ColorSpaceID::NLogBT2020),
            CameraMake::Fujifilm => Some(ColorSpaceID::FLog2FGamutC),
            CameraMake::Aces => Some(ColorSpaceID::AcesCCTAP1),
            CameraMake::GoPro | CameraMake::Other => None,
        }
    }

    /// Every log space of the camera, the default first.
    pub fn log_spaces(camera: CameraMake) -> Vec<ColorSpaceID> {
        match camera {
            CameraMake::Canon => vec![
                ColorSpaceID::CanonLog3CinemaGamut,
                ColorSpaceID::CanonLog3BT2020,
                ColorSpaceID::CanonLog3BT709,
                ColorSpaceID::CanonLog2CinemaGamut,
                ColorSpaceID::CanonLog2BT2020,
                ColorSpaceID::CanonLog2BT709,
                ColorSpaceID::CanonLogCinemaGamut,
                ColorSpaceID::CanonLogBT2020,
                ColorSpaceID::CanonLogBT709,
            ],
            CameraMake::Arri => vec![ColorSpaceID::LogC3WideGamut3, ColorSpaceID::LogC4WideGamut4],
            _ => Self::log_space(camera).into_iter().collect(),
        }
    }

    /// The camera has a log curve we can convert.
    pub fn log_available(camera: CameraMake) -> bool {
        Self::log_space(camera).is_some()
    }

    /// `None` = Log asked for on a camera without a supported log curve.
    pub fn color_space(&self) -> Option<ColorSpaceID> {
        if self.log {
            if let Some(v) = self.log_variant
                && Self::log_spaces(self.camera).contains(&v)
            {
                return Some(v);
            }
            return Self::log_space(self.camera);
        }
        Some(match self.range {
            DynamicRange::Sdr => ColorSpaceID::Rec709,
            DynamicRange::Hlg => ColorSpaceID::HlgBT2020,
            DynamicRange::Pq => ColorSpaceID::PqBT2020,
        })
    }

    /// A profile that resolves back to `space` (log spaces name their camera; the others say "other").
    pub fn describing(space: ColorSpaceID) -> InputColorProfile {
        use ColorSpaceID as S;
        let log = |camera| InputColorProfile::new(camera, true, DynamicRange::Sdr);
        match space {
            S::Rec709 => InputColorProfile::new(CameraMake::Other, false, DynamicRange::Sdr),
            S::HlgBT2020 => InputColorProfile::new(CameraMake::Other, false, DynamicRange::Hlg),
            S::PqBT2020 => InputColorProfile::new(CameraMake::Other, false, DynamicRange::Pq),
            S::SLog3SGamut3Cine => log(CameraMake::Sony),
            S::AppleLog => log(CameraMake::IPhone),
            S::DLogDGamut => log(CameraMake::Dji),
            S::VLogVGamut => log(CameraMake::Panasonic),
            S::CanonLogCinemaGamut
            | S::CanonLogBT2020
            | S::CanonLogBT709
            | S::CanonLog2CinemaGamut
            | S::CanonLog2BT2020
            | S::CanonLog2BT709
            | S::CanonLog3CinemaGamut
            | S::CanonLog3BT2020
            | S::CanonLog3BT709 => InputColorProfile { log_variant: Some(space), ..log(CameraMake::Canon) },
            S::LogC3WideGamut3 | S::LogC4WideGamut4 => {
                InputColorProfile { log_variant: Some(space), ..log(CameraMake::Arri) }
            }
            S::Log3G10RedWideGamut => log(CameraMake::Red),
            S::BmdFilmGen5WideGamut => log(CameraMake::Blackmagic),
            S::NLogBT2020 => log(CameraMake::Nikon),
            S::FLog2FGamutC => log(CameraMake::Fujifilm),
            S::AcesCCTAP1 => log(CameraMake::Aces),
        }
    }
}

/// Project-default handling of [`MediaInfo`].
pub trait MediaInfoColorExt {
    /// The video track carries a color primaries or transfer tag (probed at import into `VideoTrackInfo`).
    fn has_color_tags(&self) -> bool;
    /// The info the renderer sees under a project default: untagged video (not stills) whose detection found nothing
    /// beyond Rec.709 takes the default as its color space. A real detection, tagged Rec.709 included, is kept.
    fn applying_project_input(&self, project_default: Option<ColorSpaceID>) -> MediaInfo;
}

impl MediaInfoColorExt for MediaInfo {
    fn has_color_tags(&self) -> bool {
        self.video.as_ref().is_some_and(|v| v.color_primaries.is_some() || v.transfer.is_some())
    }

    fn applying_project_input(&self, project_default: Option<ColorSpaceID>) -> MediaInfo {
        let Some(default) = project_default else { return self.clone() };
        if self.video.is_none() || self.is_still {
            return self.clone();
        }
        let mut out = self.clone();
        out.detected_color_space =
            Some(ColorSpaceID::effective(None, self.detected_color_space, self.has_color_tags(), Some(default)));
        out
    }
}

/// The render-side view of a project's media.
pub trait ProjectInputColorExt {
    /// `media` with the project input default applied to each item's info (for the render/playback resolvers; the
    /// stored detection stays untouched).
    fn media_for_rendering(&self) -> Vec<MediaRef>;
}

impl ProjectInputColorExt for Project {
    fn media_for_rendering(&self) -> Vec<MediaRef> {
        if self.input_color_space.is_none() {
            return self.media.to_vec();
        }
        self.media
            .iter()
            .map(|m| {
                let mut m = m.clone();
                m.info = m.info.as_ref().map(|i| i.applying_project_input(self.input_color_space));
                m
            })
            .collect()
    }
}

/// What the inspector's camera / Log / SDR-HLG-PQ picker shows and edits. `camera == None` is Automatic (no override).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct InputPickerState {
    camera: Option<CameraMake>,
    log: bool,
    range: DynamicRange,
    log_variant: Option<ColorSpaceID>,
}

impl InputPickerState {
    /// The picker state for a stored override (`None` = Automatic).
    pub fn new(override_space: Option<ColorSpaceID>) -> InputPickerState {
        let Some(space) = override_space else {
            return InputPickerState { camera: None, log: false, range: DynamicRange::Sdr, log_variant: None };
        };
        let p = InputColorProfile::describing(space);
        InputPickerState { camera: Some(p.camera), log: p.log, range: p.range, log_variant: p.log_variant }
    }

    /// The chosen camera; `None` = Automatic.
    pub fn camera(&self) -> Option<CameraMake> {
        self.camera
    }

    /// Log is on.
    pub fn log(&self) -> bool {
        self.log
    }

    /// The chosen dynamic range.
    pub fn range(&self) -> DynamicRange {
        self.range
    }

    /// The chosen log space of a camera with several (Canon); `None` = the camera's default.
    pub fn log_variant(&self) -> Option<ColorSpaceID> {
        self.log_variant
    }

    /// The camera has a log curve.
    pub fn log_available(&self) -> bool {
        self.camera.is_some_and(InputColorProfile::log_available)
    }

    /// The override to store; `None` = Automatic.
    pub fn space(&self) -> Option<ColorSpaceID> {
        let camera = self.camera?;
        InputColorProfile { camera, log: self.log, range: self.range, log_variant: self.log_variant }.color_space()
    }

    /// Picking a camera selects its Log curve when there is one, else SDR.
    pub fn set_camera(&mut self, c: Option<CameraMake>) {
        self.camera = c;
        self.log = c.is_some_and(InputColorProfile::log_available);
        self.range = DynamicRange::Sdr;
        self.log_variant = None;
    }

    /// Picks one of the camera's log spaces (turns Log on); ignored when the camera does not have it.
    pub fn set_log_variant(&mut self, space: ColorSpaceID) {
        let Some(camera) = self.camera else { return };
        if !InputColorProfile::log_spaces(camera).contains(&space) {
            return;
        }
        self.log_variant = Some(space);
        self.log = true;
    }

    /// Switches Log on or off (on only when the camera has a log curve).
    pub fn set_log(&mut self, on: bool) {
        if self.camera.is_none() {
            return;
        }
        self.log = on && self.log_available();
    }

    /// Sets the dynamic range.
    pub fn set_range(&mut self, r: DynamicRange) {
        if self.camera.is_none() {
            return;
        }
        self.range = r;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ColorSpaceID as C;

    fn id(c: CameraMake, log: bool, r: DynamicRange) -> Option<ColorSpaceID> {
        InputColorProfile::new(c, log, r).color_space()
    }

    #[test]
    fn camera_profiles_resolve_to_their_curve() {
        let sdr = DynamicRange::Sdr;
        assert_eq!(id(CameraMake::Sony, true, sdr), Some(C::SLog3SGamut3Cine));
        assert_eq!(id(CameraMake::IPhone, true, sdr), Some(C::AppleLog));
        assert_eq!(id(CameraMake::Dji, true, sdr), Some(C::DLogDGamut));
        assert_eq!(id(CameraMake::Panasonic, true, sdr), Some(C::VLogVGamut));
        assert_eq!(id(CameraMake::Canon, true, sdr), Some(C::CanonLog3CinemaGamut));
        assert_eq!(id(CameraMake::GoPro, true, sdr), None);
        assert_eq!(id(CameraMake::Other, true, sdr), None);
        for c in CameraMake::ALL {
            assert_eq!(id(c, false, sdr), Some(C::Rec709));
            assert_eq!(id(c, false, DynamicRange::Hlg), Some(C::HlgBT2020));
            assert_eq!(id(c, false, DynamicRange::Pq), Some(C::PqBT2020));
        }
        assert!(!InputColorProfile::log_available(CameraMake::GoPro));
        assert!(InputColorProfile::log_available(CameraMake::Panasonic));
    }

    #[test]
    fn canon_offers_every_curve_and_color_space() {
        let canon = [
            C::CanonLogCinemaGamut,
            C::CanonLogBT2020,
            C::CanonLogBT709,
            C::CanonLog2CinemaGamut,
            C::CanonLog2BT2020,
            C::CanonLog2BT709,
            C::CanonLog3CinemaGamut,
            C::CanonLog3BT2020,
            C::CanonLog3BT709,
        ];
        let offered = InputColorProfile::log_spaces(CameraMake::Canon);
        assert!(offered.len() == canon.len() && canon.iter().all(|s| offered.contains(s)));
        assert_eq!(offered.first().copied(), InputColorProfile::log_space(CameraMake::Canon));
        for s in canon {
            assert!(s.is_log() && !s.is_hdr());
            assert!(s.display_name().starts_with("Canon Log"));
            let p = InputColorProfile {
                log_variant: Some(s),
                ..InputColorProfile::new(CameraMake::Canon, true, DynamicRange::Sdr)
            };
            assert_eq!(p.color_space(), Some(s));
            assert_eq!(InputColorProfile::describing(s).camera, CameraMake::Canon);
        }
        let mut names: Vec<_> = canon.iter().map(|s| s.display_name()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), canon.len());
        // A variant of another camera is ignored; Log off ignores the variant.
        let sony = InputColorProfile {
            log_variant: Some(C::CanonLog2BT2020),
            ..InputColorProfile::new(CameraMake::Sony, true, DynamicRange::Sdr)
        };
        assert_eq!(sony.color_space(), Some(C::SLog3SGamut3Cine));
        let off = InputColorProfile {
            log_variant: Some(C::CanonLog2BT2020),
            ..InputColorProfile::new(CameraMake::Canon, false, DynamicRange::Sdr)
        };
        assert_eq!(off.color_space(), Some(C::Rec709));
        assert_eq!(InputColorProfile::log_spaces(CameraMake::Sony), vec![C::SLog3SGamut3Cine]);
        assert!(InputColorProfile::log_spaces(CameraMake::GoPro).is_empty());
    }

    #[test]
    fn log_wins_over_the_dynamic_range() {
        assert_eq!(id(CameraMake::IPhone, true, DynamicRange::Hlg), Some(C::AppleLog));
    }

    #[test]
    fn every_space_describes_itself_as_a_profile_that_resolves_back() {
        for s in C::ALL {
            assert_eq!(InputColorProfile::describing(s).color_space(), Some(s), "{s:?}");
            assert!(!s.display_name().is_empty());
        }
    }

    #[test]
    fn log_and_hdr_flags() {
        assert!(!C::Rec709.is_log() && !C::Rec709.is_hdr());
        assert!(C::HlgBT2020.is_hdr() && !C::HlgBT2020.is_log());
        assert!(C::PqBT2020.is_hdr() && !C::PqBT2020.is_log());
        for s in [C::SLog3SGamut3Cine, C::VLogVGamut, C::AppleLog, C::DLogDGamut] {
            assert!(s.is_log() && !s.is_hdr());
        }
    }

    #[test]
    fn raw_values_are_stable_and_match_the_model_coding() {
        // Stored in .sqproj files: never rename.
        for s in C::ALL {
            let json = serde_json::to_string(&s).unwrap_or_default();
            assert_eq!(json, format!("\"{}\"", s.raw_value()));
        }
        assert_eq!(CameraMake::Canon.raw_value(), "canon");
    }

    #[test]
    fn clip_override_then_detection_then_project_default() {
        let eff = ColorSpaceID::effective;
        assert_eq!(eff(Some(C::Rec709), Some(C::SLog3SGamut3Cine), false, Some(C::VLogVGamut)), C::Rec709);
        assert_eq!(eff(Some(C::AppleLog), None, false, None), C::AppleLog);
        assert_eq!(eff(None, Some(C::SLog3SGamut3Cine), false, Some(C::VLogVGamut)), C::SLog3SGamut3Cine);
        assert_eq!(eff(None, Some(C::HlgBT2020), true, Some(C::DLogDGamut)), C::HlgBT2020);
        assert_eq!(eff(None, Some(C::Rec709), true, Some(C::VLogVGamut)), C::Rec709);
        assert_eq!(eff(None, Some(C::Rec709), false, Some(C::VLogVGamut)), C::VLogVGamut);
        assert_eq!(eff(None, None, false, Some(C::DLogDGamut)), C::DLogDGamut);
        assert_eq!(eff(None, None, false, None), C::Rec709);
        assert_eq!(eff(None, Some(C::Rec709), false, None), C::Rec709);
    }

    fn info(json: &str) -> MediaInfo {
        serde_json::from_str(json).unwrap_or_else(|e| panic!("bad test json: {e}"))
    }

    const VIDEO: &str = r#""video":{"width":10,"height":10,"codec":"avc1","bitDepth":10,"chroma":"4:2:2","nominalFrameDuration":{"value":1,"timescale":25},"isVariableFrameRate":false"#;

    fn media(extra_video: &str, detected: Option<&str>, still: bool) -> MediaInfo {
        let det = detected.map(|d| format!(r#","detectedColorSpace":"{d}""#)).unwrap_or_default();
        info(&format!(r#"{{"duration":{{"value":1,"timescale":1}},{VIDEO}{extra_video}}}{det},"isStill":{still}}}"#))
    }

    #[test]
    fn media_info_takes_the_project_default_only_for_untagged_video_without_a_detection() {
        let untagged = media("", Some("rec709"), false);
        assert!(!untagged.has_color_tags());
        assert_eq!(untagged.applying_project_input(Some(C::VLogVGamut)).color_space(), C::VLogVGamut);
        assert_eq!(untagged.applying_project_input(None), untagged);
        let sony = media("", Some("sLog3SGamut3Cine"), false);
        assert_eq!(sony.applying_project_input(Some(C::VLogVGamut)).color_space(), C::SLog3SGamut3Cine);
        let still = media("", Some("rec709"), true);
        assert_eq!(still.applying_project_input(Some(C::AppleLog)).color_space(), C::Rec709);
        let audio = info(r#"{"duration":{"value":1,"timescale":1}}"#);
        assert_eq!(audio.applying_project_input(Some(C::AppleLog)).detected_color_space, None);
    }

    #[test]
    fn tagged_rec709_video_ignores_the_project_default() {
        let phone = media(r#","colorPrimaries":"ITU_R_709_2","transfer":"ITU_R_709_2""#, Some("rec709"), false);
        assert!(phone.has_color_tags());
        assert_eq!(phone.applying_project_input(Some(C::AppleLog)), phone);
        let transfer_only = media(r#","transfer":"ITU_R_709_2""#, Some("rec709"), false);
        assert_eq!(transfer_only.applying_project_input(Some(C::VLogVGamut)).color_space(), C::Rec709);
        let primaries_only = media(r#","colorPrimaries":"ITU_R_709_2""#, Some("rec709"), false);
        assert_eq!(primaries_only.applying_project_input(Some(C::VLogVGamut)).color_space(), C::Rec709);
    }

    #[test]
    fn picker_state_round_trips_and_follows_the_camera() {
        let mut p = InputPickerState::new(None);
        assert!(p.space().is_none() && !p.log_available());
        p.set_camera(Some(CameraMake::Canon));
        assert!(p.log());
        assert_eq!(p.space(), Some(C::CanonLog3CinemaGamut));
        p.set_log_variant(C::CanonLog2BT709);
        assert_eq!(p.space(), Some(C::CanonLog2BT709));
        p.set_log_variant(C::SLog3SGamut3Cine);
        assert_eq!(p.log_variant(), Some(C::CanonLog2BT709), "a space of another camera is ignored");
        p.set_log(false);
        p.set_range(DynamicRange::Pq);
        assert_eq!(p.space(), Some(C::PqBT2020));
        p.set_camera(Some(CameraMake::GoPro));
        p.set_log(true);
        assert_eq!(p.space(), Some(C::Rec709), "GoPro has no log curve");
        for s in C::ALL {
            assert_eq!(InputPickerState::new(Some(s)).space(), Some(s));
        }
    }
}
