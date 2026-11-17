// Swift: MonitorTextHost.swift (`typeToolAct`, `createText`, `doubleClick`, `beginCaptionEditing`, the field's hooks)
//! The Program monitor's text work: the Type tool (a click makes point text, a drag area text), a double-click on a text
//! clip or a caption edits it in place, and the on-canvas field's edits reach the layer at once. A new text left empty
//! leaves no undo trace, a new one with text is one "Add Text" step.
// known limit: the field's caret map is the stand-in (the UI font's advances) until the portable raster's caret map is
// wired as `caret_source`; the caret follows a click only roughly. Upgrade with the text layout on the monitor.

use super::MonitorHost;
use sq_core_model::ClipTransform;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_time::{Id, KeyframeTrack, Time, Vec2};
use sq_draw_monitor::monitor_panel::PanelEvent;
use sq_draw_monitor::monitor_text_field::{StyleToggle, TextFieldEvent};
use sq_draw_monitor::text_hit_test::TextHitTest;
use sq_editor_session::{CaptionMonitorHit, EditorSession, OverlayTarget};
use sq_inspector_ui::graphics::editor::{GraphicsEditor, TypeToolOutcome};
use sq_text::caption_presets::CaptionLookRegistry;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::{TextAlignment, TextBox};
use sq_text::text_template::TextTemplate;
use sq_uikit::controls_grid::CGSize;
use sq_uikit::keyframe_graph_geometry::Size;
use std::collections::BTreeSet;

/// What the field edits (Swift `MonitorTextHost.Editing`).
#[derive(Clone, Debug)]
pub enum Editing {
    /// A text layer of a Graphic.
    Graphic { layer: Id, clip: Id, is_new: bool, depth: usize },
    /// An old text clip.
    Clip(Box<ClipEdit>),
    /// A caption opened by a double-click on its text: typing is one undo step.
    Caption { id: Id, first: bool },
}

/// An old text clip being edited: its template and animations as they were at the last edit.
#[derive(Clone, Debug)]
pub struct ClipEdit {
    id: Id,
    template: TextTemplate,
    animations: Option<AnimationSet>,
    is_new: bool,
    depth: usize,
    first: bool,
}

impl MonitorHost {
    /// True while the on-canvas field is open.
    pub fn is_text_editing(&self) -> bool {
        self.panel.text_field.is_editing()
    }

    /// Wires the Type tool: it works while the timeline's Type tool is on in its Text mode. Double-clicks always work.
    pub fn set_type_tool(&mut self, on: bool) {
        self.panel.wiring.type_tool = true;
        self.panel.wiring.text_double_click = true;
        self.panel.type_tool_on = on;
    }

    /// Runs a Type tool or double-click event; `false` when `event` is not one. `seconds`: the New Text Length.
    pub fn run_text_event(
        &mut self,
        session: &mut EditorSession,
        editor: Option<&mut GraphicsEditor>,
        seconds: i64,
        event: &PanelEvent,
    ) -> bool {
        match event {
            PanelEvent::TypeClick(p) => self.type_tool_act(session, editor, seconds, *p, None),
            PanelEvent::TypeBox { center, size } => {
                self.type_tool_act(session, editor, seconds, *center, Some(TextBox::new(size.x, size.y)));
            }
            PanelEvent::TextDoubleClick(p) => self.double_click(session, editor, *p),
            PanelEvent::CaptionDoubleClick(p) => self.begin_caption_editing(session, *p),
            _ => return false,
        }
        true
    }

    fn text_clip_at(session: &EditorSession, p: Vec2) -> Option<Id> {
        let tl = session.display_timeline()?;
        TextHitTest::topmost_text_clip(p, &tl, session.project(), session.playhead())
    }

    /// `GraphicsEditor::type_tool_outcome` for a click (`box_` none) or a drag at `position` (sequence px).
    fn type_tool_act(
        &mut self,
        session: &mut EditorSession,
        editor: Option<&mut GraphicsEditor>,
        seconds: i64,
        position: Vec2,
        box_: Option<TextBox>,
    ) {
        let Some(g) = editor else { return };
        // Existing text of a Graphic that is not selected: select that Graphic, the click then edits the layer.
        Self::select_graphic_of_text_at(session, g, position);
        // No Graphic under the playhead selected and no text under the pointer: the targeted Graphic takes the text.
        let active = g.clip(session).is_some_and(|c| c.timeline().contains(session.playhead()));
        if !active && Self::text_clip_at(session, position).is_none() {
            g.adopt_create_target(session, false);
        }
        let hit = Self::text_clip_at(session, position);
        let point_text = hit
            .and_then(|id| {
                let tl = session.active_timeline()?;
                let clip = tl.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == id)?;
                let (t, _) = TextGenerator::decode(clip.generator.as_ref()?).ok()?;
                Some(t.box_.is_none())
            })
            .unwrap_or(false);
        match g.type_tool_outcome(session, position, box_, hit, point_text) {
            TypeToolOutcome::EditLayer(id) => {
                g.select(session, BTreeSet::from([id]));
                self.begin_graphic(session, g, id, false, 0, false, Some(position));
            }
            TypeToolOutcome::AddLayer { at, box_ } => {
                session.stop_playback();
                let depth = session.undo_depth();
                let Some(id) = g.add_text_at(session, at, "Text", box_) else { return };
                self.begin_graphic(session, g, id, true, depth, true, None);
            }
            TypeToolOutcome::EditTextClip(id) => {
                session.stop_playback();
                session.select(BTreeSet::from([id]), BTreeSet::new());
                self.begin_clip(session, id, false, 0, Some(position));
            }
            TypeToolOutcome::NewGraphic { box_, .. } => self.create_text(session, g, seconds, position, box_),
        }
    }

    /// Type tool on empty canvas: a new Graphic clip with one text layer, typed at once (one "Add Text" step).
    fn create_text(
        &mut self,
        session: &mut EditorSession,
        g: &mut GraphicsEditor,
        seconds: i64,
        position: Vec2,
        box_: Option<TextBox>,
    ) {
        session.stop_playback();
        let depth = session.undo_depth();
        // Never over footage: with no free video track above the picture a new track goes on top (same undo step).
        if session.add_graphics_clip(None, None, Time::new(seconds, 1), Vec::new(), true).is_none() {
            return;
        }
        g.sync(session);
        let id = g.mapping(session).and_then(|map| {
            let at = map.canvas_point_from_sequence(position);
            let b = box_.map(|b| {
                let d = map.canvas_delta_from_sequence(Vec2::new(b.width, b.height));
                TextBox::new(d.x.abs(), d.y.abs())
            });
            g.add_text_at(session, at, "Text", b)
        });
        let Some(id) = id else {
            session.rewind_undo(depth);
            g.sync(session);
            return;
        };
        // An empty sequence clamped the engine to 0: show the new text now.
        session.seek(session.playhead());
        self.begin_graphic(session, g, id, true, depth, true, None);
    }

    /// Select tool double-click on the picture: edits the Graphic text layer or the text clip under the pointer.
    fn double_click(&mut self, session: &mut EditorSession, editor: Option<&mut GraphicsEditor>, position: Vec2) {
        if self.is_text_editing() {
            return;
        }
        if let Some(g) = editor
            && let Some(hit) = Self::select_graphic_of_text_at(session, g, position)
            && g.clip(session).map(|c| c.id) == Some(hit.clip)
        {
            g.select(session, BTreeSet::from([hit.layer]));
            self.begin_graphic(session, g, hit.layer, false, 0, false, Some(position));
        } else if let Some(id) = Self::text_clip_at(session, position) {
            session.select(BTreeSet::from([id]), BTreeSet::new());
            self.begin_clip(session, id, false, 0, None);
        }
    }

    /// A double-click on a text layer's row in the Graphics panel: the same field a double-click on the text opens, with the
    /// caret at the end (there is no click point on the picture).
    pub fn edit_graphic_text(&mut self, session: &mut EditorSession, editor: Option<&mut GraphicsEditor>, layer: Id) {
        if self.is_text_editing() {
            return;
        }
        if let Some(g) = editor {
            self.begin_graphic(session, g, layer, false, 0, false, None);
        }
    }

    /// Double-click on a caption's text in the monitor: the field opens over it.
    pub fn begin_caption_editing(&mut self, session: &mut EditorSession, position: Vec2) {
        if self.is_text_editing() {
            return;
        }
        let Some(tl) = session.display_timeline() else { return };
        let library = CaptionLookRegistry::shared().library_for_project(session.project());
        let Some(id) = CaptionMonitorHit::caption(position, &tl, session.playhead(), &library) else { return };
        let Some(item) = session.caption_item(id) else { return };
        session.stop_playback();
        session.select(BTreeSet::new(), BTreeSet::from([id]));
        let e = CaptionMonitorHit::edit_target(&item, &tl.format, &library);
        self.text_editing = Some(Box::new(Editing::Caption { id, first: true }));
        self.panel.text_field.sequence_size = CGSize::new(tl.format.display_width() as f64, tl.format.height as f64);
        self.caption_style(&e.style, &e.box_);
        let target = Self::caption_target(id, &e.centre, &e.box_);
        self.panel.text_field.begin(&item.lines.join("\n"), target, false, None);
    }

    fn caption_target(id: Id, centre: &Vec2, box_: &TextBox) -> OverlayTarget {
        OverlayTarget::new(
            id,
            Size::new(box_.width, box_.height),
            true,
            ClipTransform { position: *centre, ..ClipTransform::IDENTITY },
            Vec2::new(0.0, 0.0),
            KeyframeTrack::default(),
        )
    }

    fn caption_style(&mut self, s: &sq_text::text_style::TextStyle, _box: &TextBox) {
        let f = &mut self.panel.text_field;
        f.font_size = s.size;
        f.is_box = true;
        f.line_spacing = s.line_spacing;
        f.alignment = alignment(s.alignment);
    }

    /// A Graphic's text layer under `p` selects that Graphic (when another is selected) and returns the hit.
    fn select_graphic_of_text_at(
        session: &mut EditorSession,
        g: &mut GraphicsEditor,
        p: Vec2,
    ) -> Option<sq_inspector_ui::graphics::editor_text::TextLayerHit> {
        let hit = g.text_layer_hit(session, p)?;
        if g.clip(session).map(|c| c.id) != Some(hit.clip) {
            session.select(BTreeSet::from([hit.clip]), BTreeSet::new());
            g.sync(session);
        }
        Some(hit)
    }

    #[allow(clippy::too_many_arguments)]
    fn begin_graphic(
        &mut self,
        session: &mut EditorSession,
        g: &mut GraphicsEditor,
        id: Id,
        is_new: bool,
        depth: usize,
        select_all: bool,
        caret_at: Option<Vec2>,
    ) {
        g.select(session, BTreeSet::from([id]));
        let Some(clip) = g.clip(session).map(|c| c.id) else { return };
        let (Some(target), Some(template)) = (g.text_edit_target(session, id), g.text_template(session)) else {
            return;
        };
        session.stop_playback();
        g.begin_gesture(session);
        self.text_editing = Some(Box::new(Editing::Graphic { layer: id, clip, is_new, depth }));
        self.open_field(session, &template, target, select_all, caret_at);
    }

    fn begin_clip(&mut self, session: &mut EditorSession, id: Id, is_new: bool, depth: usize, caret_at: Option<Vec2>) {
        let Some(clip) = session.displayed_selected_clip().filter(|c| c.id == id) else { return };
        let Some((template, animations)) = clip.generator.as_ref().and_then(|r| TextGenerator::decode(r).ok()) else {
            return;
        };
        let Some(target) = Self::clip_target(session, &clip) else { return };
        session.stop_playback();
        self.text_editing = Some(Box::new(Editing::Clip(Box::new(ClipEdit {
            id,
            template: template.clone(),
            animations,
            is_new,
            depth,
            first: true,
        }))));
        self.open_field(session, &template, target, false, caret_at);
    }

    fn clip_target(session: &EditorSession, clip: &sq_core_model::Clip) -> Option<OverlayTarget> {
        let tl = session.display_timeline()?;
        OverlayTarget::make(clip, session.project(), &tl, session.playhead(), session.active_variant_id())
    }

    fn open_field(
        &mut self,
        session: &EditorSession,
        template: &TextTemplate,
        target: OverlayTarget,
        select_all: bool,
        caret_at: Option<Vec2>,
    ) {
        if let Some(tl) = session.display_timeline() {
            self.panel.text_field.sequence_size =
                CGSize::new(tl.format.display_width() as f64, tl.format.height as f64);
        }
        self.text_style(template);
        self.panel.text_field.begin(&template.text, target, select_all, caret_at);
    }

    fn text_style(&mut self, t: &TextTemplate) {
        let f = &mut self.panel.text_field;
        f.font_size = t.style.size;
        f.is_box = t.box_.is_some();
        f.line_spacing = t.style.line_spacing;
        f.alignment = alignment(t.style.alignment);
    }

    /// What the field reported since the last call: typing reaches the layer at once, the end folds or discards.
    pub fn pump_text(&mut self, session: &mut EditorSession, mut editor: Option<&mut GraphicsEditor>) {
        for event in std::mem::take(&mut self.panel.text_field.events) {
            match event {
                TextFieldEvent::Edited(text) => self.edited(session, editor.as_deref_mut(), &text),
                TextFieldEvent::Ended(text) => self.ended(session, editor.as_deref_mut(), &text),
                TextFieldEvent::StyleToggle(t) => self.toggle_style(session, editor.as_deref_mut(), t),
            }
        }
    }

    fn edited(&mut self, session: &mut EditorSession, editor: Option<&mut GraphicsEditor>, text: &str) {
        match self.text_editing.as_deref().cloned() {
            Some(Editing::Graphic { layer, clip, .. }) => {
                let Some(g) = editor.filter(|g| g.is_editing_valid(session, layer, clip)) else {
                    self.panel.text_field.end();
                    return;
                };
                g.update_text(session, "Edit Text", None, |t| t.text = text.to_string());
            }
            Some(Editing::Clip(mut e)) => {
                e.template.text = text.to_string();
                session.update_text_clip(e.id, &e.template, e.animations.as_ref(), !e.first);
                e.first = false;
                self.text_editing = Some(Box::new(Editing::Clip(e)));
            }
            Some(Editing::Caption { id, first }) => {
                let _ = first;
                session.set_caption_text(id, text, !first);
                self.text_editing = Some(Box::new(Editing::Caption { id, first: false }));
            }
            None => {}
        }
    }

    fn ended(&mut self, session: &mut EditorSession, editor: Option<&mut GraphicsEditor>, text: &str) {
        let editing = self.text_editing.take().map(|b| *b);
        let empty = text.trim().is_empty();
        match editing {
            Some(Editing::Graphic { layer, clip, is_new, depth }) => {
                let Some(g) = editor else { return };
                g.end_gesture();
                if !is_new || !g.is_editing_valid(session, layer, clip) {
                    return;
                }
                if empty {
                    g.discard_new_layer(session, depth); // an empty new layer leaves no trace
                } else {
                    session.fold_undo(depth, "Add Text");
                }
            }
            Some(Editing::Clip(e)) if e.is_new => {
                if empty {
                    session.discard_text_clip(e.id, Some(e.depth));
                } else {
                    session.fold_undo(e.depth, "Add Text");
                }
            }
            _ => {}
        }
    }

    /// Ctrl+B / Ctrl+I while editing: bold between Bold and Regular, italic on and off, for the whole text.
    fn toggle_style(&mut self, session: &mut EditorSession, editor: Option<&mut GraphicsEditor>, t: StyleToggle) {
        let flip = |s: &mut sq_text::text_style::TextStyle| match t {
            StyleToggle::Bold => {
                use sq_text::text_style::FontWeight;
                s.weight = if s.weight >= FontWeight::Bold { FontWeight::Regular } else { FontWeight::Bold };
            }
            StyleToggle::Italic => s.italic = !s.italic,
        };
        match self.text_editing.as_deref().cloned() {
            Some(Editing::Graphic { layer, clip, .. }) => {
                let Some(g) = editor.filter(|g| g.is_editing_valid(session, layer, clip)) else { return };
                let name = if t == StyleToggle::Bold { "Bold" } else { "Italic" };
                g.update_text(session, name, None, |tpl| flip(&mut tpl.style));
            }
            Some(Editing::Clip(mut e)) => {
                flip(&mut e.template.style);
                session.update_text_clip(e.id, &e.template, e.animations.as_ref(), !e.first);
                e.first = false;
                self.text_editing = Some(Box::new(Editing::Clip(e)));
            }
            // A caption's look is its style preset (Captions panel), not the field.
            _ => {}
        }
    }

    /// Per frame while editing: the field follows the layer (typing grows it, the playhead moves it); a layer that is gone
    /// (undo, another selection) ends the edit.
    pub fn sync_text(&mut self, session: &EditorSession, editor: Option<&GraphicsEditor>) {
        if !self.is_text_editing() {
            return;
        }
        match self.text_editing.as_deref().cloned() {
            Some(Editing::Graphic { layer, clip, .. }) => {
                let Some(g) = editor.filter(|g| g.is_editing_valid(session, layer, clip)) else {
                    self.panel.text_field.end();
                    return;
                };
                let Some(target) = g.text_edit_target(session, layer) else {
                    self.panel.text_field.end();
                    return;
                };
                if let Some(t) = g.text_template(session) {
                    self.text_style(&t);
                }
                self.panel.text_field.retarget(target);
            }
            Some(Editing::Clip(e)) => {
                let target = session
                    .displayed_selected_clip()
                    .filter(|c| c.id == e.id)
                    .and_then(|c| Self::clip_target(session, &c));
                let Some(target) = target else {
                    self.panel.text_field.end();
                    return;
                };
                self.text_style(&e.template);
                self.panel.text_field.retarget(target);
            }
            Some(Editing::Caption { id, .. }) => {
                let (Some(item), Some(tl)) = (session.caption_item(id), session.display_timeline()) else {
                    self.panel.text_field.end();
                    return;
                };
                let library = CaptionLookRegistry::shared().library_for_project(session.project());
                let e = CaptionMonitorHit::edit_target(&item, &tl.format, &library);
                self.caption_style(&e.style, &e.box_);
                self.panel.text_field.retarget(Self::caption_target(id, &e.centre, &e.box_));
            }
            None => self.panel.text_field.end(),
        }
    }
}

fn alignment(a: TextAlignment) -> f64 {
    match a {
        TextAlignment::Left => 0.0,
        TextAlignment::Center => 0.5,
        TextAlignment::Right => 1.0,
    }
}
