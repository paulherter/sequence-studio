// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: InterfaceScale.swift
//
// Preferences > Interface Size as stored (`sq.ui.scale`): the steps and the clamp, without UI. The settings store is the
// caller's: `load` takes the stored value, `store` returns the value to write.

/// The settings key.
pub const DEFAULTS_KEY: &str = "sq.ui.scale";

/// Posted after a store (the Mac relayout rebuilds its windows on it).
pub const DID_CHANGE: &str = "sq.uiScaleDidChange";

/// The allowed factors, one step per Cmd+Plus / Cmd+Minus.
pub const STEPS: [f64; 6] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5];

/// The factor inside the allowed range; 1 for a value that is not finite.
pub fn clamp(v: f64) -> f64 {
    if !v.is_finite() {
        return 1.0;
    }
    v.max(STEPS[0]).min(STEPS[STEPS.len() - 1])
}

/// The next step above (`delta` > 0) or below (`delta` < 0) `value`; stays at the ends.
pub fn stepped(value: f64, delta: i64) -> f64 {
    let v = clamp(value);
    if delta > 0 {
        return STEPS.iter().copied().find(|s| *s > v + 1e-9).unwrap_or(STEPS[STEPS.len() - 1]);
    }
    if delta < 0 {
        return STEPS.iter().copied().rev().find(|s| *s < v - 1e-9).unwrap_or(STEPS[0]);
    }
    v
}

/// The factor for a stored value (`None` = nothing stored: 1).
pub fn load(stored: Option<f64>) -> f64 {
    stored.map_or(1.0, clamp)
}

/// The value to write for `value` (a non-finite value stores 1).
pub fn store(value: f64) -> f64 {
    clamp(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_keeps_the_range_and_repairs_garbage() {
        assert_eq!(clamp(0.1), 0.8);
        assert_eq!(clamp(9.0), 1.5);
        assert_eq!(clamp(f64::NAN), 1.0);
        assert_eq!(clamp(f64::INFINITY), 1.0);
        assert_eq!(clamp(1.1), 1.1);
    }

    #[test]
    fn stepping_moves_one_step_and_stays_at_the_ends() {
        assert_eq!(stepped(1.0, 1), 1.1);
        assert_eq!(stepped(1.0, -1), 0.9);
        assert_eq!(stepped(1.5, 1), 1.5);
        assert_eq!(stepped(0.8, -1), 0.8);
        assert_eq!(stepped(1.05, 0), 1.05);
    }

    #[test]
    fn load_and_store_clamp() {
        assert_eq!(load(None), 1.0);
        assert_eq!(load(Some(3.0)), 1.5);
        assert_eq!(store(f64::NAN), 1.0);
    }
}
