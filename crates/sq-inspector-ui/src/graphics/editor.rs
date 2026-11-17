// Swift: GraphicsEditor.swift, GraphicsEditor+TextResize.swift, GraphicsEditor+CreateTools.swift, GraphicsEditor+Monitor.swift
//! The Graphics panel's and the Program monitor's view of the selected graphics clip: which layers are selected, and every
//! layer edit as one undo step (property drags merge per layer and property).
//!
//! The Swift class holds the `EditorSession`; here every method that reads or edits takes it as `session`.

use std::collections::BTreeSet;

use sq_core_effects::effect_transform_stage::ClipStageEval;
use sq_core_graphics::graphics_create::{GraphicCreateTargetExt, PathSmoothing};
use sq_core_graphics::graphics_editing::{
    GraphicsAlign, GraphicsAxis, GraphicsCorner, GraphicsDocumentEditingExt, GraphicsLayerGeometryExt, GraphicsRect,
    GraphicsReorder, GraphicsTextMeasure, ResizeDrag, Vec2PropertyExt,
};
use sq_core_graphics::graphics_follow::GraphicsFollowDocumentExt;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::graphics_item_range::GraphicsTextTime;
use sq_core_model::{
    Clip, ClipEffect, EffectCatalog, EffectColor, GeneratorRef, GraphicsContent, GraphicsDocument, GraphicsLayer,
    LabelColor, SequenceFormat, ShapeKind,
};
use sq_core_time::{Id, IdSource, Time, Vec2};
use sq_editor_session::{EditorSession, EffectDragPayload, GraphicLayerSelection};
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::portable_text_carets::TextGeneratorBoxExt;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextBox;
use sq_text::text_template::TextTemplate;
use sq_text::text_template_resize::TextTemplateResizeExt;
use sq_uikit::localization::SQL10n;

use crate::graphics::canvas_mapping::GraphicsCanvasMapping;

/// The result of dropping effects on a layer: the panel shows a refusal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EffectDrop {
    Added,
    Refused(String),
}

/// A layer list drop (Swift `LayerDrop` of `LayerListLogic.swift`).
// shortcut: declared here until the layer list logic of the timeline UI is ported; move it there then.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LayerDrop {
    pub ids: Vec<Id>,
    /// Index in the layer list without the moving layers (0 = bottom).
    pub to_index: i64,
    /// The group the moved layers end up in (`None` = none).
    pub group: Option<Id>,
}

/// What a Type tool click or drag does.
#[derive(Clone, Debug, PartialEq)]
pub enum TypeToolOutcome {
    /// Over a text layer of the selected Graphic.
    EditLayer(Id),
    /// Empty canvas in the selected Graphic (canvas px; area text with a box).
    AddLayer { at: Vec2, box_: Option<TextBox> },
    /// Over an old text clip.
    EditTextClip(Id),
    /// Empty canvas, no Graphic: a new Graphic with one text layer (box in sequence px).
    NewGraphic { at: Vec2, box_: Option<TextBox> },
}

/// A text layer found under a point of the Program picture (Swift `GraphicsEditor.TextLayerHit`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextLayerHit {
    /// The graphics clip.
    pub clip: Id,
    /// The text layer.
    pub layer: Id,
    /// Index of the clip's track in the displayed timeline.
    pub track_index: usize,
}

pub struct GraphicsEditor {
    shown_clip: Option<Id>,
    /// Draw tool: a drag on the Program monitor adds a freeform stroke layer (switched off after each stroke).
    is_drawing: bool,
    gesture: u64,
    ids: Box<dyn IdSource>,
    version: u64,
}

fn name_key(name: &str) -> String {
    SQL10n::undo_name(name)
}

impl GraphicsEditor {
    /// Smoothing tolerance of a stroke when the caller has no view scale (canvas px).
    pub const STROKE_TOLERANCE: f64 = 2.0;

    pub fn new(ids: Box<dyn IdSource>) -> GraphicsEditor {
        GraphicsEditor { shown_clip: None, is_drawing: false, gesture: 0, ids, version: 0 }
    }

    /// Bumped when the layer selection or the draw mode changed (Swift `onSelectionChange`): panel and overlay refresh.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The selected layers of the shown Graphic. The one store is the session's shared item selection
    /// (`graphic_layer_selection`), so a pick on the monitor, in this panel or in Controls is the same selection.
    pub fn selected_layers<'a>(&self, session: &'a EditorSession) -> &'a BTreeSet<Id> {
        static NONE: BTreeSet<Id> = BTreeSet::new();
        let shown = self.clip(session).map(|c| c.id);
        session.graphic_layer_selection().filter(|s| Some(s.clip) == shown).map_or(&NONE, |s| &s.layers)
    }

    pub fn is_drawing(&self) -> bool {
        self.is_drawing
    }

    pub fn set_drawing(&mut self, on: bool) {
        if self.is_drawing != on {
            self.is_drawing = on;
            self.version += 1;
        }
    }

    /// Releases the selection the session shows (Swift `deinit`).
    pub fn close(&mut self, session: &mut EditorSession) {
        session.set_graphic_layer_selection(None);
    }

    /// Stores the layers of the shown Graphic as the session's shared selection (a Look needs the clip too: a copy of the
    /// clip keeps the layer ids).
    fn set_selected(&mut self, session: &mut EditorSession, ids: BTreeSet<Id>) {
        let next =
            if ids.is_empty() { None } else { self.clip(session).map(|c| GraphicLayerSelection::new(c.id, ids)) };
        if session.graphic_layer_selection() != next.as_ref() {
            session.set_graphic_layer_selection(next);
        }
    }

    // MARK: State

    /// The selected clip when it is a graphics clip.
    pub fn clip<'a>(&self, session: &'a EditorSession) -> Option<&'a Clip> {
        session.single_selected_clip().filter(|c| c.is_graphics())
    }

    pub fn document<'a>(&self, session: &'a EditorSession) -> Option<&'a GraphicsDocument> {
        self.clip(session).and_then(|c| c.graphics())
    }

    /// Playhead in the clip's local time (keys are written here), clamped to the clip.
    pub fn local_time(&self, session: &EditorSession) -> Time {
        let Some(c) = self.clip(session) else { return Time::ZERO };
        let t = session.playhead() - c.start;
        if t < Time::ZERO {
            Time::ZERO
        } else if t > c.duration() {
            c.duration()
        } else {
            t
        }
    }

    pub fn canvas(&self, session: &EditorSession) -> Vec2 {
        match session.active_timeline() {
            Some(t) => Vec2::new(t.format.width as f64, t.format.height as f64),
            None => Vec2::new(1920.0, 1080.0),
        }
    }

    /// The single selected layer (properties are shown for it).
    pub fn selected_layer<'a>(&self, session: &'a EditorSession) -> Option<&'a GraphicsLayer> {
        if self.selected_layers(session).len() != 1 {
            return None;
        }
        let id = *self.selected_layers(session).iter().next()?;
        self.document(session)?.layer(id)
    }

    /// The graphic's Motion at the playhead (clip space <-> sequence space).
    pub fn mapping(&self, session: &EditorSession) -> Option<GraphicsCanvasMapping> {
        let c = self.clip(session)?;
        let shown = session.displayed_clip(c);
        Some(GraphicsCanvasMapping::new(shown.render_transform(session.playhead(), self.canvas(session))))
    }

    /// Text bounds for hit tests, handles and align: the text layout's box at scale 1 (layer Motion not applied), on the
    /// item's text time (range-local for an item with a range), the clock render draws it with.
    pub fn text_measure(
        &self,
        session: &EditorSession,
    ) -> impl Fn(&GeneratorRef, GraphicsTextTime) -> Option<GraphicsRect> + use<> {
        let dur = self.clip(session).map_or(Time::new(5, 1), Clip::duration);
        Self::text_measure_for(dur, session.active_timeline().map(|t| t.format.clone()))
    }

    pub fn text_measure_for(
        dur: Time,
        format: Option<SequenceFormat>,
    ) -> impl Fn(&GeneratorRef, GraphicsTextTime) -> Option<GraphicsRect> {
        move |r, t| {
            let format = format.as_ref()?;
            TextGenerator::portable_graphics_rect(r, t.local, t.duration.unwrap_or(dur), format)
        }
    }

    /// Call on every session change: a different clip clears the layer selection; deleted layers drop out of it.
    pub fn sync(&mut self, session: &mut EditorSession) {
        let id = self.clip(session).map(|c| c.id);
        let ids: BTreeSet<Id> =
            self.document(session).map(|d| d.layers.iter().map(|l| l.id).collect()).unwrap_or_default();
        if id != self.shown_clip {
            self.set_drawing(false);
        }
        self.shown_clip = id;
        let kept: BTreeSet<Id> = self.selected_layers(session).intersection(&ids).copied().collect();
        // Also drops a selection another clip left in the session.
        let next = id.filter(|_| !kept.is_empty()).map(|clip| GraphicLayerSelection::new(clip, kept));
        if session.graphic_layer_selection() != next.as_ref() {
            session.set_graphic_layer_selection(next);
            self.version += 1;
        }
    }

    pub fn select(&mut self, session: &mut EditorSession, ids: BTreeSet<Id>) {
        let all: BTreeSet<Id> =
            self.document(session).map(|d| d.layers.iter().map(|l| l.id).collect()).unwrap_or_default();
        let ids: BTreeSet<Id> = ids.intersection(&all).copied().collect();
        if &ids == self.selected_layers(session) {
            return;
        }
        self.set_selected(session, ids);
        self.version += 1;
    }

    pub fn select_all_layers(&mut self, session: &mut EditorSession) {
        let all: BTreeSet<Id> =
            self.document(session).map(|d| d.layers.iter().map(|l| l.id).collect()).unwrap_or_default();
        self.select(session, all);
    }

    /// Starts a new drag: its edits merge into one undo step, separate from the previous drag.
    pub fn begin_gesture(&mut self, session: &mut EditorSession) {
        self.gesture += 1;
        session.stop_playback();
    }

    /// Closes the open gesture: the next edit never merges into it.
    pub fn end_gesture(&mut self) {
        self.gesture += 1;
    }

    // MARK: Edits

    /// Intro / outro zone lengths in seconds (the in and out animation of the whole clip). One undo step per drag.
    pub fn set_zone_lengths(&mut self, session: &mut EditorSession, intro: Option<f64>, outro: Option<f64>) {
        let Some(c) = self.clip(session) else { return };
        let (cid, z) = (c.id, c.zones.clone());
        let t = |s: f64| Time::new((s * 600.0).round() as i64, 600);
        let i = intro.map(t).or(z.as_ref().map(|z| z.intro_end)).unwrap_or(Time::ZERO);
        let o = outro.map(t).or(z.as_ref().map(|z| z.outro_length)).unwrap_or(Time::ZERO);
        let key = format!("zoneLengths:{cid}:{}", self.gesture);
        // A locked track: no change.
        let _ = session.try_perform("Set Intro and Outro", Some(&key), |p| p.set_animation_zone_lengths(i, o, cid));
    }

    /// One undo step on the selected graphics clip. `merge`: edits with the same key merge (drags, steppers).
    pub fn edit(
        &mut self,
        session: &mut EditorSession,
        name: &str,
        merge: Option<&str>,
        body: impl FnOnce(&mut GraphicsDocument),
    ) -> bool {
        self.edit_with_ids(session, name, merge, |d, _| body(d))
    }

    /// `edit` for a body that makes new objects.
    pub fn edit_with_ids(
        &mut self,
        session: &mut EditorSession,
        name: &str,
        merge: Option<&str>,
        body: impl FnOnce(&mut GraphicsDocument, &mut dyn IdSource),
    ) -> bool {
        let Some(c) = self.clip(session) else { return false };
        let cid = c.id;
        let key = merge.map(|m| format!("gfx:{cid}:{m}:{}", self.gesture));
        let ids = self.ids.as_mut();
        session.edit_graphics(cid, &name_key(name), key.as_deref(), |d| body(d, ids))
    }

    /// New Graphics Clip: an empty graphic at the playhead, selected.
    pub fn new_graphics_clip(&mut self, session: &mut EditorSession) -> Option<Id> {
        let id = session.add_graphics_clip(None, None, Time::new(5, 1), Vec::new(), false);
        self.sync(session);
        id
    }

    pub fn add_shape(&mut self, session: &mut EditorSession, kind: ShapeKind) {
        let c = self.canvas(session);
        let layer = GraphicsLayer::shape(self.ids.as_mut(), kind, c.x as i64, c.y as i64);
        self.add(session, layer, &format!("Add {}", shape_title(kind)));
    }

    pub fn add_text(&mut self, session: &mut EditorSession, string: &str) {
        let template = TextTemplate::new("Text", string, CaptionPresetLibrary::built_in().style(Some("title")));
        let Ok(r) = TextGenerator::make_ref(&template, None) else { return };
        let layer = GraphicsLayer::text(self.ids.next_id(), r, string);
        self.add(session, layer, "Add Text");
    }

    /// A free drawing stroke (canvas points, offsets from the canvas center), smoothed and reduced to the points that carry
    /// its shape (`tolerance` in canvas px).
    pub fn add_path(
        &mut self,
        session: &mut EditorSession,
        points: &[Vec2],
        closed: bool,
        color: EffectColor,
        stroke_width: f64,
        tolerance: f64,
    ) {
        self.set_drawing(false);
        let Some(layer) = Self::stroke_layer(self.ids.as_mut(), points, closed, color, stroke_width, tolerance) else {
            return;
        };
        self.add(session, layer, "Draw");
    }

    /// The layer of a drawn stroke; `None` for fewer than two points.
    pub fn stroke_layer(
        ids: &mut dyn IdSource,
        points: &[Vec2],
        closed: bool,
        color: EffectColor,
        stroke_width: f64,
        tolerance: f64,
    ) -> Option<GraphicsLayer> {
        let pts = PathSmoothing::smooth(points, tolerance);
        if pts.len() < 2 {
            return None;
        }
        Some(GraphicsLayer::path(ids, &pts, closed, color, stroke_width))
    }

    /// Adds `layer` above the selected ones as one undo step `name` and selects it.
    pub fn add(&mut self, session: &mut EditorSession, layer: GraphicsLayer, name: &str) {
        let above = self.top_selected(session);
        let new_id = layer.id;
        if !self.edit(session, name, None, |d| {
            d.add(layer, above);
        }) {
            return;
        }
        self.set_selected(session, BTreeSet::from([new_id]));
        self.version += 1;
    }

    /// The selected layer highest in the stack (new layers go right above it).
    fn top_selected(&self, session: &EditorSession) -> Option<Id> {
        let doc = self.document(session)?;
        let top = self.selected_layers(session).iter().filter_map(|id| doc.index_of(*id)).max()?;
        doc.layers.get(top).map(|l| l.id)
    }

    pub fn delete_selected(&mut self, session: &mut EditorSession) {
        let ids = self.selected_layers(session).clone();
        if ids.is_empty() || !self.edit(session, "Delete Layers", None, |d| d.remove(&ids)) {
            return;
        }
        self.select(session, BTreeSet::new());
    }

    pub fn duplicate_selected(&mut self, session: &mut EditorSession) {
        let Some(doc) = self.document(session) else { return };
        if self.selected_layers(session).is_empty() {
            return;
        }
        let ordered: Vec<Id> =
            doc.layers.iter().map(|l| l.id).filter(|id| self.selected_layers(session).contains(id)).collect();
        let mut copies: Vec<Id> = Vec::new();
        if !self.edit_with_ids(session, "Duplicate Layers", None, |d, ids| copies = d.duplicate(&ordered, ids)) {
            return;
        }
        self.set_selected(session, copies.into_iter().collect());
        self.version += 1;
    }

    pub fn group_selected(&mut self, session: &mut EditorSession) {
        let ids: Vec<Id> = self.selected_layers(session).iter().copied().collect();
        if ids.len() < 2 {
            return;
        }
        self.edit_with_ids(session, "Group Layers", None, |d, new_ids| {
            d.group_layers(&ids, "Group", new_ids);
        });
    }

    pub fn ungroup_selected(&mut self, session: &mut EditorSession) {
        let Some(doc) = self.document(session) else { return };
        let groups: BTreeSet<Id> =
            self.selected_layers(session).iter().filter_map(|id| doc.layer(*id).and_then(|l| l.group)).collect();
        if groups.is_empty() {
            return;
        }
        self.edit(session, "Ungroup Layers", None, |d| {
            for g in &groups {
                d.ungroup(*g);
            }
        });
    }

    pub fn reorder(&mut self, session: &mut EditorSession, how: GraphicsReorder) {
        let ids: Vec<Id> = self.selected_layers(session).iter().copied().collect();
        if ids.is_empty() {
            return;
        }
        self.edit(session, "Arrange Layers", None, |d| d.reorder(&ids, how));
    }

    pub fn move_layers(&mut self, session: &mut EditorSession, ids: &[Id], to_index: i64) {
        let set: BTreeSet<Id> = ids.iter().copied().collect();
        self.edit(session, "Arrange Layers", None, |d| d.move_to_index(&set, to_index));
    }

    /// Layer list drag: one undo step "Arrange Layers"; the moved layers stay selected.
    pub fn apply(&mut self, session: &mut EditorSession, drop: &LayerDrop) {
        let set: BTreeSet<Id> = drop.ids.iter().copied().collect();
        if !self.edit(session, "Arrange Layers", None, |d| d.move_to_index_in_group(&set, drop.to_index, drop.group)) {
            return;
        }
        self.select(session, set);
    }

    /// Layer list Option-drag: copies of the dragged layers land at the drop, the originals stay; the copies are selected.
    pub fn apply_copy(&mut self, session: &mut EditorSession, drop: &LayerDrop) {
        let set: BTreeSet<Id> = drop.ids.iter().copied().collect();
        let mut copies: Vec<Id> = Vec::new();
        if !self.edit_with_ids(session, "Duplicate Layers", None, |d, ids| {
            copies = d.copy_to_index(&set, drop.to_index, drop.group, ids);
        }) || copies.is_empty()
        {
            return;
        }
        self.select(session, copies.into_iter().collect());
    }

    pub fn rename_group(&mut self, session: &mut EditorSession, id: Id, name: &str) {
        let Some(old) = self.document(session).and_then(|d| d.group(id)).map(|g| g.name.clone()) else { return };
        if old == name.trim() {
            return;
        }
        self.edit(session, "Rename Group", None, |d| d.rename_group(id, name));
    }

    /// Eye of a group row: every member shown or hidden, one undo step.
    pub fn set_visible_all(&mut self, session: &mut EditorSession, ids: &BTreeSet<Id>, on: bool) {
        self.edit(session, if on { "Show Layers" } else { "Hide Layers" }, None, |d| {
            for id in ids {
                d.update(*id, |l| l.is_visible = on);
            }
        });
    }

    /// Lock of a group row: every member locked or unlocked, one undo step.
    pub fn set_locked_all(&mut self, session: &mut EditorSession, ids: &BTreeSet<Id>, on: bool) {
        self.edit(session, if on { "Lock Layers" } else { "Unlock Layers" }, None, |d| {
            for id in ids {
                d.update(*id, |l| l.is_locked = on);
            }
        });
    }

    /// Isolate: every layer except the selected ones hidden (`lock` false) or locked (`lock` true), one undo step.
    pub fn isolate_selection(&mut self, session: &mut EditorSession, lock: bool) {
        let keep = self.selected_layers(session).clone();
        let Some(all) = self.document(session).map(|d| d.layers.iter().map(|l| l.id).collect::<Vec<_>>()) else {
            return;
        };
        let others: Vec<Id> = all.into_iter().filter(|id| !keep.contains(id)).collect();
        if keep.is_empty() || others.is_empty() {
            return;
        }
        self.edit(session, if lock { "Lock Others" } else { "Hide Others" }, None, |d| {
            for id in &others {
                d.update(*id, |l| if lock { l.is_locked = true } else { l.is_visible = false });
            }
        });
    }

    /// Every layer shown and unlocked, one undo step.
    pub fn show_all_layers(&mut self, session: &mut EditorSession) {
        let Some(all) = self.document(session).map(|d| d.layers.iter().map(|l| l.id).collect::<Vec<_>>()) else {
            return;
        };
        if all.is_empty() {
            return;
        }
        self.edit(session, "Show All Layers", None, |d| {
            for id in &all {
                d.update(*id, |l| {
                    l.is_visible = true;
                    l.is_locked = false;
                });
            }
        });
    }

    /// The members of group `g`.
    pub fn members(&self, session: &EditorSession, g: Id) -> BTreeSet<Id> {
        self.document(session)
            .map(|d| d.layers.iter().filter(|l| l.group == Some(g)).map(|l| l.id).collect())
            .unwrap_or_default()
    }

    /// Align: to the frame (each layer on its own) or, for 2+ layers, to the selection's joint bounds.
    pub fn align(&mut self, session: &mut EditorSession, edge: GraphicsAlign, to_frame: bool) {
        let ids: Vec<Id> = self.selected_layers(session).iter().copied().collect();
        let (t, c) = (self.local_time(session), self.canvas(session));
        let m = self.text_measure(session);
        if ids.is_empty() {
            return;
        }
        // Measured as drawn (Follow resolved); axes and sizes Follow sets stay its own.
        self.edit(session, "Align Layers", None, |d| {
            d.editing_resolved(t, c, Some(&m), |d| d.align(&ids, edge, c, t, Some(&m), to_frame));
        });
    }

    pub fn distribute(&mut self, session: &mut EditorSession, axis: GraphicsAxis) {
        let ids: Vec<Id> = self.selected_layers(session).iter().copied().collect();
        let (t, c) = (self.local_time(session), self.canvas(session));
        let m = self.text_measure(session);
        if ids.len() < 3 {
            return;
        }
        self.edit(session, "Distribute Layers", None, |d| {
            d.editing_resolved(t, c, Some(&m), |d| d.distribute(&ids, axis, t, Some(&m)));
        });
    }

    pub fn set_visible(&mut self, session: &mut EditorSession, id: Id, on: bool) {
        self.edit(session, if on { "Show Layer" } else { "Hide Layer" }, None, |d| d.update(id, |l| l.is_visible = on));
    }

    pub fn set_locked(&mut self, session: &mut EditorSession, id: Id, on: bool) {
        self.edit(session, if on { "Lock Layer" } else { "Unlock Layer" }, None, |d| {
            d.update(id, |l| l.is_locked = on)
        });
    }

    /// Color label of the layers (`None` = none), one undo step; unchanged = no step.
    pub fn set_label(&mut self, session: &mut EditorSession, ids: &[Id], label: Option<LabelColor>) {
        let Some(d) = self.document(session) else { return };
        if !ids.iter().any(|id| d.layer(*id).map(|l| l.label) != Some(label)) {
            return;
        }
        self.edit(session, if label.is_none() { "Clear Layer Label" } else { "Label Layers" }, None, |d| {
            for id in ids {
                d.update(*id, |l| l.label = label);
            }
        });
    }

    pub fn rename(&mut self, session: &mut EditorSession, id: Id, name: &str) {
        let n = name.trim().to_string();
        if n.is_empty() || self.document(session).and_then(|d| d.layer(id)).is_some_and(|l| l.name == n) {
            return;
        }
        self.edit(session, "Rename Layer", None, |d| d.update(id, |l| l.name = n));
    }

    /// Monitor drag: moves the selected layers (and their groups) by a canvas delta; one undo step per drag.
    pub fn translate_selected(&mut self, session: &mut EditorSession, by: Vec2) {
        let ids: Vec<Id> = self.selected_layers(session).iter().copied().collect();
        if ids.is_empty() || by == Vec2::ZERO {
            return;
        }
        // A pinned layer's dragged axis is unpinned where it is drawn.
        let (t, c) = (self.local_time(session), self.canvas(session));
        let m = self.text_measure(session);
        self.edit(session, "Move Layers", Some("move"), |d| d.move_editing_resolved(&ids, by, t, c, Some(&m)));
    }

    /// Monitor corner handle drag (one undo step per drag).
    pub fn resize(&mut self, session: &mut EditorSession, id: Id, corner: GraphicsCorner, to: Vec2, keep_aspect: bool) {
        let (t, c) = (self.local_time(session), self.canvas(session));
        let m = self.text_measure(session);
        let drag = ResizeDrag { corner, to, keep_aspect };
        // Text: the handles change the font size, not Scale (non-text layers keep scaling).
        if let Some(doc) = self.document(session)
            && let Some(out) = Self::resizing_text(doc, id, drag, t, Some(&m), self.ids.as_mut())
        {
            self.edit(session, "Resize Text", Some("resize"), |d| *d = out);
            return;
        }
        self.edit_with_ids(session, "Resize Layer", Some("resize"), |d, ids| {
            d.editing_resolved(t, c, Some(&m), |d| d.resize(id, drag, t, Some(&m), ids));
        });
    }

    // MARK: Text resize

    /// A corner-handle drag on a text layer: the font size (tracking, line spacing, area box) follows the handle by the same
    /// factor the core resize would have scaled the layer by, Scale stays, and the opposite corner stays put. `None` when
    /// `id` is not an unlocked text layer or nothing changes (the caller then runs the plain resize).
    // known limit: a Follow-pinned text layer is edited as stored (not as drawn); upgrade when Follow resizes text boxes.
    pub(crate) fn resizing_text(
        doc: &GraphicsDocument,
        id: Id,
        drag: ResizeDrag,
        t: Time,
        text: Option<GraphicsTextMeasure>,
        ids: &mut dyn IdSource,
    ) -> Option<GraphicsDocument> {
        let mut l = doc.layer(id)?.clone();
        let GraphicsContent::Text { generator } = &l.content else { return None };
        if l.is_locked {
            return None;
        }
        let decoded = TextGenerator::decode(generator).ok()?;
        let before = l.corners(t, text)?;
        // The factor: what the core resize does to Scale (geometric mean of the axis ratios; edge handles stretch one axis).
        let mut probe = doc.clone();
        probe.resize(id, drag, t, text, ids);
        let s0 = l.animation.scale.value_at_local(t);
        let s1 = probe.layer(id)?.animation.scale.value_at_local(t);
        if s0.x.abs() <= 1e-9 || s0.y.abs() <= 1e-9 {
            return None;
        }
        let f = ((s1.x / s0.x) * (s1.y / s0.y)).abs().sqrt();
        if !f.is_finite() || f <= 0.0 || (f - 1.0).abs() <= 1e-9 {
            return None;
        }
        let new = TextGenerator::make_ref(&decoded.0.resized(f), decoded.1.as_ref()).ok()?;
        l.content = GraphicsContent::Text { generator: new };
        if let Some(after) = l.corners(t, text) {
            let k = match drag.corner.opposite() {
                GraphicsCorner::TopLeft => 0,
                GraphicsCorner::TopRight => 1,
                GraphicsCorner::BottomRight => 2,
                GraphicsCorner::BottomLeft => 3,
            };
            let d = before[k] - after[k];
            if d != Vec2::ZERO {
                l.animation.position = l.animation.position.moved_base(l.animation.position.value_at_local(t) + d, t);
            }
        }
        let mut out = doc.clone();
        out.update(id, |x| *x = l);
        Some(out)
    }

    // MARK: Layer list helpers

    /// The selected layers, bottom first.
    pub fn target_layers<'a>(&self, session: &'a EditorSession) -> Vec<&'a GraphicsLayer> {
        self.document(session)
            .map(|d| d.layers.iter().filter(|l| self.selected_layers(session).contains(&l.id)).collect())
            .unwrap_or_default()
    }

    /// The front-most selected layer: its key state is what the stopwatch shows.
    pub fn primary_layer<'a>(&self, session: &'a EditorSession) -> Option<&'a GraphicsLayer> {
        self.target_layers(session).last().copied()
    }

    // MARK: Text

    pub fn text_template(&self, session: &EditorSession) -> Option<TextTemplate> {
        let l = self.selected_layer(session)?;
        let GraphicsContent::Text { generator } = &l.content else { return None };
        TextGenerator::decode(generator).ok().map(|d| d.0)
    }

    /// In / Out animation of the selected text layer (`None` for other layers; an empty set when none is stored).
    pub fn text_animations(&self, session: &EditorSession) -> Option<AnimationSet> {
        let l = self.selected_layer(session)?;
        let GraphicsContent::Text { generator } = &l.content else { return None };
        let d = TextGenerator::decode(generator).ok()?;
        Some(d.1.unwrap_or_else(|| AnimationSet::new(None, None)))
    }

    /// Stores new In / Out animations on the selected text layer; the style and text stay as they are. One undo step.
    pub fn update_text_animations(&mut self, session: &mut EditorSession, name: &str, animations: &AnimationSet) {
        self.update_text(session, name, Some(animations), |_| {});
    }

    /// Text string, size or color of the selected text layer (the layer name follows a string that was its name).
    pub fn update_text(
        &mut self,
        session: &mut EditorSession,
        name: &str,
        animations: Option<&AnimationSet>,
        body: impl FnOnce(&mut TextTemplate),
    ) {
        let Some(l) = self.selected_layer(session) else { return };
        let GraphicsContent::Text { generator } = &l.content else { return };
        let Ok(decoded) = TextGenerator::decode(generator) else { return };
        let (lid, lname) = (l.id, l.name.clone());
        let mut template = decoded.0;
        let anims = animations.cloned().or(decoded.1);
        let old_text = template.text.clone();
        body(&mut template);
        let Ok(new) = TextGenerator::make_ref(&template, anims.as_ref()) else { return };
        let rename = lname == old_text || lname == "Text";
        let text = template.text;
        self.edit(session, name, Some(&format!("{lid}:text:{name}")), |d| {
            d.update(lid, |l| {
                l.content = GraphicsContent::Text { generator: new };
                if rename && !text.is_empty() {
                    l.name = text.chars().take(40).collect();
                }
            })
        });
    }

    // MARK: Create tools

    /// The Graphic a new item goes into, selected when it was found through the targeted track. With
    /// `converting_text_or_shape`, a selected old text or shape clip under the playhead becomes a Graphic first (the
    /// "Make Graphic" conversion). `false`: there is none.
    pub fn adopt_create_target(&mut self, session: &mut EditorSession, converting_text_or_shape: bool) -> bool {
        let Some(t) = session.active_timeline() else { return false };
        if let Some(target) = t.graphic_create_target(session.selection(), session.playhead()) {
            if session.single_selected_clip().map(|c| c.id) != Some(target) {
                session.select(BTreeSet::from([target]), BTreeSet::new());
            }
            self.sync(session);
            return self.clip(session).map(|c| c.id) == Some(target);
        }
        if converting_text_or_shape
            && let Some(c) = session.single_selected_clip()
            && c.timeline().contains(session.playhead())
        {
            let cid = c.id;
            if session.make_graphic() {
                self.sync(session);
                return self.clip(session).map(|c| c.id) == Some(cid);
            }
        }
        false
    }

    /// Create tool item: `make` builds the layer from the Graphic's Motion at the playhead and the canvas size. It goes into
    /// the Graphic that takes it (a selected old text or shape clip is converted first); one undo step ("Make Graphic" and
    /// the item fold into `name`). `false`: no Graphic takes it, the caller makes a new Graphic clip.
    pub fn add_created_item(
        &mut self,
        session: &mut EditorSession,
        name: &str,
        make: impl FnOnce(&mut dyn IdSource, &GraphicsCanvasMapping, Vec2) -> Option<GraphicsLayer>,
    ) -> bool {
        let depth = session.undo_depth();
        let map = if self.adopt_create_target(session, true) { self.mapping(session) } else { None };
        let Some(map) = map else {
            if session.undo_depth() > depth {
                session.rewind_undo(depth);
                self.sync(session);
            }
            return false;
        };
        let canvas = self.canvas(session);
        let Some(layer) = make(self.ids.as_mut(), &map, canvas) else {
            if session.undo_depth() > depth {
                session.rewind_undo(depth);
                self.sync(session);
            }
            // A Graphic takes it, the gesture just gave nothing.
            return true;
        };
        self.add(session, layer, name);
        if session.undo_depth() > depth + 1 {
            session.fold_undo(depth, name);
        }
        true
    }

    /// The decision behind the Type tool at `point` (sequence px). A Graphic selected under the playhead takes the text;
    /// otherwise `text_clip_hit` (the old text clip under the point) / `hit_is_point_text` decide. A drag over a text layer
    /// or point text edits it like a click; a drag over area text starts a new one.
    pub fn type_tool_outcome(
        &self,
        session: &EditorSession,
        point: Vec2,
        box_: Option<TextBox>,
        text_clip_hit: Option<Id>,
        hit_is_point_text: bool,
    ) -> TypeToolOutcome {
        if let Some(c) = self.clip(session)
            && c.timeline().contains(session.playhead())
            && let Some(map) = self.mapping(session)
        {
            let p = map.canvas_point_from_sequence(point);
            if let Some(layer) = self.text_layer_at(session, p) {
                return TypeToolOutcome::EditLayer(layer);
            }
            let canvas_box = box_.map(|b| {
                let d = map.canvas_delta_from_sequence(Vec2::new(b.width, b.height));
                TextBox::new(d.x.abs(), d.y.abs())
            });
            return TypeToolOutcome::AddLayer { at: p, box_: canvas_box };
        }
        if let Some(hit) = text_clip_hit
            && (box_.is_none() || hit_is_point_text)
        {
            return TypeToolOutcome::EditTextClip(hit);
        }
        TypeToolOutcome::NewGraphic { at: point, box_ }
    }

    // MARK: Program monitor

    /// A new text layer centered on canvas point `p`, selected, one undo step. Returns its ID. With `box_` (canvas px) it is
    /// area text: the text wraps inside the box, left aligned.
    pub fn add_text_at(
        &mut self,
        session: &mut EditorSession,
        p: Vec2,
        string: &str,
        box_: Option<TextBox>,
    ) -> Option<Id> {
        let mut template = TextTemplate::new("Text", string, CaptionPresetLibrary::built_in().style(Some("title")));
        if let Some(b) = box_ {
            template.box_ = Some(b);
            template.style.alignment = sq_text::text_style::TextAlignment::Left;
        }
        let r = TextGenerator::make_ref(&template, None).ok()?;
        let mut layer = GraphicsLayer::text(self.ids.next_id(), r, string);
        let t = self.local_time(session);
        let mut at = p;
        let m = self.text_measure(session);
        if let Some(r) = layer.content_rect(t, Some(&m)) {
            at = Vec2::new(p.x - r.mid_x(), p.y - r.mid_y());
        }
        layer.animation.position.set_at_local(at, t, self.ids.as_mut());
        let above = self.top_selected(session);
        let new_id = layer.id;
        if !self.edit(session, "Add Text", None, |d| {
            d.add(layer, above);
        }) {
            return None;
        }
        self.select(session, BTreeSet::from([new_id]));
        Some(new_id)
    }

    /// Select Layer Above / Below. `false` when no graphic with layers is open; at the end of the stack the selection stays.
    pub fn step_layer_selection(&mut self, session: &mut EditorSession, up: bool) -> bool {
        let Some(doc) = self.document(session).filter(|d| !d.layers.is_empty()) else { return false };
        if let Some(id) = doc.step_target(self.selected_layers(session), up) {
            self.select(session, BTreeSet::from([id]));
        }
        true
    }

    /// Withdraws a layer that was created and left empty: every undo step above `depth` goes, no redo entry stays.
    pub fn discard_new_layer(&mut self, session: &mut EditorSession, depth: usize) {
        if session.undo_depth() > depth {
            session.rewind_undo(depth);
        }
        self.sync(session);
        self.select(session, BTreeSet::new());
    }

    /// True while a monitor text edit on `layer` of graphic `clip` still applies: same clip, that layer alone selected.
    pub fn is_editing_valid(&self, session: &EditorSession, layer: Id, clip: Id) -> bool {
        self.clip(session).map(|c| c.id) == Some(clip)
            && *self.selected_layers(session) == BTreeSet::from([layer])
            && self.document(session).and_then(|d| d.layer(layer)).is_some()
    }

    /// The topmost text layer under canvas point `p` (`None` when something else is on top or it is locked).
    pub fn text_layer_at(&self, session: &EditorSession, p: Vec2) -> Option<Id> {
        let doc = self.shown_document(session)?;
        let m = self.text_measure(session);
        crate::graphics::monitor_logic::text_layer_at(&doc, p, self.local_time(session), Some(&m))
    }

    /// The topmost enabled Graphic under the playhead whose text layer lies under sequence point `p`, over all visible video
    /// tracks (Swift `textLayerHit(atSequence:)`, the Select tool's pick).
    pub fn text_layer_hit(&self, session: &EditorSession, p: Vec2) -> Option<TextLayerHit> {
        let tl = session.display_timeline()?;
        let canvas = self.canvas(session);
        let now = session.playhead();
        for (index, track) in tl.tracks.iter().enumerate().rev() {
            if track.kind != sq_core_model::TrackKind::Video || !track.is_visible {
                continue;
            }
            for c in
                track.clips().iter().rev().filter(|c| c.is_enabled && c.is_graphics() && c.timeline().contains(now))
            {
                let Some(doc) = c.graphics() else { continue };
                let shown = session.displayed_clip(c);
                let map = GraphicsCanvasMapping::new(shown.render_transform(now, canvas));
                let local = (now - c.start).max(Time::ZERO).min(c.duration());
                let measure = Self::text_measure_for(c.duration(), Some(tl.format.clone()));
                if let Some(layer) = crate::graphics::monitor_logic::text_layer_at(
                    doc,
                    map.canvas_point_from_sequence(p),
                    local,
                    Some(&measure),
                ) {
                    return Some(TextLayerHit { clip: c.id, layer, track_index: index });
                }
            }
        }
        None
    }

    /// Moves the playhead to a clip-local time.
    pub fn seek_local(&self, session: &mut EditorSession, t: Time) {
        let Some(start) = self.clip(session).map(|c| c.start) else { return };
        session.seek(start + t);
    }

    /// The playhead lies inside the selected graphics clip (a key can only be added there).
    pub fn playhead_in_clip(&self, session: &EditorSession) -> bool {
        let Some(c) = self.clip(session) else { return false };
        session.playhead() >= c.start && session.playhead() < c.start + c.duration()
    }

    /// Why `kind` cannot go onto a graphics layer (`None` = it can). One rule for the drop from the Effects panel and the API.
    pub fn refusal_for_effect(kind: &str) -> Option<&'static str> {
        if EffectDragPayload::transition_kind(kind).is_some() {
            return Some("Transitions go on the timeline, not on a layer.");
        }
        if EffectCatalog::is_generator_owned(kind) {
            return Some("That look is built into the layer.");
        }
        if EffectCatalog::spec_for(kind).is_none() {
            return Some("That is not a layer effect.");
        }
        if ClipEffect::is_audio_kind(kind) {
            return Some("Audio effects do not apply to graphics.");
        }
        None
    }

    /// Appends several effects (a dragged folder) to `layer` (default: the selected layer) as one undo step. Refused
    /// kinds are skipped; the result is the first refusal when there was one, else `Added`.
    pub fn add_effects(&mut self, session: &mut EditorSession, kinds: &[String], layer: Option<Id>) -> EffectDrop {
        let target = layer.or_else(|| self.selected_layer(session).map(|l| l.id));
        let Some(id) = target else { return EffectDrop::Refused("Select a layer first.".to_string()) };
        let Some(locked) = self.document(session).and_then(|d| d.layer(id)).map(|l| l.is_locked) else {
            return EffectDrop::Refused("Select a layer first.".to_string());
        };
        if locked {
            return EffectDrop::Refused("The layer is locked.".to_string());
        }
        let mut new = Vec::new();
        let mut refusal: Option<String> = None;
        for kind in kinds {
            if let Some(why) = Self::refusal_for_effect(kind) {
                refusal.get_or_insert_with(|| why.to_string());
                continue;
            }
            match ClipEffect::make(self.ids.next_id(), kind) {
                Some(e) => new.push(e),
                None => {
                    refusal.get_or_insert_with(|| "That is not a layer effect.".to_string());
                }
            }
        }
        if !new.is_empty() {
            self.edit(session, "Add Effect", None, |d| d.update(id, |l| l.effects.extend(new)));
        }
        refusal.map_or(EffectDrop::Added, EffectDrop::Refused)
    }

    /// The document as drawn: layer Follow links resolved at the playhead.
    pub fn shown_document(&self, session: &EditorSession) -> Option<GraphicsDocument> {
        let doc = self.document(session)?;
        let (t, c) = (self.local_time(session), self.canvas(session));
        let m = self.text_measure(session);
        Some(doc.resolving_follow(t, c, Some(&m)))
    }
}

pub(crate) fn shape_title(kind: ShapeKind) -> &'static str {
    match kind {
        ShapeKind::Rectangle => "Rectangle",
        ShapeKind::Ellipse => "Ellipse",
        ShapeKind::Line => "Line",
        ShapeKind::Arrow => "Arrow",
    }
}
