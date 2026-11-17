// SPDX-License-Identifier: GPL-3.0-or-later
//! Keeps the last raster of every text clip that was drawn, so an edit whose new raster is still being rendered shows
//! the previous one instead of making the text disappear for a few frames (Swift: TextStandIns.swift).

use sq_core_model::GeneratorRef;
use sq_core_time::Id;
use std::collections::HashMap;
use std::sync::Mutex;

/// A drawn text: its clip (a graphics layer's id) and the clip that contains it. Layers of graphics clips made from one
/// template share ids, so the container is part of the key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct Key {
    clip: Id,
    group: Option<Id>,
}

/// Last drawn ref per text clip.
#[derive(Default)]
pub struct TextStandIns {
    last: Mutex<HashMap<Key, GeneratorRef>>,
}

impl TextStandIns {
    /// The ref to draw for `clip` now: `reference` when its raster is cached (and remembered), else the last drawn ref of
    /// the clip while that one is still cached, else None (nothing to show yet).
    pub fn resolve(
        &self,
        clip: Id,
        group: Option<Id>,
        reference: &GeneratorRef,
        is_cached: impl Fn(&GeneratorRef) -> bool,
    ) -> Option<GeneratorRef> {
        let key = Key { clip, group };
        let mut m = self.last.lock().unwrap_or_else(|e| e.into_inner());
        if is_cached(reference) {
            m.insert(key, reference.clone());
            return Some(reference.clone());
        }
        m.get(&key).filter(|old| is_cached(old)).cloned()
    }

    /// Forgets the clips that are not in `keeping` (the container, or the clip itself without one).
    pub fn prune(&self, keeping: &[Id]) {
        let mut m = self.last.lock().unwrap_or_else(|e| e.into_inner());
        m.retain(|k, _| keeping.contains(&k.group.unwrap_or(k.clip)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn r(n: u8) -> GeneratorRef {
        GeneratorRef { kind: "text".into(), payload: vec![n], payload_version: 1 }
    }
    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn uncached_edit_keeps_showing_the_last_raster() {
        let s = TextStandIns::default();
        let (clip, a, b) = (id(1), r(1), r(2));
        let mut cached: HashSet<Vec<u8>> = HashSet::from([a.payload.clone()]);
        assert_eq!(s.resolve(clip, None, &a, |x| cached.contains(&x.payload)), Some(a.clone()));
        assert_eq!(s.resolve(clip, None, &b, |x| cached.contains(&x.payload)), Some(a.clone()));
        cached.insert(b.payload.clone());
        assert_eq!(s.resolve(clip, None, &b, |x| cached.contains(&x.payload)), Some(b));
    }

    #[test]
    fn nothing_before_the_first_raster_and_no_evicted_stand_in() {
        let s = TextStandIns::default();
        let (clip, a, b) = (id(1), r(1), r(2));
        assert_eq!(s.resolve(clip, None, &a, |_| false), None);
        s.resolve(clip, None, &a, |x| *x == a);
        assert_eq!(s.resolve(clip, None, &b, |_| false), None); // a was evicted
        s.resolve(clip, None, &a, |x| *x == a);
        s.prune(&[]);
        assert_eq!(s.resolve(clip, None, &b, |x| *x == a), None);
    }

    #[test]
    fn clips_sharing_a_layer_id_keep_separate_stand_ins() {
        let s = TextStandIns::default();
        let (layer, g1, g2, a, b) = (id(1), id(2), id(3), r(1), r(2));
        s.resolve(layer, Some(g1), &a, |x| *x == a);
        assert_eq!(s.resolve(layer, Some(g2), &b, |x| *x == a), None);
        assert_eq!(s.resolve(layer, Some(g1), &b, |x| *x == a), Some(a.clone()));
        s.prune(&[g2]);
        assert_eq!(s.resolve(layer, Some(g1), &b, |x| *x == a), None);
    }
}
