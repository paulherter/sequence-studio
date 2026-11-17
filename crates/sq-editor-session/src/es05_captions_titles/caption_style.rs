//! Caption style of the track, per-caption overrides, the karaoke word highlight, caption Looks and the caption
//! panels' view of the Look store.

use std::collections::BTreeSet;

use sq_core_model::KaraokeStyle;
use sq_core_model::anchored_animation::KeyframeTemplate;
use sq_core_time::Id;
use sq_library::library_folder_store::SettingsStore;
use sq_text::caption_presets::{CaptionLook, CaptionLookRegistry};
use sq_text::text_generator::TextGenerator;
use sq_transcribe::caption_preset::CaptionPreset;

use crate::EditorSession;
use sq_core_audio::TimelineCaptionEditsExt as TimelineCaptionEdits;

impl EditorSession {
    /// The karaoke style of the first caption track that has one (`None`: off everywhere).
    // Swift: EditorSession+CaptionStyle.swift:10
    pub fn caption_karaoke(&self) -> Option<KaraokeStyle> {
        self.active_timeline()?.caption_tracks.iter().find_map(|t| t.karaoke.clone())
    }

    /// Turns the word highlight on (a style) or off (`None`) for every caption track.
    // Swift: EditorSession+CaptionStyle.swift:13
    pub fn set_caption_karaoke(&mut self, karaoke: Option<KaraokeStyle>) -> bool {
        let ids: Vec<Id> = match self.active_timeline() {
            Some(tl) if !tl.caption_tracks.is_empty() => tl.caption_tracks.iter().map(|t| t.id).collect(),
            _ => return false,
        };
        let name = if karaoke.is_none() { "Word Highlight Off" } else { "Word Highlight" };
        self.attempt_keyed_ids(name, None, |t, _| {
            for id in &ids {
                t.set_track_karaoke(karaoke.clone(), *id)?;
            }
            Ok(())
        })
    }

    /// The selected captions get their own style (the track style no longer changes them); `None` hands them back.
    // Swift: EditorSession+CaptionStyle.swift:23
    pub fn set_selected_caption_style(&mut self, style_ref: Option<&str>) -> bool {
        if self.caption_selection.is_empty() {
            return false;
        }
        let ids = self.caption_selection.clone();
        let name = if style_ref.is_none() { "Use Track Style" } else { "Caption Style" };
        self.attempt_keyed_ids(name, None, |t, _| t.set_caption_item_style(&ids, style_ref))
    }

    /// True when any selected caption has a style of its own.
    // Swift: EditorSession+CaptionStyle.swift:31
    pub fn selected_captions_have_own_style(&self) -> bool {
        let ids = &self.caption_selection;
        self.caption_items().iter().any(|c| ids.contains(&c.id) && c.style_overridden)
    }

    /// Registers `look` under `id` and gives every caption of every caption track its style and animation (one undo
    /// step). Captions in `releasing` (default: the selected ones) lose their own-style override in the same step.
    // Swift: EditorSession+CaptionStyle.swift:43
    pub fn push_caption_look(&mut self, look: &CaptionLook, id: &str, releasing: Option<&BTreeSet<Id>>) -> bool {
        let ids: Vec<Id> = match self.active_timeline() {
            Some(tl) if !tl.caption_tracks.is_empty() => tl.caption_tracks.iter().map(|t| t.id).collect(),
            _ => return false,
        };
        let (style_ref, animation_ref) = CaptionLookRegistry::shared().register(look.clone(), id);
        let release = releasing.cloned().unwrap_or_else(|| self.caption_selection.clone());
        self.attempt_keyed_ids("Caption Look", None, |t, _| {
            for tid in &ids {
                t.set_caption_style(&style_ref, Some(&animation_ref), *tid, false)?;
            }
            t.set_caption_item_style(&release, None)
        })
    }

    /// The look of the selected caption (first one), or of the first caption when none is selected.
    // Swift: EditorSession+CaptionStyle.swift:57
    pub fn current_caption_look(&self) -> Option<CaptionLook> {
        let items = self.caption_items();
        let c = items.iter().find(|c| self.caption_selection.contains(&c.id)).or_else(|| items.first())?;
        // The project's library: saved looks (`look-<id>`) and the kit's styles resolve there, so an edit shows.
        let lib = CaptionLookRegistry::shared().library_for_project(self.project());
        Some(CaptionLook::new(
            lib.style(Some(c.style_ref.as_str()).filter(|r| !r.is_empty())),
            lib.animation(Some(c.animation_ref.as_str()).filter(|r| !r.is_empty())),
        ))
    }

    /// Animation of the single selected text clip (its in-animation, else its out-animation); `None` if no text clip is
    /// selected or it has no animation.
    // Swift: EditorSession+CaptionStyle.swift:68
    pub fn animation_from_selected_text_clip(&self) -> Option<KeyframeTemplate> {
        if self.selection.len() != 1 {
            return None;
        }
        let id = *self.selection.iter().next()?;
        let generator = self.es5_clip(id)?.generator.as_ref()?;
        let (template, anims) = TextGenerator::decode(generator).ok()?;
        // The first side that actually animates: an empty in-animation must not hide the out-animation.
        let animates = |t: &KeyframeTemplate| {
            *t != KeyframeTemplate::none() && (!t.tracks.is_empty() || t.text_animator.is_some())
        };
        [anims.as_ref().and_then(|a| a.animation_in.clone()), anims.and_then(|a| a.animation_out), template.animation]
            .into_iter()
            .flatten()
            .find(animates)
    }
}

/// A saved Look as the caption panels use it: style, animation and the segmentation it was made with.
// Swift: EditorSession+CaptionStyle.swift:66
#[derive(Clone, Debug, PartialEq)]
pub struct StoredCaptionLook {
    // Swift: EditorSession+CaptionStyle.swift:80
    pub id: Id,
    // Swift: EditorSession+CaptionStyle.swift:81
    pub name: String,
    // Swift: EditorSession+CaptionStyle.swift:82
    pub look: CaptionLook,
    // Swift: EditorSession+CaptionStyle.swift:83
    pub segmentation: CaptionPreset,
}

/// Payload of an old `.caption` preset: the look plus its segmentation (an absent segmentation reads as standard).
// Swift: EditorSession+CaptionStyle.swift:74
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CaptionLookPayload {
    // Swift: EditorSession+CaptionStyle.swift:90
    pub look: CaptionLook,
    // Swift: EditorSession+CaptionStyle.swift:91
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub segmentation: Option<CaptionPreset>,
    /// The Look's group in the Look strip filter; only set when a Look is exported.
    // Swift: EditorSession+CaptionStyle.swift:93
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

impl CaptionLookPayload {
    // Swift: EditorSession+CaptionStyle.swift:89
    pub const VERSION: i64 = 1;

    // Swift: EditorSession+CaptionStyle.swift:94
    pub fn new(look: CaptionLook, segmentation: Option<CaptionPreset>, category: Option<String>) -> Self {
        CaptionLookPayload { look, segmentation, category }
    }
}

/// The Look store as the caption panels use it (the app implements this for ES4's `LookStore`).
pub trait CaptionLookStore {
    /// The user's Looks that carry a caption look, with their segmentation.
    fn user_looks(&self) -> Vec<StoredCaptionLook>;
    /// Adds a Look; `false` for a blank name.
    fn add(&mut self, id: Id, name: &str, look: &CaptionLook, segmentation: &CaptionPreset) -> bool;
    /// Replaces the look (and the segmentation, when given); `false` for an unknown id.
    fn update(&mut self, id: Id, look: &CaptionLook, segmentation: Option<&CaptionPreset>) -> bool;
    /// Deletes a Look.
    fn delete(&mut self, id: Id);
}

/// Why a Look could not be saved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptionLookSaveError {
    // Swift: EditorSession+CaptionStyle.swift:143
    EmptyName,
}

/// How a saved Look stands in the Style tab: its name, whether the current look differs from it ("Edited"), whether it is
/// the default for Create Captions (the star).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaptionStyleMark {
    pub id: Id,
    pub name: String,
    pub edited: bool,
    pub is_default: bool,
}

/// What `CaptionLookLibrary::save` stores.
pub struct NewCaptionLook<'a> {
    pub id: Id,
    pub name: &'a str,
    pub look: &'a CaptionLook,
    pub segmentation: &'a CaptionPreset,
    pub make_default: bool,
}

/// The caption panels' view of the Look store: the user's Looks with a segmentation, and the default look Create
/// Captions applies.
// Swift: EditorSession+CaptionStyle.swift:88
pub struct CaptionLookLibrary {
    pub(crate) looks: Vec<StoredCaptionLook>,
}

impl CaptionLookLibrary {
    /// Settings key of the default look.
    // Swift: EditorSession+CaptionStyle.swift:90
    pub const DEFAULT_KEY: &'static str = "sq.captionLook.default";

    /// A library over `store`.
    // Swift: EditorSession+CaptionStyle.swift:118
    pub fn new(store: &dyn CaptionLookStore) -> CaptionLookLibrary {
        CaptionLookLibrary { looks: store.user_looks() }
    }

    /// A library without Looks (no Look store).
    pub fn empty() -> CaptionLookLibrary {
        CaptionLookLibrary { looks: Vec::new() }
    }

    /// The saved Looks.
    pub fn looks(&self) -> &[StoredCaptionLook] {
        &self.looks
    }

    // Swift: EditorSession+CaptionStyle.swift:139
    pub fn default_look_id(&self, settings: &dyn SettingsStore) -> Option<Id> {
        let raw = settings.data(Self::DEFAULT_KEY)?;
        Id::parse(std::str::from_utf8(&raw).ok()?)
    }

    /// Makes the saved look `id` the default for Create Captions (`None` clears it). Settings are written at once, so the
    /// star survives a restart. An unknown id changes nothing (`false`).
    pub fn set_default_look(&self, settings: &mut dyn SettingsStore, id: Option<Id>) -> bool {
        match id {
            None => settings.remove(Self::DEFAULT_KEY),
            Some(id) if self.looks.iter().any(|l| l.id == id) => {
                settings.set_data(Self::DEFAULT_KEY, id.to_string().into_bytes());
            }
            Some(_) => return false,
        }
        true
    }

    /// The Style tab's mark for the picked look: `edited` when `current` no longer equals the saved look. `None` when the
    /// look is gone (deleted elsewhere).
    pub fn mark(&self, settings: &dyn SettingsStore, picked: Id, current: &CaptionLook) -> Option<CaptionStyleMark> {
        let l = self.looks.iter().find(|l| l.id == picked)?;
        Some(CaptionStyleMark {
            id: l.id,
            name: l.name.clone(),
            edited: l.look != *current,
            is_default: self.default_look_id(settings) == Some(l.id),
        })
    }

    // Swift: EditorSession+CaptionStyle.swift:144
    pub fn default_look(&self, settings: &dyn SettingsStore) -> Option<&StoredCaptionLook> {
        let id = self.default_look_id(settings)?;
        self.looks.iter().find(|l| l.id == id)
    }

    /// Reads the Look store again.
    // Swift: EditorSession+CaptionStyle.swift:149
    pub fn reload(&mut self, store: &dyn CaptionLookStore, settings: &mut dyn SettingsStore) {
        // The one-time import of the old preset store is not ported (Rust has no old store to import); the merge-follow of
        // the default look belongs to the Look store (ES4).
        let _ = settings;
        self.looks = store.user_looks();
    }

    /// Saves a new Look. Fails with `EmptyName` for a blank name: nothing is saved, the default stays.
    // Swift: EditorSession+CaptionStyle.swift:171
    pub fn save(
        &mut self,
        store: &mut dyn CaptionLookStore,
        settings: &mut dyn SettingsStore,
        new: NewCaptionLook<'_>,
    ) -> Result<Id, CaptionLookSaveError> {
        let NewCaptionLook { id, name, look, segmentation, make_default } = new;
        let name = name.trim();
        // The old preset store copy (`legacy`) is not written: Rust has no old store; the Library panel reads the Look store.
        if !store.add(id, name, look, segmentation) {
            return Err(CaptionLookSaveError::EmptyName);
        }
        if make_default {
            settings.set_data(Self::DEFAULT_KEY, id.to_string().into_bytes());
        }
        self.looks = store.user_looks();
        Ok(id)
    }

    /// Replaces the look (and the segmentation, when given) of a saved look. An unknown id changes nothing.
    // Swift: EditorSession+CaptionStyle.swift:191
    pub fn update(
        &mut self,
        store: &mut dyn CaptionLookStore,
        settings: &mut dyn SettingsStore,
        id: Id,
        look: &CaptionLook,
        segmentation: Option<&CaptionPreset>,
    ) {
        let _ = settings;
        store.update(id, look, segmentation);
        self.looks = store.user_looks();
    }

    /// Deletes a saved look.
    // Swift: EditorSession+CaptionStyle.swift:210
    pub fn delete(&mut self, store: &mut dyn CaptionLookStore, settings: &mut dyn SettingsStore, id: Id) {
        store.delete(id);
        if self.default_look_id(settings) == Some(id) {
            settings.remove(Self::DEFAULT_KEY);
        }
        self.looks = store.user_looks();
    }

    /// Refs of a saved look (style, animation) as captions carry them.
    // Swift: EditorSession+CaptionStyle.swift:219
    pub fn refs(id: Id) -> (String, String) {
        let raw = id.to_string();
        (CaptionLook::style_id(&raw), CaptionLook::animation_id(&raw))
    }

    /// The preset Create Captions uses: the default look's segmentation and refs when one is set, else `preset`.
    // Swift: EditorSession+CaptionStyle.swift:225
    pub fn apply_default(&self, settings: &dyn SettingsStore, preset: &CaptionPreset) -> CaptionPreset {
        match self.default_look(settings) {
            Some(l) => {
                let mut p = l.segmentation.clone();
                (p.style_ref, p.animation_ref) = Self::refs(l.id);
                p
            }
            None => preset.clone(),
        }
    }
}

// Swift: EditorSession+CaptionStyle.swift:105 (`CaptionLookLibrary.shared`: the app owns the one library and passes it on)
