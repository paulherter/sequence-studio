//! ☆ My Curves: the user's own easing curves, kept in the preferences (one JSON blob under `sq.myCurves`) so every
//! project and every place that lists curves (transitions, keyframe easing) sees the same list.

use sq_core_time::{EasingCurve, EasingLibrary, IdSource};
use sq_uikit::appearance_palette::UiDefaults;

pub enum MyCurves {}

impl MyCurves {
    pub const KEY: &'static str = "sq.myCurves";

    /// The stored curves (an empty library when nothing is stored or the blob is unreadable).
    pub fn load(defaults: &dyn UiDefaults) -> EasingLibrary {
        defaults.data(Self::KEY).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn store(defaults: &mut dyn UiDefaults, library: &EasingLibrary) {
        if let Ok(bytes) = serde_json::to_vec(library) {
            defaults.set_data(Self::KEY, &bytes);
        }
    }

    /// Saves a copy of `curve` under `name` (a blank name becomes "My Curve N") and stores the list. A curve whose
    /// shape is already saved is not added twice. Returns the curve now in the list.
    pub fn save(defaults: &mut dyn UiDefaults, ids: &mut dyn IdSource, curve: &EasingCurve, name: &str) -> EasingCurve {
        let mut library = Self::load(defaults);
        if let Some(same) = library.user_curves().iter().find(|c| Self::same_shape(c, curve)) {
            return same.clone();
        }
        let name = name.trim();
        let name =
            if name.is_empty() { format!("My Curve {}", library.user_curves().len() + 1) } else { name.to_string() };
        let mut copy = curve.clone();
        copy.id = ids.next_id();
        copy.name = name;
        library.add(copy.clone());
        Self::store(defaults, &library);
        copy
    }

    pub fn remove(defaults: &mut dyn UiDefaults, id: sq_core_time::Id) {
        let mut library = Self::load(defaults);
        library.remove(id);
        Self::store(defaults, &library);
    }

    fn same_shape(a: &EasingCurve, b: &EasingCurve) -> bool {
        a.interpolation() == b.interpolation() && a.out_handle == b.out_handle && a.in_handle == b.in_handle
    }
}

#[cfg(test)]
mod tests {
    use super::super::defaults::TestDefaults;
    use super::*;
    use sq_core_time::SequentialIds;

    #[test]
    fn saved_curves_persist_and_are_not_duplicated() {
        let mut d = TestDefaults::default();
        let mut ids = SequentialIds::default();
        assert!(MyCurves::load(&d).user_curves().is_empty());
        let saved = MyCurves::save(&mut d, &mut ids, &EasingCurve::ease_in(), " Punchy ");
        assert_eq!(saved.name, "Punchy");
        let again = MyCurves::save(&mut d, &mut ids, &EasingCurve::ease_in(), "Other");
        assert_eq!(again.id, saved.id, "same shape is kept once");
        let second = MyCurves::save(&mut d, &mut ids, &EasingCurve::ease_out(), "");
        assert_eq!(second.name, "My Curve 2");
        // A fresh read (a new launch) sees both, in order.
        let names: Vec<String> = MyCurves::load(&d).user_curves().iter().map(|c| c.name.clone()).collect();
        assert_eq!(names, ["Punchy", "My Curve 2"]);
        MyCurves::remove(&mut d, saved.id);
        assert_eq!(MyCurves::load(&d).user_curves().len(), 1);
    }

    #[test]
    fn unreadable_data_gives_an_empty_list() {
        let mut d = TestDefaults::default();
        d.set_data(MyCurves::KEY, b"not json");
        assert!(MyCurves::load(&d).user_curves().is_empty());
    }
}
