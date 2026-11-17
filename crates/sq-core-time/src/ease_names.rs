// SPDX-License-Identifier: GPL-3.0-or-later
//! The one easing vocabulary of the app (docs/VOCABULARY.md): every menu, pop-up, chip and tooltip that names a
//! curve reads it here. Display only: stored names (`EasingCurve::name`) never change. Ported from `EaseNames`.

use crate::EasingCurve;

/// Display names, Title Case. Order of any list: Linear, Ease In & Out, Ease In, Ease Out, Hold (2026-11-13, redesign #35), extra presets, Custom last.
pub mod ease_name {
    /// Constant speed.
    pub const STEADY: &str = "Linear";
    /// Slow at both keys.
    pub const SMOOTH: &str = "Ease In & Out";
    /// Slow arriving at the right key.
    pub const SMOOTH_IN: &str = "Ease In";
    /// Slow leaving the left key.
    pub const SMOOTH_OUT: &str = "Ease Out";
    /// Steps.
    pub const HOLD: &str = "Hold";
    /// The mirrored hold of a clip key (the next key's value right after the key); only listed for clip keyframes.
    pub const HOLD_AHEAD: &str = "Hold Ahead";
    /// Fast leaving, slow arriving.
    pub const FAST_START: &str = "Fast Start";
    /// Slow leaving, fast arriving.
    pub const FAST_END: &str = "Fast End";
    /// Classic bezier with 16.7 % influence.
    pub const GENTLE: &str = "Gentle";
    /// Arrival with 100 % influence.
    pub const SMOOTH_IN_100: &str = "Ease In 100%";
    /// Departure with 100 % influence.
    pub const SMOOTH_OUT_100: &str = "Ease Out 100%";
    /// Brisk leave, gentle settle.
    pub const SOFT_LANDING: &str = "Soft Landing";
    /// A user's own curve.
    pub const CUSTOM: &str = "Custom";
    /// Menu item that opens the curve editor.
    pub const CUSTOM_MENU: &str = "Custom\u{2026}";
    /// The keyframe right-click list.
    pub const KEYFRAME_MENU: [&str; 5] = [STEADY, SMOOTH, SMOOTH_IN, SMOOTH_OUT, HOLD];
}

impl EasingCurve {
    /// The name shown for this curve: the own name of a built-in (by id, so curves stored under an older name read
    /// the same), else the name the user gave it.
    pub fn display_name(&self) -> &str {
        use ease_name::*;
        let named: [(EasingCurve, &str); 11] = [
            (Self::linear(), STEADY),
            (Self::hold(), HOLD),
            (Self::ease_in_out(), SMOOTH),
            (Self::ease_in(), SMOOTH_IN),
            (Self::ease_out(), SMOOTH_OUT),
            (Self::fast_start(), FAST_START),
            (Self::fast_end(), FAST_END),
            (Self::premiere_default(), GENTLE),
            (Self::ease_out_100(), SMOOTH_IN_100),
            (Self::ease_in_100(), SMOOTH_OUT_100),
            (Self::soft_landing(), SOFT_LANDING),
        ];
        named.iter().find(|(c, _)| c.id == self.id).map_or(self.name.as_str(), |(_, n)| n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EaseHandle, Id, Interpolation};

    #[test]
    fn every_built_in_has_an_own_name() {
        let built_ins = EasingCurve::built_ins();
        let names: Vec<&str> = built_ins.iter().map(EasingCurve::display_name).collect();
        assert_eq!(
            names,
            [
                "Linear",
                "Hold",
                "Ease In & Out",
                "Ease In",
                "Ease Out",
                "Fast Start",
                "Fast End",
                "Gentle",
                "Ease In 100%",
                "Ease Out 100%",
                "Soft Landing"
            ]
        );
        let mut unique = names.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), names.len());
        for n in names {
            assert!(!n.contains("33") && !n.contains("Steady") && !n.contains("Smooth"), "{n}");
        }
    }

    #[test]
    fn display_names_never_change_what_is_stored() {
        assert_eq!(EasingCurve::ease_in_out().name, "Ease-in-out 33%");
        assert_eq!(EasingCurve::ease_in().name, "Ease-in 33%");
        // A curve stored under its old name still shows the own name (matched by built-in id).
        let json = serde_json::to_string(&EasingCurve::ease_out()).unwrap_or_default();
        assert!(json.contains("Ease-out 33%"));
        let back: EasingCurve = serde_json::from_str(&json).unwrap_or_else(|_| EasingCurve::linear());
        assert_eq!(back.display_name(), "Ease Out");
    }

    #[test]
    fn a_user_curve_keeps_its_name() {
        let own = EasingCurve::new(
            Id::NIL,
            "My ease-y curve".into(),
            Interpolation::Bezier,
            EaseHandle::LINEAR,
            EaseHandle::LINEAR,
        );
        assert_eq!(own.display_name(), "My ease-y curve");
        assert_eq!(ease_name::KEYFRAME_MENU, ["Linear", "Ease In & Out", "Ease In", "Ease Out", "Hold"]);
    }
}
