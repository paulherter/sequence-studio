// Swift: PunchInCuts.swift
//! "Punch In Cuts": alternating or cycling zoom levels over consecutive shots, written as the same marked Punch In stage
//! as Shift+P (one punch system: toggle and remove work alike), so no file format change.

use crate::punch_in::PunchIn;
use sq_core_model::{AnimatedProperty, ClipEffect, EditError, Timeline, TrackKind};
use sq_core_time::ease_names::ease_name;
use sq_core_time::{EaseSide, EasingCurve, Id, IdSource, Keyframe, Time};

/// How the levels are laid over the shots.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PunchInPattern {
    /// 100% and the smallest selected level above it, alternating.
    Alternate,
    /// The selected levels ascending, cycling.
    Cyclic,
}

/// How a shot reaches its level.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PunchInEase {
    /// Hard cut to the level (static scale).
    Hold,
    /// Constant-speed ramp.
    Linear,
    /// Smooth ramp.
    EaseInOut,
    /// Fast start, slow end.
    FastStart,
}

impl PunchInEase {
    /// Every choice.
    pub const ALL: [PunchInEase; 4] = [Self::Hold, Self::Linear, Self::EaseInOut, Self::FastStart];

    /// Display name.
    pub fn title(self) -> &'static str {
        match self {
            Self::Hold => ease_name::HOLD,
            Self::Linear => ease_name::STEADY,
            Self::EaseInOut => ease_name::SMOOTH,
            Self::FastStart => ease_name::FAST_START,
        }
    }
}

/// The zoom pattern the sheet sets.
#[derive(Clone, Debug, PartialEq)]
pub struct PunchInCutsOptions {
    /// Selected levels in percent.
    pub scales: Vec<f64>,
    /// How a shot reaches its level.
    pub ease: PunchInEase,
    /// Level order.
    pub pattern: PunchInPattern,
    /// Length of the eased ramp from the previous shot's level (ignored for `Hold`).
    pub ramp_frames: i64,
}

impl PunchInCutsOptions {
    /// Percent choices offered by the sheet.
    pub const SCALE_CHOICES: [f64; 4] = [100.0, 110.0, 115.0, 126.5];

    /// Options with the sheet's defaults: hold, alternate, 6 ramp frames.
    pub fn new(scales: Vec<f64>) -> PunchInCutsOptions {
        PunchInCutsOptions { scales, ease: PunchInEase::Hold, pattern: PunchInPattern::Alternate, ramp_frames: 6 }
    }

    /// Zoom factors in play order: alternate = 100% and the smallest selected level above it; cyclic = the selected
    /// levels ascending.
    pub fn levels(&self) -> Vec<f64> {
        let mut sorted: Vec<f64> = self.scales.iter().copied().filter(|s| *s > 0.0).collect();
        sorted.sort_by(f64::total_cmp);
        sorted.dedup();
        match self.pattern {
            PunchInPattern::Alternate => match sorted.iter().find(|s| **s > 100.0) {
                Some(top) => vec![1.0, top / 100.0],
                None => Vec::new(),
            },
            PunchInPattern::Cyclic => {
                if sorted.len() < 2 {
                    Vec::new()
                } else {
                    sorted.iter().map(|s| s / 100.0).collect()
                }
            }
        }
    }
}

/// `extension Timeline` of `PunchInCuts.swift`.
pub trait TimelinePunchInCutsExt {
    /// Applies the zoom pattern to the video clips `ids`, ordered by start (one atomic edit). Each zoomed clip gets the
    /// Punch In stage (marker `PunchIn::MARKER_KEY`, Transform stage, multiplies onto Motion); an existing one is updated,
    /// never stacked. `Hold` is a static scale; an eased `ease` ramps from the previous shot's level over `ramp_frames` at
    /// the clip's head. Motion keys are left alone (old projects that used them keep rendering). Returns the clips changed.
    /// `ClipNotFound`, `WrongTrackKind` (non-video or generator) and `TrackLocked`; nothing changes then.
    fn punch_in_cuts(
        &mut self,
        ids: &[Id],
        options: &PunchInCutsOptions,
        key_ids: &mut dyn IdSource,
    ) -> Result<usize, EditError>;
}

impl TimelinePunchInCutsExt for Timeline {
    fn punch_in_cuts(
        &mut self,
        ids: &[Id],
        options: &PunchInCutsOptions,
        key_ids: &mut dyn IdSource,
    ) -> Result<usize, EditError> {
        let mut work = self.clone();
        let mut found: Vec<(usize, sq_core_model::Clip)> = Vec::new();
        for id in ids {
            let m = work.find(*id).ok_or(EditError::ClipNotFound)?;
            if m.clip.kind != TrackKind::Video || m.clip.is_generator() {
                return Err(EditError::WrongTrackKind);
            }
            if work.tracks[m.track].is_locked {
                return Err(EditError::TrackLocked);
            }
            found.push((m.track, m.clip));
        }
        let levels = options.levels();
        if levels.is_empty() || found.is_empty() {
            return Ok(0);
        }
        found.sort_by_key(|f| f.1.start);
        let fd = self.frame_duration();
        let mut changed = 0;
        for (i, (ti, mut c)) in found.into_iter().enumerate() {
            let factor = levels[i % levels.len()];
            let prev = if i == 0 { factor } else { levels[(i - 1) % levels.len()] };
            let hold = options.ease == PunchInEase::Hold || prev == factor || options.ramp_frames <= 0;
            let prop = if hold {
                if factor == 1.0 {
                    // A 100% shot carries no stage: an earlier run's Punch In stage comes off, nothing else is touched.
                    let before = c.effects.len();
                    let id = c.id;
                    c.effects.retain(|e| !PunchIn::is_punch_in(e, id));
                    if c.effects.len() != before {
                        work.tracks[ti].replace(c);
                        changed += 1;
                    }
                    continue;
                }
                // Zoomed by the old Punch In Cuts (static Motion scale already at this level): do not stack 1.15 x 1.15.
                let motion = &c.animation.scale;
                if !motion.is_animated()
                    && (motion.value.x - factor).abs() < 1e-9
                    && (motion.value.y - factor).abs() < 1e-9
                {
                    continue;
                }
                AnimatedProperty::new(100.0 * factor)
            } else {
                let ramp = (fd * options.ramp_frames).min(c.duration());
                let mut a = Keyframe::new(key_ids.next_id(), Time::ZERO, 100.0 * prev);
                let mut b = Keyframe::new(key_ids.next_id(), ramp, 100.0 * factor);
                let curve = match options.ease {
                    PunchInEase::Hold | PunchInEase::Linear => None,
                    PunchInEase::EaseInOut => Some(EasingCurve::ease_in_out()),
                    PunchInEase::FastStart => Some(EasingCurve::fast_start()),
                };
                if let Some(curve) = curve {
                    curve.apply(&mut a, EaseSide::Both);
                    curve.apply(&mut b, EaseSide::Both);
                }
                let mut prop = AnimatedProperty::new(100.0 * factor);
                prop.track.insert(a);
                prop.track.insert(b);
                prop
            };
            let id = c.id;
            if let Some(e) = c.effects.iter_mut().find(|e| PunchIn::is_punch_in(e, id)) {
                e.parameters.insert(ClipEffect::STAGE_SCALE_KEY.to_string(), prop);
            } else if let Some(e) = PunchIn::make_stage(id, prop) {
                c.effects.push(e);
            } else {
                continue;
            }
            work.tracks[ti].replace(c);
            changed += 1;
        }
        *self = work;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alternate_uses_100_and_the_smallest_level_above() {
        let o = PunchInCutsOptions::new(vec![126.5, 110.0, 100.0, 115.0]);
        assert_eq!(o.levels(), vec![1.0, 1.1]);
        assert!(PunchInCutsOptions::new(vec![100.0]).levels().is_empty());
    }

    #[test]
    fn cyclic_needs_two_levels_and_sorts_them() {
        let mut o = PunchInCutsOptions::new(vec![115.0, 100.0, 115.0]);
        o.pattern = PunchInPattern::Cyclic;
        assert_eq!(o.levels(), vec![1.0, 1.15]);
        o.scales = vec![110.0, -5.0, 0.0];
        assert!(o.levels().is_empty());
    }

    #[test]
    fn ease_titles_use_the_shared_names() {
        assert_eq!(PunchInEase::Hold.title(), "Hold");
        assert_eq!(PunchInEase::EaseInOut.title(), "Ease In & Out");
    }
}
