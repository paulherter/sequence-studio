// Swift: Color/ColorSharpen.swift
//! The Sharpen row of Color Basic (the maintainer's grade: Sharpen 20). It is backed by the ordinary Sharpen effect of the
//! graded clip (`ClipEffect::SHARPEN_KIND`, Amount 0...100 in the row), so Effect Controls shows the same value and no
//! project data changes.

use sq_core_model::{AnimatedProperty, Clip, ClipEffect};
use sq_core_time::IdSource;

/// Row range: Sharpen in the Color panel runs 0...100 (the effect itself goes to 4000).
pub const SHARPEN_ROW_RANGE: (f32, f32) = (0.0, 100.0);

/// Swift `extension Clip` of ColorSharpen.swift.
pub trait ClipSharpenExt {
    /// Amount of the clip's first Sharpen effect (0 = none or neutral).
    fn sharpen_amount(&self) -> f32;
    /// Sets the Sharpen amount; adds the effect when there is none and `amount` is not 0. False when nothing changed.
    /// known limit: the value is static (a keyed Sharpen keeps its keys and is not edited here), upgrade with the Color
    /// keyframe controls when the maintainer animates Sharpen.
    fn set_sharpen_amount(&mut self, amount: f32, ids: &mut dyn IdSource) -> bool;
}

impl ClipSharpenExt for Clip {
    fn sharpen_amount(&self) -> f32 {
        let Some(e) = self.effects.iter().find(|e| e.kind == ClipEffect::SHARPEN_KIND) else {
            return 0.0;
        };
        e.parameters.get(ClipEffect::SHARPEN_AMOUNT_KEY).map(|p| p.value).unwrap_or(0.0) as f32
    }

    fn set_sharpen_amount(&mut self, amount: f32, ids: &mut dyn IdSource) -> bool {
        let v = f64::from(amount.max(SHARPEN_ROW_RANGE.0).min(SHARPEN_ROW_RANGE.1));
        if let Some(i) = self.effects.iter().position(|e| e.kind == ClipEffect::SHARPEN_KIND) {
            if self.effects[i].parameters.get(ClipEffect::SHARPEN_AMOUNT_KEY).map(|p| p.value) == Some(v) {
                return false;
            }
            self.effects[i].parameters.insert(ClipEffect::SHARPEN_AMOUNT_KEY.to_string(), AnimatedProperty::new(v));
            return true;
        }
        if v == 0.0 {
            return false;
        }
        let Some(mut e) = ClipEffect::make(ids.next_id(), ClipEffect::SHARPEN_KIND) else {
            return false;
        };
        e.parameters.insert(ClipEffect::SHARPEN_AMOUNT_KEY.to_string(), AnimatedProperty::new(v));
        self.effects.push(e);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::{Id, SequentialIds, Time, TimeRange};

    fn clip() -> Clip {
        Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::ZERO),
            Time::ZERO,
        )
    }

    #[test]
    fn sharpen_amount_is_zero_without_the_effect() {
        assert_eq!(clip().sharpen_amount(), 0.0);
    }

    #[test]
    fn first_nonzero_value_adds_the_effect_and_zero_adds_nothing() {
        let mut ids = SequentialIds::default();
        let mut c = clip();
        assert!(!c.set_sharpen_amount(0.0, &mut ids));
        assert!(c.effects.is_empty());
        assert!(c.set_sharpen_amount(20.0, &mut ids));
        assert_eq!(c.sharpen_amount(), 20.0);
        assert!(!c.set_sharpen_amount(20.0, &mut ids));
        assert!(c.set_sharpen_amount(500.0, &mut ids));
        assert_eq!(c.sharpen_amount(), 100.0);
    }
}
