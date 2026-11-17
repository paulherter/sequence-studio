// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DisplayView.swift
//! Which display the monitors preview for (a view only: export never reads it). `Sdr` is the default and the long-standing
//! path (8-bit Rec.709 code values); `Hdr1000` and `UnToneMapped` need an extended-range float drawable, which
//! `surface_mode` grants only when the display reports HDR headroom. On every other display the surface stays 8-bit SDR,
//! so SDR screens look exactly as before.

use crate::color::gamut::Gamut;
use crate::color::tone_mapping::ToneMapping;
use crate::color::transfer::bt709_oetf;
use crate::color::vec::Vec3;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DisplayView {
    Sdr,
    DisplayP3,
    Hdr1000,
    UnToneMapped,
}

/// The drawable the window surface is configured with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SurfaceMode {
    /// `Bgra8Unorm`, the sRGB/709 tagged surface (the whole app today).
    Sdr8,
    /// `Bgra8Unorm` tagged Display P3 (macOS): the window is drawn through the present pass with P3 primaries.
    DisplayP3,
    /// `Rgba16Float` with `SurfaceColorSpace::ExtendedSrgbLinear` (EDR on macOS, scRGB on Windows).
    ExtendedLinear,
}

impl DisplayView {
    pub const ALL: [DisplayView; 4] =
        [DisplayView::Sdr, DisplayView::DisplayP3, DisplayView::Hdr1000, DisplayView::UnToneMapped];

    /// Peak of `Hdr1000` in reference whites (1000 nit / 100 nit).
    pub const HDR_PEAK: f32 = 10.0;

    pub fn title(self) -> &'static str {
        match self {
            DisplayView::Sdr => "SDR 100 nit Rec.709",
            DisplayView::DisplayP3 => "Display P3",
            DisplayView::Hdr1000 => "HDR 1000 nit",
            DisplayView::UnToneMapped => "Not Tone-Mapped",
        }
    }

    pub fn is_extended_range(self) -> bool {
        matches!(self, DisplayView::Hdr1000 | DisplayView::UnToneMapped)
    }

    /// CPU reference of the presenter shader: working-linear Rec.709 -> the value written to the drawable.
    pub fn encode(self, working_linear: Vec3) -> Vec3 {
        let p3 = self != DisplayView::Sdr;
        let v = if p3 { Gamut::rec709().matrix(Gamut::display_p3()).mul_vec(working_linear) } else { working_linear };
        match self {
            DisplayView::Sdr | DisplayView::DisplayP3 => v.max(Vec3::ZERO).min(Vec3::ONE).map(bt709_oetf),
            DisplayView::UnToneMapped => v.max(Vec3::ZERO),
            DisplayView::Hdr1000 => {
                let c = v.max(Vec3::ZERO);
                let m = c.x.max(c.y).max(c.z);
                if m <= 0.0 {
                    return c;
                }
                let mapped = ToneMapping::default().map_max(m / Self::HDR_PEAK) * Self::HDR_PEAK;
                c * (mapped / m)
            }
        }
    }

    /// What the extended-range window surface (`Rgba16Float`, scRGB: Rec.709 primaries, 1.0 = 80 nit) gets for a working-linear
    /// picture value: the extended views without the P3 matrix (the surface is 709) and scaled by `203 / 80` so reference
    /// white (203 nit) shows at 203 nit. Mirrors `sq_draw::hdr_present::encode_picture` (a test in sequence-studio keeps them equal).
    pub fn encode_scrgb(self, working_linear: Vec3) -> Vec3 {
        const SCALE: f32 = 203.0 / 80.0;
        match self {
            DisplayView::Hdr1000 | DisplayView::UnToneMapped => {
                let c = working_linear.max(Vec3::ZERO);
                let m = c.x.max(c.y).max(c.z);
                let rolled = if self == DisplayView::Hdr1000 && m > 0.0 {
                    c * (ToneMapping::default().map_max(m / Self::HDR_PEAK) * Self::HDR_PEAK / m)
                } else {
                    c
                };
                rolled * SCALE
            }
            DisplayView::Sdr | DisplayView::DisplayP3 => self.encode(working_linear),
        }
    }
}

/// Chooses the surface: extended-range float only when the view asks for it and the display reports HDR headroom
/// (`headroom` = the display's peak over reference white, `> 1.0` when HDR is on; `None` = unknown or not supported).
/// `sequence_is_hdr` does not change the choice (Swift picks by view only); it is only part of the log line.
pub fn surface_mode(view: DisplayView, headroom: Option<f32>) -> SurfaceMode {
    if view.is_extended_range() && headroom.is_some_and(|h| h > 1.0) {
        SurfaceMode::ExtendedLinear
    } else if view == DisplayView::DisplayP3 {
        SurfaceMode::DisplayP3
    } else {
        SurfaceMode::Sdr8
    }
}

/// One log line for the chosen mode.
pub fn describe(view: DisplayView, headroom: Option<f32>, sequence_is_hdr: bool) -> String {
    format!(
        "display mode: {:?} for view {} (display headroom {:?}, HDR sequence {})",
        surface_mode(view, headroom),
        view.title(),
        headroom,
        sequence_is_hdr
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_sdr_display_never_gets_the_float_surface() {
        for view in DisplayView::ALL {
            let want = if view == DisplayView::DisplayP3 { SurfaceMode::DisplayP3 } else { SurfaceMode::Sdr8 };
            assert_eq!(surface_mode(view, None), want, "{view:?}");
            assert_eq!(surface_mode(view, Some(1.0)), want, "{view:?}");
        }
        assert_eq!(surface_mode(DisplayView::Sdr, Some(4.0)), SurfaceMode::Sdr8);
        // Display P3 is an 8-bit view with its own tag, on any display; the HDR views never take it.
        assert_eq!(surface_mode(DisplayView::DisplayP3, Some(4.0)), SurfaceMode::DisplayP3);
    }

    #[test]
    fn an_hdr_view_on_an_hdr_display_gets_extended_linear() {
        assert_eq!(surface_mode(DisplayView::Hdr1000, Some(5.0)), SurfaceMode::ExtendedLinear);
        assert_eq!(surface_mode(DisplayView::UnToneMapped, Some(1.5)), SurfaceMode::ExtendedLinear);
        let line = describe(DisplayView::Hdr1000, Some(5.0), true);
        assert!(line.contains("ExtendedLinear") && line.contains("HDR sequence true"), "{line}");
    }

    #[test]
    fn encode_matches_the_swift_reference() {
        let white = Vec3::ONE;
        let sdr = DisplayView::Sdr.encode(Vec3::splat(2.0));
        assert!((sdr.x - 1.0).abs() < 1e-6, "SDR clamps to white");
        assert!((DisplayView::Sdr.encode(white).x - 1.0).abs() < 1e-6);
        // Extended views keep scene values above white; gray stays gray through the P3 matrix.
        let raw = DisplayView::UnToneMapped.encode(Vec3::splat(3.0));
        assert!((raw.x - 3.0).abs() < 2e-3 && (raw.x - raw.z).abs() < 2e-3, "{raw:?}");
        // Hdr1000 is hue-preserving and rolls the peak off below 10x white.
        let hdr = DisplayView::Hdr1000.encode(Vec3::new(8.0, 4.0, 2.0));
        assert!(hdr.x > hdr.y && hdr.y > hdr.z && hdr.x <= DisplayView::HDR_PEAK, "{hdr:?}");
        // Dark values pass through the roll-off unchanged (below the knee).
        let low = DisplayView::Hdr1000.encode(Vec3::splat(0.05));
        assert!((low.x - 0.05).abs() < 1e-3, "{low:?}");
    }
}
