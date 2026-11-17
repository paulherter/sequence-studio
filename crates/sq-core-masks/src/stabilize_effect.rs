// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizeEffect.swift (`Clip.addStabilizer` and `EffectTransformStage.stabilizeSpec` wait on the effects crate,
// see NOTES.md)
//! Stabilize as an effect. The `stabilize` effect is offered in the Effects panel under Video > Transform and dragged onto a
//! clip like any other effect. Its Method picks the engine:
//!   Standard: the picture analysis measures the shake, `Stabilizer` plans the correction and writes it as the effect's
//!             stage keys (Position / Rotation / Scale), so playback and export render the same keys.
//!   Gyroflow: the camera's own gyro data, undistorted and stabilized by gyroflow_core in its own render pass. Its settings
//!             live on the effect; the Standard stage keys are ignored while it is chosen.
//! A Gyroflow Stabilizer is version gated (v52): an older build would re-plan it as Standard.

use crate::stabilizer::{Stabilizer, StabilizerEdgeFill};
use sq_core_model::{Clip, ClipEffect, Project, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// Kind of the Stabilizer effect.
pub const STABILIZE_KIND: &str = "stabilize";
/// Stored parameter key (never rename).
pub const STABILIZE_METHOD_KEY: &str = "stabilizeMethod";
/// Gyroflow parameter key.
pub const GYRO_SMOOTHNESS_KEY: &str = "gyroSmoothness";
/// Gyroflow parameter key.
pub const GYRO_ZOOM_LIMIT_KEY: &str = "gyroZoomLimit";
/// Gyroflow parameter key.
pub const GYRO_ROLLING_SHUTTER_KEY: &str = "gyroRollingShutter";
/// Gyroflow parameter key.
pub const GYRO_HORIZON_LOCK_KEY: &str = "gyroHorizonLock";
/// Gyroflow parameter key (v59).
pub const GYRO_FIELD_OF_VIEW_KEY: &str = "gyroFieldOfView";
/// Gyroflow parameter key (v59).
pub const GYRO_LENS_CORRECTION_KEY: &str = "gyroLensCorrection";
/// Gyroflow parameter key (v59).
pub const GYRO_SYNC_OFFSET_KEY: &str = "gyroSyncOffset";
// shortcut: the stage keys are copied because the transform-stage constants live in the effects crate; use its
// constants when that crate exists.
const STAGE_POSITION_X_KEY: &str = "positionX";
const STAGE_SCALE_KEY: &str = "scale";

/// Which engine a Stabilizer uses. Stored as the index of the Method choice (never reorder).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StabilizerMethod {
    /// Picture analysis.
    Standard = 0,
    /// Camera gyro data.
    Gyroflow = 1,
}

impl StabilizerMethod {
    /// Both methods in menu order.
    pub const ALL: [StabilizerMethod; 2] = [StabilizerMethod::Standard, StabilizerMethod::Gyroflow];

    /// Display name.
    pub fn title(self) -> &'static str {
        if self == StabilizerMethod::Standard { "Standard" } else { "Gyroflow" }
    }

    /// The stored index.
    pub fn from_raw(i: i64) -> Option<StabilizerMethod> {
        match i {
            0 => Some(StabilizerMethod::Standard),
            1 => Some(StabilizerMethod::Gyroflow),
            _ => None,
        }
    }

    /// The parameter rows Effect Controls shows for this method, in order (Method first).
    pub fn visible_keys(self) -> Vec<&'static str> {
        match self {
            StabilizerMethod::Standard => vec![
                STABILIZE_METHOD_KEY,
                Stabilizer::MODE_KEY,
                Stabilizer::STRENGTH_KEY,
                Stabilizer::SMOOTHNESS_KEY,
                Stabilizer::MAX_CROP_KEY,
                Stabilizer::EDGE_FILL_KEY,
                Stabilizer::ROLLING_SHUTTER_KEY,
                Stabilizer::ROLLING_SHUTTER_STRENGTH_KEY,
            ],
            StabilizerMethod::Gyroflow => vec![
                STABILIZE_METHOD_KEY,
                GYRO_SMOOTHNESS_KEY,
                GYRO_ZOOM_LIMIT_KEY,
                GYRO_FIELD_OF_VIEW_KEY,
                GYRO_LENS_CORRECTION_KEY,
                GYRO_ROLLING_SHUTTER_KEY,
                GYRO_HORIZON_LOCK_KEY,
                GYRO_SYNC_OFFSET_KEY,
            ],
        }
    }
}

/// The Gyroflow settings stored on a Stabilizer (names and ranges of the Gyroflow plugins).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GyroflowOptions {
    /// Smoothness, % (1...100; Gyroflow's 0.001...1 range, its default is 50).
    pub smoothness: f64,
    /// Most the adaptive zoom may scale up, % (100...300).
    pub zoom_limit: f64,
    /// Rolling-shutter correction (readout time from the lens profile).
    pub rolling_shutter: bool,
    /// Horizon lock amount, % (0...100).
    pub horizon_lock: f64,
    /// Field of view of the stabilized frame, % (10...300; 100 = as framed).
    pub field_of_view: f64,
    /// How much of the lens profile's distortion is undone, % (0...100; 0 keeps the lens look, 100 = straight lines).
    pub lens_correction: f64,
    /// Gyro data shifted against the picture, ms (-5000...5000; the gyro is looked up at `frame time - offset`, so positive
    /// = an EARLIER gyro sample is used). Added to the offsets the file brings.
    pub sync_offset_ms: f64,
}

impl Default for GyroflowOptions {
    fn default() -> Self {
        GyroflowOptions {
            smoothness: 50.0,
            zoom_limit: 130.0,
            rolling_shutter: true,
            horizon_lock: 0.0,
            field_of_view: 100.0,
            lens_correction: 100.0,
            sync_offset_ms: 0.0,
        }
    }
}

impl GyroflowOptions {
    /// Field of View, Lens Correction or Sync Offset differ from their defaults (a v58 build would ignore them: v59 gate).
    pub fn changes_lens_or_sync(&self) -> bool {
        let d = GyroflowOptions::default();
        self.field_of_view != d.field_of_view
            || self.lens_correction != d.lens_correction
            || self.sync_offset_ms != d.sync_offset_ms
    }

    /// The settings stored on a Stabilizer effect (defaults for missing values).
    pub fn from_effect(e: &ClipEffect) -> GyroflowOptions {
        let mut o = GyroflowOptions::default();
        let v = |k: &str| e.parameters.get(k).map(|p| p.value).filter(|x| x.is_finite());
        if let Some(s) = v(GYRO_SMOOTHNESS_KEY) {
            o.smoothness = s.clamp(1.0, 100.0);
        }
        if let Some(z) = v(GYRO_ZOOM_LIMIT_KEY) {
            o.zoom_limit = z.clamp(100.0, 300.0);
        }
        if let Some(r) = v(GYRO_ROLLING_SHUTTER_KEY) {
            o.rolling_shutter = r >= 0.5;
        }
        if let Some(h) = v(GYRO_HORIZON_LOCK_KEY) {
            o.horizon_lock = h.clamp(0.0, 100.0);
        }
        if let Some(f) = v(GYRO_FIELD_OF_VIEW_KEY) {
            o.field_of_view = f.clamp(10.0, 300.0);
        }
        if let Some(l) = v(GYRO_LENS_CORRECTION_KEY) {
            o.lens_correction = l.clamp(0.0, 100.0);
        }
        if let Some(s) = v(GYRO_SYNC_OFFSET_KEY) {
            o.sync_offset_ms = s.clamp(-5000.0, 5000.0);
        }
        o
    }

    /// A source frame time as the gyro engine takes it: microseconds from the start of the file, rounded to nearest.
    pub fn timestamp_microseconds(t: Time) -> i64 {
        let n = i128::from(t.value()) * 1_000_000;
        let d = i128::from(t.timescale());
        let q = if n >= 0 { (2 * n + d) / (2 * d) } else { -((-2 * n + d) / (2 * d)) };
        q.clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64
    }
}

/// Logic Swift keeps on `ClipEffect` in `StabilizeEffect.swift` and `Stabilizer.swift`.
pub trait ClipEffectStabilizeExt {
    /// The Stabilizer's engine (Standard when missing or out of range: Stabilizers written before v52 are Standard).
    fn stabilize_method(&self) -> StabilizerMethod;
    /// A Stabilizer that already holds its correction: Standard with an analyzed range or stage keys.
    fn stabilize_is_analysed(&self) -> bool;
    /// What fills the border a Standard Stabilizer's Crop Limit leaves open (Zoom when missing or out of range).
    fn stabilize_edge_fill(&self) -> StabilizerEdgeFill;
    /// The Stabilizer's correction is a picture warp with a filled border instead of a clip transform.
    #[doc(hidden)]
    fn stabilize_fills_edges(&self) -> bool;
    /// The source range (seconds) a Stabilizer's analysis covered; `None` for a Stabilizer written before it was recorded.
    fn stabilize_analysed_range(&self) -> Option<(f64, f64)>;
    /// The Stabilizer's analysis no longer covers `needed` (source range the clip shows now): trimmed longer, so the new
    /// frames would hold the last correction. `frame_duration` is the tolerance.
    fn stabilize_needs_analysis(&self, needed: TimeRange, frame_duration: Time) -> bool;
}

impl ClipEffectStabilizeExt for ClipEffect {
    fn stabilize_method(&self) -> StabilizerMethod {
        let Some(v) = self.parameters.get(STABILIZE_METHOD_KEY).map(|p| p.value).filter(|v| v.is_finite()) else {
            return StabilizerMethod::Standard;
        };
        StabilizerMethod::from_raw(v.round() as i64).unwrap_or(StabilizerMethod::Standard)
    }

    fn stabilize_is_analysed(&self) -> bool {
        if self.kind != STABILIZE_KIND || self.stabilize_method() != StabilizerMethod::Standard {
            return false;
        }
        self.stabilize_analysed_range().is_some()
            || self.parameters.contains_key(STAGE_POSITION_X_KEY)
            || self.parameters.contains_key(STAGE_SCALE_KEY)
    }

    fn stabilize_edge_fill(&self) -> StabilizerEdgeFill {
        if self.kind != STABILIZE_KIND {
            return StabilizerEdgeFill::Zoom;
        }
        let Some(v) = self.parameters.get(Stabilizer::EDGE_FILL_KEY).map(|p| p.value).filter(|v| v.is_finite()) else {
            return StabilizerEdgeFill::Zoom;
        };
        StabilizerEdgeFill::from_raw(v.round() as i64).unwrap_or(StabilizerEdgeFill::Zoom)
    }

    fn stabilize_fills_edges(&self) -> bool {
        self.enabled
            && self.stabilize_method() == StabilizerMethod::Standard
            && self.stabilize_edge_fill() != StabilizerEdgeFill::Zoom
    }

    fn stabilize_analysed_range(&self) -> Option<(f64, f64)> {
        if self.kind != STABILIZE_KIND {
            return None;
        }
        let a = self.parameters.get(Stabilizer::FROM_KEY)?.value;
        let b = self.parameters.get(Stabilizer::TO_KEY)?.value;
        Some((a, b))
    }

    fn stabilize_needs_analysis(&self, needed: TimeRange, fd: Time) -> bool {
        let Some(r) = self.stabilize_analysed_range() else { return false };
        let tol = 2.0 * fd.value() as f64 / fd.timescale() as f64; // the range ends one frame past the last frame shown
        let lo = needed.start.value() as f64 / needed.start.timescale() as f64;
        let hi = needed.end().value() as f64 / needed.end().timescale() as f64;
        lo < r.0 - tol || hi > r.1 + tol
    }
}

/// Logic Swift keeps on `Clip` in `StabilizeEffect.swift`.
pub trait ClipStabilizeExt {
    /// Clips whose picture moves (media video, not a still, hold or nested sequence): what Stabilize can analyze.
    fn can_stabilize(&self) -> bool;
    /// Options of the clip's enabled Gyroflow Stabilizer (`None`: none, Standard, or switched off).
    fn gyroflow_options(&self) -> Option<GyroflowOptions>;
    /// The clip's Stabilizer, if any.
    fn stabilizer_id(&self) -> Option<Id>;
}

impl ClipStabilizeExt for Clip {
    fn can_stabilize(&self) -> bool {
        self.kind == TrackKind::Video
            && !self.is_generator()
            && self.sequence.is_none()
            && !self.is_still
            && self.hold_frame.is_none()
    }

    fn gyroflow_options(&self) -> Option<GyroflowOptions> {
        if !self.can_stabilize() {
            return None;
        }
        let e = self.effects.iter().find(|e| e.kind == STABILIZE_KIND)?;
        (e.enabled && e.stabilize_method() == StabilizerMethod::Gyroflow).then(|| GyroflowOptions::from_effect(e))
    }

    fn stabilizer_id(&self) -> Option<Id> {
        self.effects.iter().find(|e| e.kind == STABILIZE_KIND).map(|e| e.id)
    }
}

/// Logic Swift keeps on `Project` in `StabilizeEffect.swift`.
pub trait ProjectStabilizeExt {
    /// Any clip carries a Gyroflow Stabilizer: the file must be v52.
    fn contains_gyroflow_stabilizers(&self) -> bool;
}

impl ProjectStabilizeExt for Project {
    fn contains_gyroflow_stabilizers(&self) -> bool {
        self.timelines.iter().any(|t| {
            t.tracks.iter().any(|tr| {
                tr.clips().iter().any(|c| {
                    c.effects
                        .iter()
                        .any(|e| e.kind == STABILIZE_KIND && e.stabilize_method() == StabilizerMethod::Gyroflow)
                })
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::AnimatedProperty;

    fn effect() -> ClipEffect {
        ClipEffect::new(Id::from_u128(1), STABILIZE_KIND)
    }

    #[test]
    fn the_method_defaults_to_standard_and_reads_the_stored_index() {
        let mut e = effect();
        assert_eq!(e.stabilize_method(), StabilizerMethod::Standard);
        e.parameters.insert(STABILIZE_METHOD_KEY.into(), AnimatedProperty::new(1.0));
        assert_eq!(e.stabilize_method(), StabilizerMethod::Gyroflow);
        e.parameters.insert(STABILIZE_METHOD_KEY.into(), AnimatedProperty::new(9.0));
        assert_eq!(e.stabilize_method(), StabilizerMethod::Standard);
    }

    #[test]
    fn gyroflow_options_are_clamped_and_the_timestamp_rounds_to_nearest() {
        let mut e = effect();
        e.parameters.insert(GYRO_SMOOTHNESS_KEY.into(), AnimatedProperty::new(500.0));
        e.parameters.insert(GYRO_SYNC_OFFSET_KEY.into(), AnimatedProperty::new(-9000.0));
        e.parameters.insert(GYRO_ROLLING_SHUTTER_KEY.into(), AnimatedProperty::new(0.0));
        let o = GyroflowOptions::from_effect(&e);
        assert!(o.smoothness == 100.0 && o.sync_offset_ms == -5000.0 && !o.rolling_shutter);
        assert!(o.changes_lens_or_sync());
        assert!(!GyroflowOptions::default().changes_lens_or_sync());
        assert_eq!(GyroflowOptions::timestamp_microseconds(Time::new(1, 3)), 333_333);
        assert_eq!(GyroflowOptions::timestamp_microseconds(Time::new(-1, 3)), -333_333);
        assert_eq!(GyroflowOptions::timestamp_microseconds(Time::new(2, 3)), 666_667);
    }

    #[test]
    fn visible_keys_follow_the_method() {
        assert_eq!(StabilizerMethod::Standard.visible_keys().len(), 8);
        assert!(!StabilizerMethod::Gyroflow.visible_keys().contains(&Stabilizer::ROLLING_SHUTTER_KEY));
        let std_keys = StabilizerMethod::Standard.visible_keys();
        assert_eq!(&std_keys[6..], &[Stabilizer::ROLLING_SHUTTER_KEY, Stabilizer::ROLLING_SHUTTER_STRENGTH_KEY]);
        assert_eq!(StabilizerMethod::ALL.map(|m| m.title()), ["Standard", "Gyroflow"]);
    }

    #[test]
    fn analysed_range_and_trim_check() {
        let mut e = effect();
        assert!(!e.stabilize_is_analysed() && e.stabilize_analysed_range().is_none());
        e.parameters.insert(Stabilizer::FROM_KEY.into(), AnimatedProperty::new(2.0));
        e.parameters.insert(Stabilizer::TO_KEY.into(), AnimatedProperty::new(8.0));
        assert!(e.stabilize_is_analysed());
        let fd = Time::new(1, 30);
        assert!(!e.stabilize_needs_analysis(TimeRange::new(Time::new(3, 1), Time::new(4, 1)), fd));
        assert!(e.stabilize_needs_analysis(TimeRange::new(Time::new(1, 1), Time::new(4, 1)), fd));
        assert!(e.stabilize_needs_analysis(TimeRange::new(Time::new(5, 1), Time::new(5, 1)), fd));
        e.parameters.insert(Stabilizer::EDGE_FILL_KEY.into(), AnimatedProperty::new(2.0));
        assert_eq!(e.stabilize_edge_fill(), StabilizerEdgeFill::Blur);
        assert!(e.stabilize_fills_edges());
    }
}
