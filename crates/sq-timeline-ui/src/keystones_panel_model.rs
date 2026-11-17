// Swift: KeystonesPanelModel.swift
//! Keystones panel content: built-ins plus the user's `.keystone` presets (kept in step with the Library by the app).
//! Portable (the Windows panel uses it too). Swift's `@Observable` becomes `version`, bumped when the presets change.

use sq_core_effects::keystone::{Keystone, KeystoneProperty};
use sq_core_graphics::custom_animation::{AnimationSide, KeystoneAnimationExt};
use sq_core_time::{EasingCurve, Id};
use sq_library::keystone_library;
use sq_library::preset_store::PresetItem;
use sq_uikit::sqicon::SQIcon;
use std::collections::BTreeSet;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

/// Saves a keystone and answers after the Library holds it (true) or could not store it (false).
pub type SaveStored = Rc<dyn Fn(Keystone) -> Pin<Box<dyn Future<Output = bool>>>>;

pub struct KeystonesPanelModel {
    presets: Vec<PresetItem>,
    pub selected_id: Option<Id>,
    /// `presets` decoded, until they change: the panel, the Intro / Outro popups and every refresh read the list.
    decoded: Option<Vec<Keystone>>,
    version: u64,
    /// Saves (adds or replaces) a keystone in the Library.
    pub on_save: Option<Rc<dyn Fn(Keystone)>>,
    /// Saves like `on_save` but answers after the Library holds it. The app sets this one: its Library stores
    /// asynchronously. Without it `on_save` is taken to store at once.
    pub on_save_stored: Option<SaveStored>,
    /// Deletes the Library preset with this id (a user keystone, or a built-in's saved changes).
    pub on_delete: Option<Rc<dyn Fn(Id)>>,
}

impl Default for KeystonesPanelModel {
    fn default() -> Self {
        Self::new()
    }
}

impl KeystonesPanelModel {
    pub fn new() -> Self {
        KeystonesPanelModel {
            presets: Vec::new(),
            selected_id: None,
            decoded: None,
            version: 0,
            on_save: None,
            on_save_stored: None,
            on_delete: None,
        }
    }

    /// The Library's presets (every kind; only `.keystone` is read).
    pub fn presets(&self) -> &[PresetItem] {
        &self.presets
    }

    /// Replaces the presets (Swift `didSet`: drops the decoded list).
    pub fn set_presets(&mut self, presets: Vec<PresetItem>) {
        self.presets = presets;
        self.decoded = None;
        self.version += 1;
    }

    /// Bumped with every change of `presets`; a view redraws when it differs from the one it drew.
    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn keystones(&mut self) -> &[Keystone] {
        let presets = &self.presets;
        self.decoded.get_or_insert_with(|| keystone_library::keystones(presets))
    }

    /// The user's saved animations for a side (`AnimationChoices`): keystones that start or end with the clip.
    pub fn saved_animations(&mut self, side: AnimationSide) -> Vec<Keystone> {
        self.keystones().iter().filter(|k| !k.is_built_in() && k.animation_side() == Some(side)).cloned().collect()
    }

    /// What the Intro / Outro popups offer for a side: the built-in keystones first, then the saved ones, each id once
    /// (a built-in with saved changes stands in its own place), a built-in never under a name an earlier entry has.
    pub fn offered_animations(&mut self, side: AnimationSide) -> Vec<Keystone> {
        let mut ids: BTreeSet<Id> = BTreeSet::new();
        let mut built_in_names: BTreeSet<String> = BTreeSet::new();
        let mut out = Vec::new();
        for k in self.keystones() {
            if k.animation_side() != Some(side) || !ids.insert(k.id) {
                continue;
            }
            if k.is_built_in() && !built_in_names.insert(k.name.to_lowercase()) {
                continue;
            }
            out.push(k.clone());
        }
        out
    }

    /// Saves in the Library and tells whether the keystone is stored now (listed in `keystones`): the app stores
    /// asynchronously (`on_save_stored` answers once it did), a plain `on_save` stores at once. A save that did not
    /// happen is false, so no caller shows a result the Library does not have.
    pub async fn save(&mut self, k: Keystone) -> bool {
        let id = k.id;
        if let Some(stored) = self.on_save_stored.clone() {
            if !stored(k).await {
                return false;
            }
        } else if let Some(save) = self.on_save.clone() {
            save(k);
        } else {
            return false;
        }
        self.keystones().iter().any(|k| k.id == id)
    }

    /// True when a keystone can be saved here.
    pub fn can_save(&self) -> bool {
        self.on_save.is_some() || self.on_save_stored.is_some()
    }

    /// The selected keystone; a hidden built-in whose saved changes were deleted still resolves.
    pub fn selected(&mut self) -> Option<Keystone> {
        let id = self.selected_id?;
        if let Some(k) = self.keystones().iter().find(|k| k.id == id) {
            return Some(k.clone());
        }
        keystone_library::keystone(id, &self.presets)
    }

    /// A user keystone, or a built-in with saved changes (deleting restores the built-in).
    pub fn can_delete(&self, id: Id) -> bool {
        keystone_library::is_customised(id, &self.presets)
    }

    /// Sets (`None` clears) the keystone's own curve and saves it.
    pub fn set_easing(&mut self, curve: Option<EasingCurve>, id: Id) {
        let Some(mut k) = self.keystones().iter().find(|k| k.id == id).cloned() else { return };
        k.easing = curve;
        if let Some(save) = &self.on_save {
            save(k);
        }
    }

    /// Short description for the list: properties and length.
    pub fn subtitle(k: &Keystone) -> String {
        let props: Vec<&str> = k
            .properties()
            .iter()
            .map(|p| match p {
                KeystoneProperty::Position => "Position",
                KeystoneProperty::Scale => "Scale",
                KeystoneProperty::Rotation => "Rotation",
                KeystoneProperty::Opacity => "Opacity",
            })
            .collect();
        let ms = (k.duration.value() as f64 / k.duration.timescale() as f64 * 1000.0).round() as i64;
        let len = if ms < 1000 { format!("{ms} ms") } else { format!("{:.1} s", ms as f64 / 1000.0) };
        let custom = if k.easing.is_some() { " · custom curve" } else { "" };
        format!("{} · {len}{custom}", props.join(", "))
    }

    pub fn symbol(k: &Keystone) -> SQIcon {
        let p = k.properties();
        if p.contains(&KeystoneProperty::Rotation) {
            return SQIcon::RotateCW;
        }
        if p.contains(&KeystoneProperty::Position) {
            return SQIcon::MoveHorizontal;
        }
        if p.contains(&KeystoneProperty::Scale) {
            return SQIcon::Maximize;
        }
        SQIcon::Contrast
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{Time, Timestamp};
    use std::cell::RefCell;

    fn user_keystone(name: &str, n: u128, anchor: sq_core_effects::keystone::KeystoneAnchor) -> Keystone {
        let mut k = Keystone::new(Id::from_u128(n), name, Time::new(1, 2), anchor);
        k.opacity = Some(sq_core_time::KeyframeTrack { keys: Vec::new() });
        k
    }

    fn item(k: &Keystone) -> PresetItem {
        keystone_library::preset_item(k, Timestamp::from_reference_seconds(0.0)).expect("payload")
    }

    #[test]
    fn keystones_list_built_ins_then_user_presets_and_follow_set_presets() {
        let mut m = KeystonesPanelModel::new();
        let built = m.keystones().len();
        assert!(built > 0);
        let k = user_keystone("Mine", 1 << 70, sq_core_effects::keystone::KeystoneAnchor::Free);
        m.set_presets(vec![item(&k)]);
        assert_eq!(m.version(), 1);
        assert_eq!(m.keystones().len(), built + 1);
        assert!(m.can_delete(k.id));
        assert!(!m.can_delete(Id::from_u128(5)));
    }

    #[test]
    fn selected_resolves_a_built_in_id() {
        let mut m = KeystonesPanelModel::new();
        let first = m.keystones()[0].id;
        m.selected_id = Some(first);
        assert_eq!(m.selected().map(|k| k.id), Some(first));
        m.selected_id = Some(Id::from_u128(9));
        assert!(m.selected().is_none());
    }

    #[test]
    fn set_easing_saves_the_changed_keystone() {
        let mut m = KeystonesPanelModel::new();
        let first = m.keystones()[0].id;
        let saved = Rc::new(RefCell::new(Vec::<Keystone>::new()));
        let sink = Rc::clone(&saved);
        m.on_save = Some(Rc::new(move |k| sink.borrow_mut().push(k)));
        m.set_easing(None, first);
        m.set_easing(None, Id::from_u128(77));
        assert_eq!(saved.borrow().len(), 1);
        assert_eq!(saved.borrow()[0].id, first);
    }

    #[test]
    fn save_without_a_handler_is_false_and_with_on_save_checks_the_list() {
        let mut m = KeystonesPanelModel::new();
        let k = user_keystone("Mine", 1 << 70, sq_core_effects::keystone::KeystoneAnchor::Free);
        assert!(!m.can_save());
        assert!(!block_on(m.save(k.clone())));
        m.on_save = Some(Rc::new(|_| {}));
        assert!(m.can_save());
        // The handler stores nothing, so the list lacks the keystone.
        assert!(!block_on(m.save(k)));
    }

    #[test]
    fn subtitle_lists_length_and_custom_curve() {
        let mut k = user_keystone("x", 1, sq_core_effects::keystone::KeystoneAnchor::Free);
        k.duration = Time::new(1500, 1000);
        assert_eq!(KeystonesPanelModel::subtitle(&k), " · 1.5 s");
        k.duration = Time::new(250, 1000);
        k.easing = Some(EasingCurve::new(
            Id::from_u128(2),
            "c".to_string(),
            sq_core_time::Interpolation::Linear,
            sq_core_time::EaseHandle::LINEAR,
            sq_core_time::EaseHandle::LINEAR,
        ));
        assert_eq!(KeystonesPanelModel::subtitle(&k), " · 250 ms · custom curve");
    }

    #[test]
    fn symbol_prefers_rotation_then_position_then_scale() {
        let k = user_keystone("x", 1, sq_core_effects::keystone::KeystoneAnchor::Free);
        assert_eq!(KeystonesPanelModel::symbol(&k), SQIcon::Contrast);
    }

    /// Polls a future that never waits.
    fn block_on<T>(f: impl Future<Output = T>) -> T {
        use std::task::{Context, Poll, Waker};
        let mut f = Box::pin(f);
        match f.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
            Poll::Ready(v) => v,
            Poll::Pending => panic!("future waited"),
        }
    }
}
