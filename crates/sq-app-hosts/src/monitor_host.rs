// Swift: SQAppShell/Monitors/MonitorHost.swift (onPickClip, onSeek, onScrub*)
//! The Program/Source monitor card as an app host: wraps [`MonitorPanel`], runs the events that need only the session
//! (pick a clip, seek, scrub) and queues the rest for the app root ([`MonitorHost::take_deferred`]).

use crate::MonitorPicture;
use crate::analysis_links::eyedropper::Eyedropper;
use crate::analysis_links::magic_flow::MagicFlow;
use crate::analysis_links::matte_tint::MatteTint;
use crate::picture::fit_size;
use sq_app_shell::{AppHost, HostCx};
use sq_core_model::EffectParamKind;
use sq_core_time::{Time, Vec2};
use sq_draw::monitor::monitor_footer::ScrubHit;
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, InputKey, InputModifiers};
use sq_draw_monitor::monitor_panel::{MonitorPanel, PanelEvent};
use sq_draw_monitor::monitor_panel_model::MonitorEvent;
use sq_draw_monitor::point_param_handles::{PointHandle, PointHandleMapping};
use sq_draw_monitor::program_context_menu::ProgramMenuState;
use sq_draw_monitor::text_hit_test::TextHitTest;
use sq_draw_monitor::transform_overlay::OverlayEvent;
use sq_editor_session::EffectSection;
use sq_editor_session::es01_session_core::MaskToolMode;
use sq_editor_session::{Change, EditorSession};
use sq_inspector_ui::ec::effect_controls_model::core::EffectControlsModel;
use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
use sq_inspector_ui::graphics::editor::GraphicsEditor;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::collections::BTreeSet;

/// What the host could not do alone (menus, drags, tools that place text and shapes, engine and format choices).
#[derive(Clone, Debug)]
pub enum MonitorDeferred {
    /// A hook of the card.
    Panel(PanelEvent),
    /// A hook of the card's model.
    Model(MonitorEvent),
}

/// The monitor card in the window.
pub struct MonitorHost {
    /// The card.
    pub panel: MonitorPanel,
    deferred: Vec<MonitorDeferred>,
    picture: Option<MonitorPicture>,
    eyedropper: Option<Eyedropper>,
    magic: Option<MagicFlow>,
    tint: Option<MatteTint>,
    /// Overlay hooks other than the Magic click, for the app root.
    overlay_rest: Vec<OverlayEvent>,
    /// The Dynamic Zoom editor's run (Swift `zoomEditRun`).
    zoom_run: Option<zoom_edit::ZoomRun>,
    /// A media item is open in the Source monitor (enables Reverse Match Frame in the right-click menu).
    source_open: bool,
    /// The stored Subject Mask Edges choice, for the right-click menu check.
    subject_edges: sq_analysis::subject_mask_quality::SubjectMaskQuality,
    /// Where the choice goes for the tracking runs.
    edges_choice: Option<sq_analysis::subject_mask_quality::SubjectEdgesChoice>,
    /// The clip the overlay is on (Swift `overlayTarget`).
    overlay_target: Option<sq_editor_session::OverlayTarget>,
    /// A transform box drag: its target and the transform at the press.
    overlay_gesture: Option<(sq_editor_session::OverlayTarget, sq_core_model::ClipTransform)>,
    /// A text clip's transform box drag: the template and animations at the press, the undo depth, and whether the first
    /// size change is still to come (Swift `textResize`).
    text_resize: Option<TextResize>,
    /// What the on-canvas text field edits (Swift `MonitorTextHost.editing`).
    text_editing: Option<Box<text_edit::Editing>>,
    /// The eyedropper's loupe and the pointer (points) while picking over the picture, and the card it may cover.
    loupe: Option<(sq_draw_monitor::color_loupe::ColorLoupe, CGPoint)>,
    bounds: CGRect,
    /// The clip a mask handle gesture runs on.
    mask_gesture_clip: Option<sq_core_time::Id>,
    /// The timeline's Mask tool mode, `None` while another tool is on.
    mask_tool: Option<MaskToolMode>,
    /// The Color page shows no transform handles over the picture (its own Step window handles stay).
    pub hides_transform_handles: bool,
    /// What the card's layer overlay reads of the Graphics editor and the edits it queued.
    layers: std::rc::Rc<std::cell::RefCell<layer_bridge::LayerBridge>>,
}

/// The text of a clip while its scale handles resize the font (Swift `textResize`).
struct TextResize {
    template: sq_text::text_template::TextTemplate,
    animations: Option<sq_core_model::anchored_animation::AnimationSet>,
    depth: usize,
    first: bool,
}

impl MonitorHost {
    /// A host around `panel`.
    pub fn new(mut panel: MonitorPanel) -> MonitorHost {
        panel.model.wired.full_screen = true;
        panel.wiring.type_tool = true;
        panel.wiring.text_double_click = true;
        panel.captions = Some(Box::new(captions::CaptionPicks::default()));
        let layers = MonitorHost::wire_layer_overlay(&mut panel);
        MonitorHost {
            panel,
            deferred: Vec::new(),
            picture: None,
            eyedropper: None,
            magic: None,
            tint: None,
            overlay_rest: Vec::new(),
            zoom_run: None,
            source_open: false,
            subject_edges: sq_analysis::subject_mask_quality::SubjectMaskQuality::standard(),
            edges_choice: None,
            overlay_target: None,
            overlay_gesture: None,
            text_resize: None,
            text_editing: None,
            loupe: None,
            bounds: CGRect::default(),
            mask_gesture_clip: None,
            mask_tool: None,
            hides_transform_handles: false,
            layers,
        }
    }

    /// Shows the frames put into `picture` on the video quad.
    pub fn with_picture(mut self, picture: MonitorPicture) -> MonitorHost {
        self.picture = Some(picture);
        self
    }

    /// Lets the inspector's eyedropper sample the picture: a press while it is armed picks instead of acting on the monitor.
    pub fn with_eyedropper(mut self, eyedropper: Eyedropper) -> MonitorHost {
        self.eyedropper = Some(eyedropper);
        self
    }

    /// Lets the Magic Mask tool collect its prompt through `flow`: clicks add points, Enter confirms, Escape forgets.
    pub fn with_magic_flow(mut self, flow: MagicFlow) -> MonitorHost {
        self.magic = Some(flow);
        self
    }

    /// Shows the stored mattes of the selected clip's Magic masks over the picture (the Mask Tint).
    pub fn with_matte_tint(mut self, tint: MatteTint) -> MonitorHost {
        self.tint = Some(tint);
        self
    }

    /// The overlay hooks the host did not use, in the order they happened.
    pub fn take_overlay_events(&mut self) -> Vec<OverlayEvent> {
        std::mem::take(&mut self.overlay_rest)
    }

    /// What waits for the app root, in the order it happened.
    pub fn take_deferred(&mut self) -> Vec<MonitorDeferred> {
        std::mem::take(&mut self.deferred)
    }

    /// Keeps the Magic flow in step with the chosen tool and takes its clicks off the overlay.
    fn route_magic(&mut self) {
        let overlay = &mut self.panel.overlay;
        if let Some(flow) = &self.magic {
            flow.arm(overlay.mask_tool == Some(MaskToolMode::Magic));
        }
        let subtract = overlay.magic_subtract;
        let flow = self.magic.as_ref().filter(|f| f.is_armed());
        for event in overlay.take_events() {
            match (event, flow) {
                (OverlayEvent::MaskToolClick(at, keys), Some(flow)) => {
                    flow.click_with(
                        at,
                        subtract != keys.contains(InputModifiers::OPTION),
                        keys.contains(InputModifiers::SHIFT),
                    );
                }
                (OverlayEvent::MaskToolBox(a, b, _), Some(flow)) => flow.drag_box(a, b),
                (other, _) => self.overlay_rest.push(other),
            }
        }
    }

    /// Applies what the rows of the right-click and "..." menus queued and routes the events they raised now: without the
    /// second step a row (Mark In, Add Marker, Show in Source) waited for the next mouse event over the monitor.
    pub fn pump(&mut self, session: &mut EditorSession) {
        self.panel.pump(session);
        self.route(session);
    }

    fn route(&mut self, session: &mut EditorSession) {
        let panel = self.panel.take_events();
        let model = self.panel.model.take_events();
        self.deferred.extend(route_monitor(session, panel, model));
        self.route_zoom_edit(session);
    }
}

/// Select tool click on the Program picture: a Graphic's text layer above the topmost clip selects that Graphic and the
/// layer, else the topmost clip under the pointer (Swift `onPickClip` and `pickGraphicText`).
pub fn pick_clip(session: &mut EditorSession, editor: Option<&mut GraphicsEditor>, p: Vec2) {
    let Some(timeline) = session.display_timeline() else { return };
    let picked = TextHitTest::topmost_visual_clip(
        p,
        &timeline,
        session.project(),
        session.playhead(),
        session.active_variant_id(),
        &|_| true,
    );
    let track = picked.and_then(|id| timeline.tracks.iter().position(|t| t.clips().iter().any(|c| c.id == id)));
    if let Some(editor) = editor
        && let Some(hit) = editor.text_layer_hit(session, p)
        && TextHitTest::hit_wins(hit.track_index, track, &timeline.tracks)
    {
        session.select(BTreeSet::from([hit.clip]), BTreeSet::new());
        editor.sync(session);
        editor.select(session, BTreeSet::from([hit.layer]));
        return;
    }
    if let Some(id) = picked {
        session.select(BTreeSet::from([id]), BTreeSet::new());
    }
}

/// Runs the events that need only the session and returns the rest (Swift `onPickClip`, `onSeek`, `onScrub*`).
pub fn route_monitor(
    session: &mut EditorSession,
    panel: Vec<PanelEvent>,
    model: Vec<MonitorEvent>,
) -> Vec<MonitorDeferred> {
    let mut deferred = Vec::new();
    // Every card event waits for the root; the Select tool's click needs the Graphics editor (`pick_clip`).
    deferred.extend(panel.into_iter().map(MonitorDeferred::Panel));
    for event in model {
        match event {
            MonitorEvent::Seek(t) => session.seek(t),
            MonitorEvent::ScrubBegan => session.begin_scrub(),
            MonitorEvent::Scrub(t) => session.scrub(t),
            MonitorEvent::ScrubEnded => session.end_scrub(),
            // Swift `MonitorHost` init: the strip's grips set the marks (the strip reports the stored end,
            // one frame past Out), the quality popup and the Auto governor reach the engine, "..." > Playback Speed the session.
            MonitorEvent::MarkEdit(end, t) => {
                let fd = session.active_timeline().map_or(Time::new(1001, 30000), |t| t.frame_duration());
                match end {
                    ScrubHit::MarkIn => session.set_in_point(t),
                    ScrubHit::MarkOut => session.set_out_point(t - fd),
                    ScrubHit::Playhead => {}
                }
            }
            MonitorEvent::QualityChange(q) => {
                session.engine_mut().set_quality(q.decode_scale());
                // The root saves a hand pick as the Default Quality.
                deferred.push(MonitorDeferred::Model(MonitorEvent::QualityChange(q)));
            }
            MonitorEvent::PreviewRateChange(r) => session.set_preview_rate(r),
            // Read from the card's model each frame (safe zones in `sync_overlay`); Swift sets no hook for these on the
            // Program monitor (`onZoomChange`, `onTransparencyGridChange`, `onDragEnded`, the drop and pick hooks are the
            // Source card's).
            MonitorEvent::SafeZoneChange(_)
            | MonitorEvent::ZoomChange(_)
            | MonitorEvent::TransparencyGridChange(_)
            | MonitorEvent::DragEnded => {}
            other => deferred.push(MonitorDeferred::Model(other)),
        }
    }
    deferred
}

impl MonitorHost {
    /// Per frame: the selected picture clip under the playhead drives the transform box (not while playing, not on a
    /// Color solo view; a running drag keeps its own live transform). Swift: MonitorHost.swift:370 `syncOverlay`.
    /// `fx`: the Effect Controls model, which owns the point handles, the mask outlines, the selected key, the Scale link
    /// and the Crop section (Swift `effects`); without it (a host alone) those stay as they are.
    fn sync_overlay(&mut self, session: &EditorSession, fx: Option<&EffectControlsModel>) {
        if self.panel.overlay.is_dragging() {
            return;
        }
        let safe_margins = self.panel.model.safe_margins();
        let zone = Some(self.panel.model.safe_zone());
        let found = if session.is_playing() || session.color_solo_clip().is_some() || self.hides_transform_handles {
            None
        } else {
            session.display_timeline().zip(session.displayed_selected_clip()).and_then(|(tl, clip)| {
                // Swift `fx.clip?.id == clip.id`: the model must show the selected clip.
                if fx.is_some_and(|m| m.clip().map(|c| c.id) != Some(clip.id)) {
                    return None;
                }
                let t = sq_editor_session::OverlayTarget::make(
                    &clip,
                    session.project(),
                    &tl,
                    session.playhead(),
                    session.active_variant_id(),
                )?;
                Some((tl, t))
            })
        };
        self.overlay_target = found.as_ref().map(|(_, t)| t.clone());
        let o = &mut self.panel.overlay;
        o.mask_tool = self.mask_tool;
        match found {
            None => {
                o.is_shown = false;
                if fx.is_some() {
                    o.point_handles = Vec::new();
                    o.masks = Vec::new();
                }
            }
            Some((tl, t)) => {
                if let Some(m) = fx {
                    o.masks = m.mask_overlays();
                    o.point_handles = point_handles(m, &t);
                    o.selected_key = m.selected_key_ids(&EffectProperty::Position).first().copied();
                    o.uniform_scale = m.uniform_scale;
                }
                o.is_shown = true;
                o.sequence_size =
                    sq_uikit::controls_grid::CGSize::new(tl.format.display_width() as f64, tl.format.height as f64);
                o.media_pixel_size = Some(sq_uikit::controls_grid::CGSize::new(t.size.width, t.size.height));
                o.transform = t.display_transform();
                o.position_track = t.position_track.clone();
                // Snap targets: canvas center and edges, the safe frames, the platform zone and the other layers' bounds
                // (Swift `syncOverlay`; Safe Margins draw their own frames, so the overlay draws none).
                let canvas = sq_uikit::keyframe_graph_geometry::Size::new(
                    f64::from(tl.format.display_width() as i32),
                    tl.format.height as f64,
                );
                let others: Vec<_> = tl
                    .tracks
                    .iter()
                    .filter(|tr| tr.kind == sq_core_model::TrackKind::Video && tr.is_visible)
                    .flat_map(|tr| tr.clips().iter())
                    .filter(|c| c.id != t.clip)
                    .filter_map(|c| {
                        sq_editor_session::OverlayTarget::make(
                            c,
                            session.project(),
                            &tl,
                            session.playhead(),
                            session.active_variant_id(),
                        )
                    })
                    .collect();
                let bounds = sq_editor_session::SnapGuides::other_bounds(&others);
                let areas: &[sq_editor_session::SafeArea] = if safe_margins {
                    &[sq_editor_session::SafeArea::Action, sq_editor_session::SafeArea::Title]
                } else {
                    &[]
                };
                let zone = zone.and_then(|z| z.norm_rect(canvas.width / canvas.height.max(1.0))).map(|n| {
                    sq_uikit::keyframe_graph_geometry::Rect::new(
                        (n.x - 0.5) * canvas.width,
                        (n.y - 0.5) * canvas.height,
                        n.width * canvas.width,
                        n.height * canvas.height,
                    )
                });
                o.snap_targets = Some(sq_editor_session::SnapGuides::targets(canvas, &bounds, areas, zone));
                o.neighbor_bounds = bounds;
                o.safe_areas = Vec::new();
                o.crop_insets = match fx {
                    Some(m) => crop_section(m).and_then(|_| crop_insets(&m.clip().cloned(), session.playhead())),
                    None => crop_insets(&session.displayed_selected_clip(), session.playhead()),
                };
            }
        }
    }
}

/// Point parameters of the shown clip's enabled effects (Swift `pointHandles`): offsets from the canvas center through the
/// clip's transform; Corner Warp only while its section is selected.
fn point_handles(fx: &EffectControlsModel, target: &sq_editor_session::OverlayTarget) -> Vec<PointHandle> {
    let Some(clip) = fx.clip() else { return Vec::new() };
    let transform = target.display_transform();
    let mut handles = Vec::new();
    for e in clip.effects.iter().filter(|e| e.enabled) {
        let Some(spec) = sq_core_model::EffectCatalog::spec_for(&e.kind) else { continue };
        for p in &spec.params {
            if !matches!(p.kind, EffectParamKind::Point(_)) || !PointHandleMapping::has_handle(&e.kind, &p.key) {
                continue;
            }
            let prop = EffectProperty::Fx { id: e.id, kind: e.kind.clone(), key: p.key.clone() };
            let mut v = fx.vector_value(&prop);
            if PointHandleMapping::is_corner_offset(&e.kind) {
                let selected = matches!(&fx.selected_section, Some(EffectSection::Effect { id, .. }) if *id == e.id);
                if !selected {
                    continue;
                }
                v = PointHandleMapping::corner_local(&p.key, v, CGSize::new(target.size.width, target.size.height));
            }
            handles.push(PointHandle {
                id: format!("{}|{}", e.id, p.key),
                offset: PointHandleMapping::offset(&e.kind, v, &transform),
            });
        }
    }
    handles
}

/// The Crop effect while its section is selected and enabled (its edge handles replace the scale handles).
fn crop_section(fx: &EffectControlsModel) -> Option<sq_core_time::Id> {
    let Some(EffectSection::Effect { id, kind }) = &fx.selected_section else { return None };
    (kind == sq_core_model::ClipEffect::CROP_KIND).then_some(())?;
    fx.clip()?.effects.iter().find(|e| e.id == *id && e.enabled).map(|e| e.id)
}

/// The selected clip's Crop effect as fractions of the picture (Swift `cropSection` / `cropInsets`), `None` without one.
fn crop_insets(
    clip: &Option<sq_core_model::Clip>,
    playhead: sq_core_time::Time,
) -> Option<sq_core_effects::effects_evaluation::CropInsets> {
    use sq_core_model::ClipEffect;
    let clip = clip.as_ref()?;
    let fx = clip.effects.iter().find(|e| e.kind == ClipEffect::CROP_KIND && e.enabled)?;
    let local = playhead - clip.start;
    let v = |key: &str| fx.parameters.get(key).map_or(0.0, |p| p.value_at_local(local)) / 100.0;
    Some(sq_core_effects::effects_evaluation::CropInsets {
        left: v(ClipEffect::CROP_LEFT_KEY),
        top: v(ClipEffect::CROP_TOP_KEY),
        right: v(ClipEffect::CROP_RIGHT_KEY),
        bottom: v(ClipEffect::CROP_BOTTOM_KEY),
    })
}

/// What the Program right-click menu needs (Swift `programMenuItems`: In/Out, the clip kind, its masks, picture tracks).
fn menu_state(
    session: &EditorSession,
    fx: &EffectControlsModel,
    source_open: bool,
    edges: sq_analysis::subject_mask_quality::SubjectMaskQuality,
) -> ProgramMenuState {
    let clip = fx.clip();
    let mask_clip = clip.is_some_and(|c| c.kind == sq_core_model::TrackKind::Video);
    let default = fx.default_picture_track();
    let picture_tracks = if mask_clip {
        fx.picture_track_choices()
            .into_iter()
            .filter(|c| c.track.is_some())
            .map(|c| (c.track, c.title, c.track == default))
            .collect()
    } else {
        Vec::new()
    };
    ProgramMenuState {
        has_in_out: session.active_timeline().is_some_and(|t| t.in_out.is_some()),
        mask_clip,
        has_masks: clip.is_some_and(|c| !sq_core_masks::masks::ClipMasksExt::masks(c).is_empty()),
        has_source: source_open,
        subject_mask_enabled: session.add_subject_mask_enabled(),
        picture_tracks,
        subject_edges: sq_analysis::subject_mask_quality::SubjectMaskQuality::ALL
            .iter()
            .map(|q| (q.title().to_string(), q.help().to_string(), *q == edges))
            .collect(),
    }
}

impl MonitorHost {
    /// Sets the stored Subject Mask Edges choice the right-click menu checks.
    pub fn set_subject_edges(&mut self, q: sq_analysis::subject_mask_quality::SubjectMaskQuality) {
        self.subject_edges = q;
        if let Some(choice) = &self.edges_choice {
            choice.set(q);
        }
    }

    /// Hands the stored Subject Mask Edges choice on to the tracking runs.
    pub fn with_subject_edges(mut self, choice: sq_analysis::subject_mask_quality::SubjectEdgesChoice) -> MonitorHost {
        choice.set(self.subject_edges);
        self.edges_choice = Some(choice);
        self
    }

    /// Tells the host whether the Source monitor shows a media item.
    pub fn set_source_open(&mut self, open: bool) {
        self.source_open = open;
    }

    /// [`AppHost::sync`] with the Effect Controls model, so the overlay shows point handles and mask outlines.
    pub fn sync_with(&mut self, session: &EditorSession, fx: &EffectControlsModel) {
        self.panel.sync(session);
        self.panel.model.context_menu =
            self.panel.model.program_context_menu(&menu_state(session, fx, self.source_open, self.subject_edges));
        self.refresh_dynamic_zoom_edit(session);
        self.sync_overlay(session, Some(fx));
    }
}

impl AppHost for MonitorHost {
    fn sync(&mut self, session: &EditorSession) {
        self.panel.sync(session);
        self.refresh_dynamic_zoom_edit(session);
        self.sync_overlay(session, None);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.bounds = frame;
        if let Some(tint) = &mut self.tint {
            let on = self.panel.model.shows_mask_tint() && tint.update(cx.session);
            self.panel.overlay.mask_tint_slot = on.then_some(tint.slot());
        }
        let sequence = cx.session.active_timeline().map(|t| (t.format.display_width(), t.format.height));
        let picture = self.picture.as_ref().and_then(MonitorPicture::size);
        if let Some(size) = fit_size(sequence, picture) {
            self.panel.set_sequence_size(size);
        }
        self.panel.layout(frame, cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        if let Some(p) = &self.picture {
            self.panel.has_picture = p.size().is_some();
        }
        self.panel.draw(c, t, cx);
        if self.eyedropper.as_ref().is_some_and(Eyedropper::is_armed)
            && let Some((loupe, pointer)) = &self.loupe
        {
            loupe.draw(c, *pointer, self.bounds, t);
        }
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.update_loupe(e);
        if let (InputEvent::MouseDown { x, y, .. }, Some(dropper)) = (e, &self.eyedropper)
            && dropper.is_armed()
        {
            let picture = self.picture.as_ref().and_then(MonitorPicture::get);
            if dropper.offer(picture.as_deref(), self.panel.canvas_rect(), f64::from(*x), f64::from(*y)) {
                return true;
            }
        }
        if let (InputEvent::KeyDown { key, .. }, Some(flow)) = (e, &self.magic)
            && flow.is_armed()
            && !flow.points().is_empty()
        {
            match key {
                InputKey::Enter => flow.confirm(),
                InputKey::Escape => flow.cancel(),
                _ => {}
            }
            if matches!(key, InputKey::Enter | InputKey::Escape) {
                return true;
            }
        }
        let taken = self.panel.handle(e, cx);
        self.route_magic();
        self.route(cx.session);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        self.panel.a11y(a);
        self.push_nodes(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: sq_app_shell::A11yAction, cx: &mut HostCx) -> bool {
        self.run_action(id, action, cx)
    }

    fn take_image_uploads(&mut self) -> Vec<sq_app_shell::ImageUpload> {
        self.tint.iter_mut().filter_map(MatteTint::take_upload).collect()
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.panel.on_change(changes, cx);
        self.route(cx.session);
    }
}

impl MonitorHost {
    /// While the eyedropper waits, the pointer over the picture shows the loupe around the pixel under it (Swift
    /// `ColorPageHost.handle(.mouseMoved)`); a press or leaving the picture hides it.
    fn update_loupe(&mut self, e: &InputEvent) {
        let armed = self.eyedropper.as_ref().is_some_and(Eyedropper::is_armed);
        match e {
            InputEvent::MouseMoved { x, y } if armed => {
                let r = self.panel.canvas_rect();
                let (px, py) = (f64::from(*x), f64::from(*y));
                let picture = self.picture.as_ref().and_then(MonitorPicture::get);
                self.loupe = picture.filter(|_| r.contains(CGPoint::new(px, py))).and_then(|img| {
                    let (u, v) = ((px - r.x) / r.width.max(1.0), (py - r.y) / r.height.max(1.0));
                    crate::analysis_links::eyedropper::loupe(&img, u, v).map(|l| (l, CGPoint::new(px, py)))
                });
            }
            InputEvent::MouseMoved { .. } | InputEvent::MouseDown { .. } | InputEvent::KeyDown { .. } => {
                self.loupe = None
            }
            _ => {}
        }
    }
}

mod access;
mod captions;
pub mod create_tool;
mod layer_bridge;
mod overlay_edits;
mod step_window;
mod text_edit;
mod zoom_edit;

#[cfg(test)]
mod tests;
