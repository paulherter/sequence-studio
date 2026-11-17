// Swift: EasingMenuSpec.swift
//! Pure description of the easing menu.

use sq_core_time::{EaseSide, EasingCurve, EasingLibrary};

/// One entry of the easing menu.
#[derive(Clone, Debug, PartialEq)]
pub enum EasingMenuEntry {
    Header(String),
    Side { side: EaseSide, title: String, checked: bool },
    Curve { curve: EasingCurve, enabled: bool },
    Separator,
    SaveCurve { enabled: bool },
}

/// Pure description of the easing menu (testable without AppKit).
#[derive(Clone, Debug, PartialEq)]
pub struct EasingMenuSpec {
    pub entries: Vec<EasingMenuEntry>,
}

impl EasingMenuSpec {
    /// Board order of the built-in curves (menus.txt "Inline keyframe graph"): the 33 % curves are the Smooth family.
    pub fn ease_order() -> Vec<EasingCurve> {
        vec![
            EasingCurve::linear(),
            EasingCurve::ease_in_out(),
            EasingCurve::ease_in(),
            EasingCurve::ease_out(),
            EasingCurve::hold(),
            EasingCurve::fast_start(),
            EasingCurve::fast_end(),
            EasingCurve::premiere_default(),
            EasingCurve::ease_out_100(),
            EasingCurve::ease_in_100(),
        ]
    }

    /// Menu wording of a curve: the app's one easing vocabulary (`EaseName`).
    pub fn title(c: &EasingCurve) -> String {
        c.display_name().to_string()
    }

    pub fn new(library: &EasingLibrary, side: EaseSide, has_selection: bool) -> EasingMenuSpec {
        let side_entry =
            |s: EaseSide, title: &str| EasingMenuEntry::Side { side: s, title: title.to_string(), checked: side == s };
        let mut e = vec![EasingMenuEntry::Header("Apply to".to_string())];
        e.push(side_entry(EaseSide::Both, "Both sides"));
        e.push(side_entry(EaseSide::In, "Incoming only"));
        e.push(side_entry(EaseSide::Out, "Outgoing only"));
        e.push(EasingMenuEntry::Separator);
        e.push(EasingMenuEntry::Header("Ease".to_string()));
        for c in Self::ease_order() {
            e.push(EasingMenuEntry::Curve { curve: c, enabled: has_selection });
        }
        if !library.user_curves().is_empty() {
            e.push(EasingMenuEntry::Separator);
            e.push(EasingMenuEntry::Header("Presets".to_string()));
            for c in library.user_curves() {
                e.push(EasingMenuEntry::Curve { curve: c.clone(), enabled: has_selection });
            }
        }
        e.push(EasingMenuEntry::Separator);
        e.push(EasingMenuEntry::SaveCurve { enabled: has_selection });
        EasingMenuSpec { entries: e }
    }

    pub fn curve_names(&self) -> Vec<String> {
        self.entries
            .iter()
            .filter_map(|e| if let EasingMenuEntry::Curve { curve, .. } = e { Some(curve.name.clone()) } else { None })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_lists_sides_built_ins_and_save() {
        let spec = EasingMenuSpec::new(&EasingLibrary::default(), EaseSide::Out, true);
        assert_eq!(spec.entries.len(), 1 + 3 + 1 + 1 + 10 + 1 + 1);
        assert!(matches!(&spec.entries[3], EasingMenuEntry::Side { side: EaseSide::Out, checked: true, .. }));
        assert!(matches!(spec.entries.last(), Some(EasingMenuEntry::SaveCurve { enabled: true })));
        assert_eq!(spec.curve_names().len(), 10);
    }

    #[test]
    fn user_curves_get_a_presets_section_and_no_selection_disables() {
        let mut lib = EasingLibrary::default();
        lib.add(EasingCurve::soft_landing());
        let spec = EasingMenuSpec::new(&lib, EaseSide::Both, false);
        assert!(spec.entries.contains(&EasingMenuEntry::Header("Presets".to_string())));
        assert!(spec.entries.iter().all(|e| !matches!(e, EasingMenuEntry::Curve { enabled: true, .. })));
        assert_eq!(spec.curve_names().len(), 11);
    }
}
