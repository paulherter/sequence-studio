// Swift: SubjectMaskQualityMenu.swift
//! Program monitor menu > Subject Mask Edges: the one choice between Quality and Speed for tracking a subject mask
//! (`SubjectMaskQuality`, stored for this Mac under `sq.subjectMask.quality`, not in the project). The next Track
//! uses it; frames tracked before keep their edge until they are tracked again.

use std::cell::RefCell;
use std::rc::Rc;

use sq_analysis::subject_mask_quality::{StringDefaults, SubjectMaskQuality};
use sq_uikit::sqmenu_model::SQMenuItem;

pub struct SubjectMaskQualityMenu;

impl SubjectMaskQualityMenu {
    pub const TITLE: &'static str = "Subject Mask Edges";

    pub fn help(q: SubjectMaskQuality) -> &'static str {
        match q {
            SubjectMaskQuality::Quality => "Finer hair and soft edges, tracks slower",
            SubjectMaskQuality::Speed => "Tracks faster, simpler edges",
        }
    }

    /// The submenu row with the stored choice checked. `changed` runs after a new choice was stored.
    /// The defaults are shared with the menu actions (`Rc<RefCell>`: the actions outlive this call and write to them).
    pub fn item(defaults: Rc<RefCell<dyn StringDefaults>>, changed: Rc<dyn Fn(SubjectMaskQuality)>) -> SQMenuItem {
        let current = SubjectMaskQuality::stored(&*defaults.borrow());
        let submenu = SubjectMaskQuality::ALL
            .iter()
            .map(|&q| {
                let mut row = SQMenuItem::new(q.title()).with_help(Self::help(q));
                row.is_checked = q == current;
                let defaults = Rc::clone(&defaults);
                let changed = Rc::clone(&changed);
                row.action = Some(Rc::new(move || {
                    q.store(&mut *defaults.borrow_mut());
                    changed(q);
                }));
                row
            })
            .collect();
        let mut item = SQMenuItem::new(Self::TITLE);
        item.submenu = Some(submenu);
        item
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Defaults(HashMap<String, String>);

    impl StringDefaults for Defaults {
        fn string(&self, key: &str) -> Option<String> {
            self.0.get(key).cloned()
        }
        fn set_string(&mut self, key: &str, value: &str) {
            self.0.insert(key.to_string(), value.to_string());
        }
    }

    #[test]
    fn the_stored_choice_is_checked_and_picking_stores_it() {
        let defaults = Rc::new(RefCell::new(Defaults::default()));
        defaults.borrow_mut().set_string(SubjectMaskQuality::DEFAULTS_KEY, "speed");
        let seen = Rc::new(RefCell::new(Vec::new()));
        let seen2 = Rc::clone(&seen);
        let shared = Rc::clone(&defaults);
        let dyn_defaults: Rc<RefCell<dyn StringDefaults>> = shared;
        let item = SubjectMaskQualityMenu::item(dyn_defaults, Rc::new(move |q| seen2.borrow_mut().push(q)));
        let sub = item.submenu.unwrap_or_default();
        assert_eq!(sub.len(), 2);
        assert!(!sub[0].is_checked && sub[1].is_checked);
        if let Some(a) = &sub[0].action {
            a();
        }
        assert_eq!(defaults.borrow().string(SubjectMaskQuality::DEFAULTS_KEY).as_deref(), Some("quality"));
        assert_eq!(*seen.borrow(), vec![SubjectMaskQuality::Quality]);
    }
}
