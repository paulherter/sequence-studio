// Swift: KeystoneEaseSource.swift
//! The curve popover's source for one keystone's own curve: reads it (or the first segment's ease when it has none) and
//! writes it back to the Library at the end of a handle drag or on a chip click.

use crate::keystones_panel_model::KeystonesPanelModel;
use sq_core_effects::keystone::Keystone;
use sq_core_model::{EaseReading, EaseShape};
use sq_core_time::{EasingCurve, Id, IdSource, KeyframeTrack};
use sq_uikit::ease_curve_source::EaseCurveSource;
use std::cell::RefCell;
use std::rc::Rc;

pub struct KeystoneEaseSource {
    pub model: Rc<RefCell<KeystonesPanelModel>>,
    pub id: Id,
    in_gesture: bool,
    pending: Option<EaseShape>,
    /// Ids of the curves it saves (Swift `EasingCurve(...)` makes a `UUID()`).
    ids: Box<dyn IdSource>,
}

impl KeystoneEaseSource {
    pub fn new(model: Rc<RefCell<KeystonesPanelModel>>, id: Id, ids: Box<dyn IdSource>) -> Self {
        KeystoneEaseSource { model, id, in_gesture: false, pending: None, ids }
    }

    fn keystone(&self) -> Option<Keystone> {
        self.model.borrow_mut().keystones().iter().find(|k| k.id == self.id).cloned()
    }

    /// The ease of the first segment of the first keyed property (scale, position, rotation, opacity).
    pub fn first_segment(k: &Keystone) -> Option<EaseShape> {
        fn shape<V>(t: &Option<KeyframeTrack<V>>) -> Option<EaseShape> {
            let t = t.as_ref().filter(|t| t.keys.len() >= 2)?;
            Some(EaseShape::new(t.keys[0].interpolation, t.keys[0].out_handle, t.keys[1].in_handle))
        }
        shape(&k.scale).or_else(|| shape(&k.position)).or_else(|| shape(&k.rotation)).or_else(|| shape(&k.opacity))
    }

    fn save(&mut self, shape: EaseShape) {
        let curve =
            EasingCurve::new(self.ids.next_id(), "Custom".to_string(), shape.interpolation(), shape.out, shape.r#in);
        self.model.borrow_mut().set_easing(Some(curve), self.id);
    }
}

impl EaseCurveSource for KeystoneEaseSource {
    fn ease_reading(&self) -> EaseReading {
        if let Some(p) = self.pending {
            return EaseReading::Common(p);
        }
        let Some(k) = self.keystone() else { return EaseReading::Empty };
        if let Some(e) = &k.easing {
            return EaseReading::Common(EaseShape::new(e.interpolation(), e.out_handle, e.in_handle));
        }
        Self::first_segment(&k).map_or(EaseReading::Empty, EaseReading::Common)
    }

    fn apply_ease_shape(&mut self, shape: EaseShape) {
        if self.in_gesture {
            self.pending = Some(shape);
            return;
        }
        self.save(shape);
    }

    fn begin_gesture(&mut self) {
        self.in_gesture = true;
    }

    fn end_gesture(&mut self) {
        self.in_gesture = false;
        if let Some(p) = self.pending.take() {
            self.save(p);
        }
    }

    fn session_easing_curves(&self) -> Vec<EasingCurve> {
        Vec::new()
    }

    fn observe_ease_inputs(&self) {
        // `version()` is what a view polls; nothing to register here.
    }

    fn empty_ease_hint(&self) -> String {
        "Select a keystone".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{EaseHandle, Interpolation, SequentialIds};

    fn setup() -> (KeystoneEaseSource, Rc<RefCell<Vec<Keystone>>>, Id) {
        let model = Rc::new(RefCell::new(KeystonesPanelModel::new()));
        let id = model.borrow_mut().keystones()[0].id;
        let saved = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&saved);
        model.borrow_mut().on_save = Some(Rc::new(move |k| sink.borrow_mut().push(k)));
        (KeystoneEaseSource::new(model, id, Box::new(SequentialIds::default())), saved, id)
    }

    fn shape() -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.2, dy: 0.0 }, EaseHandle { dx: 0.5, dy: 1.0 })
    }

    #[test]
    fn a_shape_applied_outside_a_gesture_saves_at_once() {
        let (mut s, saved, id) = setup();
        s.apply_ease_shape(shape());
        assert_eq!(saved.borrow().len(), 1);
        assert_eq!(saved.borrow()[0].id, id);
        assert_eq!(saved.borrow()[0].easing.as_ref().map(|e| e.name.as_str()), Some("Custom"));
    }

    #[test]
    fn a_gesture_saves_once_at_its_end_and_reads_the_pending_shape() {
        let (mut s, saved, _) = setup();
        s.begin_gesture();
        s.apply_ease_shape(shape());
        s.apply_ease_shape(shape());
        assert!(saved.borrow().is_empty());
        assert_eq!(s.ease_reading(), EaseReading::Common(shape()));
        s.end_gesture();
        assert_eq!(saved.borrow().len(), 1);
    }

    #[test]
    fn an_unknown_keystone_reads_empty() {
        let model = Rc::new(RefCell::new(KeystonesPanelModel::new()));
        let s = KeystoneEaseSource::new(model, Id::from_u128(3), Box::new(SequentialIds::default()));
        assert_eq!(s.ease_reading(), EaseReading::Empty);
        assert_eq!(s.empty_ease_hint(), "Select a keystone");
    }
}
