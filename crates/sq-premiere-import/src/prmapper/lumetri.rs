// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRMapper.swift (Lumetri). Lumetri Color -> a Color effect, and the display-gamma curve of Premiere's color
//! management.

use super::Mapping;
use crate::prcontainer::utf16le_units;
use crate::prdocument::{PRComponent, PRParamValue};
use crate::primport_report::Status;
use sq_core_color::ClipEffectColorExt;
use sq_core_model::{Clip, ClipEffect, ColorEffect, CurvePoint, LUTRef, RGBCurves};
use sq_core_time::base64;

fn sv(comp: &PRComponent, id: i64) -> Option<&str> {
    comp.param(id).and_then(|p| p.static_value.as_deref())
}

fn blob(comp: &PRComponent, id: i64) -> Option<&str> {
    comp.param(id).and_then(|p| p.blob.as_deref())
}

/// Lumetri Color Wheels blob (param 47), checked 2026-10-06 on all 809 Lumetri instances of the maintainer's 16 projects
/// plus the 325 Lumetri presets shipped with Premiere 26: little-endian doubles, three per wheel (puck a, luma slider, puck
/// b), neutral (0, 0.5, 0). Premiere 25/26 writes four wheels (96 bytes; the fourth is the HDR Specular wheel, appended to
/// the three-wheel 72-byte layout of the presets). Only one instance was edited (luma 0.4977 and 0.4388 on wheels one and
/// two, pucks untouched), so the wheel order (Shadows, Midtones, Highlights, the order of Premiere's own label strings)
/// and the slider scale are inferred, and the puck pair's meaning (x/y or hue/amount) is unknown.
/// Nothing of it is applied to the grade until it is verified against a Premiere render.
struct LumetriWheels {
    values: Vec<f64>,
}

impl LumetriWheels {
    fn edited(&self, i: usize) -> bool {
        (self.values[i] - if i % 3 == 1 { 0.5 } else { 0.0 }).abs() > 1e-9
    }

    fn luma_edited(&self) -> bool {
        [1, 4, 7].iter().any(|&i| self.edited(i))
    }

    fn pucks_edited(&self) -> bool {
        [0, 2, 3, 5, 6, 8].iter().any(|&i| self.edited(i))
    }

    fn specular_edited(&self) -> bool {
        self.values.len() == 12 && (9..12).any(|i| self.edited(i))
    }
}

/// One report text for every wheel loss (the report keeps the first note per feature).
const WHEELS_DROPPED_NOTE: &str = "luma sliders decoded, not applied (scale and wheel order unverified against a Premiere render); puck colors and unreadable blobs not decoded";

enum WheelBlob {
    /// No blob (the param is missing or empty).
    Absent,
    /// A blob that is not 9 or 12 finite doubles within -1...1: the layout this decoder knows does not fit.
    Unreadable,
    Values(LumetriWheels),
}

fn wheels(b64: Option<&str>) -> WheelBlob {
    let Some(b64) = b64.filter(|s| !s.is_empty()) else { return WheelBlob::Absent };
    let Some(data) = base64::decode(b64).filter(|d| d.len() == 72 || d.len() == 96) else {
        return WheelBlob::Unreadable;
    };
    let values: Vec<f64> = data.as_chunks::<8>().0.iter().map(|c| f64::from_le_bytes(*c)).collect();
    if !values.iter().all(|v| v.is_finite() && v.abs() <= 1.0) {
        return WheelBlob::Unreadable;
    }
    WheelBlob::Values(LumetriWheels { values })
}

/// Hue Saturation Curves params: Hue vs Sat (42), Hue vs Hue (106), Hue vs Luma (108), Luma vs Sat (110), Sat vs Sat (112).
const HUE_CURVE_IDS: [i64; 5] = [42, 106, 108, 110, 112];

/// A hue curve blob (520 bytes: UInt32 axis kind, 3 = hue axis, 2 = luma/sat axis, 1 in old presets; UInt32 point count;
/// then 32 (x, y) doubles like the RGB curves) with points set. All 4,045 hue curve blobs in the maintainer's projects have
/// count 0 (flat, with stale default points after it).
fn hue_curve_edited(b64: Option<&str>) -> bool {
    let Some(data) = b64.and_then(base64::decode).filter(|d| d.len() == 520) else { return false };
    u32::from_le_bytes([data[4], data[5], data[6], data[7]]) > 0
}

/// Lumetri RGB curves blob (param 39): four blocks of 520 bytes (master, red, green, blue), each
/// `UInt32 0, UInt32 pointCount, 32 x (x, y: Double)`. `None` when the blob is missing or does not parse.
fn rgb_curves(b64: Option<&str>) -> Option<RGBCurves> {
    let data = b64.and_then(base64::decode).filter(|d| d.len() >= 4 * 520)?;
    let double = |o: usize| {
        f64::from_le_bytes([
            data[o],
            data[o + 1],
            data[o + 2],
            data[o + 3],
            data[o + 4],
            data[o + 5],
            data[o + 6],
            data[o + 7],
        ])
    };
    let block = |i: usize| -> Option<Vec<CurvePoint>> {
        let base = i * 520;
        let n = usize::from(data[base + 4]);
        if !(2..=32).contains(&n) {
            return None;
        }
        let pts: Vec<CurvePoint> = (0..n)
            .map(|k| CurvePoint { x: double(base + 8 + 16 * k) as f32, y: double(base + 16 + 16 * k) as f32 })
            .collect();
        let ok = pts.iter().all(|p| (0.0..=1.0).contains(&p.x) && (0.0..=1.0).contains(&p.y))
            && pts.windows(2).all(|w| w[0].x < w[1].x);
        ok.then_some(pts)
    };
    Some(RGBCurves { master: block(0)?, red: block(1)?, green: block(2)?, blue: block(3)? })
}

/// The user's master curve applied after `first` (the look-space curve or the diagonal): sampled at `first`'s points, the
/// user curve interpolated linearly.
fn composed(user: &[CurvePoint], first: &[CurvePoint]) -> Vec<CurvePoint> {
    if first == RGBCurves::default().master.as_slice() {
        return user.to_vec();
    }
    let eval = |x: f32| -> f32 {
        let Some(i) = user.iter().position(|p| p.x >= x) else { return user.last().map_or(x, |p| p.y) };
        if i == 0 || user[i].x == x {
            return user[i].y;
        }
        let (a, b) = (user[i - 1], user[i]);
        a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    };
    first.iter().map(|p| CurvePoint { x: p.x, y: eval(p.y) }).collect()
}

/// Lumetri look color space id (param 130) seen on every graded clip of iOS 27 Features #1. Measured with
/// Tools/PrprojFidelity: Premiere's output = (LUT output)^1.224 on all 40 graded clips (a clean power law over the whole
/// range, = 2.4 / 1.961: the look output read as gamma 2.4 and written as Rec.709 at gamma 1.961).
const LOOK_SPACE_REC709_GAMMA24: f64 = 28.0;
const LOOK_SPACE_GAMMA: f32 = 2.4 / 1.961;

/// The power law as master-curve points (denser at the dark end where it bends most).
fn look_space_curve() -> Vec<CurvePoint> {
    [0.0f32, 0.03, 0.07, 0.12, 0.2, 0.3, 0.42, 0.55, 0.7, 0.85, 1.0]
        .iter()
        .map(|&x| CurvePoint { x, y: f64::from(x).powf(f64::from(LOOK_SPACE_GAMMA)) as f32 })
        .collect()
}

/// A LUT file path stored as a NUL-terminated UTF-16LE string (Lumetri Look / Input LUT).
fn lut_path(b64: Option<&str>) -> Option<String> {
    let data = b64.and_then(base64::decode).filter(|d| d.len() >= 4)?;
    let units: Vec<u16> = utf16le_units(&data).into_iter().take_while(|&u| u != 0).collect();
    let path = String::from_utf16_lossy(&units);
    (path.starts_with('/') && path.to_lowercase().ends_with(".cube")).then_some(path)
}

impl Mapping<'_> {
    /// Premiere 25 color management shows files tagged "BT.709,…,Display-Referred" with the same power law as the look
    /// color space (gamma 2.4 read, 1.961 out). Full-range RGB graphics ("BT.709 RGB Full") pass unchanged.
    pub(super) fn is_display_referred_709(profile: Option<&str>) -> bool {
        profile.is_some_and(|p| p.starts_with("BT.709") && p.contains("Display-Referred"))
    }

    /// Puts the display-gamma curve on the clip's first Color effect (master curve, unless Lumetri already set one), or adds
    /// a Color effect holding only that curve in front of the other effects.
    pub(super) fn apply_display_gamma(&mut self, c: &mut Clip) {
        self.report.note(
            "Premiere display gamma",
            Status::Approximated,
            "BT.709 display-referred source: master curve (power 2.4/1.961)",
        );
        if let Some(i) = c.effects.iter().position(ClipEffectColorExt::is_color) {
            let mut e = c.effects[i].color_effect(None, 1);
            if e.curves.master.len() > 2 {
                return;
            }
            e.curves.master = look_space_curve();
            c.effects[i].set_color_effect(&e, None, self.ids);
        } else {
            let mut e = ColorEffect::new(1, None);
            e.curves.master = look_space_curve();
            let id = self.ids.next_id();
            c.effects.insert(0, ClipEffect::color_grade(id, &e, self.ids));
        }
    }

    /// Lumetri Creative > Sharpen (param 29, -100...100; 20 is the maintainer's usual value) as a Sharpen effect after the
    /// Color effect. Only positive values: a negative amount would be a blur. Static value; units differ slightly
    /// (approximated).
    pub(super) fn lumetri_sharpen(&mut self, comp: &PRComponent) -> Option<ClipEffect> {
        if PRParamValue::bool(sv(comp, 23)) == Some(false) {
            return None;
        }
        let amount = PRParamValue::double(sv(comp, 29)).filter(|&a| a > 0.0)?;
        let mut e = self.make_effect(ClipEffect::SHARPEN_KIND);
        e.parameters.insert(ClipEffect::SHARPEN_AMOUNT_KEY.to_string(), sq_core_model::AnimatedProperty::new(amount));
        self.report.note("Lumetri sharpen", Status::Approximated, "Lumetri Sharpen amount used as SQ Sharpen amount");
        Some(e)
    }

    pub(super) fn lumetri(&mut self, comp: &PRComponent) -> Option<ClipEffect> {
        use Status::{Approximated, Dropped, Mapped};
        if PRParamValue::bool(sv(comp, 3)) == Some(false) {
            self.report.note("AE.ADBE Lumetri", Approximated, "Basic Correction off: only Basic is read");
            return None;
        }
        let mut c = ColorEffect::new(1, None);
        let v = |id: i64| PRParamValue::double(sv(comp, id)).map(|d| d as f32);
        if let Some(x) = v(7) {
            c.basic.temperature = x;
        }
        if let Some(x) = v(8) {
            c.basic.tint = x;
        }
        if let Some(x) = v(11) {
            c.basic.exposure = x;
        }
        if let Some(x) = v(12) {
            c.basic.contrast = x;
        }
        if let Some(x) = v(13) {
            c.basic.highlights = x;
        }
        if let Some(x) = v(14) {
            c.basic.shadows = x;
        }
        if let Some(x) = v(15) {
            c.basic.whites = x;
        }
        if let Some(x) = v(16) {
            c.basic.blacks = x;
        }
        if let Some(x) = v(20) {
            c.basic.saturation = x;
        }
        if let Some(x) = v(30) {
            c.basic.vibrance = x;
        }
        // Creative (switch 23): look LUT path (24, UTF-16LE) and intensity (26), faded film (28), saturation (31).
        if PRParamValue::bool(sv(comp, 23)) != Some(false) {
            if let Some(x) = v(28) {
                c.creative.faded_film = x;
            }
            if let Some(x) = v(31) {
                c.creative.saturation = x;
            }
            if let Some(path) = lut_path(blob(comp, 24)) {
                c.creative.look = Some(LUTRef::File { path });
                if let Some(x) = v(26) {
                    c.creative.intensity = x;
                }
                self.report.note("Lumetri look LUT", Mapped, "");
                // Look color space (130): Premiere converts the LUT output from that space into the sequence space.
                if PRParamValue::double(sv(comp, 130)) == Some(LOOK_SPACE_REC709_GAMMA24) {
                    c.curves.master = look_space_curve();
                    self.report.note(
                        "Lumetri look color space",
                        Approximated,
                        "Rec.709 gamma 2.4 look output as a master curve (power 2.4/1.961)",
                    );
                }
            }
        }
        // Curves (switch 37): RGB curves blob (39) = master, red, green, blue.
        if PRParamValue::bool(sv(comp, 37)) != Some(false)
            && let Some(curves) = rgb_curves(blob(comp, 39))
            && !curves.is_neutral()
        {
            c.curves.master = composed(&curves.master, &c.curves.master);
            c.curves.red = curves.red;
            c.curves.green = curves.green;
            c.curves.blue = curves.blue;
            self.report.note("Lumetri RGB curves", Mapped, "");
        }
        // Vignette (switch 50): amount 51, midpoint 52, roundness 53, feather 54.
        if PRParamValue::bool(sv(comp, 50)) != Some(false)
            && let Some(amount) = v(51).filter(|&a| a != 0.0)
        {
            c.vignette.amount = amount;
            if let Some(x) = v(52) {
                c.vignette.midpoint = x;
            }
            if let Some(x) = v(53) {
                c.vignette.roundness = x;
            }
            if let Some(x) = v(54) {
                c.vignette.feather = x;
            }
            self.report.note("Lumetri vignette", Mapped, "");
        }
        // Color wheels (switch 46, blob 47): decoded, never applied (the design notes 2026-10-06: the luma scale and wheel
        // order rest on one sample and SQ's wheel maths is not Lumetri's). Every set wheel is counted, never silent.
        if PRParamValue::bool(sv(comp, 46)) != Some(false) {
            match wheels(blob(comp, 47)) {
                WheelBlob::Absent => {}
                WheelBlob::Unreadable => self.report.note("Lumetri color wheels", Dropped, WHEELS_DROPPED_NOTE),
                WheelBlob::Values(w) => {
                    if w.luma_edited() || w.pucks_edited() {
                        self.report.note("Lumetri color wheels", Dropped, WHEELS_DROPPED_NOTE);
                    }
                    if w.specular_edited() {
                        self.report.note("Lumetri HDR specular wheel", Dropped, "no SQ equivalent");
                    }
                }
            }
        }
        // Hue Saturation Curves: flat blobs (point count 0) are skipped; an edited curve is counted, never silent.
        if HUE_CURVE_IDS.iter().any(|&i| hue_curve_edited(blob(comp, i))) {
            self.report.note(
                "Lumetri hue saturation curves",
                Dropped,
                "point scale not decoded (no sample with an edited curve)",
            );
        }
        let keyed = if comp.params.iter().any(PRParamValue::is_animated) { ", keys dropped" } else { "" };
        self.report.note(
            "AE.ADBE Lumetri",
            Approximated,
            &format!(
                "Basic, Creative, RGB curves, vignette, look LUT (static){keyed}; wheels, hue curves and HSL not read"
            ),
        );
        let id = self.ids.next_id();
        Some(ClipEffect::color_grade(id, &c, self.ids))
    }
}
