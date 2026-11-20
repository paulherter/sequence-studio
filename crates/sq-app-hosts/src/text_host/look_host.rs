// Swift: SQInspectorUI/Draw/CaptionStyleTabDraw.swift (`CaptionLookLibrary.shared` calls), EditorSession+CaptionStyle.swift:100
//! The Look tab's saved caption Looks, over the app's Look store and the stored settings (the default Look's id).

use crate::persist::{FileDefaults, FileView};
use crate::speech::RandomIds;
use sq_core_time::{Id, IdSource};
use sq_editor_session::{CaptionLookLibrary, CaptionStyleMark, LookStore, LookStoreCaptions, NewCaptionLook};
use sq_inspector_ui::captions::style_tab_draw::CaptionLookHost;
use sq_text::caption_presets::{CaptionLook, CaptionLookRegistry};
use sq_transcribe::caption_preset::CaptionPreset;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

pub(super) struct AppCaptionLooks {
    store: Arc<LookStore>,
    defaults: Rc<RefCell<FileDefaults>>,
}

impl AppCaptionLooks {
    pub(super) fn new(store: Arc<LookStore>, defaults: Rc<RefCell<FileDefaults>>) -> AppCaptionLooks {
        AppCaptionLooks { store, defaults }
    }

    fn library(&self) -> CaptionLookLibrary {
        CaptionLookLibrary::new(&LookStoreCaptions(&self.store))
    }
}

impl CaptionLookHost for AppCaptionLooks {
    fn looks_count(&self) -> usize {
        self.library().looks().len()
    }

    fn default_look_id(&self) -> Option<String> {
        self.library().default_look_id(&FileView(Rc::clone(&self.defaults))).map(|id| id.to_string())
    }

    fn save(&mut self, name: &str, look: &CaptionLook, segmentation: &CaptionPreset) -> Option<String> {
        let id = RandomIds.next_id();
        let mut library = self.library();
        let new = NewCaptionLook { id, name, look, segmentation, make_default: true };
        let saved =
            library.save(&mut LookStoreCaptions(&self.store), &mut FileView(Rc::clone(&self.defaults)), new).ok();
        let saved = saved.map(|id| {
            CaptionLookRegistry::shared().register(look.clone(), &id.to_string());
            id.to_string()
        });
        if saved.is_some() {
            // A new style takes the star: saved at once too.
            self.defaults.borrow().flush();
        }
        saved
    }

    fn update(&mut self, id: &str, look: &CaptionLook) -> bool {
        let Some(id) = Id::parse(id) else { return false };
        let mut library = self.library();
        if !library.looks().iter().any(|l| l.id == id) {
            return false;
        }
        library.update(&mut LookStoreCaptions(&self.store), &mut FileView(Rc::clone(&self.defaults)), id, look, None);
        CaptionLookRegistry::shared().register(look.clone(), &id.to_string());
        true
    }

    fn saved(&self) -> Vec<(String, String, bool)> {
        let library = self.library();
        let default = library.default_look_id(&FileView(Rc::clone(&self.defaults)));
        library.looks().iter().map(|l| (l.id.to_string(), l.name.clone(), Some(l.id) == default)).collect()
    }

    fn look_of(&self, id: &str) -> Option<CaptionLook> {
        let id = Id::parse(id)?;
        self.library().looks().iter().find(|l| l.id == id).map(|l| l.look.clone())
    }

    fn mark(&self, id: &str, current: &CaptionLook) -> Option<CaptionStyleMark> {
        self.library().mark(&FileView(Rc::clone(&self.defaults)), Id::parse(id)?, current)
    }

    fn set_default(&mut self, id: Option<&str>) -> bool {
        let id = match id {
            Some(raw) => match Id::parse(raw) {
                Some(id) => Some(id),
                None => return false,
            },
            None => None,
        };
        let done = self.library().set_default_look(&mut FileView(Rc::clone(&self.defaults)), id);
        if done {
            // The star is saved at once, not on the next turn of `Persist`.
            self.defaults.borrow().flush();
        }
        done
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host() -> AppCaptionLooks {
        let defaults = FileDefaults::shared(&crate::test_rig::unique_dir("sq-look-host-tests"));
        AppCaptionLooks::new(Arc::new(LookStore::new(None, None, None, None)), defaults)
    }

    #[test]
    fn save_makes_the_new_look_the_default_and_update_changes_it() {
        let mut h = host();
        assert_eq!((h.looks_count(), h.default_look_id()), (0, None));
        let look = CaptionLook::default_look();
        let id = h.save("Mine", &look, &CaptionPreset::standard());
        assert!(id.is_some());
        assert_eq!((h.looks_count(), h.default_look_id()), (1, id.clone()));
        assert!(h.update(&id.unwrap_or_default(), &look));
        assert!(!h.update("nope", &look));
        assert!(h.save("  ", &look, &CaptionPreset::standard()).is_none());
    }

    #[test]
    fn moving_the_star_writes_prefs_json_at_once() {
        let dir = crate::test_rig::test_dir("sq-look-host-flush");
        let defaults = FileDefaults::shared(&dir);
        let store = Arc::new(LookStore::new(None, None, None, None));
        let mut h = AppCaptionLooks::new(Arc::clone(&store), Rc::clone(&defaults));
        let look = CaptionLook::default_look();
        let a = h.save("A", &look, &CaptionPreset::standard()).unwrap_or_default();
        let b = h.save("B", &look, &CaptionPreset::standard()).unwrap_or_default();
        assert!(h.set_default(Some(&a)));
        // a fresh reading of the file, without any `Persist` turn in between
        let on_disk = AppCaptionLooks::new(Arc::clone(&store), FileDefaults::shared(&dir));
        assert_eq!(on_disk.default_look_id(), Some(a.clone()));
        assert!(h.set_default(Some(&b)));
        let on_disk = AppCaptionLooks::new(store, FileDefaults::shared(&dir));
        assert_eq!(on_disk.default_look_id(), Some(b));
    }

    #[test]
    fn the_star_moves_between_saved_looks_and_survives_a_new_host_on_the_same_store() {
        // The settings are one shared store (`Persist` writes it to prefs.json on the next turn): a second host over it
        // sees the same star, like the panel after a rebuild.
        let defaults = FileDefaults::shared(&crate::test_rig::unique_dir("sq-look-host-star"));
        let store = Arc::new(LookStore::new(None, None, None, None));
        let mut h = AppCaptionLooks::new(Arc::clone(&store), Rc::clone(&defaults));
        let look = CaptionLook::default_look();
        let a = h.save("A", &look, &CaptionPreset::standard()).unwrap_or_default();
        let b = h.save("B", &look, &CaptionPreset::standard()).unwrap_or_default();
        assert_eq!(h.default_look_id(), Some(b.clone()));
        assert!(h.set_default(Some(&a)));
        let stars = |h: &AppCaptionLooks| h.saved().into_iter().filter(|s| s.2).map(|s| s.1).collect::<Vec<_>>();
        assert_eq!(stars(&h), ["A"]);
        let again = AppCaptionLooks::new(store, defaults);
        assert_eq!(stars(&again), ["A"]);
        assert!(!h.set_default(Some("nope")));
        assert!(h.set_default(None));
        assert!(stars(&h).is_empty());
    }
}
