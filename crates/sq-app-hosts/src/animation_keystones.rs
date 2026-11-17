// Swift: SQAppShell (the Library as `AnimationKeystoneSource` of the Text Inspector)
//! The Library's keystones as the Intro / Outro popups' saved animations. The root refreshes the list from the Library's
//! presets; a saved Custom animation lands in the list at once and waits in a queue until the root stores it.

use sq_core_effects::keystone::Keystone;
use sq_core_graphics::custom_animation::{AnimationSide, KeystoneAnimationExt};
use sq_core_time::Timestamp;
use sq_inspector_ui::ec::animation::AnimationKeystoneSource;
use sq_library::keystone_library;
use sq_library::preset_store::PresetItem;
use std::cell::RefCell;

/// Shared between the root and the text models of the Graphics panel.
#[derive(Default)]
pub struct AnimationKeystones {
    seen: RefCell<Vec<PresetItem>>,
    list: RefCell<Vec<Keystone>>,
    queue: RefCell<Vec<PresetItem>>,
}

impl AnimationKeystones {
    /// Follows the Library's list; a no-op while it is unchanged.
    pub fn refresh(&self, presets: &[PresetItem]) {
        if self.seen.borrow().as_slice() == presets {
            return;
        }
        *self.seen.borrow_mut() = presets.to_vec();
        *self.list.borrow_mut() = keystone_library::keystones(presets);
    }

    /// The saved animations waiting for the Library.
    pub fn take_saved(&self) -> Vec<PresetItem> {
        std::mem::take(&mut self.queue.borrow_mut())
    }
}

impl AnimationKeystoneSource for AnimationKeystones {
    fn offered_animations(&self, side: AnimationSide) -> Vec<Keystone> {
        self.list.borrow().iter().filter(|k| k.animation_side() == Some(side)).cloned().collect()
    }

    fn can_save(&self) -> bool {
        true
    }

    fn save(&self, keystone: Keystone) -> bool {
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
        let Ok(item) = keystone_library::preset_item(&keystone, Timestamp::from_unix_seconds(secs)) else {
            return false;
        };
        self.queue.borrow_mut().push(item);
        self.list.borrow_mut().push(keystone);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::keystone::KeystoneAnchor;
    use sq_core_time::{Id, Time};

    #[test]
    fn a_saved_animation_is_listed_and_queued_for_the_library() {
        let s = AnimationKeystones::default();
        let k = Keystone::new(Id::from_u128(7), "Mine", Time::new(1, 1), KeystoneAnchor::ClipStart);
        assert!(s.save(k));
        assert_eq!(s.offered_animations(AnimationSide::Intro).len(), 1);
        assert!(s.offered_animations(AnimationSide::Outro).is_empty());
        let queued = s.take_saved();
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].name, "Mine");
        assert!(s.take_saved().is_empty());
        // the Library gives it back: the refresh shows it from the presets
        s.refresh(&queued);
        assert!(s.offered_animations(AnimationSide::Intro).iter().any(|k| k.name == "Mine"));
    }
}
