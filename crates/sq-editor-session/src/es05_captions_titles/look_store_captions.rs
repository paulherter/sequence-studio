//! The caption panels' window onto the app's `LookStore` (Swift `CaptionLookLibrary.refresh/save/update/delete` over the store).

use sq_core_time::{Id, IdSource};
use sq_text::caption_presets::CaptionLook;
use sq_text::look::LookValues;
use sq_transcribe::caption_preset::CaptionPreset;

use super::{CaptionLookStore, StoredCaptionLook};
use crate::es04_effects::LookStore;

/// Ids are always given by the caller (`add` with `Some(id)`), so this is never asked.
struct GivenIds;

impl IdSource for GivenIds {
    fn next_id(&mut self) -> Id {
        Id::from_u128(0)
    }
}

/// `CaptionLookStore` over the one Look store of the app.
pub struct LookStoreCaptions<'a>(pub &'a LookStore);

impl CaptionLookStore for LookStoreCaptions<'_> {
    // Swift: EditorSession+CaptionStyle.swift:132 (`refresh`)
    fn user_looks(&self) -> Vec<StoredCaptionLook> {
        self.0
            .library()
            .user()
            .iter()
            .filter_map(|l| {
                Id::parse(&l.id).map(|id| StoredCaptionLook {
                    id,
                    name: l.name.clone(),
                    look: l.caption_look(),
                    segmentation: LookStore::segmentation(l).unwrap_or_else(CaptionPreset::standard),
                })
            })
            .collect()
    }

    // Swift: EditorSession+CaptionStyle.swift:171
    fn add(&mut self, id: Id, name: &str, look: &CaptionLook, segmentation: &CaptionPreset) -> bool {
        let mut values = LookValues::new(look.style.clone());
        values.animation = Some(look.animation.clone());
        values.caption_segmentation = LookStore::encode(segmentation);
        let id = id.to_string();
        matches!(self.0.edit(|lib| lib.add(name, values, Some(&id), &mut GivenIds)), Ok(Some(_)))
    }

    // Swift: EditorSession+CaptionStyle.swift:191
    fn update(&mut self, id: Id, look: &CaptionLook, segmentation: Option<&CaptionPreset>) -> bool {
        let seg = segmentation.and_then(LookStore::encode);
        self.0
            .edit(|lib| {
                lib.update(&id.to_string(), |l| {
                    l.style = look.style.clone();
                    l.animation = Some(look.animation.clone());
                    if let Some(s) = seg {
                        l.caption_segmentation = Some(s);
                    }
                })
            })
            .unwrap_or(false)
    }

    // Swift: EditorSession+CaptionStyle.swift:210
    fn delete(&mut self, id: Id) {
        let _ = self.0.edit(|lib| lib.delete(&id.to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::es05_captions_titles::{CaptionLookLibrary, NewCaptionLook};
    use sq_library::library_folder_store::MemorySettings;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn a_saved_look_lists_with_its_segmentation_and_becomes_the_default() {
        let store = LookStore::new(None, None, None, None);
        let mut settings = MemorySettings::default();
        let look = CaptionLook::default_look();
        let seg = CaptionPreset::standard();
        let mut lib = CaptionLookLibrary::new(&LookStoreCaptions(&store));
        let saved = lib.save(
            &mut LookStoreCaptions(&store),
            &mut settings,
            NewCaptionLook { id: id(7), name: " Bold ", look: &look, segmentation: &seg, make_default: true },
        );
        assert_eq!(saved, Ok(id(7)));
        let again = CaptionLookLibrary::new(&LookStoreCaptions(&store));
        assert_eq!(again.looks().len(), 1);
        assert_eq!(again.looks()[0].name, "Bold");
        assert_eq!(again.default_look(&settings).map(|l| l.id), Some(id(7)));
        assert_eq!(again.looks()[0].segmentation, seg);
    }

    #[test]
    fn a_blank_name_saves_nothing_and_delete_clears_the_default() {
        let store = LookStore::new(None, None, None, None);
        let mut settings = MemorySettings::default();
        let look = CaptionLook::default_look();
        let seg = CaptionPreset::standard();
        let mut lib = CaptionLookLibrary::new(&LookStoreCaptions(&store));
        let blank = NewCaptionLook { id: id(1), name: "  ", look: &look, segmentation: &seg, make_default: true };
        assert!(lib.save(&mut LookStoreCaptions(&store), &mut settings, blank).is_err());
        assert!(lib.looks().is_empty());
        let ok = NewCaptionLook { id: id(2), name: "A", look: &look, segmentation: &seg, make_default: true };
        assert!(lib.save(&mut LookStoreCaptions(&store), &mut settings, ok).is_ok());
        lib.delete(&mut LookStoreCaptions(&store), &mut settings, id(2));
        assert!(lib.looks().is_empty());
        assert_eq!(lib.default_look_id(&settings), None);
    }

    #[test]
    fn update_changes_the_look_and_keeps_the_segmentation_when_none_is_given() {
        let store = LookStore::new(None, None, None, None);
        let mut settings = MemorySettings::default();
        let look = CaptionLook::default_look();
        let seg = CaptionPreset::standard();
        let mut lib = CaptionLookLibrary::new(&LookStoreCaptions(&store));
        let n = NewCaptionLook { id: id(3), name: "A", look: &look, segmentation: &seg, make_default: false };
        assert!(lib.save(&mut LookStoreCaptions(&store), &mut settings, n).is_ok());
        let mut changed = look.clone();
        changed.style.size = 99.0;
        lib.update(&mut LookStoreCaptions(&store), &mut settings, id(3), &changed, None);
        assert_eq!(lib.looks()[0].look.style.size, 99.0);
        assert_eq!(lib.looks()[0].segmentation, seg);
        assert!(!LookStoreCaptions(&store).update(id(99), &changed, None));
    }
}
