// Swift: SQAppShell/Monitors/MonitorHost.swift (attachOverlay, pointHandleDrag, overlayTransform, maskGesture)
//! What the picture's handles do to Effect Controls: the transform box, the motion path, the Crop edges, the point
//! handles and the mask outlines. Each drag is one gesture of the model, so it is one undo step.

use super::{MonitorHost, TextResize, crop_section};
use sq_core_model::ClipEffect;
use sq_core_time::Id;
use sq_draw::monitor::crop_handle_geometry::CropEdge;
use sq_draw_monitor::mask_handle_edit::MaskHandleEdit;
use sq_draw_monitor::point_param_handles::PointHandleMapping;
use sq_draw_monitor::transform_overlay::{OverlayEvent, Phase};
use sq_editor_session::EditorSession;
use sq_editor_session::es01_session_core::MaskToolMode;
use sq_inspector_ui::ec::effect_controls_model::core::EffectControlsModel;
use sq_inspector_ui::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
use sq_text::text_generator::TextGenerator;
use sq_text::text_template::TextTemplate;
use sq_text::text_template_resize::TextTemplateResizeExt;
use sq_uikit::controls_grid::CGSize;

impl MonitorHost {
    /// The Mask tool the overlay offers (the timeline's Mask tool and its mode; `None` for any other tool).
    pub fn set_mask_tool(&mut self, tool: Option<MaskToolMode>) {
        self.mask_tool = tool;
    }

    /// The timeline's Hand tool: a drag on the Program picture pans the zoomed picture and a double-click fits it (Swift
    /// `handToolOn`). Nothing else sets the flag, so without this call the Hand tool never reached the monitor.
    pub fn set_hand_tool(&mut self, on: bool) {
        self.panel.hand_tool_on = on;
    }

    /// The timeline's Create tool and its mode (`None` for any other tool): a drag on the picture then makes a shape or a
    /// stroke (`PanelEvent::CreateShape` / `CreateStroke`, answered by the root). Swift `createModeNow`.
    pub fn set_create_tool(&mut self, mode: Option<sq_editor_session::CreateToolMode>) {
        self.panel.wiring.create_tool = true;
        self.panel.create_mode_now = mode;
        // The Type tool in its Text mode places text; the other modes draw items.
        self.set_type_tool(mode == Some(sq_editor_session::CreateToolMode::Text));
    }

    /// True when Effect Controls shows the clip the overlay is on (Swift `fx.clip?.id == overlayTarget?.clip`).
    fn shows_target(&self, fx: &EffectControlsModel) -> bool {
        self.overlay_target.as_ref().is_some_and(|t| fx.clip().map(|c| c.id) == Some(t.clip))
    }

    /// Applies the overlay hooks the host did not use to `fx`; the caller routes the model's edits to the session
    /// afterwards. Returns the status lines.
    pub fn apply_overlay_events(&mut self, session: &mut EditorSession, fx: &mut EffectControlsModel) -> Vec<String> {
        let mut status = Vec::new();
        for event in std::mem::take(&mut self.overlay_rest) {
            match event {
                OverlayEvent::Transform(phase, t) => self.overlay_transform(session, fx, phase, &t),
                OverlayEvent::PathEdit(phase, edit) => {
                    if !self.shows_target(fx) {
                        continue;
                    }
                    match phase {
                        Phase::Began => fx.begin_gesture(),
                        Phase::Changed => fx.edit_position_key(edit.key, edit.position, edit.tangents),
                        Phase::Ended => {
                            fx.edit_position_key(edit.key, edit.position, edit.tangents);
                            fx.end_gesture();
                        }
                    }
                }
                OverlayEvent::Crop(phase, edge, fraction) => self.crop(fx, phase, edge, fraction),
                OverlayEvent::PointHandle(phase, id, offset) => {
                    self.point_handle(session, fx, phase, &id, offset);
                }
                OverlayEvent::DragCanceled => {
                    fx.cancel_gesture();
                    self.overlay_gesture = None;
                    self.mask_gesture_clip = None;
                }
                OverlayEvent::MaskVertex(phase, id, index, point) => {
                    self.mask_gesture(session, fx, phase, id, true, &mut status, |fx| {
                        fx.move_mask_vertex(id, index, point);
                    });
                }
                OverlayEvent::MaskEdit(phase, edit) => {
                    let id = edit.mask_id();
                    self.mask_gesture(session, fx, phase, id, edit.edits_at_playhead(), &mut status, |fx| {
                        apply_mask_edit(&edit, fx);
                    });
                }
                OverlayEvent::MaskSelect(id) => {
                    if self.shows_target(fx) {
                        fx.select_mask(id);
                    }
                }
                OverlayEvent::MaskShapeDrawn(kind, path) => {
                    session.stop_playback();
                    if fx.playhead_in_clip() {
                        fx.add_drawn_mask(kind, path);
                    } else {
                        status.push("Put the playhead on the clip to draw a mask there.".to_string());
                    }
                }
                OverlayEvent::MaskToolClick(p, keys) => {
                    let Some(mode) = self.mask_tool else { continue };
                    session.stop_playback();
                    if mode == MaskToolMode::Magic {
                        status.push("Magic masks are not available here: use Pen, Ellipse or Rectangle.".to_string());
                    } else if fx.playhead_in_clip() {
                        fx.mask_tool_click(
                            mode,
                            p,
                            keys.contains(sq_draw::InputModifiers::OPTION),
                            keys.contains(sq_draw::InputModifiers::SHIFT),
                        );
                    } else {
                        status.push("Put the playhead on the clip to draw a mask there.".to_string());
                    }
                }
                OverlayEvent::MaskToolHover(_) | OverlayEvent::MaskToolBox(..) => {}
            }
        }
        status
    }

    /// One transform box gesture (Swift `overlayTransform`).
    /// A text clip's scale handles change its font size (sequence px) and keep Scale; the drag folds into one
    /// "Resize Text" step.
    fn overlay_transform(
        &mut self,
        session: &mut EditorSession,
        fx: &mut EffectControlsModel,
        phase: Phase,
        t: &sq_core_model::ClipTransform,
    ) {
        if phase == Phase::Began {
            let Some(target) = self.overlay_target.clone().filter(|t| fx.clip().map(|c| c.id) == Some(t.clip)) else {
                return;
            };
            session.stop_playback();
            self.text_resize = None;
            if target.is_text && !target.is_graphics {
                let generator =
                    session.displayed_selected_clip().and_then(|c| c.generator).filter(|g| g.kind == "text");
                if let Some((template, animations)) = generator.and_then(|g| TextGenerator::decode(&g).ok()) {
                    self.text_resize =
                        Some(TextResize { template, animations, depth: session.undo_depth(), first: true });
                }
            }
            self.overlay_gesture = Some((target, *t));
            fx.begin_gesture();
            return;
        }
        let Some((target, start)) = self.overlay_gesture.clone() else { return };
        let mut t = *t;
        if let Some(r) = self.text_resize.as_mut()
            && t.scale != start.scale
        {
            let ratio = TextTemplate::resize_factor(start.scale, t.scale);
            session.update_text_clip(target.clip, &r.template.resized(ratio), r.animations.as_ref(), !r.first);
            r.first = false;
            t.scale = start.scale;
        }
        let wrote =
            fx.set_transform(&target.base_transform_from_display(&t), &target.base_transform_from_display(&start));
        // animated and the playhead outside the clip: nothing to write, end here
        if !wrote || phase == Phase::Ended {
            fx.end_gesture();
            self.overlay_gesture = None;
            if phase == Phase::Ended
                && let Some(r) = &self.text_resize
                && !r.first
                && session.undo_depth() > r.depth + 1
            {
                session.fold_undo(r.depth, "Resize Text");
            }
            self.text_resize = None;
        }
    }

    fn crop(&mut self, fx: &mut EffectControlsModel, phase: Phase, edge: CropEdge, fraction: f64) {
        if !self.shows_target(fx) {
            return;
        }
        let Some(crop) = crop_section(fx) else { return };
        if phase == Phase::Began {
            fx.begin_gesture();
            return;
        }
        let prop = EffectProperty::Fx {
            id: crop,
            kind: ClipEffect::CROP_KIND.to_string(),
            key: edge.effect_key().to_string(),
        };
        fx.set_value(&prop, EffectComponent::All, fraction * 100.0);
        if phase == Phase::Ended {
            fx.end_gesture();
        }
    }

    /// A point handle drag writes the value at the playhead, one undo step per gesture (Swift `pointHandleDrag`).
    fn point_handle(
        &mut self,
        session: &mut EditorSession,
        fx: &mut EffectControlsModel,
        phase: Phase,
        id: &str,
        offset: sq_core_time::Vec2,
    ) {
        let Some(target) = self.overlay_target.clone().filter(|t| fx.clip().map(|c| c.id) == Some(t.clip)) else {
            return;
        };
        let Some((effect, key)) = id.split_once('|') else { return };
        let Some((eid, kind)) = fx
            .clip()
            .and_then(|c| c.effects.iter().find(|e| e.id.to_string() == effect).map(|e| (e.id, e.kind.clone())))
        else {
            return;
        };
        if phase == Phase::Began {
            session.stop_playback();
            fx.begin_gesture();
            return;
        }
        let transform = target.display_transform();
        let mut local = PointHandleMapping::local(&kind, offset, &transform);
        if PointHandleMapping::is_corner_offset(&kind) {
            local = PointHandleMapping::corner_value(key, local, CGSize::new(target.size.width, target.size.height));
        }
        fx.set_vector(&EffectProperty::Fx { id: eid, kind, key: key.to_string() }, local);
        if phase == Phase::Ended {
            fx.end_gesture();
        }
    }

    /// One mask handle gesture: refused up front for an animated path while the playhead is outside the clip, else one
    /// undo step from `Began` to `Ended` (Swift `maskGesture`).
    #[allow(clippy::too_many_arguments)] // the gesture's context travels as it does in Swift's closure
    fn mask_gesture(
        &mut self,
        session: &mut EditorSession,
        fx: &mut EffectControlsModel,
        phase: Phase,
        id: Id,
        needs_playhead: bool,
        status: &mut Vec<String>,
        edit: impl Fn(&mut EffectControlsModel),
    ) {
        match phase {
            Phase::Began => {
                self.mask_gesture_clip = None;
                let Some(clip) = fx.clip().map(|c| c.id) else { return };
                if Some(clip) != self.overlay_target.as_ref().map(|t| t.clip) {
                    return;
                }
                if needs_playhead && fx.mask_edit_needs_playhead(id) {
                    status.push("Put the playhead on the clip to edit an animated mask path there.".to_string());
                    return;
                }
                self.mask_gesture_clip = Some(clip);
                session.stop_playback();
                fx.begin_gesture();
            }
            Phase::Changed => {
                if self.mask_gesture_clip.is_some() && self.mask_gesture_clip == fx.clip().map(|c| c.id) {
                    edit(fx);
                }
            }
            Phase::Ended => {
                let Some(started) = self.mask_gesture_clip.take() else { return };
                if Some(started) == fx.clip().map(|c| c.id) {
                    edit(fx);
                }
                fx.end_gesture();
            }
        }
    }
}

/// Swift `MonitorHost.apply(_:to:)`.
fn apply_mask_edit(edit: &MaskHandleEdit, fx: &mut EffectControlsModel) {
    match *edit {
        MaskHandleEdit::Tangent { mask, vertex, out, offset, independent } => {
            fx.move_mask_tangent(mask, vertex, out, offset, independent);
        }
        MaskHandleEdit::Move { mask, delta } => fx.move_mask(mask, delta),
        MaskHandleEdit::Insert { mask, segment, t } => fx.insert_mask_vertex(mask, segment, t),
        MaskHandleEdit::Pen { mask, segment, t, handle, independent } => {
            fx.place_mask_vertex(mask, segment, t, handle, independent);
        }
        MaskHandleEdit::Remove { mask, vertex } => fx.remove_mask_vertex(mask, vertex),
        MaskHandleEdit::ToggleSmooth { mask, vertex } => fx.toggle_mask_vertex_smooth(mask, vertex),
    }
}
